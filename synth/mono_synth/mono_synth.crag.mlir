// Monophonic synthesizer — music_note event → oscillator → filter → envelope
//
// A complete single-voice synthesizer driven by a `crag.event_struct` carrying
// a `music_note` payload (pitch in MIDI note numbers, velocity in [0, 1]).
//
// Signal flow:
//   note_on event → MIDI pitch → frequency → sawtooth oscillator
//                                          → resonant low-pass filter
//                                          → ADSR amplitude envelope
//                                          → velocity scale
//                                          → output
//
// Parameters:
//   cutoff_hz   [200, 8000] Hz  — filter cutoff frequency (default 2000 Hz)
//   attack_ms   [1,   2000] ms — ADSR attack time  (default  10 ms)
//   decay_ms    [1,   2000] ms — ADSR decay time   (default 200 ms)
//   sustain     [0,      1]    — ADSR sustain level (default 0.8)
//   release_ms  [1,   5000] ms — ADSR release time (default 300 ms)
//
// Events:
//   note_on (struct music_note) — starts a note; pitch sets the oscillator
//                                 frequency, velocity scales the output.
//
// Output: !crag.audio<f32, 0, 1> — mono synthesizer signal
//
// Note on pitch/velocity persistence: the per-event host-pointer global
// (crag_event_struct_N_ptr) retains the last host-supplied pointer across
// blocks, so `%pitch` and `%vel` reflect the most-recently-fired note's
// values even in non-trigger blocks.  The ADSR handles timing via `%fired`
// and `%at`.

module {
  // Pull in the music_note struct definition.
  crag.include "utility/music_note.crag.mlir" as "music_note_defs"

  crag.graph sample_rate = 0 channels = 1 {

    // -------------------------------------------------------------------------
    // Event: note_on carries pitch (MIDI note) + velocity
    // -------------------------------------------------------------------------
    %fired, %at, %pitch, %vel =
        crag.event_struct "note_on" type = @music_note subtype = "music_note"
            infrequent : i1, i32, f32, f32

    // -------------------------------------------------------------------------
    // MIDI pitch → frequency: freq = 440 * 2^((pitch - 69) / 12)
    // -------------------------------------------------------------------------
    %c69  = arith.constant 69.0  : f32
    %c12  = arith.constant 12.0  : f32
    %c440 = arith.constant 440.0 : f32
    %semi   = arith.subf %pitch, %c69 : f32
    %oct    = arith.divf %semi, %c12 : f32
    %ratio  = math.exp2 %oct : f32
    %freq   = arith.mulf %ratio, %c440 : f32

    // -------------------------------------------------------------------------
    // Oscillator: band-limited sawtooth
    // -------------------------------------------------------------------------
    %phase = arith.constant 0.0 : f32
    %osc   = crag.saw %freq, %phase : f32, f32 -> !crag.audio<f32, 0, 1>

    // -------------------------------------------------------------------------
    // Resonant low-pass filter
    // -------------------------------------------------------------------------
    %cutoff_hz  = crag.param "cutoff_hz"  min = 200.0  max = 8000.0  default = 2000.0  unit = "hz" infrequent : f32

    // Normalize cutoff: cutoff_norm = cutoff_hz / (sample_rate / 2)
    %sr         = crag.sample_rate : f32
    %two        = arith.constant 2.0 : f32
    %nyquist    = arith.divf %sr, %two : f32
    %cutoff_norm = arith.divf %cutoff_hz, %nyquist : f32

    %fb, %ff = crag.get_filter_coeffs %cutoff_norm order = 2 type = "lowpass"
                   : f32, !crag.coeff_vec, !crag.coeff_vec
    %filtered = crag.filter %osc, %fb, %ff
                    : (!crag.audio<f32, 0, 1>, !crag.coeff_vec, !crag.coeff_vec)
                      -> !crag.audio<f32, 0, 1>

    // -------------------------------------------------------------------------
    // ADSR amplitude envelope
    // -------------------------------------------------------------------------
    %attack_ms  = crag.param "attack_ms"  min = 1.0  max = 2000.0  default = 10.0   unit = "ms" infrequent : f32
    %decay_ms   = crag.param "decay_ms"   min = 1.0  max = 2000.0  default = 200.0  unit = "ms" infrequent : f32
    %sustain    = crag.param "sustain"    min = 0.0  max = 1.0     default = 0.8 infrequent : f32
    %release_ms = crag.param "release_ms" min = 1.0  max = 5000.0  default = 300.0  unit = "ms" infrequent : f32

    %env = crag.adsr %attack_ms, %decay_ms, %sustain, %release_ms, %fired, %at
               : f32, f32, f32, f32, i1, i32 -> !crag.audio<f32, 0, 1>

    // -------------------------------------------------------------------------
    // Apply envelope + velocity scaling
    // -------------------------------------------------------------------------
    %shaped = crag.audio_mul %filtered, %env : !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1> -> !crag.audio<f32, 0, 1>
    %out    = crag.scale %shaped, %vel : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    crag.output %out : !crag.audio<f32, 0, 1>
  }
}
