// Program-Dependent Release Compressor
//
// Blends a fast and a slow envelope follower so release behavior adapts with
// signal intensity.

module {
  crag.graph name = "program_dependent_release_compressor"
             sample_rate = 48000 channels = 1 default_visualizer = "compressor-viz" {
  ^bb0(%input: !crag.audio<f32, 0, 0>):
    %threshold_db = crag.param "threshold_db" min = -60.0 max = 0.0 default = -18.0 unit = "dB" : f32
    %ratio        = crag.param "ratio"        min = 1.0   max = 20.0 default = 4.0 : f32
    %attack_ms    = crag.param "attack_ms"    min = 0.1   max = 200.0 default = 10.0 unit = "ms" : f32
    %release_fast = crag.param "release_fast_ms" min = 10.0 max = 800.0 default = 80.0 unit = "ms" : f32
    %release_slow = crag.param "release_slow_ms" min = 30.0 max = 4000.0 default = 600.0 unit = "ms" : f32
    %makeup_db    = crag.param "makeup_db"    min = -12.0 max = 24.0 default = 0.0 unit = "dB" : f32

    %det      = crag.rms %input : !crag.audio<f32, 0, 0> -> f32
    %env_f    = crag.smooth %det, %attack_ms, %release_fast : f32, f32, f32 -> f32
    %env_s    = crag.smooth %det, %attack_ms, %release_slow : f32, f32, f32 -> f32

    %tiny     = arith.constant 1.0e-7 : f32
    %env_f_s  = arith.maximumf %env_f, %tiny : f32
    %env_s_s  = arith.maximumf %env_s, %tiny : f32
    %log_f    = math.log %env_f_s : f32
    %log_s    = math.log %env_s_s : f32
    %k20ln10  = arith.constant 8.6858896380650366 : f32
    %envf_db  = arith.mulf %log_f, %k20ln10 : f32
    %envs_db  = arith.mulf %log_s, %k20ln10 : f32

    // Blend toward the fast release path as level rises above threshold.
    %above    = arith.subf %envf_db, %threshold_db : f32
    %zero     = arith.constant 0.0 : f32
    %above_p  = arith.maximumf %above, %zero : f32
    %k24      = arith.constant 24.0 : f32
    %w_u      = arith.divf %above_p, %k24 : f32
    %one      = arith.constant 1.0 : f32
    %w        = arith.minimumf %w_u, %one : f32
    %iw       = arith.subf %one, %w : f32
    %a        = arith.mulf %envf_db, %w : f32
    %b        = arith.mulf %envs_db, %iw : f32
    %env_db   = arith.addf %a, %b : f32

    %inv_r    = arith.divf %one, %ratio : f32
    %slope    = arith.subf %inv_r, %one : f32
    %ab       = arith.subf %env_db, %threshold_db : f32
    %gr_u     = arith.mulf %ab, %slope : f32
    %gr_db    = arith.minimumf %gr_u, %zero : f32
    %total_db = arith.addf %gr_db, %makeup_db : f32
    %kln10_20 = arith.constant 0.11512925464970229 : f32
    %gain_log = arith.mulf %total_db, %kln10_20 : f32
    %gain     = math.exp %gain_log : f32

    %output   = crag.scale %input, %gain : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
