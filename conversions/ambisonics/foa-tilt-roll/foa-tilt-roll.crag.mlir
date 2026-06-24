// FOA Transform: Tilt (Roll) — Rotate the Soundfield Around the X Axis
//
// Applies a roll (tilt) rotation to a First-Order Ambisonics (FOA) stream.
// A positive angle rolls the left side of the soundfield upwards (sources on
// the left move upward; sources above move to the right).
//
// Transform (ACN/SN3D, rotation of soundfield by angle ρ around X axis):
//
//   W′ = W
//   X′ = X
//   Y′ = Y·cos(ρ) − Z·sin(ρ)
//   Z′ = Y·sin(ρ) + Z·cos(ρ)
//
// The X component is unaffected by rotation around the X axis; the Y and Z
// components mix according to a 2-D rotation in the YZ plane.
//
// Parameters:
//   roll – rotation angle in radians.  Positive = left side rolls up.
//
// Channel count: 4 (subtype="ambisonics") → 4 (subtype="ambisonics")
//
// References:
//   Henderson, J. & Thornburg, H. (2011). The Ambisonic Toolkit. ICMC 2011.
//     https://ambisonictoolkit.net/  (FoaTilt in ATK)
//   Zotter, F. & Frank, M. (2019). Ambisonics. Springer. §3.

module {
  crag.graph name = "foa_tilt_roll" sample_rate = 0 channels = 4 default_visualizer = "oscilloscope" {
  ^bb0(%foa: !crag.audio<f32, 0, 4, subtype="ambisonics">):

    %roll = crag.param "roll"
                min = -3.14159274 max = 3.14159274 default = 0.0
                unit = "rad" : f32

    %cos_r = math.cos %roll : f32
    %sin_r = math.sin %roll : f32

    // Extract components.
    %W = crag.channel_slice %foa, 0
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Y = crag.channel_slice %foa, 1
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Z = crag.channel_slice %foa, 2
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %X = crag.channel_slice %foa, 3
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>

    // W′ = W, X′ = X  (unchanged)

    // Y′ = Y·cos(ρ) − Z·sin(ρ)
    %Y_cos     = crag.scale %Y, %cos_r
                     : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %neg_one   = arith.constant -1.0 : f32
    %neg_sin_r = arith.mulf %neg_one, %sin_r : f32
    %Z_neg_sin = crag.scale %Z, %neg_sin_r
                     : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %Y_out     = crag.sum %Y_cos, %Z_neg_sin
                     : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>) -> !crag.audio<f32, 0, 1>

    // Z′ = Y·sin(ρ) + Z·cos(ρ)
    %Y_sin = crag.scale %Y, %sin_r
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %Z_cos = crag.scale %Z, %cos_r
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %Z_out = crag.sum %Y_sin, %Z_cos
                 : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>) -> !crag.audio<f32, 0, 1>

    %out = crag.channel_join %W, %Y_out, %Z_out, %X
               : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                  !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                 -> !crag.audio<f32, 0, 4, subtype="ambisonics">

    crag.output %out : !crag.audio<f32, 0, 4, subtype="ambisonics">
  }
}
