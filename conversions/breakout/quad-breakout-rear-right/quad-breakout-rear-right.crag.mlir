// Quadraphonic (FL/FR/RL/RR) Breakout - Rear Right  (RR)
//
// Channel splitter: extracts the rear/surround-right channel
// (channel 3) from a 4-channel Quadraphonic (FL/FR/RL/RR) stream and passes it
// through as an independent 1-channel (mono) audio stream.  All other channels
// are discarded by this graph.
//
// A "breakout" of an N-channel bus is the set of N such single-channel
// extractor graphs.  Route one instance of each member from the same
// 4-channel source to fan the bus out into 4 independent mono
// streams that can be processed, metered, or routed separately, then optionally
// recombined downstream with crag.channel_join.
//
// Conversion: channels 4 -> 1  (extracts channel 3)
//
// Usage via crag.include:
//   %rear_right = crag.subgraph_ref "quad_breakout_rear_right"(%bus)
//              : (!crag.audio<f32, 48000, 4>)
//                -> !crag.audio<f32, 48000, 1>

module {
  crag.graph name = "quad_breakout_rear_right" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 4>):
    // Extract channel 3 (Rear Right  (RR)) as a mono stream.
    %ch = crag.channel_slice %in, 3
              : !crag.audio<f32, 0, 4> -> !crag.audio<f32, 0, 1>
    crag.output %ch : !crag.audio<f32, 0, 1>
  }
}
