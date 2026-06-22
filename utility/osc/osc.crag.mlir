// Osc
//
// Basic waveform oscillator with a runtime-selectable shape.  Produces a
// full-scale (±1) signal at the requested frequency; put a `gain` node (or
// crag.scale) after it to set the level.
//
// All four shapes share the same frequency and phase inputs, so switching
// the type while playing stays phase-coherent.  Triangle and square use a
// fixed 0.5 duty cycle (symmetric waveforms).
//
// Parameters:
//   type       enum               – waveform: 0=sine, 1=saw, 2=triangle,
//                                   3=square (default 0 = sine)
//   frequency  [0.1, 20000] Hz    – oscillation frequency (default 440).
//                                   Sub-audio settings make it usable as an
//                                   audio-rate LFO.
//   phase      [0, 2π] rad        – phase offset (default 0)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "osc"()
//              : () -> !crag.audio<f32, 0, 1>

module {
  crag.graph name = "osc" sample_rate = 0 channels = 1 {

    %type      = crag.param_enum "type"
                     values = ["sine", "saw", "triangle", "square"]
                     default = 0 : i32
    %frequency = crag.param "frequency" min = 0.1 max = 20000.0 default = 440.0 unit = "hz" : f32
    %phase     = crag.param "phase"     min = 0.0 max = 6.28318530718 default = 0.0 : f32

    // Symmetric triangle / square.
    %duty = arith.constant 0.5 : f32

    %out = crag.selector %type : i32 -> !crag.audio<f32, 0, 1> (
      {
        %sine = crag.sine %frequency, %phase
                    : f32, f32 -> !crag.audio<f32, 0, 1>
        crag.selector_yield %sine : !crag.audio<f32, 0, 1>
      }, {
        %saw = crag.saw %frequency, %phase
                   : f32, f32 -> !crag.audio<f32, 0, 1>
        crag.selector_yield %saw : !crag.audio<f32, 0, 1>
      }, {
        %tri = crag.tri %frequency, %phase, %duty
                   : f32, f32, f32 -> !crag.audio<f32, 0, 1>
        crag.selector_yield %tri : !crag.audio<f32, 0, 1>
      }, {
        %square = crag.square %frequency, %phase, %duty
                      : f32, f32, f32 -> !crag.audio<f32, 0, 1>
        crag.selector_yield %square : !crag.audio<f32, 0, 1>
      })

    crag.output %out : !crag.audio<f32, 0, 1>
  }
}
