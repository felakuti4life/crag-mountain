// Upward Compressor
//
// Boosts signals below threshold (instead of reducing signals above threshold).

module {
  crag.graph name = "upward_compressor"
             sample_rate = 48000 channels = 1 default_visualizer = "compressor-viz" {
  ^bb0(%input: !crag.audio<f32, 0, 0>):
    %threshold_db = crag.param "threshold_db" min = -72.0 max = -6.0 default = -36.0 unit = "dB" : f32
    %ratio_up     = crag.param "ratio_up"     min = 1.0   max = 8.0  default = 2.0 : f32
    %max_boost_db = crag.param "max_boost_db" min = 0.0   max = 30.0 default = 12.0 unit = "dB" : f32
    %attack_ms    = crag.param "attack_ms"    min = 0.1   max = 400.0 default = 25.0 unit = "ms" : f32
    %release_ms   = crag.param "release_ms"   min = 10.0  max = 4000.0 default = 300.0 unit = "ms" : f32

    %det      = crag.rms %input : !crag.audio<f32, 0, 0> -> f32
    %env      = crag.smooth %det, %attack_ms, %release_ms : f32, f32, f32 -> f32
    %tiny     = arith.constant 1.0e-7 : f32
    %env_safe = arith.maximumf %env, %tiny : f32
    %log_env  = math.log %env_safe : f32
    %k20ln10  = arith.constant 8.6858896380650366 : f32
    %env_db   = arith.mulf %log_env, %k20ln10 : f32

    %below    = arith.subf %threshold_db, %env_db : f32
    %zero     = arith.constant 0.0 : f32
    %below_p  = arith.maximumf %below, %zero : f32
    %one      = arith.constant 1.0 : f32
    %inv_r    = arith.divf %one, %ratio_up : f32
    %coeff    = arith.subf %one, %inv_r : f32
    %boost_u  = arith.mulf %below_p, %coeff : f32
    %boost_db = arith.minimumf %boost_u, %max_boost_db : f32

    %kln10_20 = arith.constant 0.11512925464970229 : f32
    %gain_log = arith.mulf %boost_db, %kln10_20 : f32
    %gain     = math.exp %gain_log : f32

    %output   = crag.scale %input, %gain : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
