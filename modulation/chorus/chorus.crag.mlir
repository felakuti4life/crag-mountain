// Stereo Chorus
//
// Classic dual-voice chorus effect using two independent LFO-modulated delay
// taps, one per stereo channel.  A second LFO slightly offset in phase drives
// the right channel tap, producing a wide, spacious stereo image.
//
// Algorithm:
//   For each channel (L and R):
//     1. Push the dry mono input into a shared circular buffer.
//     2. Compute LFO: lfo(t) = sin(2π · rate · t + phase_offset)
//     3. Compute modulated delay (in samples):
//          D = center_ms · sr / 1000 + depth_ms · sr / 1000 · lfo(t)
//     4. Clamp D into the safe range [blockSize, maxSize] so the read never
//        walks off the end of the buffer or past the most recent write.
//        Without this clamp, parameter combinations such as
//        center_ms = 10, depth_ms = 20, lfo = -1  would yield a negative
//        delay and the peek offset would wrap, producing very loud audio
//        artifacts.  `crag.block_size` is used so the lower bound tracks
//        the actual host block size at compile time.
//     5. Compute peek offset from buffer head: offset = maxSize - D
//        (since head points to the oldest sample, offset selects how far
//         past the head to start reading, giving a delay of maxSize-offset
//         samples from the most recent write)
//     6. Peek (non-destructive read) at that offset.
//     7. Mix: out = dry_level · in + wet_level · peeked
//
// The buffer uses the modulatable-delay form (delaySize, maxSize):
//   delaySize = 960  samples — nominal centre delay (20 ms) used for
//                              periodicity analysis and run-time estimates.
//   maxSize   = 4800 samples — actual allocated buffer (100 ms) sized to
//                              hold the worst-case modulated delay
//                              (max_center + max_depth = 50 + 20 = 70 ms
//                              = 3360 samples) plus block-size headroom.
// At 48 kHz, parameter ranges produce delays in:
//   center_ms ∈ [10, 50]  → [480, 2400] samples
//   depth_ms  ∈ [1, 20]   → [48, 960]   samples
//   delay     = center ± depth          → [-480, 3360] samples (pre-clamp)
//                                       → [blockSize, 3360]    (post-clamp)
//
// Parameters:
//   rate       [0.05, 5]   – LFO frequency in Hz        (default 0.5)
//   depth_ms   [1, 20]     – modulation depth in ms     (default 10.0)
//   center_ms  [10, 50]    – base (centre) delay in ms  (default 20.0)
//   wet_level  [0, 1]      – wet/chorus mix amplitude   (default 0.5)
//   dry_level  [0, 1]      – dry pass-through amplitude (default 0.5)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "chorus"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 2>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/modulation/chorus.crag.mlir" as "chorus"

