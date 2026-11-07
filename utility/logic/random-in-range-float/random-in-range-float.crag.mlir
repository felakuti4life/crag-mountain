// Random In Range (Float) — emit a random float in [min, max] each bang.
//
// Draws one sample of white noise (uniform in roughly [-1, 1]) at the exact
// sample offset of the `bang` event and remaps it into [min, max].  The drawn
// value is held between bangs, mirroring the hold behaviour used by
// `float_peak`/`observe_float`.
//
// Parameters:
//   min  — inclusive lower bound of the output range (default 0.0)
//   max  — inclusive upper bound of the output range (default 1.0)
//
// Events:
//   bang (void)          — draws a new random value
//
// Event output:
//   value (float)        — random float in [min, max], emitted each bang

module {
  crag.graph name = "random-in-range-float" sample_rate = 0 channels = 1 {

    %min_p = crag.param "min" min = -1.0e20 max = 1.0e20 default = 0.0 : f32
    %max_p = crag.param "max" min = -1.0e20 max = 1.0e20 default = 1.0 : f32

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

    // Remap held value from [-1, 1] to [min, max].
    %one_f   = arith.constant 1.0 : f32
    %two_f   = arith.constant 2.0 : f32
    %shifted = arith.addf %held_out, %one_f : f32          // [0, 2]
    %norm    = arith.divf %shifted, %two_f : f32           // [0, 1]
    %range_f = arith.subf %max_p, %min_p : f32
    %scaled  = arith.mulf %norm, %range_f : f32
    %value_raw = arith.addf %scaled, %min_p : f32

    // Clamp to [min, max] to guard against float rounding at the edges.
    %clamped_hi = arith.minimumf %value_raw, %max_p : f32
    %value      = arith.maximumf %clamped_hi, %min_p : f32

    crag.event_output_float "value" %bang_fired, %bang_at, %value : i1, i32, f32

    // Silent audio output required by crag.graph.
    %silence_noise = crag.white_noise : !crag.audio<f32, 0, 1>
    %c0_f    = arith.constant 0.0 : f32
    %silence = crag.scale %silence_noise, %c0_f
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %silence : !crag.audio<f32, 0, 1>
  }
}
