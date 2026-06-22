module {
  crag.include "amps/wdf-core/nonlinear-polynomial-tube.crag.mlir" as "tube_model"
  crag.graph name = "6l6_push_pull" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %drive = crag.param "drive" min = 0.0 max = 1.0 default = 0.7 : f32
    %turns = crag.param "turns_ratio" min = 0.1 max = 8.0 default = 2.0 : f32
    %k = arith.addf %drive, %drive : f32
    %pos = crag.scale %in, %k : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %neg = crag.scale %in, %k : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %neg1 = arith.constant -1.0 : f32
    %negp = crag.scale %neg, %neg1 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %sum = crag.sum %pos, %negp : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    %out = crag.scale %sum, %turns : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
