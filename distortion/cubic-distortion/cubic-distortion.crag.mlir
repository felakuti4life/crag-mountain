// Cubic Soft Clipper
//
// Polynomial waveshaper based on the cubic function.  Unlike hard clipping
// (which produces a discontinuous first derivative) or tanh saturation (which
// requires a transcendental function), the cubic waveshaper is an algebraic
// polynomial that can be evaluated with two multiplications and a subtraction
// per sample.
//
// Algorithm:
//   For the pre-clipped input u = hard_clip(drive * x, 1.0):
//     y[n] = (3/2) * u[n] - (1/2) * u[n]^3
//
// This formula maps the interval [-1, 1] monotonically onto [-1, 1]:
//   - u = 0   →  y = 0      (identity at the origin)
//   - u = 1   →  y = 1      (peaks map to full scale)
//   - u = -1  →  y = -1     (odd symmetry preserved)
//
// The response is "softer" than tanh at small amplitudes and "harder" (more
// abruptly saturated) near the clipping boundary.  It generates odd-order
// harmonics (3rd, 5th, 7th …) much like tanh but with a slightly different
// harmonic balance: the cubic transfer function contains only a 3rd-harmonic
// distortion term, while higher harmonics arise from cascaded application or
// higher-order polynomials.
//
// Implementation details:
//   The input is pre-clipped to [-1, 1] before the polynomial to prevent
//   |u| > 1, which would make the cubic diverge.  With |u| ≤ 1:
//
//     y = (3/2)*u - (1/2)*u^3
//       = u * (3/2 - (1/2)*u^2)
//
//   Implemented as:
//     u       = crag.hard_clip(drive * x, 1.0)
//     u2      = crag.audio_mul(u, u)           // u^2
//     half_u2 = crag.scale(u2, 0.5)           // u^2 / 2
//     half_u3 = crag.audio_mul(half_u2, u)    // u^3 / 2
//     scaled_u = crag.scale(u, 1.5)           // 3u/2
//     y       = crag.sum(scaled_u, neg(half_u3))
//
// Parameters:
//   drive      [1, 20]   – pre-clip gain             (default 4.0)
//   wet_level  [0, 1]    – distorted signal level    (default 1.0)
//   dry_level  [0, 1]    – clean (direct) level      (default 0.0)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "cubic_distortion"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/distortion/cubic-distortion.crag.mlir" as "cubic_distortion"

module {
  crag.graph name = "cubic_distortion" sample_rate = 48000 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %drive = crag.param "drive"     min = 1.0 max = 20.0 default = 4.0 : f32
    %wet_p = crag.param "wet_level" min = 0.0 max = 1.0  default = 1.0 : f32
    %dry_p = crag.param "dry_level" min = 0.0 max = 1.0  default = 0.0 : f32

    // -----------------------------------------------------------------------
    // Pre-amp and hard-clip to [-1, 1] to keep |u| <= 1 for the polynomial
    // -----------------------------------------------------------------------
    %driven   = crag.scale %in, %drive : !crag.audio<f32, 0, 0>, f32
                    -> !crag.audio<f32, 0, 0>
    %clip1    = arith.constant 1.0 : f32
    %u        = crag.hard_clip %driven, %clip1
                    : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Cubic waveshaper: y = (3/2)*u - (1/2)*u^3
    //   Step 1: u^2
    // -----------------------------------------------------------------------
    %u2       = crag.audio_mul %u, %u
                    : !crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>
                      -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    //   Step 2: (1/2)*u^3  =  (1/2)*u^2  *  u
    // -----------------------------------------------------------------------
    %half     = arith.constant 0.5 : f32
    %half_u2  = crag.scale %u2, %half : !crag.audio<f32, 0, 0>, f32
                    -> !crag.audio<f32, 0, 0>
    %half_u3  = crag.audio_mul %half_u2, %u
                    : !crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>
                      -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    //   Step 3: (3/2)*u
    // -----------------------------------------------------------------------
    %three_halves = arith.constant 1.5 : f32
    %scaled_u     = crag.scale %u, %three_halves : !crag.audio<f32, 0, 0>, f32
                        -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    //   Step 4: y = (3/2)*u - (1/2)*u^3
    //           negate (1/2)*u^3 and sum
    // -----------------------------------------------------------------------
    %neg_one  = arith.constant -1.0 : f32
    %neg_u3   = crag.scale %half_u3, %neg_one : !crag.audio<f32, 0, 0>, f32
                    -> !crag.audio<f32, 0, 0>
    %shaped   = crag.sum %scaled_u, %neg_u3
                    : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                      -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Wet / dry mix
    // -----------------------------------------------------------------------
    %wet_out = crag.scale %shaped, %wet_p : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %dry_out = crag.scale %in, %dry_p     : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %output  = crag.sum %dry_out, %wet_out
                   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                     -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
