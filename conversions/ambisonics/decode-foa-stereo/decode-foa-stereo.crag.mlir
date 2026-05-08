// First-Order Ambisonics Decoder — FOA → Stereo
//
// Decodes a First-Order Ambisonics (FOA) stream to a 2-channel stereo output
// using two virtual cardioid microphones oriented at ±45° from front in the
// horizontal plane.  The channel ordering of the input must follow ACN/SN3D
// (AmbiX convention):
//
//   Channel 0  W  (omnidirectional)
//   Channel 1  Y  (left/right)
//   Channel 2  Z  (up/down — unused by this horizontal decode)
//   Channel 3  X  (front/back)
//
// Stereo decode (cardioid at ±45°):
//   L = 0.5 * (W + cos(45°)·X + sin(45°)·Y)  = 0.5 * (W + 0.7071·X + 0.7071·Y)
//   R = 0.5 * (W + cos(-45°)·X + sin(-45°)·Y) = 0.5 * (W + 0.7071·X − 0.7071·Y)
//
// The 0.5 factor maintains the same loudness for a centred mono source as
// the original W component (W + X·cos(0°)·1.0 ≈ 2W, so 0.5 → W).
//
// Channel count: 4 (subtype="ambisonics") → 2 (plain stereo)
//
// References:
//   Gerzon, M. (1992). General metatheory of auditory localisation. AES 92nd
//     Convention, preprint 3306.
//   Malham, D. (2003). Space in Music. PhD thesis, University of York.
//   IEM Plugin Suite documentation, https://plugins.iem.at/

module {
  crag.graph name = "decode_foa_stereo" sample_rate = 0 channels = 2 default_visualizer = "oscilloscope" {
  ^bb0(%foa: !crag.audio<f32, 0, 4, subtype="ambisonics">):

    // Extract ACN/SN3D components as plain mono channels.
    %W = crag.channel_slice %foa, 0
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    %Y = crag.channel_slice %foa, 1
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    // Z channel (index 2) is not used in a horizontal stereo decode.
    %X = crag.channel_slice %foa, 3
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>

    // Shared gain: 0.7071 ≈ 1/√2 = cos(45°) = sin(45°)
    %k = arith.constant 7.07106781e-01 : f32
    // Overall 0.5 scale to keep centred mono at unity gain.
    %half = arith.constant 5.0e-01 : f32

    // L = 0.5 * (W + 0.7071*X + 0.7071*Y)
    %kX   = crag.scale %X, %k : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %kY   = crag.scale %Y, %k : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %WkXkY = crag.sum %W, %kX, %kY
                 : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                    !crag.audio<f32, 0, 1>) -> !crag.audio<f32, 0, 1>
    %L = crag.scale %WkXkY, %half
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // R = 0.5 * (W + 0.7071*X − 0.7071*Y)
    %neg_one = arith.constant -1.0 : f32
    %neg_kY  = crag.scale %kY, %neg_one
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %WkX_neg_kY = crag.sum %W, %kX, %neg_kY
                      : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                         !crag.audio<f32, 0, 1>) -> !crag.audio<f32, 0, 1>
    %R = crag.scale %WkX_neg_kY, %half
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    %stereo = crag.channel_join %L, %R
                  : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                    -> !crag.audio<f32, 0, 2>

    crag.output %stereo : !crag.audio<f32, 0, 2>
  }
}
