// Coin Flip — emit a random boolean each time it is banged.
//
// Draws one sample of white noise (uniform in roughly [-1, 1]) at the exact
// sample offset of the `bang` event and thresholds it at zero, so each bang
// yields an independent ~50/50 true/false outcome.  The drawn value is held
// (not re-drawn) between bangs, mirroring the hold behaviour used by
// `float_peak`/`observe_float`.
//
// Events:
//   bang (void)          — draws a new random outcome
//
// Event output:
//   value (bool)         — true or false, emitted each time `bang` fires

module {
  crag.graph name = "coin-flip" sample_rate = 0 channels = 1 {

    %bang_fired, %bang_at = crag.event_void "bang" : i1, i32

    %noise = crag.white_noise : !crag.audio<f32, 0, 1>

    // Block size for wrapping the sample-index counter.
    %bs_i64 = crag.block_size : i64
    %bs_i32 = arith.trunci %bs_i64 : i64 to i32

    %s0_held = arith.constant 0.0 : f32
    %s0_idx  = arith.constant 0   : i32

    %noise_out, %held_out, %idx_hold =
        crag.per_sample (%noise) states (%s0_held, %s0_idx) {
    ^bb0(%x: f32, %held: f32, %idx: i32):
      // Latch this sample's noise value at the exact sample offset of `bang`.
      %is_bang_sample = arith.cmpi eq, %idx, %bang_at : i32
      %do_draw        = arith.andi %bang_fired, %is_bang_sample : i1
      %new_held       = arith.select %do_draw, %x, %held : f32

      // Advance the sample index, wrapping at block_size.
      %one_i32      = arith.constant 1 : i32
      %next_idx_raw = arith.addi %idx, %one_i32 : i32
      %next_idx     = arith.remsi %next_idx_raw, %bs_i32 : i32

      crag.per_sample_yield %x, %new_held, %next_idx : f32, f32, i32
    } : (!crag.audio<f32, 0, 1>, f32, i32) -> (!crag.audio<f32, 0, 1>, f32, i32)

    %zero_f = arith.constant 0.0 : f32
    %outcome = arith.cmpf ogt, %held_out, %zero_f : f32

    crag.event_output_bool "value" %bang_fired, %bang_at, %outcome : i1, i32, i1

    // Silent audio output required by crag.graph.
    %silence_noise = crag.white_noise : !crag.audio<f32, 0, 1>
    %c0_f    = arith.constant 0.0 : f32
    %silence = crag.scale %silence_noise, %c0_f
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %silence : !crag.audio<f32, 0, 1>
  }
}
