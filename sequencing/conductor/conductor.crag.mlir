// Conductor graph — tempo clock with beat-count meters.
//
// A standalone `crag.graph` that drives the metronome function and exposes
// tempo state to hosts via meter outputs.  The audio output is intentionally
// silent; the useful outputs are the three meters:
//
//   beat_fired         (bool)  — true when a beat fired in the current block
//   beat_sample_offset (int)   — sample offset of the beat within the block
//   beat_count         (int)   — total number of beats elapsed (0-indexed)
//
// Parameters:
//   start_ms    — time (ms) at which beat 0 occurs relative to playback start
//   bpm         — tempo in beats per minute
//
// The `simple_amp_sequencer` graph demonstrates using the underlying
// `metronome` and `beat_in_measure` funcs directly to build a beat-indexed
// amplitude sequencer without requiring conductor as a subgraph.

module {
  crag.include_func "sequencing/metronome.crag.mlir" as "metronome"

  crag.graph name = "conductor" sample_rate = 0 channels = 1 {
    %sr         = crag.sample_rate : f32

    // Parameters
    %start_ms   = crag.param "start_ms" min = 0.0 max = 3600000.0 default = 0.0
                      unit = "ms" : f32
    %bpm        = crag.param "bpm" min = 20.0 max = 300.0 default = 120.0
                      unit = "bpm" : f32

    // Convert BPM to beat period in samples: sr * 60 / bpm
    %sixty_f    = arith.constant 60.0 : f32
    %sr_x60     = arith.mulf %sr, %sixty_f : f32
    %period_f   = arith.divf %sr_x60, %bpm : f32
    %period_i64 = arith.fptosi %period_f : f32 to i64

    // Convert start_ms to start sample: start_ms / 1000 * sr
    %thousand_f   = arith.constant 1000.0 : f32
    %start_sec_f  = arith.divf %start_ms, %thousand_f : f32
    %start_samp_f = arith.mulf %start_sec_f, %sr : f32
    %start_samp   = arith.fptosi %start_samp_f : f32 to i64

    // Call metronome to detect beat events in the current block
    %fired, %at = crag.func_ref "metronome"(%start_samp, %period_i64)
                      : (i64, i64) -> (i1, i32)

    // Compute beat count = max(0, (curframe - start_samp) / period)
    %cur_frame  = crag.curframe : i64
    %zero_i64   = arith.constant 0 : i64
    %elapsed    = arith.subi %cur_frame, %start_samp : i64
    %before     = arith.cmpi slt, %elapsed, %zero_i64 : i64
    %safe_el    = arith.select %before, %zero_i64, %elapsed : i64
    %count_i64  = arith.divsi %safe_el, %period_i64 : i64
    %beat_count = arith.trunci %count_i64 : i64 to i32

    // Post meters so hosts can observe the beat state
    crag.meter_bool "beat_fired"         %fired     : i1
    crag.meter_int  "beat_sample_offset" %at    min = 0 max = 512  : i32
    crag.meter_int  "beat_count"         %beat_count min = 0 max = 1000000 : i32

    // Silent audio output (required by crag.graph)
    %noise    = crag.white_noise : !crag.audio<f32, 0, 1>
    %zero_f   = arith.constant 0.0 : f32
    %silence  = crag.scale %noise, %zero_f
                    : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %silence : !crag.audio<f32, 0, 1>
  }
}
