// Random Wave
//
// A multi-waveform oscillator that selects between sine, sawtooth, square, and
// triangle waves via an enum parameter.  Useful as a general-purpose test tone
// or demonstration of the crag.selector op.
//
// Parameters:
//   freq      [20, 20000] Hz — oscillator frequency (default 440 Hz)
//   wave_type enum [0..3]    — waveform: 0=sine, 1=saw, 2=square, 3=triangle
//                              (default 0 = sine)
//
// Output: !crag.audio<f32, 0, 1> — mono audio signal
//
// Usage (after crag.include):
//   crag.include "standard-graphs/playback/random-wave.crag.mlir" as "random-wave"
//   ...
//   %audio = crag.subgraph_ref "random-wave"()
//                : () -> !crag.audio<f32, 0, 1>

module {
  crag.graph name = "random-wave" sample_rate = 0 channels = 1
             default_visualizer = "oscilloscope" {

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    %freq = crag.param "freq" min = 20.0 max = 20000.0 default = 440.0 : f32
    %wave_type = crag.param_enum "wave_type"
                     values = ["sine", "saw", "square", "triangle"]
                     default = 0 : i32

    // -------------------------------------------------------------------------
    // Shared constants
    // -------------------------------------------------------------------------
    %phase = arith.constant 0.0 : f32
    %duty  = arith.constant 0.5 : f32

    // -------------------------------------------------------------------------
    // Select the active waveform: each branch computes only its own waveform
    // -------------------------------------------------------------------------
    %out = crag.selector %wave_type : i32 -> !crag.audio<f32, 0, 1> (
      {
        %sine = crag.sine %freq, %phase
                    : f32, f32 -> !crag.audio<f32, 0, 1>
        crag.selector_yield %sine : !crag.audio<f32, 0, 1>
      }, {
        %saw = crag.saw %freq, %phase
                   : f32, f32 -> !crag.audio<f32, 0, 1>
        crag.selector_yield %saw : !crag.audio<f32, 0, 1>
      }, {
        %square = crag.square %freq, %phase, %duty
                      : f32, f32, f32 -> !crag.audio<f32, 0, 1>
        crag.selector_yield %square : !crag.audio<f32, 0, 1>
      }, {
        %tri = crag.tri %freq, %phase, %duty
                   : f32, f32, f32 -> !crag.audio<f32, 0, 1>
        crag.selector_yield %tri : !crag.audio<f32, 0, 1>
      })

    crag.output %out : !crag.audio<f32, 0, 1>
  }
}
