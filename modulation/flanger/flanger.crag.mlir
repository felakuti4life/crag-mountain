// Flanger
//
// A flanger creates a sweeping, jet-like comb-filter effect by mixing the dry
// signal with a very short, LFO-modulated delay of itself.  When the two
// signals interact, constructive and destructive interference produces evenly
// spaced peaks and notches that sweep up and down in frequency as the delay
// time varies.  An adjustable feedback path feeds a scaled copy of the wet
// output back into the buffer, deepening the notches and adding resonance.
//
// Algorithm (per block):
//   1. Push the dry input into the circular buffer.
//   2. Compute the LFO-modulated delay time:
//        D = center_ms · sr/1000 + depth_ms · sr/1000 · sin(2π · rate · t)
//   3. Clamp D into the safe range [blockSize, maxSize] so the peek offset
//      stays within the buffer.  Without this clamp the typical flanger
//      parameter range — center_ms ≈ 1 ms, depth_ms ≈ 1 ms — yields
//      delays at or below the block size, the peek offset overflows the
//      strict-bounds invariant and the read wraps to give very loud
//      artifacts.  `crag.block_size` is used so the lower bound tracks
//      the host block size automatically.
//   4. Peek (non-destructive read) at offset = maxSize - D from buffer head.
//   5. Mix with feedback from the previous block:
//        wet[n] = peeked[n] + feedback · prev_wet[n]
//        (prev_wet is stored in a second delay_line of length 1 block)
//   6. Output: out = dry · in + wet_level · wet
//
// Buffer parameters (at 48 kHz) — modulatable-delay form (delaySize, maxSize):
//   delaySize = 48   samples — nominal centre delay (1 ms) for periodicity
//                              analysis and run-time estimates.
//   maxSize   = 2400 samples — actual allocated buffer (50 ms) sized to hold
//                              the worst-case modulated delay (max_center +
//                              max_depth = 15 ms = 720 samples) plus
//                              comfortable block-size headroom.
// At 48 kHz, parameter ranges produce delays in:
//   center_ms ∈ [0.5, 10] → [24, 480] samples
//   depth_ms  ∈ [0.1, 5]  → [4.8, 240] samples
//   delay     = center ± depth → [-216, 720] samples (pre-clamp)
//                              → [blockSize, 720]    (post-clamp)
//
// Parameters:
//   rate       [0.05, 5]   – LFO frequency in Hz           (default 0.3)
//   depth_ms   [0.1, 5]    – modulation depth in ms        (default 1.0)
//   center_ms  [0.5, 10]   – base (centre) delay in ms     (default 1.0)
//   feedback   [-0.9, 0.9] – feedback gain (negative = phase-inverted)
//                                                           (default 0.5)
//   wet_level  [0, 1]      – wet/flange mix amplitude      (default 0.7)
//   dry_level  [0, 1]      – dry pass-through amplitude    (default 0.7)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "flanger"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/modulation/flanger.crag.mlir" as "flanger"

