module {
  crag.graph name = "wdf_rc_adaptor" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %mix = crag.param "wdf.mix" min = 0.0 max = 1.0 default = 0.5 : f32
    %s0 = arith.constant 0.0 : f32
    %out, %s1 = crag.per_sample (%in) states (%s0) {
    ^bb0(%x: f32, %s: f32):
      %prev, %ns = crag.sample_delay %x, %s : (f32, f32) -> (f32, f32)
      %dry = arith.subf %x, %prev : f32
      %wet = arith.mulf %prev, %mix : f32
      %y = arith.addf %dry, %wet : f32
      crag.per_sample_yield %y, %ns : f32, f32
    } : (!crag.audio<f32, 0, 0>, f32) -> (!crag.audio<f32, 0, 0>, f32)
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
