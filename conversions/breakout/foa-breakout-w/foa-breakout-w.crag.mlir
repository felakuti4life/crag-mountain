// First-Order Ambisonics (AmbiX: ACN/SN3D) Breakout - W (l=0, m= 0) omnidirectional
//
// Channel splitter: extracts the W (omnidirectional / pressure) component
// (channel 0) from a 4-channel First-Order Ambisonics (AmbiX: ACN/SN3D) stream and passes it
// through as an independent 1-channel (mono) audio stream.  All other channels
// are discarded by this graph.
//
// A "breakout" of an N-channel bus is the set of N such single-channel
// extractor graphs.  Route one instance of each member from the same
// 4-channel source to fan the bus out into 4 independent mono
// streams that can be processed, metered, or routed separately, then optionally
// recombined downstream with crag.channel_join.
//
// Conversion: channels 4 -> 1  (extracts channel 0)
//
// Usage via crag.include:
//   %w = crag.subgraph_ref "foa_breakout_w"(%bus)
//              : (!crag.audio<f32, 48000, 4, subtype="ambisonics">)
//                -> !crag.audio<f32, 48000, 1>

module {
  crag.graph name = "foa_breakout_w" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 4, subtype="ambisonics">):
    // Extract channel 0 (W (l=0, m= 0) omnidirectional) as a mono stream.
    %ch = crag.channel_slice %in, 0
              : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>
    crag.output %ch : !crag.audio<f32, 0, 1>
  }
}
