// Dual-Stage Serial Compressor
//
// Two serial downward stages: gentle "leveler" then fast "peak tamer".

module {
  crag.graph name = "dual_stage_serial_compressor"
             sample_rate = 48000 channels = 1 default_visualizer = "compressor-viz" {
  ^bb0(%input: !crag.audio<f32, 0, 0>):
    %thr1_db   = crag.param "stage1_threshold_db" min = -60.0 max = 0.0 default = -24.0 unit = "dB" : f32
    %ratio1    = crag.param "stage1_ratio"        min = 1.0   max = 10.0 default = 2.0 : f32
    %atk1_ms   = crag.param "stage1_attack_ms"    min = 0.1   max = 400.0 default = 35.0 unit = "ms" : f32
    %rel1_ms   = crag.param "stage1_release_ms"   min = 10.0  max = 4000.0 default = 400.0 unit = "ms" : f32

    %thr2_db   = crag.param "stage2_threshold_db" min = -36.0 max = 0.0 default = -10.0 unit = "dB" : f32
    %ratio2    = crag.param "stage2_ratio"        min = 1.0   max = 30.0 default = 8.0 : f32
    %atk2_ms   = crag.param "stage2_attack_ms"    min = 0.1   max = 80.0 default = 2.0 unit = "ms" : f32
    %rel2_ms   = crag.param "stage2_release_ms"   min = 10.0  max = 1500.0 default = 130.0 unit = "ms" : f32
    %makeup_db = crag.param "makeup_db"           min = -12.0 max = 24.0 default = 3.0 unit = "dB" : f32

    %tiny      = arith.constant 1.0e-7 : f32
    %one       = arith.constant 1.0 : f32
    %zero      = arith.constant 0.0 : f32
    %k20ln10   = arith.constant 8.6858896380650366 : f32
    %kln10_20  = arith.constant 0.11512925464970229 : f32

    // Stage 1
    %d1        = crag.rms %input : !crag.audio<f32, 0, 0> -> f32
    %e1        = crag.smooth %d1, %atk1_ms, %rel1_ms : f32, f32, f32 -> f32
    %e1s       = arith.maximumf %e1, %tiny : f32
    %l1        = math.log %e1s : f32
    %e1db      = arith.mulf %l1, %k20ln10 : f32
    %ir1       = arith.divf %one, %ratio1 : f32
    %sl1       = arith.subf %ir1, %one : f32
    %ab1       = arith.subf %e1db, %thr1_db : f32
    %gr1u      = arith.mulf %ab1, %sl1 : f32
    %gr1       = arith.minimumf %gr1u, %zero : f32
    %g1log     = arith.mulf %gr1, %kln10_20 : f32
    %g1        = math.exp %g1log : f32
    %s1        = crag.scale %input, %g1 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>

    // Stage 2
    %d2        = crag.peak %s1 : !crag.audio<f32, 0, 0> -> f32
    %e2        = crag.smooth %d2, %atk2_ms, %rel2_ms : f32, f32, f32 -> f32
    %e2s       = arith.maximumf %e2, %tiny : f32
    %l2        = math.log %e2s : f32
    %e2db      = arith.mulf %l2, %k20ln10 : f32
    %ir2       = arith.divf %one, %ratio2 : f32
    %sl2       = arith.subf %ir2, %one : f32
    %ab2       = arith.subf %e2db, %thr2_db : f32
    %gr2u      = arith.mulf %ab2, %sl2 : f32
    %gr2       = arith.minimumf %gr2u, %zero : f32
    %tot2      = arith.addf %gr2, %makeup_db : f32
    %g2log     = arith.mulf %tot2, %kln10_20 : f32
    %g2        = math.exp %g2log : f32
    %output    = crag.scale %s1, %g2 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
