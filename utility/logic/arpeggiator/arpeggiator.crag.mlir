// Arpeggiator — step through a chord built on a root note, one note per bang.
//
// Builds a 4-note-per-octave chord table from the `root` pitch and the
// `chord` type, spanning `octaves` octaves (4 · octaves total steps), and
// walks through it in the order chosen by `direction`.  Each `bang` advances
// the walk by one step (sample-accurately, at the event's offset within the
// block) and emits the corresponding pitch as a `music_note` note_on event.
// The very first bang after graph start emits the root note (step 0);
// subsequent bangs advance the step position.  `crag.per_sample` states are
// re-seeded from their operands every block, so the walk position, the held
// step and the random draw live in persistent line cells (`crag.line_load`
// / `crag.line_store`) and survive across blocks.
//
// Chord tables (semitones from root, 4 entries; triads repeat the root an
// octave up as the 4th entry so every chord type has a uniform step count):
//   major       0  4  7 12       maj7      0  4  7 11
//   minor       0  3  7 12       min7      0  3  7 10
//   diminished  0  3  6 12       dom7      0  4  7 10
//   augmented   0  4  8 12       minMaj7   0  3  7 11
//   sus2        0  2  7 12       sus4      0  5  7 12
//
// Direction modes (`direction` enum):
//   up       — step 0, 1, 2, ... (total - 1), then wraps to 0
//   down     — step (total - 1), ... 1, 0, then wraps to (total - 1)
//   up_down  — bounces 0 .. (total - 1) .. 0 without repeating the endpoints
//   random   — each bang jumps to an independent random step in [0, total)
//
// Parameters:
//   root      [0, 127]  — MIDI root note number (default 60 = middle C)
//   chord     enum      — chord type (default 0 = major)
//   octaves   [1, 8]    — number of octaves the pattern spans (default 1)
//   direction enum      — walk order: up/down/up_down/random (default 0 = up)
//   velocity  [0, 1]    — note-on velocity carried on each emitted note
//                         (default 1.0)
//
// Events:
//   bang (void)                  — advances the arpeggio by one step
//
// Event output:
//   note_on (struct music_note)  — emitted each time `bang` fires, carrying
//                                  the current step's pitch and `velocity`

