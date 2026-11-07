// First-Order Ambisonics (AmbiX: ACN/SN3D) Breakout - Z (l=1, m= 0) up/down
//
// Channel splitter: extracts the Z (up-down dipole) component
// (channel 2) from a 4-channel First-Order Ambisonics (AmbiX: ACN/SN3D) stream and passes it
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
//   %z = crag.subgraph_ref "foa_breakout_z"(%bus)
//              : (!crag.audio<f32, 48000, 4, subtype="ambisonics">)
//                -> !crag.audio<f32, 48000, 1>

module {
  crag.graph name = "foa_breakout_z" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 4, subtype="ambisonics">):
    // Extract channel 2 (Z (l=1, m= 0) up/down) as a mono stream.
    %ch = crag.channel_slice %in, 2
              : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    crag.output %ch : !crag.audio<f32, 0, 1>
  }
}
