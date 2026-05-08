// Stereo to Mid/Side Encoder (Stereo → Mid-Side)
//
// Encodes a 2-channel stereo signal into a 2-channel Mid/Side (M/S)
// representation, tagged with subtype="midside".
//
// The Mid/Side encoding separates the stereo signal into:
//   M  (mid)  = (L + R) * 0.5  — mono-compatible centre content
//   S  (side) = (L − R) * 0.5  — stereo difference / width content
//
// The 0.5 scale factor ensures a perfect round-trip with the matching
// midside-to-stereo decoder (L = M + S, R = M − S).
//
// Output channel layout (subtype="midside"):
//   Channel 0  M  — mid (sum)
//   Channel 1  S  — side (difference)
//
// Channel count: 2 (plain stereo) → 2 (subtype="midside")
//
// Use the midside-to-stereo graph to decode back to plain stereo.

module {
  crag.graph name = "stereo_to_midside" sample_rate = 0 channels = 2 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 2>):

    // Extract left (ch 0) and right (ch 1) as plain mono channels.
    %L = crag.channel_slice %in, 0
             : !crag.audio<f32, 0, 2> -> !crag.audio<f32, 0, 1>
    %R = crag.channel_slice %in, 1
             : !crag.audio<f32, 0, 2> -> !crag.audio<f32, 0, 1>

    %half    = arith.constant 5.000000e-01 : f32
    %neg_one = arith.constant -1.0 : f32

    // M = (L + R) * 0.5
    %sum = crag.sum %L, %R
               : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                 -> !crag.audio<f32, 0, 1>
    %M = crag.scale %sum, %half
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // S = (L − R) * 0.5
    %neg_R = crag.scale %R, %neg_one
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %diff = crag.sum %L, %neg_R
                : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                  -> !crag.audio<f32, 0, 1>
    %S = crag.scale %diff, %half
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // Assemble M/S stream: plain mono inputs → tagged midside output.
    %ms = crag.channel_join %M, %S
              : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                -> !crag.audio<f32, 0, 2, subtype = "midside">

    crag.output %ms : !crag.audio<f32, 0, 2, subtype = "midside">
  }
}
