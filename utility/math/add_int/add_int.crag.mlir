// add_int — a + b on int control values.
//
//   sum = a + b
//
// Place this as a control node to offset one integer control by another, e.g.
// transposing a MIDI note number by a semitone count.
//
// Named control pins:
//   Inputs (param_int, i32):
//     a        — first operand (default 0)
//     b        — second operand (default 0)
//   Output (param_output_int, i32):
//     sum      — a + b
//
// A crag.graph (not a bare crag.func) so the engine registry lists it as an
// instantiable node; the audio output is silent and exists only because
// crag.graph requires one.

module {
  crag.graph name = "add_int" sample_rate = 0 channels = 1 {
    %a = crag.param_int "a" min = -2147483648 max = 2147483647 default = 0 : i32
    %b = crag.param_int "b" min = -2147483648 max = 2147483647 default = 0 : i32

    %sum = arith.addi %a, %b : i32

    crag.param_output_int "sum" %sum min = -2147483648 max = 2147483647 default = 0 : i32

    // Silent audio output required by crag.graph.
    %noise   = crag.white_noise : !crag.audio<f32, 0, 1>
    %c0_f    = arith.constant 0.0 : f32
    %silence = crag.scale %noise, %c0_f
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %silence : !crag.audio<f32, 0, 1>
  }
}
