// FOA Transform: Mirror Front/Back
//
// Reflects the ambisonics soundfield across the left-right plane, swapping
// front and back.  A source at azimuth θ appears at azimuth (π − θ) after
// the transform (e.g. front→back, back→front; left and right are preserved).
//
// Transform (negate the X component):
//
//   W′ = W
//   Y′ = Y
//   Z′ = Z
//   X′ = −X
//
// Derivation: X = cos(θ)·cos(el).  A front-back mirror maps cos(θ) →
// −cos(θ) (i.e. θ → π−θ) which is equivalent to negating X.
//
// Channel count: 4 (subtype="ambisonics") → 4 (subtype="ambisonics")
//
// References:
//   Henderson, J. & Thornburg, H. (2011). The Ambisonic Toolkit. ICMC 2011.
//     https://ambisonictoolkit.net/  (FoaMirrorO in ATK)

module {
  crag.graph name = "foa_mirror_frontback" sample_rate = 0 channels = 4 default_visualizer = "oscilloscope" {
  ^bb0(%foa: !crag.audio<f32, 0, 4, subtype="ambisonics">):

    %W = crag.channel_slice %foa, 0
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Y = crag.channel_slice %foa, 1
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Z = crag.channel_slice %foa, 2
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %X = crag.channel_slice %foa, 3
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>

    // X′ = −X
    %neg_one = arith.constant -1.0 : f32
    %X_neg = crag.scale %X, %neg_one
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    %out = crag.channel_join %W, %Y, %Z, %X_neg
               : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                  !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                 -> !crag.audio<f32, 0, 4, subtype="ambisonics">

    crag.output %out : !crag.audio<f32, 0, 4, subtype="ambisonics">
  }
}
