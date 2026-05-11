module {
  crag.graph name = "boss_ds1_clip" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %dist = crag.param "dist" min = 0.0 max = 1.0 default = 0.65 : f32
    %tone = crag.param "tone" min = 0.0 max = 1.0 default = 0.5 : f32
    %k = arith.addf %dist, %dist : f32
    %dr = crag.scale %in, %k : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %sym = crag.tanh %dr : !crag.audio<f32, 0, 0> -> !crag.audio<f32, 0, 0>
    %hard_thr = arith.constant 0.65 : f32
    %asym = crag.hard_clip %dr, %hard_thr : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %one = arith.constant 1.0 : f32
    %dryg = arith.subf %one, %tone : f32
    %dry = crag.scale %sym, %dryg : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %wet = crag.scale %asym, %tone : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %clip = crag.sum %dry, %wet : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.output %clip : !crag.audio<f32, 0, 0>
  }
}
