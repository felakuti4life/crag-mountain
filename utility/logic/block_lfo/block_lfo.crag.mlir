// Block LFO — block-rate low-frequency oscillator with sample-accurate retrigger.
//
// Accumulates a phase variable one sample at a time using a per-sample loop,
// advancing by 2π·frequency/sample_rate each sample.  When `retrigger` fires
// the phase is reset to the `phase` parameter value at the exact sample offset
// of the event.  At the end of each block the accumulated phase is used to
// compute one LFO sample, which is scaled by `amplitude` and published as a
// patchable control output.
//
// Parameters:
//   frequency  [0.001, 100] Hz — LFO rate (default 1 Hz)
//   phase      [0, 2π]         — phase offset applied on retrigger (default 0)
//   amplitude  [0, 1]          — output scale (default 1.0)
//   shape      enum            — waveform: 0=sin, 1=saw, 2=tri, 3=square
//                               (default 0 = sin)
//
// Events:
//   retrigger (void) — resets the phase accumulator to `phase` at the
//                      event's sample offset
//
// Control output:
//   value — LFO value in [-amplitude, +amplitude], updated every block
//
// Waveform definitions (phase φ ∈ [0, 2π)):
//   sin:    sin(φ)                            ∈ [-1, 1]
//   saw:    φ/π − 1                           ∈ [-1, 1)
//   tri:    1 − 2·|φ/π − 1|                  ∈ [-1, 1]
//   square: 1 if φ < π, −1 otherwise          ∈ {-1, +1}

module {
  crag.graph name = "block_lfo" sample_rate = 0 channels = 1 {

    %frequency = crag.param "frequency" min = 0.001 max = 100.0  default = 1.0  unit = "hz" : f32
    %phase     = crag.param "phase"     min = 0.0   max = 6.28318530718 default = 0.0 : f32
    %amplitude = crag.param "amplitude" min = 0.0   max = 1.0    default = 1.0 : f32
    %retrig_fired, %retrig_at = crag.event_void "retrigger" : i1, i32
    %shape = crag.param_enum "shape"
                 values = ["sin", "saw", "tri", "square"] default = 0 : i32

    // Compute per-sample phase increment: 2π·freq / sample_rate.
    %sr     = crag.sample_rate : f32
    %two_pi = arith.constant 6.28318530718 : f32
    %inc_raw = arith.mulf %two_pi, %frequency : f32
    %phase_inc = arith.divf %inc_raw, %sr : f32

    // Block size for wrapping the sample-index counter.
    %bs_i64 = crag.block_size : i64
    %bs_i32 = arith.trunci %bs_i64 : i64 to i32

    // Run per-sample loop to accumulate phase with sample-accurate retrigger.
    %dummy   = crag.impulse : !crag.audio<f32, 0, 1>
    %s_phase = arith.constant 0.0 : f32
    %s_idx   = arith.constant 0   : i32

    %lfo_dummy, %acc_phase, %idx_hold =
        crag.per_sample (%dummy) states (%s_phase, %s_idx) {
    ^bb0(%x: f32, %curr_phase: f32, %idx: i32):
      // Advance and wrap phase.
      %next_phase_raw = arith.addf %curr_phase, %phase_inc : f32
      %wrapped        = arith.remf %next_phase_raw, %two_pi : f32

      // On retrigger at this sample: reset to the phase param value.
      %is_retrig  = arith.cmpi eq, %idx, %retrig_at : i32
      %do_retrig  = arith.andi %retrig_fired, %is_retrig : i1
      %next_phase = arith.select %do_retrig, %phase, %wrapped : f32

      // Advance the sample index, wrapping at block_size.
      %one_i32      = arith.constant 1 : i32
      %next_idx_raw = arith.addi %idx, %one_i32 : i32
      %next_idx     = arith.remsi %next_idx_raw, %bs_i32 : i32

      crag.per_sample_yield %x, %next_phase, %next_idx : f32, f32, i32
    } : (!crag.audio<f32, 0, 1>, f32, i32) -> (!crag.audio<f32, 0, 1>, f32, i32)

    // Compute waveform value at the accumulated phase.
    %sine_val = math.sin %acc_phase : f32

    %pi         = arith.constant 3.14159265359 : f32
    %one_f      = arith.constant 1.0 : f32
    %saw_norm   = arith.divf %acc_phase, %pi : f32
    %saw_val    = arith.subf %saw_norm, %one_f : f32   // φ/π − 1 ∈ [-1, 1)

    %tri_abs    = math.absf %saw_val : f32              // |φ/π − 1| ∈ [0, 1)
    %two_f      = arith.constant 2.0 : f32
    %tri_scaled = arith.mulf %two_f, %tri_abs : f32
    %tri_val    = arith.subf %one_f, %tri_scaled : f32  // 1 − 2|φ/π − 1| ∈ (-1, 1]

    %sq_pos  = arith.constant  1.0 : f32
    %sq_neg  = arith.constant -1.0 : f32
    %sq_cond = arith.cmpf olt, %acc_phase, %pi : f32
    %sq_val  = arith.select %sq_cond, %sq_pos, %sq_neg : f32

    // Select waveform via nested arith.select.
    %c0_i32 = arith.constant 0 : i32
    %c1_i32 = arith.constant 1 : i32
    %c2_i32 = arith.constant 2 : i32
    %is_sin = arith.cmpi eq, %shape, %c0_i32 : i32
    %is_saw = arith.cmpi eq, %shape, %c1_i32 : i32
    %is_tri = arith.cmpi eq, %shape, %c2_i32 : i32

    %tri_or_sq  = arith.select %is_tri, %tri_val, %sq_val : f32
    %saw_or_tri = arith.select %is_saw, %saw_val, %tri_or_sq : f32
    %lfo_val    = arith.select %is_sin, %sine_val, %saw_or_tri : f32

    %out = arith.mulf %lfo_val, %amplitude : f32

    crag.param_output "value" %out : f32

    // Silent audio output required by crag.graph.
    %noise   = crag.white_noise : !crag.audio<f32, 0, 1>
    %c0_f    = arith.constant 0.0 : f32
    %silence = crag.scale %noise, %c0_f
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %silence : !crag.audio<f32, 0, 1>
  }
}
