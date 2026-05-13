// Sidechain Ducker
//
// Two-input compressor topology where sidechain drives gain reduction on program.

module {
  crag.graph name = "sidechain_ducker"
             sample_rate = 48000 channels = 1 default_visualizer = "compressor-viz" {
  ^bb0(%program: !crag.audio<f32, 0, 0>, %sidechain: !crag.audio<f32, 0, 0>):
    %threshold_db = crag.param "threshold_db" min = -60.0 max = 0.0 default = -24.0 unit = "dB" : f32
    %duck_ratio   = crag.param "duck_ratio"   min = 1.0   max = 40.0 default = 8.0 : f32
    %attack_ms    = crag.param "attack_ms"    min = 0.1   max = 200.0 default = 8.0 unit = "ms" : f32
    %release_ms   = crag.param "release_ms"   min = 10.0  max = 3000.0 default = 350.0 unit = "ms" : f32
    %floor_db     = crag.param "floor_db"     min = -60.0 max = 0.0 default = -24.0 unit = "dB" : f32

    %det      = crag.rms %sidechain : !crag.audio<f32, 0, 0> -> f32
    %env      = crag.smooth %det, %attack_ms, %release_ms : f32, f32, f32 -> f32
    %tiny     = arith.constant 1.0e-7 : f32
    %env_safe = arith.maximumf %env, %tiny : f32
    %log_env  = math.log %env_safe : f32
    %k20ln10  = arith.constant 8.6858896380650366 : f32
    %env_db   = arith.mulf %log_env, %k20ln10 : f32

    %one      = arith.constant 1.0 : f32
    %inv_r    = arith.divf %one, %duck_ratio : f32
    %slope    = arith.subf %inv_r, %one : f32
    %above    = arith.subf %env_db, %threshold_db : f32
    %gr_u     = arith.mulf %above, %slope : f32
    %zero     = arith.constant 0.0 : f32
    %gr_db0   = arith.minimumf %gr_u, %zero : f32
    %gr_db    = arith.maximumf %gr_db0, %floor_db : f32

    %kln10_20 = arith.constant 0.11512925464970229 : f32
    %gain_log = arith.mulf %gr_db, %kln10_20 : f32
    %gain     = math.exp %gain_log : f32

    %output   = crag.scale %program, %gain : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
