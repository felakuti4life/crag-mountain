module {
  crag.graph name = "wdf_series_junction" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %rp_left  = crag.param "wdf.rp_left"  min = 1.0 max = 1.0e6 default = 10000.0 : f32
    %rp_right = crag.param "wdf.rp_right" min = 1.0 max = 1.0e6 default = 10000.0 : f32
    %two = arith.constant 2.0 : f32
    %sum = arith.addf %rp_left, %rp_right : f32
    %num = arith.mulf %two, %rp_left : f32
    %k = arith.divf %num, %sum : f32
    %one = arith.constant 1.0 : f32
    %km1 = arith.subf %k, %one : f32
    %out = crag.scale %in, %km1 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
