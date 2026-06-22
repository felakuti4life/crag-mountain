// Mono-to-Stereo Channel Mixer
//
// Duplicates a 1-channel (mono) audio signal onto both channels of a 2-channel
// (stereo) output.  The resulting left and right channels are identical; apply
// a stereo width processor downstream if independent L/R signals are desired.
//
// Conversion: channels 1 → 2
//   L_out = mono_in
//   R_out = mono_in
//
// Usage via crag-inject-channel-mixers (preferred_channel_mixer = "mono_to_stereo"):
//
//   crag.graph sample_rate = 48000 channels = 1
//              preferred_channel_mixer = "mono_to_stereo" {
//     %mono = crag.white_noise : !crag.audio<f32, 48000, 1>
//     crag.output %mono : !crag.audio<f32, 48000, 1>
//   }
//
// After injection the top-level graph's channels attribute is updated to 2
// and the final output carries two identical copies of the original mono signal.

module {
  crag.graph name = "mono_to_stereo" sample_rate = 0 channels = 2 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 1>):
    // Duplicate the mono signal onto both channels.
    %stereo = crag.channel_join %in, %in
                  : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                    -> !crag.audio<f32, 0, 2>
    crag.output %stereo : !crag.audio<f32, 0, 2>
  }
}
