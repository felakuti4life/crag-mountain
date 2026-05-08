// FOA Transform: Tumble (Pitch) — Rotate the Soundfield Around the Y Axis
//
// Applies a pitch (tumble) rotation to a First-Order Ambisonics (FOA) stream.
// A positive angle tilts the front of the soundfield upwards (sources that
// were in front move upward; sources above move to the back).
//
// Transform (ACN/SN3D, rotation of soundfield by angle χ around Y axis):
//
//   W′ = W
//   Y′ = Y
//   Z′ = −X·sin(χ) + Z·cos(χ)
//   X′ =  X·cos(χ) + Z·sin(χ)
//
// The Y component is unaffected by rotation around the Y axis; the X and Z
// components mix according to a 2-D rotation in the XZ plane.
//
// Parameters:
//   pitch – rotation angle in radians.  Positive = front tilts up.
//
// Channel count: 4 (subtype="ambisonics") → 4 (subtype="ambisonics")
//
// References:
//   Henderson, J. & Thornburg, H. (2011). The Ambisonic Toolkit. ICMC 2011.
//     https://ambisonictoolkit.net/  (FoaTumble in ATK)
//   Zotter, F. & Frank, M. (2019). Ambisonics. Springer. §3.

module {
  crag.graph name = "foa_tumble_pitch" sample_rate = 0 channels = 4 default_visualizer = "oscilloscope" {
  ^bb0(%foa: !crag.audio<f32, 0, 4, subtype="ambisonics">):

    %pitch = crag.param "pitch"
                 min = -3.14159274 max = 3.14159274 default = 0.0
                 unit = "rad" : f32

    %cos_p = math.cos %pitch : f32
    %sin_p = math.sin %pitch : f32

    // Extract components.
    %W = crag.channel_slice %foa, 0
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Y = crag.channel_slice %foa, 1
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Z = crag.channel_slice %foa, 2
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %X = crag.channel_slice %foa, 3
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>

    // W′ = W, Y′ = Y  (unchanged)

    // X′ = X·cos(χ) + Z·sin(χ)
    %X_cos = crag.scale %X, %cos_p
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %Z_sin = crag.scale %Z, %sin_p
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %X_out = crag.sum %X_cos, %Z_sin
                 : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>) -> !crag.audio<f32, 0, 1>

    // Z′ = −X·sin(χ) + Z·cos(χ)
    %neg_one   = arith.constant -1.0 : f32
    %neg_sin_p = arith.mulf %neg_one, %sin_p : f32
    %X_neg_sin = crag.scale %X, %neg_sin_p
                     : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %Z_cos     = crag.scale %Z, %cos_p
                     : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %Z_out     = crag.sum %X_neg_sin, %Z_cos
                     : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>) -> !crag.audio<f32, 0, 1>

    %out = crag.channel_join %W, %Y, %Z_out, %X_out
               : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                  !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                 -> !crag.audio<f32, 0, 4, subtype="ambisonics">

    crag.output %out : !crag.audio<f32, 0, 4, subtype="ambisonics">
  }
}
