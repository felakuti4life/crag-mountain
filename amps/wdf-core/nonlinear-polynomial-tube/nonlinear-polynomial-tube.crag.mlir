module {
  crag.graph name = "wdf_nonlinear_polynomial_tube" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %a1 = crag.param "wdf.a1" min = 0.0 max = 8.0 default = 1.5 : f32
    %a2 = crag.param "wdf.a2" min = -8.0 max = 8.0 default = -0.5 : f32
    %a3 = crag.param "wdf.a3" min = -8.0 max = 8.0 default = 0.8 : f32
    %x2 = crag.audio_mul %in, %in : !crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0> -> !crag.audio<f32, 0, 0>
    %x3 = crag.audio_mul %x2, %in : !crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0> -> !crag.audio<f32, 0, 0>
    %t1 = crag.scale %in, %a1 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %t2 = crag.scale %x2, %a2 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %t3 = crag.scale %x3, %a3 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %u  = crag.sum %t1, %t2 : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    %out = crag.sum %u, %t3 : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
