module {
  crag.graph name = "wdf_nonlinear_tanh_diode" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %drive = crag.param "wdf.drive" min = 0.1 max = 20.0 default = 3.0 : f32
    %pre = crag.scale %in, %drive : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %out = crag.tanh %pre : !crag.audio<f32, 0, 0> -> !crag.audio<f32, 0, 0>
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
