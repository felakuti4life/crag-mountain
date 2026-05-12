// FFT Block Echo
//
// Multi-tap echo built entirely inside the spectral pipeline.  The input is
// transformed to the frequency domain, the resulting spectrum is pushed
// into a 16-slot `crag.freq_delay_line`, and three past spectra are peeked
// at fixed block offsets and inverse-transformed back to audio.  The three
// recovered audio blocks are then summed with progressively decaying gain
// to form a series of attenuated echoes of the input.
//
// Algorithm (per audio block):
//   1. fft(input) → push into the frequency-domain ring buffer.
//   2. For each fixed tap offset T ∈ {4, 8, 12} blocks back:
//        - peek_freq_delay at offset T
//        - ifft to recover audio block from T blocks ago
//        - scale by the tap's decay coefficient (decay, decay², decay³)
//   3. Sum the three taps and the dry input (under wet/dry control).
//
// Tap timing (at 48 kHz with the default 512-sample block size):
//   Tap 1 →  4 blocks  ≈  43 ms
//   Tap 2 →  8 blocks  ≈  85 ms
//   Tap 3 → 12 blocks  ≈ 128 ms
//
// Because the taps are at compile-time-constant offsets and the ring buffer
// has 16 slots, the strict-bounds-check pass on `crag.peek_freq_delay` is
// trivially satisfied.  The per-block cost is a fixed number of FFT/IFFT
// pairs regardless of the chosen decay parameter.
//
// The repeated FFT-then-IFFT round-trips on the same spectrum demonstrate
// the spectral pipeline acting as a transparent transport for time-domain
// echo taps; downstream variants of this graph can replace the ifft-and-sum
// with frequency-domain processing (e.g. per-tap `crag.freq_mul` with a
// filter spectrum) to build "spectrally coloured" echoes.
//
// Parameters:
//   feedback   [0, 0.99]  – per-tap decay coefficient (geometric)  (default 0.6)
//   wet_level  [0, 1]     – combined echo amplitude                (default 0.6)
//   dry_level  [0, 1]     – original signal amplitude              (default 0.7)
//
// Input:
//   %in  — the audio block to echo through the frequency-domain ring buffer.
//
// Output:
//   The dry signal summed with three decaying frequency-domain echo taps.
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "fft_block_echo"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/spectral/fft_block_echo.crag.mlir"
//       as "fft_block_echo"

module {
  crag.graph name = "fft_block_echo" sample_rate = 48000 channels = 1
      default_visualizer = "spectrometer" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %feedback  = crag.param "feedback"  min = 0.0 max = 0.99 default = 0.6 : f32
    %wet_level = crag.param "wet_level" min = 0.0 max = 1.0  default = 0.6 : f32
    %dry_level = crag.param "dry_level" min = 0.0 max = 1.0  default = 0.7 : f32

    // -----------------------------------------------------------------------
    // 16-slot frequency-domain ring buffer.  16 · blockSize samples of
    // spectral history are retained (≈ 170 ms at 48 kHz / 512-sample blocks).
    // -----------------------------------------------------------------------
    %fd = crag.freq_delay_line : !crag.freq_delay<f32, 48000, 1, 16>

    // -----------------------------------------------------------------------
    // 1. Forward FFT and push the current spectrum into the ring buffer.
    // -----------------------------------------------------------------------
    %freq = crag.fft %in : !crag.audio<f32, 0, 0> -> !crag.freq<f32, 0, 0>
    crag.push_freq_delay %fd, %freq
        : !crag.freq_delay<f32, 48000, 1, 16>, !crag.freq<f32, 0, 0>

    // -----------------------------------------------------------------------
    // 2. Compile-time tap offsets (in blocks).
    // -----------------------------------------------------------------------
    %tap1_idx = arith.constant  4 : i32
    %tap2_idx = arith.constant  8 : i32
    %tap3_idx = arith.constant 12 : i32

    // -----------------------------------------------------------------------
    // 3. Peek + IFFT for each tap.
    // -----------------------------------------------------------------------
    %t1_freq = crag.peek_freq_delay %fd, %tap1_idx
                   : !crag.freq_delay<f32, 48000, 1, 16>, i32
                     -> !crag.freq<f32, 0, 0>
    %t1_aud  = crag.ifft %t1_freq : !crag.freq<f32, 0, 0>
                   -> !crag.audio<f32, 0, 0>

    %t2_freq = crag.peek_freq_delay %fd, %tap2_idx
                   : !crag.freq_delay<f32, 48000, 1, 16>, i32
                     -> !crag.freq<f32, 0, 0>
    %t2_aud  = crag.ifft %t2_freq : !crag.freq<f32, 0, 0>
                   -> !crag.audio<f32, 0, 0>

    %t3_freq = crag.peek_freq_delay %fd, %tap3_idx
                   : !crag.freq_delay<f32, 48000, 1, 16>, i32
                     -> !crag.freq<f32, 0, 0>
    %t3_aud  = crag.ifft %t3_freq : !crag.freq<f32, 0, 0>
                   -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // 4. Per-tap geometric decay coefficients: g₁ = feedback,
    //    g₂ = feedback², g₃ = feedback³.
    // -----------------------------------------------------------------------
    %g1 = arith.mulf %feedback, %feedback : f32                    // feedback²
    %g2 = arith.mulf %g1,       %feedback : f32                    // feedback³
    // (g0 = feedback by itself, used directly for tap 1.)

    %t1_sc = crag.scale %t1_aud, %feedback
                 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %t2_sc = crag.scale %t2_aud, %g1
                 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %t3_sc = crag.scale %t3_aud, %g2
                 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // 5. Sum the three taps to form the wet (echo) signal.
    // -----------------------------------------------------------------------
    %taps12 = crag.sum %t1_sc, %t2_sc
                  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                    -> !crag.audio<f32, 0, 0>
    %wet    = crag.sum %taps12, %t3_sc
                  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                    -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // 6. Wet / dry mix
    // -----------------------------------------------------------------------
    %wet_sc = crag.scale %wet, %wet_level
                  : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %dry_sc = crag.scale %in,  %dry_level
                  : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %output = crag.sum %dry_sc, %wet_sc
                  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                    -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
