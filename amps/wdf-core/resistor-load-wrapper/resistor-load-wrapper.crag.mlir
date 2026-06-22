module {
  crag.graph name = "wdf_resistor_load" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %load = crag.param "wdf.load" min = 0.0 max = 1.0 default = 1.0 : f32
    %out = crag.scale %in, %load : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
