// Observe Float — emit an event when a float parameter changes.
//
// Compares the `value` parameter to its value in the previous audio block.
// When the value differs, fires a float event carrying the new value.
//
// The detection uses a per-sample state loop whose state variable holds the
// previous block's parameter value.  At sample 0 of each block the state
// equals last block's value; from sample 1 onward both sides equal the
// current value, so only one change can fire per block.
//
// Parameters:
//   value   — float to observe (full practical range)
//
// Events:
//   changed (event_float) — fires at sample 0 of any block where value
//                           differs from the previous block's value;
//                           carries the new value

module {
  crag.graph name = "observe_float" sample_rate = 0 channels = 1 {

    %val = crag.param "value" min = -1.0e20 max = 1.0e20 default = 0.0 : f32

    // A unit impulse drives the per_sample loop; its audio content is
    // discarded — we only need the state-carry mechanism.
    %dummy = crag.impulse : !crag.audio<f32, 0, 1>

    // State = previous block's %val (initialized to 0.0).
    %s0 = arith.constant 0.0 : f32

    // At sample 0, %prev == last block's value; we detect changes there.
    // Every sample yields %val as the new state so that later samples in
    // the same block no longer see a difference.
    %changed_audio, %val_hold = crag.per_sample (%dummy) states (%s0) {
    ^bb0(%x: f32, %prev: f32):
      %changed   = arith.cmpf one, %val, %prev : f32
      %changed_f = arith.uitofp %changed : i1 to f32
      crag.per_sample_yield %changed_f, %val : f32, f32
    } : (!crag.audio<f32, 0, 1>, f32) -> (!crag.audio<f32, 0, 1>, f32)

    // peak > 0 iff at least one sample (i.e., sample 0) detected a change.
    %zero_f = arith.constant 0.0 : f32
    %peak   = crag.peak %changed_audio : !crag.audio<f32, 0, 1> -> f32
    %fired  = arith.cmpf ogt, %peak, %zero_f : f32
    %at     = arith.constant 0 : i32

    crag.event_output_float "changed" %fired, %at, %val
        subtype = "param_changed" : i1, i32, f32

    // Silent audio output required by crag.graph.
    %noise   = crag.white_noise : !crag.audio<f32, 0, 1>
    %c0_f    = arith.constant 0.0 : f32
    %silence = crag.scale %noise, %c0_f
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    crag.output %silence : !crag.audio<f32, 0, 1>
  }
}