module {
  crag.include "utility/music_note.crag.mlir" as "music_note_defs"

  crag.graph name = "arpeggiator" sample_rate = 0 channels = 1 {

    %root     = crag.param "root" min = 0.0 max = 127.0 default = 60.0 : f32
    %velocity = crag.param "velocity" min = 0.0 max = 1.0 default = 1.0 : f32
    %chord    = crag.param_enum "chord"
                    values = ["major", "minor", "diminished", "augmented",
                              "maj7", "min7", "dom7", "minMaj7", "sus2", "sus4"]
                    default = 0 : i32
    %octaves    = crag.param_int "octaves" min = 1 max = 8 default = 1 : i32
    %direction  = crag.param_enum "direction"
                      values = ["up", "down", "up_down", "random"]
                      default = 0 : i32

    %bang_fired, %bang_at = crag.event_void "bang" : i1, i32

    // -------------------------------------------------------------------
    // Total step count (4 notes per octave) and the up_down cycle length.
    // -------------------------------------------------------------------
    %chord_size  = arith.constant 4 : i32
    %total_i32   = arith.muli %chord_size, %octaves : i32
    %one_i32     = arith.constant 1 : i32
    %total_m1    = arith.subi %total_i32, %one_i32 : i32
    %two_i32     = arith.constant 2 : i32
    %updown_len  = arith.muli %total_m1, %two_i32 : i32

    // up_down uses the bounce cycle length as its wrap modulus; every other
    // direction (including random, which ignores the wrapped position) uses
    // the plain step count.
    %dir_c2     = arith.constant 2 : i32
    %is_updown  = arith.cmpi eq, %direction, %dir_c2 : i32
    %wrap_i32   = arith.select %is_updown, %updown_len, %total_i32 : i32

    // -------------------------------------------------------------------
    // Per-sample state: monotonic step counter (`pos`), the step value held
    // for output since the last bang (`pos_hold`), a random draw for the
    // `random` direction mode (`held`), and the block-wrapped sample index.
    //
    // The first three must persist across blocks, so they are seeded from
    // (and written back to) f32 line cells; the integer ones are converted
    // at the boundary.  The sample index is block-local by definition.
    // -------------------------------------------------------------------
    %noise = crag.white_noise : !crag.audio<f32, 0, 1>

    %bs_i64 = crag.block_size : i64
    %bs_i32 = arith.trunci %bs_i64 : i64 to i32

    %line0 = arith.constant 0 : index
    %s0_pos_f = crag.line_load %line0 group = "arpeggiator_state"
                    slot = 0 lines = 1 : index -> f32
    %s0_pos_hold_f = crag.line_load %line0 group = "arpeggiator_state"
                    slot = 1 lines = 1 : index -> f32
    %s0_held = crag.line_load %line0 group = "arpeggiator_state"
                    slot = 2 lines = 1 : index -> f32
    %s0_pos      = arith.fptosi %s0_pos_f : f32 to i32
    %s0_pos_hold = arith.fptosi %s0_pos_hold_f : f32 to i32
    %s0_idx      = arith.constant 0   : i32

    %noise_out, %pos_hold_out, %pos_out, %held_out, %idx_hold =
        crag.per_sample (%noise) states (%s0_pos_hold, %s0_pos, %s0_held, %s0_idx) {
    ^bb0(%x: f32, %pos_hold: i32, %pos: i32, %held: f32, %idx: i32):
      %is_bang_sample = arith.cmpi eq, %idx, %bang_at : i32
      %do_advance     = arith.andi %bang_fired, %is_bang_sample : i1

      // Capture the pre-increment step for output, so the first bang ever
      // emits step 0 (the root) rather than step 1.
      %new_pos_hold = arith.select %do_advance, %pos, %pos_hold : i32

      %pos_inc_raw = arith.addi %pos, %one_i32 : i32
      %pos_wrapped = arith.remsi %pos_inc_raw, %wrap_i32 : i32
      %new_pos     = arith.select %do_advance, %pos_wrapped, %pos : i32

      // Draw a fresh random value on every bang (used only by `random`).
      %new_held = arith.select %do_advance, %x, %held : f32

      %next_idx_raw = arith.addi %idx, %one_i32 : i32
      %next_idx     = arith.remsi %next_idx_raw, %bs_i32 : i32

      crag.per_sample_yield %x, %new_pos_hold, %new_pos, %new_held, %next_idx
          : f32, i32, i32, f32, i32
    } : (!crag.audio<f32, 0, 1>, i32, i32, f32, i32)
        -> (!crag.audio<f32, 0, 1>, i32, i32, f32, i32)

    // Carry the walk state into the next block.
    %pos_out_f      = arith.sitofp %pos_out : i32 to f32
    %pos_hold_out_f = arith.sitofp %pos_hold_out : i32 to f32
    crag.line_store %line0, %pos_out_f group = "arpeggiator_state"
        slot = 0 lines = 1 : index, f32
    crag.line_store %line0, %pos_hold_out_f group = "arpeggiator_state"
        slot = 1 lines = 1 : index, f32
    crag.line_store %line0, %held_out group = "arpeggiator_state"
        slot = 2 lines = 1 : index, f32

    // -------------------------------------------------------------------
    // Resolve the step to emit this bang, based on `direction`.
    // -------------------------------------------------------------------
    %down_val = arith.subi %total_m1, %pos_hold_out : i32

    %is_second_half = arith.cmpi sge, %pos_hold_out, %total_i32 : i32
    %folded         = arith.subi %updown_len, %pos_hold_out : i32
    %updown_val     = arith.select %is_second_half, %folded, %pos_hold_out : i32

    %one_f    = arith.constant 1.0 : f32
    %two_f    = arith.constant 2.0 : f32
    %shifted  = arith.addf %held_out, %one_f : f32          // [0, 2]
    %norm     = arith.divf %shifted, %two_f : f32           // [0, 1]
    %total_f  = arith.sitofp %total_i32 : i32 to f32
    %rand_raw = arith.mulf %norm, %total_f : f32
    %rand_flr = math.floor %rand_raw : f32
    %rand_i32 = arith.fptosi %rand_flr : f32 to i32
    %zero_i32 = arith.constant 0 : i32
    %rand_hi  = arith.minsi %rand_i32, %total_m1 : i32
    %rand_val = arith.maxsi %rand_hi, %zero_i32 : i32

    %dir_c0 = arith.constant 0 : i32
    %dir_c1 = arith.constant 1 : i32
    %is_dir0 = arith.cmpi eq, %direction, %dir_c0 : i32
    %is_dir1 = arith.cmpi eq, %direction, %dir_c1 : i32

    %sel_23     = arith.select %is_updown, %updown_val, %rand_val : i32
    %sel_123    = arith.select %is_dir1, %down_val, %sel_23 : i32
    %step_index = arith.select %is_dir0, %pos_hold_out, %sel_123 : i32

    // -------------------------------------------------------------------
    // Split the step into a chord-table index (0..3) and an octave offset.
    // -------------------------------------------------------------------
    %note_idx   = arith.remsi %step_index, %chord_size : i32
    %octave_idx = arith.divsi %step_index, %chord_size : i32

    %idx_c0 = arith.constant 0 : i32
    %idx_c1 = arith.constant 1 : i32
    %idx_c2 = arith.constant 2 : i32
    %idx_eq0 = arith.cmpi eq, %note_idx, %idx_c0 : i32
    %idx_eq1 = arith.cmpi eq, %note_idx, %idx_c1 : i32
    %idx_eq2 = arith.cmpi eq, %note_idx, %idx_c2 : i32

    // -------------------------------------------------------------------
    // Chord interval tables (semitones from root), one candidate per type.
    // -------------------------------------------------------------------
    %major_a = arith.constant 0 : i32
    %major_b = arith.constant 4 : i32
    %major_c = arith.constant 7 : i32
    %major_d = arith.constant 12 : i32
    %major_cd  = arith.select %idx_eq2, %major_c, %major_d : i32
    %major_bcd = arith.select %idx_eq1, %major_b, %major_cd : i32
    %major_iv  = arith.select %idx_eq0, %major_a, %major_bcd : i32

    %minor_a = arith.constant 0 : i32
    %minor_b = arith.constant 3 : i32
    %minor_c = arith.constant 7 : i32
    %minor_d = arith.constant 12 : i32
    %minor_cd  = arith.select %idx_eq2, %minor_c, %minor_d : i32
    %minor_bcd = arith.select %idx_eq1, %minor_b, %minor_cd : i32
    %minor_iv  = arith.select %idx_eq0, %minor_a, %minor_bcd : i32

    %dim_a = arith.constant 0 : i32
    %dim_b = arith.constant 3 : i32
    %dim_c = arith.constant 6 : i32
    %dim_d = arith.constant 12 : i32
    %dim_cd  = arith.select %idx_eq2, %dim_c, %dim_d : i32
    %dim_bcd = arith.select %idx_eq1, %dim_b, %dim_cd : i32
    %dim_iv  = arith.select %idx_eq0, %dim_a, %dim_bcd : i32

    %aug_a = arith.constant 0 : i32
    %aug_b = arith.constant 4 : i32
    %aug_c = arith.constant 8 : i32
    %aug_d = arith.constant 12 : i32
    %aug_cd  = arith.select %idx_eq2, %aug_c, %aug_d : i32
    %aug_bcd = arith.select %idx_eq1, %aug_b, %aug_cd : i32
    %aug_iv  = arith.select %idx_eq0, %aug_a, %aug_bcd : i32

    %maj7_a = arith.constant 0 : i32
    %maj7_b = arith.constant 4 : i32
    %maj7_c = arith.constant 7 : i32
    %maj7_d = arith.constant 11 : i32
    %maj7_cd  = arith.select %idx_eq2, %maj7_c, %maj7_d : i32
    %maj7_bcd = arith.select %idx_eq1, %maj7_b, %maj7_cd : i32
    %maj7_iv  = arith.select %idx_eq0, %maj7_a, %maj7_bcd : i32

    %min7_a = arith.constant 0 : i32
    %min7_b = arith.constant 3 : i32
    %min7_c = arith.constant 7 : i32
    %min7_d = arith.constant 10 : i32
    %min7_cd  = arith.select %idx_eq2, %min7_c, %min7_d : i32
    %min7_bcd = arith.select %idx_eq1, %min7_b, %min7_cd : i32
    %min7_iv  = arith.select %idx_eq0, %min7_a, %min7_bcd : i32

    %dom7_a = arith.constant 0 : i32
    %dom7_b = arith.constant 4 : i32
    %dom7_c = arith.constant 7 : i32
    %dom7_d = arith.constant 10 : i32
    %dom7_cd  = arith.select %idx_eq2, %dom7_c, %dom7_d : i32
    %dom7_bcd = arith.select %idx_eq1, %dom7_b, %dom7_cd : i32
    %dom7_iv  = arith.select %idx_eq0, %dom7_a, %dom7_bcd : i32

    %minmaj7_a = arith.constant 0 : i32
    %minmaj7_b = arith.constant 3 : i32
    %minmaj7_c = arith.constant 7 : i32
    %minmaj7_d = arith.constant 11 : i32
    %minmaj7_cd  = arith.select %idx_eq2, %minmaj7_c, %minmaj7_d : i32
    %minmaj7_bcd = arith.select %idx_eq1, %minmaj7_b, %minmaj7_cd : i32
    %minmaj7_iv  = arith.select %idx_eq0, %minmaj7_a, %minmaj7_bcd : i32

    %sus2_a = arith.constant 0 : i32
    %sus2_b = arith.constant 2 : i32
    %sus2_c = arith.constant 7 : i32
    %sus2_d = arith.constant 12 : i32
    %sus2_cd  = arith.select %idx_eq2, %sus2_c, %sus2_d : i32
    %sus2_bcd = arith.select %idx_eq1, %sus2_b, %sus2_cd : i32
    %sus2_iv  = arith.select %idx_eq0, %sus2_a, %sus2_bcd : i32

    %sus4_a = arith.constant 0 : i32
    %sus4_b = arith.constant 5 : i32
    %sus4_c = arith.constant 7 : i32
    %sus4_d = arith.constant 12 : i32
    %sus4_cd  = arith.select %idx_eq2, %sus4_c, %sus4_d : i32
    %sus4_bcd = arith.select %idx_eq1, %sus4_b, %sus4_cd : i32
    %sus4_iv  = arith.select %idx_eq0, %sus4_a, %sus4_bcd : i32

    // -------------------------------------------------------------------
    // Pick the interval for the current `chord` type.
    // -------------------------------------------------------------------
    %chord_c0 = arith.constant 0 : i32
    %chord_c1 = arith.constant 1 : i32
    %chord_c2 = arith.constant 2 : i32
    %chord_c3 = arith.constant 3 : i32
    %chord_c4 = arith.constant 4 : i32
    %chord_c5 = arith.constant 5 : i32
    %chord_c6 = arith.constant 6 : i32
    %chord_c7 = arith.constant 7 : i32
    %chord_c8 = arith.constant 8 : i32

    %chord_eq0 = arith.cmpi eq, %chord, %chord_c0 : i32
    %chord_eq1 = arith.cmpi eq, %chord, %chord_c1 : i32
    %chord_eq2 = arith.cmpi eq, %chord, %chord_c2 : i32
    %chord_eq3 = arith.cmpi eq, %chord, %chord_c3 : i32
    %chord_eq4 = arith.cmpi eq, %chord, %chord_c4 : i32
    %chord_eq5 = arith.cmpi eq, %chord, %chord_c5 : i32
    %chord_eq6 = arith.cmpi eq, %chord, %chord_c6 : i32
    %chord_eq7 = arith.cmpi eq, %chord, %chord_c7 : i32
    %chord_eq8 = arith.cmpi eq, %chord, %chord_c8 : i32

    %r8 = arith.select %chord_eq8, %sus2_iv, %sus4_iv : i32
    %r7 = arith.select %chord_eq7, %minmaj7_iv, %r8 : i32
    %r6 = arith.select %chord_eq6, %dom7_iv, %r7 : i32
    %r5 = arith.select %chord_eq5, %min7_iv, %r6 : i32
    %r4 = arith.select %chord_eq4, %maj7_iv, %r5 : i32
    %r3 = arith.select %chord_eq3, %aug_iv, %r4 : i32
    %r2 = arith.select %chord_eq2, %dim_iv, %r3 : i32
    %r1 = arith.select %chord_eq1, %minor_iv, %r2 : i32
    %interval = arith.select %chord_eq0, %major_iv, %r1 : i32

    // -------------------------------------------------------------------
    // pitch = root + interval + 12 * octave_idx, clamped to [0, 127].
    // -------------------------------------------------------------------
    %interval_f    = arith.sitofp %interval : i32 to f32
    %octave_idx_f  = arith.sitofp %octave_idx : i32 to f32
    %twelve_f      = arith.constant 12.0 : f32
    %octave_off_f  = arith.mulf %octave_idx_f, %twelve_f : f32
    %pitch_raw     = arith.addf %root, %interval_f : f32
    %pitch_shifted = arith.addf %pitch_raw, %octave_off_f : f32

    %pitch_min = arith.constant 0.0 : f32
    %pitch_max = arith.constant 127.0 : f32
    %pitch_hi  = arith.minimumf %pitch_shifted, %pitch_max : f32
    %pitch     = arith.maximumf %pitch_hi, %pitch_min : f32

    crag.event_output_struct "note_on" %bang_fired, %bang_at, %pitch, %velocity
        type = @music_note subtype = "music_note" : i1, i32, f32, f32

    // Silent audio output required by crag.graph.
    %silence_noise = crag.white_noise : !crag.audio<f32, 0, 1>
    %c0_f    = arith.constant 0.0 : f32
    %silence = crag.scale %silence_noise, %c0_f
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %silence : !crag.audio<f32, 0, 1>
  }
}
