// Lookahead Limiter
//
// Feed-forward peak limiter with delayed program path to allow predictive gain.

module {
  crag.graph name = "lookahead_limiter"
             sample_rate = 48000 channels = 1 default_visualizer = "compressor-viz" {
  ^bb0(%input: !crag.audio<f32, 0, 0>):
    %threshold_db = crag.param "threshold_db" min = -24.0 max = 0.0 default = -1.0 unit = "dB" : f32
    %attack_ms    = crag.param "attack_ms"    min = 0.1   max = 40.0 default = 1.0 unit = "ms" : f32
    %release_ms   = crag.param "release_ms"   min = 10.0  max = 1500.0 default = 120.0 unit = "ms" : f32

    %lookahead = crag.delay_line : !crag.delay<f32, 48000, 1, 512>
    %delayed   = crag.pop_delay %lookahead : !crag.delay<f32, 48000, 1, 512> -> !crag.audio<f32, 0, 0>
    crag.push_delay %lookahead, %input : !crag.delay<f32, 48000, 1, 512>, !crag.audio<f32, 0, 0>

    %det      = crag.peak %input : !crag.audio<f32, 0, 0> -> f32
    %env      = crag.smooth %det, %attack_ms, %release_ms : f32, f32, f32 -> f32
    %tiny     = arith.constant 1.0e-7 : f32
    %env_safe = arith.maximumf %env, %tiny : f32

    %kln10_20 = arith.constant 0.11512925464970229 : f32
    %thr_log  = arith.mulf %threshold_db, %kln10_20 : f32
    %thr_lin  = math.exp %thr_log : f32
    %raw_gain = arith.divf %thr_lin, %env_safe : f32
    %one      = arith.constant 1.0 : f32
    %gain     = arith.minimumf %raw_gain, %one : f32

    %output   = crag.scale %delayed, %gain : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
