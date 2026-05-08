// Stereo-to-Mono Right-Channel Downmix
//
// Extracts only the right channel (channel 1) from a stereo signal and passes
// it through as a mono output.  The left channel is discarded.
//
//   mono_out = R
//
// Use this mixer when the right channel carries the desired programme material
// (e.g. a dual-language broadcast where R = secondary language).
//
// Conversion: channels 2 → 1
//
// Usage via crag-inject-channel-mixers (preferred_channel_mixer = "stereo_to_mono_right"):
//
//   crag.graph sample_rate = 48000 channels = 2
//              preferred_channel_mixer = "stereo_to_mono_right" {
//     %in = ...
//     crag.output %in : !crag.audio<f32, 48000, 2>
//   }

module {
  crag.graph name = "stereo_to_mono_right" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 2>):
    %mono = crag.channel_slice %in, 1
                : !crag.audio<f32, 0, 2> -> !crag.audio<f32, 0, 1>
    crag.output %mono : !crag.audio<f32, 0, 1>
  }
}
