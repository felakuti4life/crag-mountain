// multiply_float — a * b on float control values.
//
//   product = a * b
//
// Place this as a control node to scale one parameter by another, e.g.
// multiplying a base cutoff by an envelope amount before feeding a filter.
//
// Named control pins:
//   Inputs (param, f32):
//     a        — first operand (default 1.0)
//     b        — second operand (default 1.0)
//   Output (param_output, f32):
//     product  — a * b
//
// A crag.graph (not a bare crag.func) so the engine registry lists it as an
// instantiable node; the audio output is silent and exists only because
// crag.graph requires one.

module {
  crag.graph name = "multiply_float" sample_rate = 0 channels = 1 {
    %a = crag.param "a" min = -1.0e20 max = 1.0e20 default = 1.0 : f32
    %b = crag.param "b" min = -1.0e20 max = 1.0e20 default = 1.0 : f32

    %product = arith.mulf %a, %b : f32

    crag.param_output "product" %product min = -1.0e20 max = 1.0e20 default = 1.0 : f32

    // Silent audio output required by crag.graph.
    %noise   = crag.white_noise : !crag.audio<f32, 0, 1>
    %c0_f    = arith.constant 0.0 : f32
    %silence = crag.scale %noise, %c0_f
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %silence : !crag.audio<f32, 0, 1>
  }
}
