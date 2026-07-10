// Fire Note — convert a bare trigger into a music_note note_on event.
//
// A "cast" / adapter node: takes a void trigger event and, every time it
// fires, emits a `music_note` struct event carrying the pitch and velocity
// currently set on its float params.  This bridges a void event source (e.g. a
// conductor's `beat`, a MIDI/keyboard gate, or a UI button) into a synth's
// `note_on` struct event input, which are otherwise type-incompatible.
//
// Example: conductor.beat (void) -> fire_note.trigger (void)
//          fire_note.note_on (struct music_note) -> mono_synth.note_on
//   plays a note on every beat, at the pitch/velocity dialed in here.
//
// Parameters:
//   pitch      [0, 127]  — MIDI note number (default 60 = middle C)
//   velocity   [0, 1]    — note-on velocity / amplitude scale (default 1.0)
//
// Events:
//   trigger (void)               — fires the note output
//   note_on (struct music_note)  — emitted each time `trigger` fires, carrying
//                                  the current pitch and velocity values

module {
  crag.include "utility/music_note.crag.mlir" as "music_note_defs"

  crag.graph name = "fire_note" sample_rate = 0 channels = 1 {

    %trig_fired, %trig_at = crag.event_void "trigger" : i1, i32

    %pitch    = crag.param "pitch"    min = 0.0  max = 127.0  default = 60.0 : f32
    %velocity = crag.param "velocity" min = 0.0  max = 1.0    default = 1.0  : f32

    crag.event_output_struct "note_on" %trig_fired, %trig_at, %pitch, %velocity
        type = @music_note subtype = "music_note" : i1, i32, f32, f32

    // Silent audio output required by crag.graph.
    %noise   = crag.white_noise : !crag.audio<f32, 0, 1>
    %zero_f  = arith.constant 0.0 : f32
    %silence = crag.scale %noise, %zero_f
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %silence : !crag.audio<f32, 0, 1>
  }
}
