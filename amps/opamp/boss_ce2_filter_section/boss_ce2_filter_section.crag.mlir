module {
  crag.include "amps/wdf-core/series-junction.crag.mlir" as "wdf_series"
  crag.graph name = "boss_ce2_filter_section" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %rate = crag.param "rate" min = 0.0 max = 1.0 default = 0.4 : f32
    %depth = crag.param "depth" min = 0.0 max = 1.0 default = 0.6 : f32
    %cutoff = arith.addf %rate, %rate : f32
    %fb, %ff = crag.get_filter_coeffs %cutoff order = 2 type = "bandpass" : f32, !crag.coeff_vec, !crag.coeff_vec
    %flt = crag.filter %in, %fb, %ff : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec) -> !crag.audio<f32, 0, 0>
    %mod = crag.scale %flt, %depth : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %one = arith.constant 1.0 : f32
    %dryg = arith.subf %one, %rate : f32
    %dry = crag.scale %in, %dryg : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %out = crag.sum %dry, %mod : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
