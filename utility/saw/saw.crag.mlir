// Saw Tone
// a basic graph that emits a saw tone.

module {
  crag.graph name = "saw_tone" sample_rate = 0 channels = 1 {

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    %freq = crag.param "freq" min = 20.0 max = 10000.0 default = 440.0 : f32
    %amp = crag.param "amplitude" min = 0.0 max = 1.0 default = 1.0 : f32
    %phase = crag.param "phase" min = 0.0 max = 3.14 default = 0.0 : f32

    %saw = crag.saw %freq, %phase : f32, f32 -> !crag.audio<f32, 0, 1>

    // -------------------------------------------------------------------------
    // Attenuate by the amplitude parameter
    // -------------------------------------------------------------------------
    %saw_scaled = crag.scale %saw, %amp
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    crag.output %saw_scaled : !crag.audio<f32, 0, 1>
  }
}