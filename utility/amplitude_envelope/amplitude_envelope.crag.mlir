// Amplitude Envelope
//
// Applies an ADSR one-shot envelope to a mono audio signal.  The envelope
// multiplies the input sample-by-sample to produce a shaped output.
//
// Parameters:
//   attack_ms     [0, 10000] ms  — attack time  (default 10 ms)
//   decay_ms      [0, 10000] ms  — decay time   (default 100 ms)
//   sustain       [0, 1]         — sustain/decay target level (default 0.7)
//   release_ms    [0, 10000] ms  — release time (default 200 ms)
//
// Events:
//   trigger (void) — fire to start the ADSR attack phase
//
// Audio input:  !crag.audio<f32, 0, 1> — mono signal to shape
// Audio output: !crag.audio<f32, 0, 1> — envelope-shaped output
//
// Usage (after crag.include):
//   %shaped = crag.subgraph_ref "amplitude_envelope"(%dry)
//                 : (!crag.audio<f32, 0, 1>) -> !crag.audio<f32, 0, 1>
//
// Include this file:
//   crag.include "standard-graphs/utility/amplitude_envelope.crag.mlir"
//       as "amplitude_envelope"

module {
  crag.graph name = "amplitude_envelope" sample_rate = 0 channels = 1 {
  ^bb0(%input: !crag.audio<f32, 0, 1>):

    %attack_ms  = crag.param "attack_ms"  min = 0.0 max = 10000.0 default = 10.0   unit = "ms" : f32
    %decay_ms   = crag.param "decay_ms"   min = 0.0 max = 10000.0 default = 100.0  unit = "ms" : f32
    %sustain    = crag.param "sustain"    min = 0.0 max = 1.0     default = 0.7 : f32
    %release_ms = crag.param "release_ms" min = 0.0 max = 10000.0 default = 200.0  unit = "ms" : f32

    %fired, %at = crag.event_void "trigger" : i1, i32

    %env = crag.adsr %attack_ms, %decay_ms, %sustain, %release_ms, %fired, %at
               : f32, f32, f32, f32, i1, i32 -> !crag.audio<f32, 0, 1>

    %out = crag.audio_mul %input, %env
               : !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>
               -> !crag.audio<f32, 0, 1>

    crag.output %out : !crag.audio<f32, 0, 1>
  }
}
