// Conductor graph — tempo clock with public beat/measure control outputs.
//
// A standalone `crag.graph` that drives the metronome function and publishes
// tempo state both as meters (host observation) and as patchable control
// outputs (Phase 5: routable to downstream sequencer nodes via the engine
// control patchbay).  The audio output is intentionally silent; the useful
// surface is the control outputs and meters.
//
// Parameters:
//   start_ms          — time (ms) at which beat 0 occurs relative to playback
//   bpm               — tempo in beats per minute
//   beats_per_measure — time-signature numerator (e.g. 4 for 4/4)
//
// Control outputs (patchbay-routable):
//   beat              (event_output_void)  — beat trigger (fired, sample_offset)
//   beat_in_measure   (event_output_int)   — 0-based beat position in measure
//   measure           (event_output_int)   — 0-based measure number
//   beat_count        (param_output_int)   — total beats elapsed (0-indexed)
//
// Meters (host observation only; retained for backward compatibility):
//   beat_fired, beat_sample_offset, beat_count
//
// A downstream `simple_amp_sequencer` exposes a `beat_input` event pin; wiring
// `conductor.beat` → `simple_amp_sequencer.beat_input` lets the sequencer
// follow this conductor instead of its own internal metronome.

module {
  crag.include_func "sequencing/metronome.crag.mlir"        as "metronome"
  crag.include_func "sequencing/beat_in_measure.crag.mlir"  as "beat_in_measure"
  crag.include_func "sequencing/measure_number.crag.mlir"   as "measure_number"

  crag.graph name = "conductor" sample_rate = 0 channels = 1 {
    %sr         = crag.sample_rate : f32

    // Parameters
    %start_ms   = crag.param "start_ms" min = 0.0 max = 3600000.0 default = 0.0
                      unit = "ms" : f32
    %bpm        = crag.param "bpm" min = 20.0 max = 300.0 default = 120.0
                      unit = "bpm" : f32
    %beats_per_measure = crag.param_int "beats_per_measure"
                      min = 1 max = 32 default = 4 : i32

    // Convert BPM to beat period in samples: sr * 60 / bpm
    %sixty_f    = arith.constant 60.0 : f32
    %sr_x60     = arith.mulf %sr, %sixty_f : f32
    %period_f   = arith.divf %sr_x60, %bpm : f32
    %period_i64 = arith.fptosi %period_f : f32 to i64
    %period_i32 = arith.trunci %period_i64 : i64 to i32

    // Convert start_ms to start sample: start_ms / 1000 * sr
    %thousand_f   = arith.constant 1000.0 : f32
    %start_sec_f  = arith.divf %start_ms, %thousand_f : f32
    %start_samp_f = arith.mulf %start_sec_f, %sr : f32
    %start_samp   = arith.fptosi %start_samp_f : f32 to i64
    %start_samp_i32 = arith.trunci %start_samp : i64 to i32

    // Call metronome to detect beat events in the current block.
    // Named-pin metronome takes i32 sample indices (sign-extends internally).
    %fired, %at = crag.func_ref "metronome"(%start_samp_i32, %period_i32)
                      : (i32, i32) -> (i1, i32)

    // Compute beat count = max(0, (curframe - start_samp) / period)
    %cur_frame  = crag.curframe : i64
    %zero_i64   = arith.constant 0 : i64
    %elapsed    = arith.subi %cur_frame, %start_samp : i64
    %before     = arith.cmpi slt, %elapsed, %zero_i64 : i64
    %safe_el    = arith.select %before, %zero_i64, %elapsed : i64
    %count_i64  = arith.divsi %safe_el, %period_i64 : i64
    %beat_count = arith.trunci %count_i64 : i64 to i32

    // Derive beat-in-measure and measure number from the beat event.
    %bim_f, %bim_at, %bim = crag.func_ref "beat_in_measure"(
                                %fired, %at, %beat_count, %beats_per_measure)
                                : (i1, i32, i32, i32) -> (i1, i32, i32)
    %meas_f, %meas_at, %meas = crag.func_ref "measure_number"(
                                %fired, %at, %beat_count, %beats_per_measure)
                                : (i1, i32, i32, i32) -> (i1, i32, i32)

    // Post meters so hosts can observe the beat state.
    crag.meter_bool "beat_fired"         %fired      : i1
    crag.meter_int  "beat_sample_offset" %at     min = 0 max = 512  : i32
    crag.meter_int  "beat_count"         %beat_count min = 0 max = 1000000 : i32

    // Publish patchbay-routable control outputs.
    crag.event_output_void "beat" %fired, %at subtype = "beat" : i1, i32
    crag.event_output_int  "beat_in_measure" %bim_f, %bim_at, %bim
        subtype = "beat_position" : i1, i32, i32
    crag.event_output_int  "measure" %meas_f, %meas_at, %meas
        subtype = "measure_number" : i1, i32, i32
    crag.param_output_int  "beat_count" %beat_count
        min = 0 max = 1000000 default = 0 : i32

    // Silent audio output (required by crag.graph)
    %noise    = crag.white_noise : !crag.audio<f32, 0, 1>
    %zero_f   = arith.constant 0.0 : f32
    %silence  = crag.scale %noise, %zero_f
                    : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %silence : !crag.audio<f32, 0, 1>
  }
}
