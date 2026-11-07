// 5.1 Surround (ITU-R BS.775 / SMPTE) Breakout - LFE / Sub     (LFE)
//
// Channel splitter: extracts the low-frequency-effects (subwoofer) channel
// (channel 3) from a 6-channel 5.1 Surround (ITU-R BS.775 / SMPTE) stream and passes it
// through as an independent 1-channel (mono) audio stream.  All other channels
// are discarded by this graph.
//
// A "breakout" of an N-channel bus is the set of N such single-channel
// extractor graphs.  Route one instance of each member from the same
// 6-channel source to fan the bus out into 6 independent mono
// streams that can be processed, metered, or routed separately, then optionally
// recombined downstream with crag.channel_join.
//
// Conversion: channels 6 -> 1  (extracts channel 3)
//
// Usage via crag.include:
//   %lfe = crag.subgraph_ref "51_breakout_lfe"(%bus)
//              : (!crag.audio<f32, 48000, 6>)
//                -> !crag.audio<f32, 48000, 1>

module {
  crag.graph name = "51_breakout_lfe" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 6>):
    // Extract channel 3 (LFE / Sub     (LFE)) as a mono stream.
    %ch = crag.channel_slice %in, 3
              : !crag.audio<f32, 0, 6> -> !crag.audio<f32, 0, 1>
    crag.output %ch : !crag.audio<f32, 0, 1>
  }
}
