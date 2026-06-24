// FOA Transform: Rotate (Yaw) — Rotate the Soundfield Around the Z Axis
//
// Applies a horizontal yaw rotation to a First-Order Ambisonics (FOA) stream.
// A positive angle rotates the soundfield counterclockwise when viewed from
// above (i.e. sources appear to shift towards the left).
//
// Transform (ACN/SN3D, rotation of soundfield by angle ψ around Z axis):
//
//   W′ = W
//   Y′ = Y·cos(ψ) + X·sin(ψ)
//   Z′ = Z
//   X′ = X·cos(ψ) − Y·sin(ψ)
//
// Derivation: a source at azimuth θ is mapped to θ+ψ.  Expanding sin(θ+ψ)
// and cos(θ+ψ) using angle-addition identities gives the matrix above.
//
// Parameters:
//   yaw – rotation angle in radians.  Positive = counterclockwise from above.
//
// Channel count: 4 (subtype="ambisonics") → 4 (subtype="ambisonics")
//
// References:
//   Henderson, J. & Thornburg, H. (2011). The Ambisonic Toolkit: A tiled
//     approach to B-format composition and analysis. ICMC 2011.
//     https://ambisonictoolkit.net/
//   Zotter, F. & Frank, M. (2019). Ambisonics. Springer. §3.

module {
  crag.graph name = "foa_rotate_yaw" sample_rate = 0 channels = 4 default_visualizer = "oscilloscope" {
  ^bb0(%foa: !crag.audio<f32, 0, 4, subtype="ambisonics">):

    %yaw = crag.param "yaw"
               min = -3.14159274 max = 3.14159274 default = 0.0
               unit = "rad" : f32

    %cos_yaw = math.cos %yaw : f32
    %sin_yaw = math.sin %yaw : f32

    // Extract components.
    %W = crag.channel_slice %foa, 0
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Y = crag.channel_slice %foa, 1
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Z = crag.channel_slice %foa, 2
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %X = crag.channel_slice %foa, 3
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>

    // W′ = W  (unchanged)

    // Y′ = Y·cos(ψ) + X·sin(ψ)
    %Y_cos = crag.scale %Y, %cos_yaw
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %X_sin = crag.scale %X, %sin_yaw
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %Y_out = crag.sum %Y_cos, %X_sin
                 : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>) -> !crag.audio<f32, 0, 1>

    // Z′ = Z  (unchanged)

    // X′ = X·cos(ψ) − Y·sin(ψ)
    %neg_one   = arith.constant -1.0 : f32
    %neg_sin_yaw = arith.mulf %neg_one, %sin_yaw : f32
    %X_cos     = crag.scale %X, %cos_yaw
                     : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %Y_neg_sin = crag.scale %Y, %neg_sin_yaw
                     : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %X_out     = crag.sum %X_cos, %Y_neg_sin
                     : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>) -> !crag.audio<f32, 0, 1>

    %out = crag.channel_join %W, %Y_out, %Z, %X_out
               : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                  !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                 -> !crag.audio<f32, 0, 4, subtype="ambisonics">

    crag.output %out : !crag.audio<f32, 0, 4, subtype="ambisonics">
  }
}
