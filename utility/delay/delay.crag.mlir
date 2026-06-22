// Delay
//
// Feedforward (tap) delay: outputs the input signal delayed by `delay_ms`
// milliseconds, with no dry signal and no feedback.  Mix it with the dry
// path downstream (e.g. via crag.sum) to build echo or comb effects, or use
// it on its own to time-align parallel processing chains.
//
// Algorithm (per block):
//   1. Push the incoming block into a circular buffer sized for 2 s of audio.
//   2. Convert `delay_ms` to samples and clamp it to [blockSize, bufferSize]:
//      the lower bound exists because a block-granular pipeline cannot read
//      samples that were produced less than one block ago, and the upper
//      bound keeps the read offset inside the buffer.  The effective minimum
//      delay is therefore one audio block.
//   3. Peek (non-destructive read) one block starting at
//      offset = bufferSize - delaySamples from the buffer head.
//
// The buffer is declared with duration timings (250 ms nominal / 2 s
// allocated) and a zero sample count, so `crag-resolve-delay-timings` sizes
// it for whatever sample rate the enclosing module compiles at.  The
// in-graph offset math mirrors that sizing by computing
// bufferSamples = 2.0 · sample_rate.
//
// Parameters:
//   delay_ms  [0, 1900] ms – delay time (default 250).  The upper bound
//                            leaves one block of headroom below the 2 s
//                            buffer at typical sample rates.
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "delay"(%in)
//              : (!crag.audio<f32, 0, 1>) -> !crag.audio<f32, 0, 1>

module {
  crag.graph name = "delay" sample_rate = 0 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 1>):

    %delay_ms = crag.param "delay_ms" min = 0.0 max = 1900.0 default = 250.0 unit = "ms" : f32

    // Circular buffer: 250 ms nominal read depth, 2 s allocated.
    %dl = crag.delay_line {delay_timing = !crag.duration<250000>,
                           max_timing = !crag.duration<2000000>}
              : !crag.delay<f32, 0, 1, 0, 0>
    crag.push_delay %dl, %in : !crag.delay<f32, 0, 1, 0, 0>,
                                !crag.audio<f32, 0, 1>

    // Buffer size in samples (matches the 2 s max_timing above).
    %sr        = crag.sample_rate : f32
    %two       = arith.constant 2.0 : f32
    %buf_samp  = arith.mulf %sr, %two : f32

    // Block size as f32 — lower clamp for the delay so the peek offset
    // never reaches past the most recent write.
    %bs_i64 = crag.block_size : i64
    %bs_i32 = arith.trunci %bs_i64 : i64 to i32
    %bs_f   = arith.sitofp %bs_i32 : i32 to f32

    // delaySamples = delay_ms · sr / 1000, clamped to [blockSize, bufSamples]
    %ms_scale   = arith.constant 0.001 : f32
    %sr_ms      = arith.mulf %sr, %ms_scale : f32
    %delay_raw  = arith.mulf %delay_ms, %sr_ms : f32
    %delay_lo   = arith.maximumf %delay_raw, %bs_f : f32
    %delay_samp = arith.minimumf %delay_lo, %buf_samp : f32

    // offset from the buffer head (the oldest sample) to the start of the
    // requested block: offset = bufSamples - delaySamples ∈ [0, buf - block]
    %off_f = arith.subf %buf_samp, %delay_samp : f32
    %off   = arith.fptosi %off_f : f32 to i32

    %delayed = crag.peek_delay %dl, %off
                   : !crag.delay<f32, 0, 1, 0, 0>, i32
                     -> !crag.audio<f32, 0, 1>

    crag.output %delayed : !crag.audio<f32, 0, 1>
  }
}
