// Select2
//
// Forwards one of two audio inputs, chosen by the `which` enum parameter.
// Use it to A/B alternative processing chains or to switch sources without
// rewiring the graph.
//
// The switch is evaluated per block, so changing `which` takes effect at the
// next block boundary; both inputs keep running while unselected (their
// upstream state stays warm, avoiding a cold-start transient on switch).
//
// Parameters:
//   which  enum – 0 = first input, 1 = second input (default 0 = first)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "select2"(%a, %b)
//              : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
//                -> !crag.audio<f32, 0, 0>

module {
  crag.graph name = "select2" sample_rate = 0 channels = 1 {
  ^bb0(%first: !crag.audio<f32, 0, 0>, %second: !crag.audio<f32, 0, 0>):

    %which = crag.param_enum "which"
                 values = ["first", "second"]
                 default = 0 : i32

    %out = crag.selector %which : i32 -> !crag.audio<f32, 0, 0> (
      {
        crag.selector_yield %first : !crag.audio<f32, 0, 0>
      }, {
        crag.selector_yield %second : !crag.audio<f32, 0, 0>
      })

    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
