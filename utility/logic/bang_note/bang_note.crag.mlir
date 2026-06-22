// Bang Note — fire a music_note struct event on demand.
//
// Wraps a void trigger event with pitch and velocity parameters into a
// music_note struct event.  Useful for connecting a button/gate source to
// a synthesizer node that expects a music_note event input.
//
// Parameters:
//   pitch      [0, 127]  — MIDI note number (default 60 = middle C)
//   velocity   [0, 1]    — note-on velocity / amplitude scale (default 1.0)
//
// Events:
//   bang (void)          — fires the note output
//   note (struct music_note) — emitted each time bang fires, carrying the
//                             current pitch and velocity values

module {
  crag.include "utility/music_note.crag.mlir" as "music_note_defs"

  crag.graph name = "bang_note" sample_rate = 0 channels = 1 {

    %bang_fired, %bang_at = crag.event_void "bang" : i1, i32

    %pitch    = crag.param "pitch"    min = 0.0  max = 127.0  default = 60.0 : f32
    %velocity = crag.param "velocity" min = 0.0  max = 1.0    default = 1.0  : f32

    crag.event_output_struct "note" %bang_fired, %bang_at, %pitch, %velocity
        type = @music_note subtype = "music_note" : i1, i32, f32, f32

    // Silent audio output required by crag.graph.
    %noise   = crag.white_noise : !crag.audio<f32, 0, 1>
    %zero_f  = arith.constant 0.0 : f32
    %silence = crag.scale %noise, %zero_f
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %silence : !crag.audio<f32, 0, 1>
  }
}
