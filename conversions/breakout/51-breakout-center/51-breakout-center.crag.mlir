// 5.1 Surround (ITU-R BS.775 / SMPTE) Breakout - Front Centre  (FC)
//
// Channel splitter: extracts the centre channel
// (channel 2) from a 6-channel 5.1 Surround (ITU-R BS.775 / SMPTE) stream and passes it
// through as an independent 1-channel (mono) audio stream.  All other channels
// are discarded by this graph.
//
// A "breakout" of an N-channel bus is the set of N such single-channel
// extractor graphs.  Route one instance of each member from the same
// 6-channel source to fan the bus out into 6 independent mono
// streams that can be processed, metered, or routed separately, then optionally
// recombined downstream with crag.channel_join.
//
// Conversion: channels 6 -> 1  (extracts channel 2)
//
// Usage via crag.include:
//   %center = crag.subgraph_ref "51_breakout_center"(%bus)
//              : (!crag.audio<f32, 48000, 6>)
//                -> !crag.audio<f32, 48000, 1>

module {
  crag.graph name = "51_breakout_center" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 6>):
    // Extract channel 2 (Front Centre  (FC)) as a mono stream.
    %ch = crag.channel_slice %in, 2
              : !crag.audio<f32, 0, 6> -> !crag.audio<f32, 0, 1>
    crag.output %ch : !crag.audio<f32, 0, 1>
  }
}
