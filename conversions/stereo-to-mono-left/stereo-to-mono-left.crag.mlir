// Stereo-to-Mono Left-Channel Downmix
//
// Extracts only the left channel (channel 0) from a stereo signal and passes
// it through as a mono output.  The right channel is discarded.
//
//   mono_out = L
//
// Use this mixer when the left channel carries the desired programme material
// (e.g. a dual-language broadcast where L = primary language).
//
// Conversion: channels 2 → 1
//
// Usage via crag-inject-channel-mixers (preferred_channel_mixer = "stereo_to_mono_left"):
//
//   crag.graph sample_rate = 48000 channels = 2
//              preferred_channel_mixer = "stereo_to_mono_left" {
//     %in = ...
//     crag.output %in : !crag.audio<f32, 48000, 2>
//   }

module {
  crag.graph name = "stereo_to_mono_left" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 2>):
    %mono = crag.channel_slice %in, 0
                : !crag.audio<f32, 0, 2> -> !crag.audio<f32, 0, 1>
    crag.output %mono : !crag.audio<f32, 0, 1>
  }
}
