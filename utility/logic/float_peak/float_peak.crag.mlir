// Float Peak — track the running maximum of a float parameter.
//
// Maintains a persistent running maximum of the `value` parameter across
// audio blocks.  The peak only increases unless `reset` fires, at which
// point the accumulator clears at the event's sample offset and begins
// tracking from zero again.
//
// The implementation uses a per-sample state loop so that the reset is
// applied at the exact sample within the block where the event fires.
// A sample-index counter (wrapped per block) is carried as a second state
// variable so the correct sample can be identified inside the loop.
//
// Parameters:
//   value  — float to track (full practical range)
//
// Events:
//   reset (void) — clears the running peak at the event's sample offset
//
// Control output:
//   peak   — maximum value seen since the last reset (or since graph start)

module {
  crag.graph name = "float_peak" sample_rate = 0 channels = 1 {

    %val          = crag.param "value" min = -1.0e20 max = 1.0e20 default = 0.0 : f32
    %reset_fired, %reset_at = crag.event_void "reset" : i1, i32

    %dummy = crag.impulse : !crag.audio<f32, 0, 1>

    // Precompute block size for wrapping the sample-index counter.
    %bs_i64 = crag.block_size : i64
    %bs_i32 = arith.trunci %bs_i64 : i64 to i32

    %s0_peak = arith.constant 0.0 : f32
    %s0_idx  = arith.constant 0   : i32

    %peak_audio, %peak_out, %idx_hold =
        crag.per_sample (%dummy) states (%s0_peak, %s0_idx) {
    ^bb0(%x: f32, %peak: f32, %idx: i32):
      // Clear peak to 0 at the exact sample offset of the reset event.
      %is_reset_sample = arith.cmpi eq, %idx, %reset_at : i32
      %do_reset        = arith.andi %reset_fired, %is_reset_sample : i1

      %new_peak_running = arith.maximumf %peak, %val : f32
      %zero_pk          = arith.constant 0.0 : f32
      %new_peak         = arith.select %do_reset, %zero_pk, %new_peak_running : f32

      // Advance the sample index, wrapping at block_size.
      %one_i32      = arith.constant 1 : i32
      %next_idx_raw = arith.addi %idx, %one_i32 : i32
      %next_idx     = arith.remsi %next_idx_raw, %bs_i32 : i32

      crag.per_sample_yield %x, %new_peak, %next_idx : f32, f32, i32
    } : (!crag.audio<f32, 0, 1>, f32, i32) -> (!crag.audio<f32, 0, 1>, f32, i32)

    crag.param_output "peak" %peak_out : f32

    // Silent audio output required by crag.graph.
    %noise   = crag.white_noise : !crag.audio<f32, 0, 1>
    %c0_f    = arith.constant 0.0 : f32
    %silence = crag.scale %noise, %c0_f
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %silence : !crag.audio<f32, 0, 1>
  }
}
