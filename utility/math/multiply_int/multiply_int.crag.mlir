// multiply_int — a * b on int control values.
//
//   product = a * b
//
// Place this as a control node to scale one integer control by another, e.g.
// multiplying a step index by a stride.
//
// Named control pins:
//   Inputs (param_int, i32):
//     a        — first operand (default 1)
//     b        — second operand (default 1)
//   Output (param_output_int, i32):
//     product  — a * b
//
// A crag.graph (not a bare crag.func) so the engine registry lists it as an
// instantiable node; the audio output is silent and exists only because
// crag.graph requires one.

module {
  crag.graph name = "multiply_int" sample_rate = 0 channels = 1 {
    %a = crag.param_int "a" min = -2147483648 max = 2147483647 default = 1 : i32
    %b = crag.param_int "b" min = -2147483648 max = 2147483647 default = 1 : i32

    %product = arith.muli %a, %b : i32

    crag.param_output_int "product" %product min = -2147483648 max = 2147483647 default = 1 : i32

    // Silent audio output required by crag.graph.
    %noise   = crag.white_noise : !crag.audio<f32, 0, 1>
    %c0_f    = arith.constant 0.0 : f32
    %silence = crag.scale %noise, %c0_f
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %silence : !crag.audio<f32, 0, 1>
  }
}
