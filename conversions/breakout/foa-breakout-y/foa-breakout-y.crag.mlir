// First-Order Ambisonics (AmbiX: ACN/SN3D) Breakout - Y (l=1, m=-1) left/right
//
// Channel splitter: extracts the Y (left-right dipole) component
// (channel 1) from a 4-channel First-Order Ambisonics (AmbiX: ACN/SN3D) stream and passes it
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
//   %y = crag.subgraph_ref "foa_breakout_y"(%bus)
//              : (!crag.audio<f32, 48000, 4, subtype="ambisonics">)
//                -> !crag.audio<f32, 48000, 1>

module {
  crag.graph name = "foa_breakout_y" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 4, subtype="ambisonics">):
    // Extract channel 1 (Y (l=1, m=-1) left/right) as a mono stream.
    %ch = crag.channel_slice %in, 1
              : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    crag.output %ch : !crag.audio<f32, 0, 1>
  }
}
