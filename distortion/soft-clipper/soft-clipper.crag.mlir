// Soft Clipper (Tanh Saturation)
//
// Smooth soft-clipping distortion using the hyperbolic tangent function as
// the nonlinear saturator.  Unlike hard clipping, tanh produces a continuous
// S-curve that gently compresses large amplitudes; there is no abrupt cutoff,
// so the transition from linear to saturated behaviour is gradual.
//
// Algorithm:
//   y[n] = tanh(drive * x[n])
//
// The tanh function has several useful properties for audio saturation:
//   - Output is always in the open interval (-1, 1) — inherently bounded.
//   - Odd symmetry: tanh(-x) = -tanh(x), so only odd harmonics are generated
//     for a symmetric (sine wave) input, giving a "tube-like" warmth.
//   - At small amplitudes (drive ≈ 1) the response is nearly linear.
//   - At large amplitudes (drive >> 1) the signal is pushed deeply into
//     saturation and the output approaches a square wave shape.
//
// Drive interpretation:
//   drive controls the input level before the tanh.  For a sine input of
//   amplitude A the output peak is tanh(drive * A).  With drive = 1 and
//   A = 1 the output peak is tanh(1) ≈ 0.76; with drive = 5, A = 1 the
//   output peak is tanh(5) ≈ 0.9999 (nearly fully saturated).  No
//   post-normalisation is applied; use wet_level to compensate for loudness.
//
// Parameters:
//   drive      [0.5, 20]  – pre-saturation gain    (default 3.0)
//   wet_level  [0, 1]     – saturated signal level (default 1.0)
//   dry_level  [0, 1]     – clean (direct) level   (default 0.0)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "soft_clipper"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/distortion/soft-clipper.crag.mlir" as "soft_clipper"

module {
  crag.graph name = "soft_clipper" sample_rate = 48000 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %drive = crag.param "drive"     min = 0.5 max = 20.0 default = 3.0 : f32
    %wet_p = crag.param "wet_level" min = 0.0 max = 1.0  default = 1.0 : f32
    %dry_p = crag.param "dry_level" min = 0.0 max = 1.0  default = 0.0 : f32

    // -----------------------------------------------------------------------
    // Pre-amp: scale input by drive
    // -----------------------------------------------------------------------
    %driven = crag.scale %in, %drive : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Tanh saturation: y[n] = tanh(drive * x[n])
    // Output is always in (-1, 1) regardless of input level.
    // -----------------------------------------------------------------------
    %saturated = crag.tanh %driven : !crag.audio<f32, 0, 0> -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Wet / dry mix
    // -----------------------------------------------------------------------
    %wet_out = crag.scale %saturated, %wet_p : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %dry_out = crag.scale %in, %dry_p        : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %output  = crag.sum %dry_out, %wet_out
                   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                     -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
