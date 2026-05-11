module {
  crag.graph name = "dod250_mxr_distortion_plus_clip" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %drive = crag.param "drive" min = 0.0 max = 1.0 default = 0.7 : f32
    %level = crag.param "level" min = 0.0 max = 1.0 default = 0.8 : f32
    %k = arith.addf %drive, %drive : f32
    %dr = crag.scale %in, %k : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %clip = crag.tanh %dr : !crag.audio<f32, 0, 0> -> !crag.audio<f32, 0, 0>
    %out = crag.scale %clip, %level : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
