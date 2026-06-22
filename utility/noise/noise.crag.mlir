// White Noise
// a basic graph that emits noise.

module {
  crag.graph name = "white_noise" sample_rate = 0 channels = 1 {

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    %amp = crag.param "amplitude" min = 0.0 max = 1.0 default = 1.0 : f32

    %noise = crag.white_noise : !crag.audio<f32, 0, 1>

    // -------------------------------------------------------------------------
    // Gate by playing state
    // -------------------------------------------------------------------------
    %noise_scaled = crag.scale %noise, %amp
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    crag.output %noise_scaled : !crag.audio<f32, 0, 1>
  }
}