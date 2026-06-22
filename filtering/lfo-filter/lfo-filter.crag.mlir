// LFO-Driven Filter
//
// A low-frequency oscillator (LFO) continuously sweeps the cutoff frequency
// of a 2nd-order lowpass filter, producing the slow "wah"-like timbral
// motion that is characteristic of analogue filter sweeps on synth pads,
// dub-reggae snare hits, and lo-fi treatments of percussion loops.
//
// Algorithm (per block):
//   1. Generate a sine LFO at the configured rate:
//        lfo(t) = sin(2π · rate · t)                      ∈ [-1, 1]
//   2. Map the LFO into the normalised cutoff range:
//        cutoff = c_lo + (c_hi - c_lo) · (lfo + 1) / 2    ∈ [c_lo, c_hi]
//   3. Compute fresh 2nd-order lowpass coefficients for that cutoff.
//   4. Cascade two filter stages with the same coefficients (independent
//      state) so the slope is steeper and the sweep is more pronounced.
//   5. Mix: out = dry_level · in + wet_level · filtered
//
// Sweep range (normalised to Nyquist = 1.0):
//   c_lo ≈ 0.01   (~240 Hz @ 48 kHz, the bottom of the sweep)
//   c_hi ≈ 0.40   (~9.6 kHz @ 48 kHz, the top of the sweep)
//
// Parameters:
//   rate       [0.05, 8]    – LFO frequency in Hz           (default 0.5)
//   c_lo       [0.002, 0.2] – sweep lower bound (norm. freq)(default 0.01)
//   c_hi       [0.05, 0.49] – sweep upper bound (norm. freq)(default 0.40)
//   wet_level  [0, 1]       – filtered (wet) mix amplitude  (default 1.0)
//   dry_level  [0, 1]       – dry pass-through amplitude    (default 0.0)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "lfo_filter"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/filtering/lfo-filter.crag.mlir" as "lfo_filter"

module {
  crag.graph name = "lfo_filter" sample_rate = 0 channels = 1 preferred_channel_mixer = "parallel"
      default_visualizer = "spectrometer" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %rate      = crag.param "rate"      min = 0.05  max = 8.0   default = 0.5  : f32
    %c_lo      = crag.param "c_lo"      min = 0.002 max = 0.2   default = 0.01 : f32
    %c_hi      = crag.param "c_hi"      min = 0.05  max = 0.49  default = 0.40 : f32
    %wet_level = crag.param "wet_level" min = 0.0   max = 1.0   default = 1.0  : f32
    %dry_level = crag.param "dry_level" min = 0.0   max = 1.0   default = 0.0  : f32

    // -----------------------------------------------------------------------
    // LFO — sweeps the lowpass cutoff between c_lo and c_hi
    // -----------------------------------------------------------------------
    %two_pi = arith.constant 6.28318530 : f32
    %t_f64  = crag.curtime : f64
    %t_f32  = arith.truncf %t_f64 : f64 to f32
    %omega  = arith.mulf %two_pi, %rate : f32
    %phase  = arith.mulf %omega, %t_f32 : f32
    %lfo    = math.sin %phase : f32

    // Map lfo ∈ [-1,1] → [0,1]
    %one_f  = arith.constant 1.0 : f32
    %two_f  = arith.constant 2.0 : f32
    %lfo_p1 = arith.addf %lfo, %one_f : f32
    %lfo_01 = arith.divf %lfo_p1, %two_f : f32

    // Interpolate between c_lo and c_hi, then clamp into the legal
    // (0, 1) Nyquist-normalised range required by get_filter_coeffs.
    %c_range = arith.subf %c_hi, %c_lo : f32
    %c_delta = arith.mulf %lfo_01, %c_range : f32
    %c_raw   = arith.addf %c_lo, %c_delta : f32
    %c_min   = arith.constant 0.001 : f32
    %c_max   = arith.constant 0.499 : f32
    %c_clo   = arith.maximumf %c_raw, %c_min : f32
    %cutoff  = arith.minimumf %c_clo, %c_max : f32

    // -----------------------------------------------------------------------
    // Compute 2nd-order lowpass coefficients (shared across both stages)
    // -----------------------------------------------------------------------
    %fb, %ff = crag.get_filter_coeffs %cutoff order = 2 type = "lowpass"
                   : f32, !crag.coeff_vec, !crag.coeff_vec

    // -----------------------------------------------------------------------
    // Two cascaded 2nd-order lowpass stages (independent state memories)
    // -----------------------------------------------------------------------
    %s1 = crag.filter %in, %fb, %ff
              : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                -> !crag.audio<f32, 0, 0>
    %s2 = crag.filter %s1, %fb, %ff
              : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Wet/dry mix
    // -----------------------------------------------------------------------
    %dry_sc = crag.scale %in, %dry_level : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>
    %wet_sc = crag.scale %s2, %wet_level : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>
    %output = crag.sum %dry_sc, %wet_sc
                  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                    -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