module {
  crag.graph name = "flanger" sample_rate = 48000 channels = 1
      default_visualizer = "phase-correlation" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %rate      = crag.param "rate"      min = 0.05 max = 5.0  default = 0.3  : f32
    %depth_ms  = crag.param "depth_ms"  min = 0.1  max = 5.0  default = 1.0  : f32
    %center_ms = crag.param "center_ms" min = 0.5  max = 10.0 default = 1.0  : f32
    %feedback  = crag.param "feedback"  min = -0.9 max = 0.9  default = 0.5  : f32
    %wet_level = crag.param "wet_level" min = 0.0  max = 1.0  default = 0.7  : f32
    %dry_level = crag.param "dry_level" min = 0.0  max = 1.0  default = 0.7  : f32

    // -----------------------------------------------------------------------
    // Circular delay buffer for the main signal — modulatable-delay form:
    //   delaySize = 48   — nominal 1 ms reading depth for timing analysis.
    //   maxSize   = 2400 — actual 50 ms backing buffer for the LFO swing
    //                       plus block-size headroom.
    // Feedback delay line: stores one block of the wet output so it can be
    // mixed back in on the next block.
    // -----------------------------------------------------------------------
    %dl  = crag.delay_line : !crag.delay<f32, 48000, 1, 48, 2400>
    %fbl = crag.delay_line : !crag.delay<f32, 48000, 1, 512>

    // -----------------------------------------------------------------------
    // Read previous feedback (before pushing current input)
    // -----------------------------------------------------------------------
    %prev_wet = crag.pop_delay %fbl : !crag.delay<f32, 48000, 1, 512>
                    -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Push the dry input into the circular buffer
    // -----------------------------------------------------------------------
    crag.push_delay %dl, %in : !crag.delay<f32, 48000, 1, 48, 2400>,
                                !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // LFO
    // -----------------------------------------------------------------------
    %sr       = arith.constant 48000.0 : f32
    %two_pi   = arith.constant 6.28318530 : f32
    %ms_scale = arith.constant 0.001 : f32
    %buf_f    = arith.constant 2400.0 : f32   // maxSize as f32

    // Block size as f32 — used as the lower clamp for the modulated delay
    // so the peek offset stays within [0, maxSize - blockSize].
    %bs_i64 = crag.block_size : i64
    %bs_i32 = arith.trunci %bs_i64 : i64 to i32
    %bs_f   = arith.sitofp %bs_i32 : i32 to f32

    %t_f64 = crag.curtime : f64
    %t_f32 = arith.truncf %t_f64 : f64 to f32
    %omega = arith.mulf %two_pi, %rate : f32
    %phase = arith.mulf %omega, %t_f32 : f32
    %lfo   = math.sin %phase : f32

    // -----------------------------------------------------------------------
    // Compute modulated delay in samples and offset from head.
    //
    //   delay_samp  = center_samp + depth_samp · lfo
    //   delay_clamp = clamp(delay_samp, blockSize, maxSize)
    //   offset      = (int)(maxSize - delay_clamp)
    //
    // The clamp guarantees offset ∈ [0, maxSize - blockSize] regardless of
    // parameter combination.
    // -----------------------------------------------------------------------
    %sr_ms       = arith.mulf %sr, %ms_scale : f32
    %center_samp = arith.mulf %center_ms, %sr_ms : f32
    %depth_samp  = arith.mulf %depth_ms,  %sr_ms : f32
    %mod         = arith.mulf %depth_samp, %lfo : f32
    %delay_samp  = arith.addf %center_samp, %mod : f32
    %delay_lo    = arith.maximumf %delay_samp, %bs_f : f32
    %delay_c     = arith.minimumf %delay_lo,   %buf_f : f32
    %off_f       = arith.subf %buf_f, %delay_c : f32
    %off         = arith.fptosi %off_f : f32 to i32

    // -----------------------------------------------------------------------
    // Peek at the modulated offset
    // -----------------------------------------------------------------------
    %peeked = crag.peek_delay %dl, %off : !crag.delay<f32, 48000, 1, 48, 2400>, i32
                  -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Add feedback: wet = peeked + feedback · prev_wet
    // -----------------------------------------------------------------------
    %fb_sig = crag.scale %prev_wet, %feedback : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>
    %wet    = crag.sum %peeked, %fb_sig
                  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                    -> !crag.audio<f32, 0, 0>

    // Store this block's wet signal for next-block feedback
    crag.push_delay %fbl, %wet : !crag.delay<f32, 48000, 1, 512>,
                                  !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Wet/dry mix
    // -----------------------------------------------------------------------
    %dry_sc = crag.scale %in,  %dry_level : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>
    %wet_sc = crag.scale %wet, %wet_level : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>
    %output = crag.sum %dry_sc, %wet_sc
                  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                    -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
