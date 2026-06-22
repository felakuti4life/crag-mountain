// Fuzz Distortion
//
// A classic fuzz effect modelling the extreme transistor or diode clipping
// circuits found in vintage fuzz pedals (e.g. Fuzz Face, Big Muff).
//
// The core idea is to drive an input signal so far into saturation that the
// output approaches a square wave, producing a dense wall of harmonics.  A
// post-saturation tone control (1st-order lowpass filter) then rolls off the
// harshest high-frequency content to taste, recovering the warm body of the
// tone without completely eliminating the harmonic richness.
//
// Algorithm:
//   1. Pre-amp:        u[n] = fuzz_gain * x[n]
//   2. Saturation:     v[n] = tanh(u[n])          (smooth rail at ±1)
//   3. Hard clip:      w[n] = hard_clip(v, 0.95)  (tighten the rails)
//   4. Tone (lowpass): y[n] = LPF(w, tone_cutoff)
//
// The double saturation (tanh followed by hard clip) produces a signal that is
// very close to a square wave at high gain settings, mimicking the behaviour
// of BJT transistors biased into hard saturation.  The tone control cuts the
// upper harmonics from ~3 kHz (tone = 0, dark and woolly) up to full bandwidth
// (tone = 1, bright and fizzy).
//
// Parameters:
//   fuzz_gain    [5, 100]   – saturation drive      (default 30.0)
//   tone         [0, 1]     – post-fuzz tonal colour
//                              0 = dark (~3 kHz cutoff)
//                              1 = full bandwidth (~24 kHz)
//                              (default 0.5)
//   volume       [0, 1]     – output level          (default 0.7)
//   dry_level    [0, 1]     – clean (direct) level  (default 0.0)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "fuzz"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/distortion/fuzz.crag.mlir" as "fuzz"

module {
  crag.graph name = "fuzz" sample_rate = 48000 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %fuzz_gain = crag.param "fuzz_gain" min = 5.0  max = 100.0 default = 30.0 : f32
    %tone      = crag.param "tone"      min = 0.0  max = 1.0   default = 0.5  : f32
    %volume    = crag.param "volume"    min = 0.0  max = 1.0   default = 0.7  : f32
    %dry_p     = crag.param "dry_level" min = 0.0  max = 1.0   default = 0.0  : f32

    // -----------------------------------------------------------------------
    // Stage 1: extreme pre-amp
    // -----------------------------------------------------------------------
    %driven = crag.scale %in, %fuzz_gain : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Stage 2: tanh saturation — smooth clipping approaching a square wave
    // -----------------------------------------------------------------------
    %saturated = crag.tanh %driven : !crag.audio<f32, 0, 0> -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Stage 3: hard clip at ±0.95 — tighten the saturation ceiling to mimic
    // diode-clipping circuits that clip more abruptly than tanh alone
    // -----------------------------------------------------------------------
    %clip_ceil = arith.constant 0.95 : f32
    %clipped   = crag.hard_clip %saturated, %clip_ceil
                     : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Stage 4: tone control — 1st-order lowpass to tame harshness
    //
    // Map tone=[0,1] to cutoff normalised to Nyquist:
    //   tone=0 → cutoff ≈ 0.06  (~3 kHz  @ 48 kHz, dark)
    //   tone=1 → cutoff ≈ 0.48  (~23 kHz @ 48 kHz, full bandwidth)
    // -----------------------------------------------------------------------
    %t_lo  = arith.constant 0.06 : f32
    %t_rng = arith.constant 0.42 : f32
    %t_sc  = arith.mulf %tone, %t_rng : f32
    %cutoff = arith.addf %t_lo, %t_sc : f32

    %fb_tone, %ff_tone = crag.get_filter_coeffs %cutoff order = 1 type = "lowpass"
                             : f32, !crag.coeff_vec, !crag.coeff_vec
    %toned = crag.filter %clipped, %fb_tone, %ff_tone
                 : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                   -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Output level + wet/dry mix
    // -----------------------------------------------------------------------
    %wet_out = crag.scale %toned, %volume : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %dry_out = crag.scale %in, %dry_p     : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %output  = crag.sum %dry_out, %wet_out
                   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                     -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
