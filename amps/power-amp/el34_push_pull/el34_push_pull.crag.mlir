module {
  crag.graph name = "el34_push_pull" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %drive = crag.param "drive" min = 0.0 max = 1.0 default = 0.75 : f32
    %turns = crag.param "turns_ratio" min = 0.1 max = 8.0 default = 2.3 : f32
    %k = arith.addf %drive, %drive : f32
    %a = crag.scale %in, %k : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %b = crag.tanh %a : !crag.audio<f32, 0, 0> -> !crag.audio<f32, 0, 0>
    %neg1 = arith.constant -1.0 : f32
    %c = crag.scale %b, %neg1 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %pp = crag.sum %b, %c : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    %out = crag.scale %pp, %turns : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
