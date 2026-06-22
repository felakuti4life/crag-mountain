module {
  crag.include "amps/wdf-core/nonlinear-tanh-diode.crag.mlir" as "wdf_tanh_diode"
  crag.graph name = "tubescreamer_ts808_clip" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %drive = crag.param "drive" min = 0.0 max = 1.0 default = 0.6 : f32
    %tone  = crag.param "tone" min = 0.0 max = 1.0 default = 0.5 : f32
    %d = arith.addf %drive, %drive : f32
    %pre = crag.scale %in, %d : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %clip = crag.tanh %pre : !crag.audio<f32, 0, 0> -> !crag.audio<f32, 0, 0>
    %one = arith.constant 1.0 : f32
    %dryg = arith.subf %one, %tone : f32
    %dry = crag.scale %in, %dryg : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %wet = crag.scale %clip, %tone : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %out = crag.sum %dry, %wet : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
