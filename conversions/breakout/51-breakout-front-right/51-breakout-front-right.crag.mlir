// 5.1 Surround (ITU-R BS.775 / SMPTE) Breakout - Front Right   (FR)
//
// Channel splitter: extracts the front-right channel
// (channel 1) from a 6-channel 5.1 Surround (ITU-R BS.775 / SMPTE) stream and passes it
// through as an independent 1-channel (mono) audio stream.  All other channels
// are discarded by this graph.
//
// A "breakout" of an N-channel bus is the set of N such single-channel
// extractor graphs.  Route one instance of each member from the same
// 6-channel source to fan the bus out into 6 independent mono
// streams that can be processed, metered, or routed separately, then optionally
// recombined downstream with crag.channel_join.
//
// Conversion: channels 6 -> 1  (extracts channel 1)
//
// Usage via crag.include:
//   %front_right = crag.subgraph_ref "51_breakout_front_right"(%bus)
//              : (!crag.audio<f32, 48000, 6>)
//                -> !crag.audio<f32, 48000, 1>

module {
  crag.graph name = "51_breakout_front_right" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 6>):
    // Extract channel 1 (Front Right   (FR)) as a mono stream.
    %ch = crag.channel_slice %in, 1
              : !crag.audio<f32, 0, 6> -> !crag.audio<f32, 0, 1>
    crag.output %ch : !crag.audio<f32, 0, 1>
  }
}
