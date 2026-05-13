// Opto-Style Compressor
//
// Feed-forward topology with fast attack and dual-time release blend to emulate
// opto memory behavior.

module {
  crag.graph name = "opto_style_compressor"
             sample_rate = 48000 channels = 1 default_visualizer = "compressor-viz" {
  ^bb0(%input: !crag.audio<f32, 0, 0>):
    %threshold_db = crag.param "threshold_db" min = -48.0 max = 0.0 default = -16.0 unit = "dB" : f32
    %ratio        = crag.param "ratio"        min = 1.0   max = 12.0 default = 3.0 : f32
    %attack_ms    = crag.param "attack_ms"    min = 0.5   max = 100.0 default = 12.0 unit = "ms" : f32
    %release_a_ms = crag.param "release_a_ms" min = 20.0  max = 1500.0 default = 120.0 unit = "ms" : f32
    %release_b_ms = crag.param "release_b_ms" min = 100.0 max = 6000.0 default = 1200.0 unit = "ms" : f32
    %memory       = crag.param "memory"       min = 0.0   max = 1.0 default = 0.55 : f32
    %makeup_db    = crag.param "makeup_db"    min = -12.0 max = 24.0 default = 2.0 unit = "dB" : f32

    %det       = crag.rms %input : !crag.audio<f32, 0, 0> -> f32
    %env_a     = crag.smooth %det, %attack_ms, %release_a_ms : f32, f32, f32 -> f32
    %env_b     = crag.smooth %det, %attack_ms, %release_b_ms : f32, f32, f32 -> f32
    %one       = arith.constant 1.0 : f32
    %inv_mem   = arith.subf %one, %memory : f32
    %a_scaled  = arith.mulf %env_a, %inv_mem : f32
    %b_scaled  = arith.mulf %env_b, %memory : f32
    %env       = arith.addf %a_scaled, %b_scaled : f32

    %tiny      = arith.constant 1.0e-7 : f32
    %env_safe  = arith.maximumf %env, %tiny : f32
    %log_env   = math.log %env_safe : f32
    %k20ln10   = arith.constant 8.6858896380650366 : f32
    %env_db    = arith.mulf %log_env, %k20ln10 : f32

    %inv_ratio = arith.divf %one, %ratio : f32
    %slope     = arith.subf %inv_ratio, %one : f32
    %above     = arith.subf %env_db, %threshold_db : f32
    %gr_u      = arith.mulf %above, %slope : f32
    %zero      = arith.constant 0.0 : f32
    %gr_db     = arith.minimumf %gr_u, %zero : f32
    %total_db  = arith.addf %gr_db, %makeup_db : f32

    %kln10_20  = arith.constant 0.11512925464970229 : f32
    %gain_log  = arith.mulf %total_db, %kln10_20 : f32
    %gain      = math.exp %gain_log : f32
    %output    = crag.scale %input, %gain : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
