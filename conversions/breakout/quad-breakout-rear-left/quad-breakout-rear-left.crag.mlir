// Quadraphonic (FL/FR/RL/RR) Breakout - Rear Left   (RL)
//
// Channel splitter: extracts the rear/surround-left channel
// (channel 2) from a 4-channel Quadraphonic (FL/FR/RL/RR) stream and passes it
// through as an independent 1-channel (mono) audio stream.  All other channels
// are discarded by this graph.
//
// A "breakout" of an N-channel bus is the set of N such single-channel
// extractor graphs.  Route one instance of each member from the same
// 4-channel source to fan the bus out into 4 independent mono
// streams that can be processed, metered, or routed separately, then optionally
// recombined downstream with crag.channel_join.
//
// Conversion: channels 4 -> 1  (extracts channel 2)
//
// Usage via crag.include:
//   %rear_left = crag.subgraph_ref "quad_breakout_rear_left"(%bus)
//              : (!crag.audio<f32, 48000, 4>)
//                -> !crag.audio<f32, 48000, 1>

module {
  crag.graph name = "quad_breakout_rear_left" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 4>):
    // Extract channel 2 (Rear Left   (RL)) as a mono stream.
    %ch = crag.channel_slice %in, 2
              : !crag.audio<f32, 0, 4> -> !crag.audio<f32, 0, 1>
    crag.output %ch : !crag.audio<f32, 0, 1>
  }
}
