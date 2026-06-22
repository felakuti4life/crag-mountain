// Simple amplitude sequencer — applies beat-indexed gain steps to audio.
//
// Consumes a routed `beat` event from an upstream `conductor` (via the public
// `beat_input` event pin) and uses `beat_in_measure` to compute the beat
// position within a measure, then selects one of four gain values
// (gain_0..gain_3) to scale the audio input.  This creates a simple rhythmic
// amplitude pattern that cycles every `beats_per_measure` beats.
//
// Block arguments:
//   %audio_in — mono audio input to scale
//
// Control inputs (patchbay-routable):
//   beat_input        — (event_void, subtype "beat") upstream beat trigger;
//                       wire `conductor.beat` -> `simple_amp_sequencer.beat_input`
//
// Parameters:
//   bpm               — tempo in beats per minute (default 120)
//   beats_per_measure — time signature numerator (default 4)
//   gain_0            — gain for beat 0 (downbeat, default 1.0)
//   gain_1            — gain for beat 1 (default 0.5)
//   gain_2            — gain for beat 2 (default 0.75)
//   gain_3            — gain for beats 3+ (default 0.25)
//
// The gain selection uses a 4-step sequencer:
//   beat_in_measure == 0 → gain_0
//   beat_in_measure == 1 → gain_1
//   beat_in_measure == 2 → gain_2
//   beat_in_measure >= 3 → gain_3
//
// This graph no longer owns an internal metronome: there is a single
// authoritative timing source, the upstream conductor, routed in through
// `beat_input`.  `bpm` is retained because the beat *count* (and hence the
// beat-in-measure index that drives gain selection) is derived locally from
// `crag.curframe` and the beat period; patch the sequencer's `bpm` to match the
// conductor's tempo so the local count tracks the routed beats.
module {
  crag.include_func "sequencing/beat_in_measure.crag.mlir" as "beat_in_measure"

  crag.graph name = "simple_amp_sequencer" sample_rate = 0 channels = 1 {
  ^bb0(%audio_in: !crag.audio<f32, 0, 1>):
    %sr = crag.sample_rate : f32

    // Upstream beat input (patchbay-routed from conductor.beat). This is the
    // sequencer's beat trigger — there is no internal metronome.
    %beat_in_fired, %beat_in_at = crag.event_void "beat_input"
                             subtype = "beat" : i1, i32

    // Parameters
    %bpm               = crag.param "bpm"
                             min = 20.0 max = 300.0 default = 120.0
                             unit = "bpm" : f32
    %beats_per_measure = crag.param_int "beats_per_measure"
                             min = 1 max = 32 default = 4 : i32
    %gain_0            = crag.param "gain_0" min = 0.0 max = 2.0 default = 1.0   : f32
    %gain_1            = crag.param "gain_1" min = 0.0 max = 2.0 default = 0.5   : f32
    %gain_2            = crag.param "gain_2" min = 0.0 max = 2.0 default = 0.75  : f32
    %gain_3            = crag.param "gain_3" min = 0.0 max = 2.0 default = 0.25  : f32

    // Beat period in samples = sr * 60 / bpm (used to count elapsed beats)
    %sixty_f    = arith.constant 60.0 : f32
    %sr_x60     = arith.mulf %sr, %sixty_f : f32
    %period_f   = arith.divf %sr_x60, %bpm : f32
    %period_i64 = arith.fptosi %period_f : f32 to i64

    // Compute beat count = curframe / period (samples elapsed / period)
    %cur_frame  = crag.curframe : i64
    %count_i64  = arith.divsi %cur_frame, %period_i64 : i64
    %beat_count = arith.trunci %count_i64 : i64 to i32

    // Get beat position within the measure (0-indexed), driven by the routed
    // beat trigger (beat_input) rather than an internal metronome.
    %fired_b, %at_b, %beat = crag.func_ref "beat_in_measure"(
                                  %beat_in_fired, %beat_in_at, %beat_count,
                                  %beats_per_measure)
                                  : (i1, i32, i32, i32) -> (i1, i32, i32)

    // Select gain for the current beat-in-measure (4-step sequencer)
    %c0       = arith.constant 0 : i32
    %c1       = arith.constant 1 : i32
    %c2       = arith.constant 2 : i32
    %is_beat0 = arith.cmpi eq, %beat, %c0 : i32
    %is_beat1 = arith.cmpi eq, %beat, %c1 : i32
    %is_beat2 = arith.cmpi eq, %beat, %c2 : i32
    %gain_sel  = arith.select %is_beat2, %gain_2, %gain_3 : f32
    %gain_sel1 = arith.select %is_beat1, %gain_1, %gain_sel : f32
    %gain      = arith.select %is_beat0, %gain_0, %gain_sel1 : f32

    // Apply the selected gain to the audio input
    %out = crag.scale %audio_in, %gain
               : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %out : !crag.audio<f32, 0, 1>
  }
}
