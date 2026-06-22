// Stereo-to-Mono Average Downmix
//
// Downmixes a 2-channel (stereo) audio signal to mono by computing the
// arithmetic mean of the left and right channels:
//
//   mono_out = (L + R) / 2
//
// This is the standard "flat" or "equal-power" downmix and is the default
// mixer used when two-to-one downmixing is requested without further
// specification.  It preserves centre-panned signals at full amplitude but
// may reduce the level of hard-panned material by up to 6 dB.
//
// Conversion: channels 2 → 1
//
// Usage via crag-inject-channel-mixers (preferred_channel_mixer = "stereo_to_mono_average"):
//
//   crag.graph sample_rate = 48000 channels = 2
//              preferred_channel_mixer = "stereo_to_mono_average" {
//     %in = ...
//     crag.output %in : !crag.audio<f32, 48000, 2>
//   }

module {
  crag.graph name = "stereo_to_mono_average" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 2>):
    // Extract left (ch 0) and right (ch 1).
    %left  = crag.channel_slice %in, 0
                 : !crag.audio<f32, 0, 2> -> !crag.audio<f32, 0, 1>
    %right = crag.channel_slice %in, 1
                 : !crag.audio<f32, 0, 2> -> !crag.audio<f32, 0, 1>

    // Sum L + R, then scale by 0.5 to get the average.
    %sum  = crag.sum %left, %right
                : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                  -> !crag.audio<f32, 0, 1>
    %half = arith.constant 5.000000e-01 : f32
    %mono = crag.scale %sum, %half
                : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    crag.output %mono : !crag.audio<f32, 0, 1>
  }
}
