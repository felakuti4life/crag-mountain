module {
  crag.graph name = "wdf_nonlinear_lambert_diode" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %drive = crag.param "wdf.drive" min = 0.1 max = 20.0 default = 2.5 : f32
    %s0 = arith.constant 0.0 : f32
    %out, %s1 = crag.per_sample (%in) states (%s0) {
    ^bb0(%x: f32, %s: f32):
      %xd = arith.mulf %x, %drive : f32
      %lw = crag.lambert_w %xd : (f32) -> f32
      %y = arith.subf %xd, %lw : f32
      crag.per_sample_yield %y, %y : f32, f32
    } : (!crag.audio<f32, 0, 0>, f32) -> (!crag.audio<f32, 0, 0>, f32)
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
