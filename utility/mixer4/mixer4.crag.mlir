// Mixer (4 → 1)
//
// Sums four audio inputs into a single output, with an independent gain in
// decibels on each input and a master gain applied to the sum.  Unconnected
// inputs contribute silence, so the graph doubles as a 2- or 3-input mixer.
//
// Conversion per input: linear = 10^(gain_db / 20) = e^(gain_db · ln(10)/20)
//
//   out = (a·g_a + b·g_b + c·g_c + d·g_d) · g_master
//
// Parameters:
//   gain_a_db   [-96, 24] dB – gain on input a (default 0.0)
//   gain_b_db   [-96, 24] dB – gain on input b (default 0.0)
//   gain_c_db   [-96, 24] dB – gain on input c (default 0.0)
//   gain_d_db   [-96, 24] dB – gain on input d (default 0.0)
//   master_db   [-96, 24] dB – gain on the summed output (default 0.0)
//
// The inputs and output are channel-agnostic; all four inputs must carry the
// same channel count.  Summing four full-scale signals at 0 dB can exceed
// ±1.0, so trim the input gains or the master gain (or follow with a
// limiter) when the sources are hot.
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "mixer4"(%a, %b, %c, %d)
//              : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>,
//                 !crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
//                -> !crag.audio<f32, 0, 0>

module {
  crag.graph name = "mixer4" sample_rate = 0 channels = 1 {
  ^bb0(%a: !crag.audio<f32, 0, 0>, %b: !crag.audio<f32, 0, 0>,
       %c: !crag.audio<f32, 0, 0>, %d: !crag.audio<f32, 0, 0>):

    %gain_a_db = crag.param "gain_a_db" min = -96.0 max = 24.0 default = 0.0 unit = "dB" : f32
    %gain_b_db = crag.param "gain_b_db" min = -96.0 max = 24.0 default = 0.0 unit = "dB" : f32
    %gain_c_db = crag.param "gain_c_db" min = -96.0 max = 24.0 default = 0.0 unit = "dB" : f32
    %gain_d_db = crag.param "gain_d_db" min = -96.0 max = 24.0 default = 0.0 unit = "dB" : f32
    %master_db = crag.param "master_db" min = -96.0 max = 24.0 default = 0.0 unit = "dB" : f32

    // linear = e^(gain_db · ln(10)/20)
    %db_to_ln = arith.constant 0.115129254649702 : f32  // ln(10)/20

    %exp_a = arith.mulf %gain_a_db, %db_to_ln : f32
    %lin_a = math.exp %exp_a : f32
    %exp_b = arith.mulf %gain_b_db, %db_to_ln : f32
    %lin_b = math.exp %exp_b : f32
    %exp_c = arith.mulf %gain_c_db, %db_to_ln : f32
    %lin_c = math.exp %exp_c : f32
    %exp_d = arith.mulf %gain_d_db, %db_to_ln : f32
    %lin_d = math.exp %exp_d : f32
    %exp_m = arith.mulf %master_db, %db_to_ln : f32
    %lin_m = math.exp %exp_m : f32

    // Per-input trim.
    %a_g = crag.scale %a, %lin_a : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %b_g = crag.scale %b, %lin_b : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %c_g = crag.scale %c, %lin_c : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %d_g = crag.scale %d, %lin_d : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>

    // Sum, then master.
    %sum = crag.sum %a_g, %b_g, %c_g, %d_g
               : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>,
                  !crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                 -> !crag.audio<f32, 0, 0>
    %out = crag.scale %sum, %lin_m : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>

    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
