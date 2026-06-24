// Order Conversion: Second-Order → First-Order Ambisonics (HOA2 → FOA)
//
// Converts a Second-Order Ambisonics (HOA2, 9-channel) stream to a
// First-Order Ambisonics (FOA, 4-channel) stream by discarding the five
// second-order components (ACN channels 4–8).
//
// Truncation retains all first-order spatial information at the cost of
// losing the second-order directional detail.  This is useful when
// downstream processing (e.g. a stereo decoder) only handles FOA.
//
// Input/output channel layout (ACN/SN3D):
//   Input  (HOA2): ACN 0–8   → W, Y, Z, X, V, T, R, S, U
//   Output (FOA):  ACN 0–3   → W, Y, Z, X  (ACN 4–8 discarded)
//
// Channel count: 9 (subtype="ambisonics") → 4 (subtype="ambisonics")
//
// References:
//   Zotter, F. & Frank, M. (2019). Ambisonics. Springer.

module {
  crag.graph name = "hoa2_to_foa" sample_rate = 0 channels = 4 default_visualizer = "oscilloscope" {
  ^bb0(%hoa2: !crag.audio<f32, 0, 9, subtype="ambisonics">):

    // Retain only the first four ACN channels; discard the rest.
    %W = crag.channel_slice %hoa2, 0
             : !crag.audio<f32, 0, 9, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Y = crag.channel_slice %hoa2, 1
             : !crag.audio<f32, 0, 9, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Z = crag.channel_slice %hoa2, 2
             : !crag.audio<f32, 0, 9, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %X = crag.channel_slice %hoa2, 3
             : !crag.audio<f32, 0, 9, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>

    %foa = crag.channel_join %W, %Y, %Z, %X
               : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                  !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                 -> !crag.audio<f32, 0, 4, subtype="ambisonics">

    crag.output %foa : !crag.audio<f32, 0, 4, subtype="ambisonics">
  }
}
