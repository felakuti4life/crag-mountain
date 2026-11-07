// Stereo (L/R) Breakout - Left  (L)
//
// Channel splitter: extracts the left channel
// (channel 0) from a 2-channel Stereo (L/R) stream and passes it
// through as an independent 1-channel (mono) audio stream.  All other channels
// are discarded by this graph.
//
// A "breakout" of an N-channel bus is the set of N such single-channel
// extractor graphs.  Route one instance of each member from the same
// 2-channel source to fan the bus out into 2 independent mono
// streams that can be processed, metered, or routed separately, then optionally
// recombined downstream with crag.channel_join.
//
// Conversion: channels 2 -> 1  (extracts channel 0)
//
// Usage via crag.include:
//   %left = crag.subgraph_ref "stereo_breakout_left"(%bus)
//              : (!crag.audio<f32, 48000, 2>)
//                -> !crag.audio<f32, 48000, 1>

module {
  crag.graph name = "stereo_breakout_left" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 2>):
    // Extract channel 0 (Left  (L)) as a mono stream.
    %ch = crag.channel_slice %in, 0
              : !crag.audio<f32, 0, 2> -> !crag.audio<f32, 0, 1>
    crag.output %ch : !crag.audio<f32, 0, 1>
  }
}
