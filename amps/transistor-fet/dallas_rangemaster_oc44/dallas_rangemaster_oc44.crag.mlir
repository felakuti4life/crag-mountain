module {
  crag.graph name = "dallas_rangemaster_oc44" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %gain = crag.param "gain" min = 0.0 max = 1.0 default = 0.6 : f32
    %bias = crag.param "bias" min = -1.0 max = 1.0 default = 0.0 : f32
    %k = arith.addf %gain, %gain : f32
    %s0 = arith.constant 0.0 : f32
    %out, %s1 = crag.per_sample (%in) states (%s0) {
    ^bb0(%x: f32, %s: f32):
      %xb = arith.addf %x, %bias : f32
      %acc = arith.addf %xb, %s : f32
      %it = crag.per_sample_iterate %acc iterations = 4 {
      ^bb0(%v: f32):
        %half = arith.constant 5.000000e-01 : f32
        %n = arith.mulf %v, %half : f32
        crag.per_sample_iterate_yield %n : f32
      } : (f32) -> (f32)
      %y = arith.mulf %it, %k : f32
      crag.per_sample_yield %y, %y : f32, f32
    } : (!crag.audio<f32, 0, 0>, f32) -> (!crag.audio<f32, 0, 0>, f32)
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
