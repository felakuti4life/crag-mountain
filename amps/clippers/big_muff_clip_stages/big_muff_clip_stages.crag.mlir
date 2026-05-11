module {
  crag.graph name = "big_muff_clip_stages" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %sustain = crag.param "sustain" min = 0.0 max = 1.0 default = 0.75 : f32
    %tone = crag.param "tone" min = 0.0 max = 1.0 default = 0.5 : f32
    %k = arith.addf %sustain, %sustain : f32
    %st1 = crag.scale %in, %k : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %c1 = crag.tanh %st1 : !crag.audio<f32, 0, 0> -> !crag.audio<f32, 0, 0>
    %st2 = crag.scale %c1, %k : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %c2 = crag.tanh %st2 : !crag.audio<f32, 0, 0> -> !crag.audio<f32, 0, 0>
    %one = arith.constant 1.0 : f32
    %dryg = arith.subf %one, %tone : f32
    %dry = crag.scale %c1, %dryg : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %wet = crag.scale %c2, %tone : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %out = crag.sum %dry, %wet : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
