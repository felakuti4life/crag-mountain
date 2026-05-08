// FOA Transform: Mirror Left/Right
//
// Reflects the ambisonics soundfield across the front-back plane, swapping
// left and right.  A source at azimuth θ appears at azimuth −θ after the
// transform (e.g. left→right, right→left; front and back are preserved).
//
// Transform (negate the Y component):
//
//   W′ = W
//   Y′ = −Y
//   Z′ = Z
//   X′ = X
//
// Derivation: Y = sin(θ)·cos(el).  A left-right mirror maps sin(θ) →
// −sin(θ) (i.e. θ → −θ), which is equivalent to negating Y.
//
// Channel count: 4 (subtype="ambisonics") → 4 (subtype="ambisonics")
//
// References:
//   Henderson, J. & Thornburg, H. (2011). The Ambisonic Toolkit. ICMC 2011.
//     https://ambisonictoolkit.net/  (FoaMirrorSide in ATK)

module {
  crag.graph name = "foa_mirror_leftright" sample_rate = 0 channels = 4 default_visualizer = "oscilloscope" {
  ^bb0(%foa: !crag.audio<f32, 0, 4, subtype="ambisonics">):

    %W = crag.channel_slice %foa, 0
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Y = crag.channel_slice %foa, 1
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Z = crag.channel_slice %foa, 2
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %X = crag.channel_slice %foa, 3
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>

    // Y′ = −Y
    %neg_one = arith.constant -1.0 : f32
    %Y_neg = crag.scale %Y, %neg_one
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    %out = crag.channel_join %W, %Y_neg, %Z, %X
               : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                  !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                 -> !crag.audio<f32, 0, 4, subtype="ambisonics">

    crag.output %out : !crag.audio<f32, 0, 4, subtype="ambisonics">
  }
}
