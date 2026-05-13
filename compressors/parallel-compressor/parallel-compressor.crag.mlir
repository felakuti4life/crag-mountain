// Parallel Compressor
//
// New York style topology: heavily compressed branch blended with dry branch.

module {
  crag.graph name = "parallel_compressor"
             sample_rate = 48000 channels = 1 default_visualizer = "compressor-viz" {
  ^bb0(%input: !crag.audio<f32, 0, 0>):
    %threshold_db = crag.param "threshold_db" min = -60.0 max = 0.0 default = -30.0 unit = "dB" : f32
    %ratio        = crag.param "ratio"        min = 1.0   max = 40.0 default = 10.0 : f32
    %attack_ms    = crag.param "attack_ms"    min = 0.1   max = 120.0 default = 8.0 unit = "ms" : f32
    %release_ms   = crag.param "release_ms"   min = 10.0  max = 2500.0 default = 220.0 unit = "ms" : f32
    %makeup_db    = crag.param "makeup_db"    min = -12.0 max = 24.0 default = 6.0 unit = "dB" : f32
    %wet_level    = crag.param "wet_level"    min = 0.0   max = 1.0 default = 0.5 : f32
    %dry_level    = crag.param "dry_level"    min = 0.0   max = 1.0 default = 0.75 : f32

    %det      = crag.rms %input : !crag.audio<f32, 0, 0> -> f32
    %env      = crag.smooth %det, %attack_ms, %release_ms : f32, f32, f32 -> f32
    %tiny     = arith.constant 1.0e-7 : f32
    %env_safe = arith.maximumf %env, %tiny : f32
    %log_env  = math.log %env_safe : f32
    %k20ln10  = arith.constant 8.6858896380650366 : f32
    %env_db   = arith.mulf %log_env, %k20ln10 : f32

    %one      = arith.constant 1.0 : f32
    %inv_r    = arith.divf %one, %ratio : f32
    %slope    = arith.subf %inv_r, %one : f32
    %above    = arith.subf %env_db, %threshold_db : f32
    %gr_u     = arith.mulf %above, %slope : f32
    %zero     = arith.constant 0.0 : f32
    %gr_db    = arith.minimumf %gr_u, %zero : f32
    %total_db = arith.addf %gr_db, %makeup_db : f32

    %kln10_20 = arith.constant 0.11512925464970229 : f32
    %gain_log = arith.mulf %total_db, %kln10_20 : f32
    %gain     = math.exp %gain_log : f32

    %comp     = crag.scale %input, %gain : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %wet      = crag.scale %comp, %wet_level : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %dry      = crag.scale %input, %dry_level : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %output   = crag.sum %wet, %dry : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
