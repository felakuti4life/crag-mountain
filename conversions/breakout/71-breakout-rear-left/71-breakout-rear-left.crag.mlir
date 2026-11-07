// 7.1 Surround (SMPTE) Breakout - Back Left     (BL)
//
// Channel splitter: extracts the back/rear-left channel
// (channel 4) from a 8-channel 7.1 Surround (SMPTE) stream and passes it
// through as an independent 1-channel (mono) audio stream.  All other channels
// are discarded by this graph.
//
// A "breakout" of an N-channel bus is the set of N such single-channel
// extractor graphs.  Route one instance of each member from the same
// 8-channel source to fan the bus out into 8 independent mono
// streams that can be processed, metered, or routed separately, then optionally
// recombined downstream with crag.channel_join.
//
// Conversion: channels 8 -> 1  (extracts channel 4)
//
// Usage via crag.include:
//   %rear_left = crag.subgraph_ref "71_breakout_rear_left"(%bus)
//              : (!crag.audio<f32, 48000, 8>)
//                -> !crag.audio<f32, 48000, 1>

module {
  crag.graph name = "71_breakout_rear_left" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 8>):
    // Extract channel 4 (Back Left     (BL)) as a mono stream.
    %ch = crag.channel_slice %in, 4
              : !crag.audio<f32, 0, 8> -> !crag.audio<f32, 0, 1>
    crag.output %ch : !crag.audio<f32, 0, 1>
  }
}
