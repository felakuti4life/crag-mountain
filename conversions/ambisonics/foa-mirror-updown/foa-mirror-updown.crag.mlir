// FOA Transform: Mirror Up/Down
//
// Reflects the ambisonics soundfield across the horizontal plane, swapping
// up and down.  A source at elevation φ appears at elevation −φ after the
// transform (e.g. ceiling→floor, floor→ceiling; azimuth is preserved).
//
// Transform (negate the Z component):
//
//   W′ = W
//   Y′ = Y
//   Z′ = −Z
//   X′ = X
//
// Derivation: Z = sin(el).  An up-down mirror maps sin(el) → −sin(el)
// (i.e. el → −el), which is equivalent to negating Z.
//
// Channel count: 4 (subtype="ambisonics") → 4 (subtype="ambisonics")
//
// References:
//   Henderson, J. & Thornburg, H. (2011). The Ambisonic Toolkit. ICMC 2011.
//     https://ambisonictoolkit.net/  (FoaMirrorHeight in ATK)

module {
  crag.graph name = "foa_mirror_updown" sample_rate = 0 channels = 4 default_visualizer = "oscilloscope" {
  ^bb0(%foa: !crag.audio<f32, 0, 4, subtype="ambisonics">):

    %W = crag.channel_slice %foa, 0
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Y = crag.channel_slice %foa, 1
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Z = crag.channel_slice %foa, 2
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %X = crag.channel_slice %foa, 3
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>

    // Z′ = −Z
    %neg_one = arith.constant -1.0 : f32
    %Z_neg = crag.scale %Z, %neg_one
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    %out = crag.channel_join %W, %Y, %Z_neg, %X
               : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                  !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                 -> !crag.audio<f32, 0, 4, subtype="ambisonics">

    crag.output %out : !crag.audio<f32, 0, 4, subtype="ambisonics">
  }
}
