// Phaser
//
// A phaser creates a sweeping, whooshing effect by passing the signal through
// a chain of notch filters whose centre frequencies are modulated by a low-
// frequency oscillator (LFO).  When mixed with the dry signal, the out-of-
// phase notches create a distinctive comb-like sweep.
//
// Algorithm:
//   1. Compute the LFO-modulated base cutoff:
//        lfo(t) = sin(2π · rate · t)                        ∈ [-1, 1]
//        c0 = c_lo + (c_hi - c_lo) · (lfo + 1) / 2        ∈ [c_lo, c_hi]
//   2. Apply 4 cascaded 2nd-order notch filters, each sharing the same
//      swept cutoff.  The cascade deepens the notches in the dry/wet mix
//      and produces a richer harmonic sweep.
//   3. Mix: out = dry_level · in + wet_level · filtered
//
// The cascade of four independent notch-filter instances (same coefficients,
// separate state memories) behaves like a classic 8-pole phaser—each filter
// stage adds one pair of conjugate transmission zeros at the notch frequency.
//
// Sweep range (normalised to Nyquist = 1.0):
//   c_lo ≈ 0.008  (~200 Hz  @ 48 kHz, the bottom of the sweep)
//   c_hi ≈ 0.17   (~4 kHz   @ 48 kHz, the top of the sweep)
//
// Parameters:
//   rate       [0.05, 5]   – LFO frequency in Hz           (default 0.3)
//   c_lo       [0.002, 0.1] – sweep lower bound (norm. freq)(default 0.008)
//   c_hi       [0.05, 0.4] – sweep upper bound (norm. freq)(default 0.17)
//   feedback   [0, 0.9]    – fraction of output fed back
//                            into the input before filtering (default 0.0)
//   wet_level  [0, 1]      – wet mix amplitude             (default 0.7)
//   dry_level  [0, 1]      – dry pass-through amplitude    (default 0.7)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "phaser"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/modulation/phaser.crag.mlir" as "phaser"

module {
  crag.graph name = "phaser" sample_rate = 48000 channels = 1
      default_visualizer = "phase-correlation" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %rate      = crag.param "rate"      min = 0.05 max = 5.0  default = 0.3   : f32
    %c_lo      = crag.param "c_lo"      min = 0.002 max = 0.1 default = 0.008 : f32
    %c_hi      = crag.param "c_hi"      min = 0.05  max = 0.4 default = 0.17  : f32
    %feedback  = crag.param "feedback"  min = 0.0  max = 0.9  default = 0.0   : f32
    %wet_level = crag.param "wet_level" min = 0.0  max = 1.0  default = 0.7   : f32
    %dry_level = crag.param "dry_level" min = 0.0  max = 1.0  default = 0.7   : f32

    // -----------------------------------------------------------------------
    // Feedback delay (stores the previous block's filtered output so it can
    // be mixed back into the input before the filter chain)
    // -----------------------------------------------------------------------
    %fbl = crag.delay_line : !crag.delay<f32, 48000, 1, 512>
    %prev_out = crag.pop_delay %fbl : !crag.delay<f32, 48000, 1, 512>
                    -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // LFO — sweeps the notch centre frequency
    // -----------------------------------------------------------------------
    %two_pi = arith.constant 6.28318530 : f32
    %t_f64  = crag.curtime : f64
    %t_f32  = arith.truncf %t_f64 : f64 to f32
    %omega  = arith.mulf %two_pi, %rate : f32
    %phase  = arith.mulf %omega, %t_f32 : f32
    %lfo    = math.sin %phase : f32

    // Map lfo ∈ [-1,1] → [0,1]
    %one_f   = arith.constant 1.0 : f32
    %two_f   = arith.constant 2.0 : f32
    %lfo_p1  = arith.addf %lfo, %one_f : f32
    %lfo_01  = arith.divf %lfo_p1, %two_f : f32

    // Interpolate between c_lo and c_hi
    %c_range = arith.subf %c_hi, %c_lo : f32
    %c_delta = arith.mulf %lfo_01, %c_range : f32
    %cutoff  = arith.addf %c_lo, %c_delta : f32

    // -----------------------------------------------------------------------
    // Get 2nd-order notch filter coefficients (shared across all 4 stages)
    // -----------------------------------------------------------------------
    %fb_n, %ff_n = crag.get_filter_coeffs %cutoff order = 2 type = "notch"
                       : f32, !crag.coeff_vec, !crag.coeff_vec

    // -----------------------------------------------------------------------
    // Mix feedback into input
    // -----------------------------------------------------------------------
    %fb_sig = crag.scale %prev_out, %feedback : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>
    %stage_in = crag.sum %in, %fb_sig
                    : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                      -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // 4 cascaded notch filter stages (each has independent state memory)
    // -----------------------------------------------------------------------
    %s1 = crag.filter %stage_in, %fb_n, %ff_n
              : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                -> !crag.audio<f32, 0, 0>
    %s2 = crag.filter %s1, %fb_n, %ff_n
              : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                -> !crag.audio<f32, 0, 0>
    %s3 = crag.filter %s2, %fb_n, %ff_n
              : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                -> !crag.audio<f32, 0, 0>
    %s4 = crag.filter %s3, %fb_n, %ff_n
              : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                -> !crag.audio<f32, 0, 0>

    // Store filtered output for next-block feedback
    crag.push_delay %fbl, %s4 : !crag.delay<f32, 48000, 1, 512>,
                                 !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Wet/dry mix
    // -----------------------------------------------------------------------
    %dry_sc = crag.scale %in,  %dry_level : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>
    %wet_sc = crag.scale %s4,  %wet_level : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>
    %output = crag.sum %dry_sc, %wet_sc
                  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                    -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