module {
  crag.graph name = "chorus" sample_rate = 48000 channels = 1
      default_visualizer = "phase-correlation" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %rate      = crag.param "rate"      min = 0.05 max = 5.0  default = 0.5  : f32
    %depth_ms  = crag.param "depth_ms"  min = 1.0  max = 20.0 default = 10.0 : f32
    %center_ms = crag.param "center_ms" min = 10.0 max = 50.0 default = 20.0 : f32
    %wet_level = crag.param "wet_level" min = 0.0  max = 1.0  default = 0.5  : f32
    %dry_level = crag.param "dry_level" min = 0.0  max = 1.0  default = 0.5  : f32

    // -----------------------------------------------------------------------
    // Shared circular buffer (mono input) using the modulatable-delay form:
    //   delaySize = 960  — nominal 20 ms reading depth for timing analysis.
    //   maxSize   = 4800 — actual 100 ms backing buffer for the LFO swing
    //                       plus block-size headroom.
    // -----------------------------------------------------------------------
    %dl = crag.delay_line : !crag.delay<f32, 48000, 1, 960, 4800>
    crag.push_delay %dl, %in : !crag.delay<f32, 48000, 1, 960, 4800>,
                                !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Shared constants
    // -----------------------------------------------------------------------
    %sr       = arith.constant 48000.0 : f32
    %two_pi   = arith.constant 6.28318530 : f32
    %ms_scale = arith.constant 0.001 : f32  // multiply ms by sr * 0.001 → samples
    %buf_f    = arith.constant 4800.0 : f32 // maxSize as f32

    // Block size as f32 — used as the lower clamp for the modulated delay
    // so the peek offset never exceeds maxSize - blockSize (the strict
    // bounds check enforces 0 ≤ offset ≤ maxSize - blockSize).
    %bs_i64 = crag.block_size : i64
    %bs_i32 = arith.trunci %bs_i64 : i64 to i32
    %bs_f   = arith.sitofp %bs_i32 : i32 to f32

    // Convert current time to f32 for LFO computation
    %t_f64 = crag.curtime : f64
    %t_f32 = arith.truncf %t_f64 : f64 to f32

    // LFO angular frequency: ω = 2π · rate
    %omega = arith.mulf %two_pi, %rate : f32

    // -----------------------------------------------------------------------
    // Left channel LFO: phase = ω · t
    // -----------------------------------------------------------------------
    %phase_l = arith.mulf %omega, %t_f32 : f32
    %lfo_l   = math.sin %phase_l : f32

    // -----------------------------------------------------------------------
    // Right channel LFO: phase = ω · t + π/2  (90° offset for stereo width)
    // -----------------------------------------------------------------------
    %half_pi = arith.constant 1.57079632 : f32
    %phase_r = arith.addf %phase_l, %half_pi : f32
    %lfo_r   = math.sin %phase_r : f32

    // -----------------------------------------------------------------------
    // Compute per-channel delay in samples and offset from buffer head
    //
    //   center_samp = center_ms · sr · ms_scale
    //   depth_samp  = depth_ms  · sr · ms_scale
    //   delay_samp  = center_samp + depth_samp · lfo
    //   delay_clamp = clamp(delay_samp, blockSize, maxSize)
    //   offset_i32  = (int)(maxSize - delay_clamp)
    //
    // The clamp guarantees offset ∈ [0, maxSize - blockSize] regardless of
    // parameter combination, satisfying the strict-bounds-check invariant
    // for crag.peek_delay and eliminating the loud wrap-around artifacts
    // that would otherwise occur when (center - depth · lfo) goes near or
    // below zero.
    // -----------------------------------------------------------------------
    %sr_ms = arith.mulf %sr, %ms_scale : f32

    %center_samp = arith.mulf %center_ms, %sr_ms : f32
    %depth_samp  = arith.mulf %depth_ms,  %sr_ms : f32

    // Left delay
    %mod_l       = arith.mulf %depth_samp, %lfo_l : f32
    %delay_l     = arith.addf %center_samp, %mod_l : f32
    %delay_l_lo  = arith.maximumf %delay_l, %bs_f : f32
    %delay_l_c   = arith.minimumf %delay_l_lo, %buf_f : f32
    %off_l_f     = arith.subf %buf_f, %delay_l_c : f32
    %off_l       = arith.fptosi %off_l_f : f32 to i32

    // Right delay
    %mod_r       = arith.mulf %depth_samp, %lfo_r : f32
    %delay_r     = arith.addf %center_samp, %mod_r : f32
    %delay_r_lo  = arith.maximumf %delay_r, %bs_f : f32
    %delay_r_c   = arith.minimumf %delay_r_lo, %buf_f : f32
    %off_r_f     = arith.subf %buf_f, %delay_r_c : f32
    %off_r       = arith.fptosi %off_r_f : f32 to i32

    // -----------------------------------------------------------------------
    // Peek at each offset
    // -----------------------------------------------------------------------
    %wet_l = crag.peek_delay %dl, %off_l : !crag.delay<f32, 48000, 1, 960, 4800>, i32
                 -> !crag.audio<f32, 0, 0>
    %wet_r = crag.peek_delay %dl, %off_r : !crag.delay<f32, 48000, 1, 960, 4800>, i32
                 -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Wet/dry mix for each channel
    // -----------------------------------------------------------------------
    %dry_sc = crag.scale %in, %dry_level : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>

    %wet_sc_l = crag.scale %wet_l, %wet_level : !crag.audio<f32, 0, 0>, f32
                    -> !crag.audio<f32, 0, 0>
    %wet_sc_r = crag.scale %wet_r, %wet_level : !crag.audio<f32, 0, 0>, f32
                    -> !crag.audio<f32, 0, 0>

    %out_l = crag.sum %dry_sc, %wet_sc_l
                 : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                   -> !crag.audio<f32, 0, 0>
    %out_r = crag.sum %dry_sc, %wet_sc_r
                 : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                   -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Join L/R into stereo output
    // -----------------------------------------------------------------------
    %stereo = crag.channel_join %out_l, %out_r
                  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                    -> !crag.audio<f32, 48000, 2>

    crag.output %stereo : !crag.audio<f32, 48000, 2>
  }
}
