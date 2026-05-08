// ADSR Envelope Generator
//
// Generates an audio-rate Attack–Decay–Sustain–Release (one-shot ADR)
// envelope that is triggered by a void event.  Note that unlike a classic
// synthesizer ADSR (which holds at the sustain level until a note-off), this
// envelope is fully one-shot: it proceeds through attack → decay → release
// automatically without waiting for a gate signal.  The "sustain" parameter
// sets the level that the decay stage ramps *to* (and from which the release
// then decays to 0).
//
// The envelope stages proceed automatically after each trigger:
//
//   1. Attack  — ramps from the current level to 1.0 over `attack_ms`
//   2. Decay   — decays from 1.0 to `sustain_level` over `decay_ms`
//   3. Release — decays from `sustain_level` to 0 over `release_ms`
//
// After the release the envelope returns to 0 (idle) and waits for the next
// trigger.  Retriggering while the envelope is active starts the attack from
// the current level (no click).
//
// Parameters:
//   attack_ms     [0, 10000] ms  — attack time (default 10 ms)
//   decay_ms      [0, 10000] ms  — decay time  (default 100 ms)
//   sustain       [0, 1]         — decay target / release start level (default 0.7)
//   release_ms    [0, 10000] ms  — release time (default 200 ms)
//
// Events:
//   trigger (void) — fire to start the attack phase at a specific sample
//
// Output: !crag.audio<f32, 0, 1> — mono audio-rate envelope in [0, 1]
//
// Usage (after crag.include):
//   %env = crag.subgraph_ref "adsr"() : () -> !crag.audio<f32, 0, 1>
//
// This file contains only a named subgraph; include it from another module:
//   crag.include "standard-graphs/utility/adsr.crag.mlir" as "adsr"

module {
  crag.graph name = "adsr" sample_rate = 0 channels = 1 {

    %attack_ms  = crag.param "attack_ms"  min = 0.0 max = 10000.0 default = 10.0   unit = "ms" : f32
    %decay_ms   = crag.param "decay_ms"   min = 0.0 max = 10000.0 default = 100.0  unit = "ms" : f32
    %sustain    = crag.param "sustain"    min = 0.0 max = 1.0     default = 0.7 : f32
    %release_ms = crag.param "release_ms" min = 0.0 max = 10000.0 default = 200.0  unit = "ms" : f32

    %fired, %at = crag.event_void "trigger" : i1, i32

    %env = crag.adsr %attack_ms, %decay_ms, %sustain, %release_ms, %fired, %at
               : f32, f32, f32, f32, i1, i32 -> !crag.audio<f32, 0, 1>

    crag.output %env : !crag.audio<f32, 0, 1>
  }
}
