// add_float — a + b on float control values.
//
//   sum = a + b
//
// Place this as a control node to offset one parameter by another, e.g.
// adding a modulation depth to a base cutoff before feeding a filter.
//
// Named control pins:
//   Inputs (param, f32):
//     a        — first operand (default 0.0)
//     b        — second operand (default 0.0)
//   Output (param_output, f32):
//     sum      — a + b
//
// A crag.graph (not a bare crag.func) so the engine registry lists it as an
// instantiable node; the audio output is silent and exists only because
// crag.graph requires one.

module {
  crag.graph name = "add_float" sample_rate = 0 channels = 1 {
    %a = crag.param "a" min = -1.0e20 max = 1.0e20 default = 0.0 : f32
    %b = crag.param "b" min = -1.0e20 max = 1.0e20 default = 0.0 : f32

    %sum = arith.addf %a, %b : f32

    crag.param_output "sum" %sum min = -1.0e20 max = 1.0e20 default = 0.0 : f32

    // Silent audio output required by crag.graph.
    %noise   = crag.white_noise : !crag.audio<f32, 0, 1>
    %c0_f    = arith.constant 0.0 : f32
    %silence = crag.scale %noise, %c0_f
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %silence : !crag.audio<f32, 0, 1>
  }
}
