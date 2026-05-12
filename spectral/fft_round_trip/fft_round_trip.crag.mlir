// FFT Round-Trip
//
// Educational identity graph that routes the input audio block through the
// frequency domain and back to the time domain via `crag.fft` followed by
// `crag.ifft`.  Mathematically this is the identity (modulo floating-point
// round-off introduced by the forward and inverse transforms) and is useful
// as:
//
//   * A smoke test for the spectral pipeline on a target host.  If a
//     downstream effect that uses `crag.fft` produces silence or NaNs, this
//     graph isolates the issue from any frequency-domain processing.
//   * A null-effect baseline against which other spectral graphs in this
//     directory can be compared (same processing latency, same per-block
//     cost overhead).
//   * A template for new spectral effects: copy this file and insert your
//     `crag.freq_mul`, `crag.peek_freq_delay`, etc. between the `fft` and
//     `ifft` ops.
//
// The graph also exposes a wet/dry mix so that the round-trip output can be
// blended against the bypassed input — handy when comparing FFT round-trip
// fidelity by ear or in a spectrometer view.
//
// Parameters:
//   wet_level  [0, 1]  – round-trip output amplitude  (default 1.0)
//   dry_level  [0, 1]  – original signal amplitude    (default 0.0)
//
// Input:
//   %in  — the audio block to round-trip through the frequency domain.
//
// Output:
//   The reconstructed audio block, optionally mixed with the dry input.
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "fft_round_trip"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/spectral/fft_round_trip.crag.mlir" as "fft_round_trip"

module {
  crag.graph name = "fft_round_trip" sample_rate = 48000 channels = 1
      default_visualizer = "spectrometer" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %wet_level = crag.param "wet_level" min = 0.0 max = 1.0 default = 1.0 : f32
    %dry_level = crag.param "dry_level" min = 0.0 max = 1.0 default = 0.0 : f32

    // -----------------------------------------------------------------------
    // Forward FFT → Inverse FFT round-trip
    // -----------------------------------------------------------------------
    %freq  = crag.fft  %in   : !crag.audio<f32, 0, 0> -> !crag.freq<f32, 0, 0>
    %recon = crag.ifft %freq : !crag.freq<f32, 0, 0>  -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Wet / dry mix
    // -----------------------------------------------------------------------
    %wet_out = crag.scale %recon, %wet_level
                   : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %dry_out = crag.scale %in,    %dry_level
                   : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %output  = crag.sum %dry_out, %wet_out
                   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                     -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
