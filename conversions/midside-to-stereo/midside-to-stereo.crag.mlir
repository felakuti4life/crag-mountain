// Mid/Side to Stereo Decoder (Mid-Side → Stereo)
//
// Decodes a 2-channel Mid/Side (M/S) signal (subtype="midside") back into
// a plain 2-channel stereo output.
//
// The Mid/Side decoding reconstructs the original stereo signal from:
//   L = M + S
//   R = M − S
//
// This is the exact inverse of the stereo-to-midside encoder when the encoder
// uses the 0.5 scale convention (M = (L+R)*0.5, S = (L−R)*0.5).
//
// Input channel layout (subtype="midside"):
//   Channel 0  M  — mid (sum)
//   Channel 1  S  — side (difference)
//
// Channel count: 2 (subtype="midside") → 2 (plain stereo)

module {
  crag.graph name = "midside_to_stereo" sample_rate = 0 channels = 2 default_visualizer = "oscilloscope" {
  ^bb0(%ms: !crag.audio<f32, 0, 2, subtype = "midside">):

    // Extract mid (ch 0) and side (ch 1) as plain mono channels.
    %M = crag.channel_slice %ms, 0
             : !crag.audio<f32, 0, 2, subtype = "midside"> -> !crag.audio<f32, 0, 1>
    %S = crag.channel_slice %ms, 1
             : !crag.audio<f32, 0, 2, subtype = "midside"> -> !crag.audio<f32, 0, 1>

    %neg_one = arith.constant -1.0 : f32

    // L = M + S
    %L = crag.sum %M, %S
             : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
               -> !crag.audio<f32, 0, 1>

    // R = M − S
    %neg_S = crag.scale %S, %neg_one
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %R = crag.sum %M, %neg_S
             : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
               -> !crag.audio<f32, 0, 1>

    // Reassemble as plain stereo (no subtype).
    %stereo = crag.channel_join %L, %R
                  : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                    -> !crag.audio<f32, 0, 2>

    crag.output %stereo : !crag.audio<f32, 0, 2>
  }
}
