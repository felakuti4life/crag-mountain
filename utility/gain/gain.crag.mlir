// Gain
//
// Scales an audio signal by a gain expressed in decibels.  Negative values
// attenuate, 0 dB passes the signal through unchanged, and positive values
// boost (up to +24 dB).
//
// Conversion: linear = 10^(gain_db / 20) = e^(gain_db · ln(10)/20)
//
// Parameters:
//   gain_db  [-96, 24] dB – gain applied to the signal (default 0.0)
//
// At the -96 dB floor the linear gain is ~1.6e-5, which is below audibility
// for full-scale program material; hosts that need a true mute should route
// silence instead.
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "gain"(%in)
//              : (!crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>

module {
  crag.graph name = "gain" sample_rate = 0 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    %gain_db = crag.param "gain_db" min = -96.0 max = 24.0 default = 0.0 unit = "dB" : f32

    // linear = e^(gain_db · ln(10)/20)
    %db_to_ln = arith.constant 0.115129254649702 : f32  // ln(10)/20
    %exponent = arith.mulf %gain_db, %db_to_ln : f32
    %linear   = math.exp %exponent : f32

    %out = crag.scale %in, %linear
               : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>

    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
