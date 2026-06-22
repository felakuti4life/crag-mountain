module {
  crag.graph name = "proco_rat_clip" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %dist = crag.param "distortion" min = 0.0 max = 1.0 default = 0.7 : f32
    %filter = crag.param "filter" min = 0.0 max = 1.0 default = 0.5 : f32
    %k = arith.addf %dist, %dist : f32
    %dr = crag.scale %in, %k : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %clip = crag.tanh %dr : !crag.audio<f32, 0, 0> -> !crag.audio<f32, 0, 0>
    %lp_c = arith.maximumf %filter, %filter : f32
    %fb, %ff = crag.get_filter_coeffs %lp_c order = 2 type = "lowpass" : f32, !crag.coeff_vec, !crag.coeff_vec
    %out = crag.filter %clip, %fb, %ff : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec) -> !crag.audio<f32, 0, 0>
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
