// Vibrato
//
// A vibrato effect created by modulating a delay line's read position with a
// sinusoidal LFO.  Unlike chorus or flanger, vibrato outputs the 100% wet
// (modulated) signal without mixing in the dry input, producing a continuous
// pitch-oscillation effect.
//
// This graph demonstrates the `maxSize` optional attribute on delay lines.
// The delay buffer is allocated as `maxSize = 2400` samples (50 ms at 48 kHz)
// to accommodate the full modulation swing, while `delaySize = 960` samples
// (20 ms) expresses the nominal reading depth used for periodicity analysis
// and run-time estimates.
//
// Algorithm (per block):
//   1. Push the dry input into the circular buffer (maxSize = 2400 samples).
//   2. Compute the LFO-modulated delay in samples:
//        D = center_ms · sr/1000 + depth_ms · sr/1000 · sin(2π · rate · t)
//   3. Compute the peek offset from the buffer head:
//        offset = bufSize - D     (bufSize = maxSize = 2400)
//   4. Peek at that offset (non-destructive read).
//   5. Output the peeked (pure-wet) signal.
//
// Buffer parameters (at 48 kHz):
//   delaySize = 960 samples  (nominal 20 ms reading depth)
//   maxSize   = 2400 samples (50 ms — covers the full modulation range)
//   center    = 20 ms = 960 samples
//   depth     ≤ 10 ms = 480 samples  → delay range [10 ms, 30 ms]
//
// Parameters:
//   rate      [0.1, 10]   – LFO frequency in Hz           (default 5.0)
//   depth_ms  [0.1, 10]   – modulation depth in ms        (default 5.0)
//   center_ms [10, 40]    – centre (nominal) delay in ms  (default 20.0)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "vibrato"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/modulation/vibrato.crag.mlir" as "vibrato"

module {
  crag.graph name = "vibrato" sample_rate = 48000 channels = 1
      default_visualizer = "phase-correlation" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %rate      = crag.param "rate"      min = 0.1  max = 10.0 default = 5.0  : f32
    %depth_ms  = crag.param "depth_ms"  min = 0.1  max = 10.0 default = 5.0  : f32
    %center_ms = crag.param "center_ms" min = 10.0 max = 40.0 default = 20.0 : f32

    // -----------------------------------------------------------------------
    // Circular delay buffer.
    //   delaySize = 960  — nominal reading depth (20 ms) for timing analysis.
    //   maxSize   = 2400 — actual allocated buffer (50 ms) for full LFO swing.
    // -----------------------------------------------------------------------
    %dl = crag.delay_line : !crag.delay<f32, 48000, 1, 960, 2400>
    crag.push_delay %dl, %in : !crag.delay<f32, 48000, 1, 960, 2400>,
                                !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // LFO
    // -----------------------------------------------------------------------
    %sr       = arith.constant 48000.0 : f32
    %two_pi   = arith.constant 6.28318530 : f32
    %ms_scale = arith.constant 0.001 : f32
    %buf_f    = arith.constant 2400.0 : f32   // maxSize as f32

    %t_f64 = crag.curtime : f64
    %t_f32 = arith.truncf %t_f64 : f64 to f32
    %omega = arith.mulf %two_pi, %rate : f32
    %phase = arith.mulf %omega, %t_f32 : f32
    %lfo   = math.sin %phase : f32

    // -----------------------------------------------------------------------
    // Modulated delay in samples and peek offset from buffer head
    //
    //   center_samp = center_ms · sr · ms_scale
    //   depth_samp  = depth_ms  · sr · ms_scale
    //   delay_samp  = center_samp + depth_samp · lfo
    //   offset      = (int)(bufSize - delay_samp)
    // -----------------------------------------------------------------------
    %sr_ms       = arith.mulf %sr, %ms_scale : f32
    %center_samp = arith.mulf %center_ms, %sr_ms : f32
    %depth_samp  = arith.mulf %depth_ms,  %sr_ms : f32
    %mod         = arith.mulf %depth_samp, %lfo : f32
    %delay_samp  = arith.addf %center_samp, %mod : f32
    %off_f       = arith.subf %buf_f, %delay_samp : f32
    %off         = arith.fptosi %off_f : f32 to i32

    // -----------------------------------------------------------------------
    // Peek at the modulated offset (pure-wet output)
    // -----------------------------------------------------------------------
    %out = crag.peek_delay %dl, %off : !crag.delay<f32, 48000, 1, 960, 2400>,
                                        i32
               -> !crag.audio<f32, 48000, 1>

    crag.output %out : !crag.audio<f32, 48000, 1>
  }
}
