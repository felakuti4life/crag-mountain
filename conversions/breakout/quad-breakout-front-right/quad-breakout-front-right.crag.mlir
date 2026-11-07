// Quadraphonic (FL/FR/RL/RR) Breakout - Front Right (FR)
//
// Channel splitter: extracts the front-right channel
// (channel 1) from a 4-channel Quadraphonic (FL/FR/RL/RR) stream and passes it
// through as an independent 1-channel (mono) audio stream.  All other channels
// are discarded by this graph.
//
// A "breakout" of an N-channel bus is the set of N such single-channel
// extractor graphs.  Route one instance of each member from the same
// 4-channel source to fan the bus out into 4 independent mono
// streams that can be processed, metered, or routed separately, then optionally
// recombined downstream with crag.channel_join.
//
// Conversion: channels 4 -> 1  (extracts channel 1)
//
// Usage via crag.include:
//   %front_right = crag.subgraph_ref "quad_breakout_front_right"(%bus)
//              : (!crag.audio<f32, 48000, 4>)
//                -> !crag.audio<f32, 48000, 1>

module {
  crag.graph name = "quad_breakout_front_right" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 4>):
    // Extract channel 1 (Front Right (FR)) as a mono stream.
    %ch = crag.channel_slice %in, 1
              : !crag.audio<f32, 0, 4> -> !crag.audio<f32, 0, 1>
    crag.output %ch : !crag.audio<f32, 0, 1>
  }
}
