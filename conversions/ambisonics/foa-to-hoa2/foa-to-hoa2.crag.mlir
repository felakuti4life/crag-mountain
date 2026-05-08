// Order Conversion: First-Order → Second-Order Ambisonics (FOA → HOA2)
//
// Upsamples a First-Order Ambisonics (FOA, 4-channel) stream to a
// Second-Order Ambisonics (HOA2, 9-channel) stream by zero-padding the
// five missing second-order components (ACN channels 4–8).
//
// This is a lossless operation for the first-order content — no spatial
// information is added.  The resulting HOA2 stream encodes only first-order
// spatial information with zeroed second-order coefficients.  Use this when
// downstream processing requires a 9-channel HOA2 input.
//
// Input/output channel layout (ACN/SN3D):
//   Input  (FOA):  ACN 0–3   → W, Y, Z, X
//   Output (HOA2): ACN 0–8   → W, Y, Z, X, V=0, T=0, R=0, S=0, U=0
//
// Channel count: 4 (subtype="ambisonics") → 9 (subtype="ambisonics")
//
// References:
//   Zotter, F. & Frank, M. (2019). Ambisonics. Springer.

module {
  crag.graph name = "foa_to_hoa2" sample_rate = 0 channels = 9 default_visualizer = "oscilloscope" {
  ^bb0(%foa: !crag.audio<f32, 0, 4, subtype="ambisonics">):

    // Extract the four FOA channels as plain mono.
    %W = crag.channel_slice %foa, 0
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Y = crag.channel_slice %foa, 1
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Z = crag.channel_slice %foa, 2
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %X = crag.channel_slice %foa, 3
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>

    // Zero-fill the five second-order channels (ACN 4–8).
    %zero = arith.constant 0.0 : f32
    %V = crag.scale %W, %zero
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %T = crag.scale %W, %zero
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %R = crag.scale %W, %zero
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %S = crag.scale %W, %zero
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %U = crag.scale %W, %zero
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    %hoa2 = crag.channel_join %W, %Y, %Z, %X, %V, %T, %R, %S, %U
                : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                   !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                   !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                   !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                   !crag.audio<f32, 0, 1>)
                  -> !crag.audio<f32, 0, 9, subtype="ambisonics">

    crag.output %hoa2 : !crag.audio<f32, 0, 9, subtype="ambisonics">
  }
}
