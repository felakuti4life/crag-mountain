// Two-Band Compressor
//
// Splits signal into low/high bands with a low-pass crossover, applies
// independent compression per band, then recombines.

module {
  crag.graph name = "two_band_compressor"
             sample_rate = 48000 channels = 1 default_visualizer = "compressor-viz" {
  ^bb0(%input: !crag.audio<f32, 0, 0>):
    %crossover_norm = crag.param "crossover_norm" min = 0.01 max = 0.45 default = 0.08 : f32

    %low_thr_db     = crag.param "low_threshold_db" min = -60.0 max = 0.0 default = -22.0 unit = "dB" : f32
    %low_ratio      = crag.param "low_ratio"        min = 1.0   max = 20.0 default = 3.0 : f32
    %low_atk_ms     = crag.param "low_attack_ms"    min = 0.1   max = 300.0 default = 25.0 unit = "ms" : f32
    %low_rel_ms     = crag.param "low_release_ms"   min = 10.0  max = 4000.0 default = 320.0 unit = "ms" : f32

    %high_thr_db    = crag.param "high_threshold_db" min = -60.0 max = 0.0 default = -16.0 unit = "dB" : f32
    %high_ratio     = crag.param "high_ratio"        min = 1.0   max = 30.0 default = 6.0 : f32
    %high_atk_ms    = crag.param "high_attack_ms"    min = 0.1   max = 150.0 default = 5.0 unit = "ms" : f32
    %high_rel_ms    = crag.param "high_release_ms"   min = 10.0  max = 2500.0 default = 180.0 unit = "ms" : f32
    %makeup_db      = crag.param "makeup_db"         min = -12.0 max = 24.0 default = 0.0 unit = "dB" : f32

    %fb_lp, %ff_lp = crag.get_filter_coeffs %crossover_norm order = 2 type = "lowpass"
                        : f32, !crag.coeff_vec, !crag.coeff_vec
    %low = crag.filter %input, %fb_lp, %ff_lp
             : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec) -> !crag.audio<f32, 0, 0>
    %neg1 = arith.constant -1.0 : f32
    %low_n = crag.scale %low, %neg1 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %high = crag.sum %input, %low_n : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>

    %tiny = arith.constant 1.0e-7 : f32
    %zero = arith.constant 0.0 : f32
    %one  = arith.constant 1.0 : f32
    %k20  = arith.constant 8.6858896380650366 : f32
    %kdb  = arith.constant 0.11512925464970229 : f32

    // Low band gain
    %ld    = crag.rms %low : !crag.audio<f32, 0, 0> -> f32
    %le    = crag.smooth %ld, %low_atk_ms, %low_rel_ms : f32, f32, f32 -> f32
    %les   = arith.maximumf %le, %tiny : f32
    %llog  = math.log %les : f32
    %ldb   = arith.mulf %llog, %k20 : f32
    %lir   = arith.divf %one, %low_ratio : f32
    %lsl   = arith.subf %lir, %one : f32
    %lab   = arith.subf %ldb, %low_thr_db : f32
    %lgr_u = arith.mulf %lab, %lsl : f32
    %lgr   = arith.minimumf %lgr_u, %zero : f32
    %llin  = arith.mulf %lgr, %kdb : f32
    %lgain = math.exp %llin : f32
    %low_c = crag.scale %low, %lgain : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>

    // High band gain
    %hd    = crag.rms %high : !crag.audio<f32, 0, 0> -> f32
    %he    = crag.smooth %hd, %high_atk_ms, %high_rel_ms : f32, f32, f32 -> f32
    %hes   = arith.maximumf %he, %tiny : f32
    %hlog  = math.log %hes : f32
    %hdb   = arith.mulf %hlog, %k20 : f32
    %hir   = arith.divf %one, %high_ratio : f32
    %hsl   = arith.subf %hir, %one : f32
    %hab   = arith.subf %hdb, %high_thr_db : f32
    %hgr_u = arith.mulf %hab, %hsl : f32
    %hgr   = arith.minimumf %hgr_u, %zero : f32
    %hlin  = arith.mulf %hgr, %kdb : f32
    %hgain = math.exp %hlin : f32
    %high_c = crag.scale %high, %hgain : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>

    %sum = crag.sum %low_c, %high_c : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    %mglog = arith.mulf %makeup_db, %kdb : f32
    %mgain = math.exp %mglog : f32
    %output = crag.scale %sum, %mgain : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
