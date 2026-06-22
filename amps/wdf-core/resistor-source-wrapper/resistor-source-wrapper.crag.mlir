module {
  crag.graph name = "wdf_resistor_source" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %gain = crag.param "wdf.source_gain" min = 0.0 max = 4.0 default = 1.0 : f32
    %out = crag.scale %in, %gain : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
