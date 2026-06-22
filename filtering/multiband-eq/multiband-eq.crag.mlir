// Multiband EQ (3-Band)
//
// A simple 3-band parametric equalizer.  The input is split into a low, mid,
// and high band by a pair of crossover filters; each band is then scaled by
// an independent gain (in decibels) and the three bands are summed back to
// produce the output.
//
// Band split:
//   low  = LPF(in, f_lo)                       (2nd-order Butterworth lowpass)
//   high = HPF(in, f_hi)                       (2nd-order Butterworth highpass)
//   mid  = in - low - high                     (residual middle band)
//
// This "subtractive" 3-band split mirrors the topology used by
// `standard-graphs/amps/tone-stacks/mesa_boogie_5band_graphic_eq.crag.mlir`
// and the multi-band split used by
// `standard-graphs/compressors/two-band-compressor.crag.mlir`.
// It does not provide perfect linear-phase reconstruction (the LPF and HPF
// have independent phase responses), but at unity gain across all bands it
// produces a near-flat magnitude response and is well behaved as a tone
// shaping tool — turning a band up boosts that band relative to the rest,
// turning it down attenuates it.
//
// Per-band gain mapping (dB → linear):
//   gain_lin = exp(gain_db · ln(10) / 20)
//            = exp(gain_db · 0.115129254...)
//
// Crossover frequencies (normalised to Nyquist = 1.0, clamped into (0, 1)):
//   f_lo defaults to 0.0083  (~200 Hz   @ 48 kHz)
//   f_hi defaults to 0.167   (~4 kHz    @ 48 kHz)
// The crag.get_filter_coeffs op requires 0 < cutoff < 1, so each crossover
// is clamped at runtime into [0.001, 0.499] to keep the IIR design stable
// across the full parameter range.
//
// Parameters:
//   low_freq   [0.002, 0.1]  – low/mid crossover (norm. freq) (default 0.0083)
//   high_freq  [0.05, 0.45]  – mid/high crossover (norm. freq)(default 0.167)
//   low_gain   [-24, +24]    – low band gain in dB            (default 0.0)
//   mid_gain   [-24, +24]    – mid band gain in dB            (default 0.0)
//   high_gain  [-24, +24]    – high band gain in dB           (default 0.0)
//   output_gain [-24, +12]   – overall output gain in dB      (default 0.0)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "multiband_eq"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/filtering/multiband-eq.crag.mlir"
//       as "multiband_eq"

module {
  crag.graph name = "multiband_eq" sample_rate = 48000 channels = 1
      default_visualizer = "spectrometer" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %low_freq    = crag.param "low_freq"    min = 0.002 max = 0.1  default = 0.0083 : f32
    %high_freq   = crag.param "high_freq"   min = 0.05  max = 0.45 default = 0.167  : f32
    %low_gain_db  = crag.param "low_gain"    min = -24.0 max = 24.0 default = 0.0 unit = "dB" : f32
    %mid_gain_db  = crag.param "mid_gain"    min = -24.0 max = 24.0 default = 0.0 unit = "dB" : f32
    %high_gain_db = crag.param "high_gain"   min = -24.0 max = 24.0 default = 0.0 unit = "dB" : f32
    %out_gain_db  = crag.param "output_gain" min = -24.0 max = 12.0 default = 0.0 unit = "dB" : f32

    // -----------------------------------------------------------------------
    // Clamp crossovers into the legal (0, 1) Nyquist-normalised range that
    // `crag.get_filter_coeffs` requires.  The static parameter bounds keep
    // them well within (0, 1), but a defensive runtime clamp guards against
    // any host-side overrides.
    // -----------------------------------------------------------------------
    %c_min = arith.constant 0.001 : f32
    %c_max = arith.constant 0.499 : f32

    %lo_lo  = arith.maximumf %low_freq,  %c_min : f32
    %lo_clp = arith.minimumf %lo_lo,     %c_max : f32
    %hi_lo  = arith.maximumf %high_freq, %c_min : f32
    %hi_clp = arith.minimumf %hi_lo,     %c_max : f32

    // -----------------------------------------------------------------------
    // Band split:
    //   low  = LPF(in, low_freq)
    //   high = HPF(in, high_freq)
    //   mid  = in - low - high
    // -----------------------------------------------------------------------
    %fb_lp, %ff_lp = crag.get_filter_coeffs %lo_clp order = 2 type = "lowpass"
                         : f32, !crag.coeff_vec, !crag.coeff_vec
    %fb_hp, %ff_hp = crag.get_filter_coeffs %hi_clp order = 2 type = "highpass"
                         : f32, !crag.coeff_vec, !crag.coeff_vec

    %low = crag.filter %in, %fb_lp, %ff_lp
               : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                 -> !crag.audio<f32, 0, 0>
    %high = crag.filter %in, %fb_hp, %ff_hp
                : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                  -> !crag.audio<f32, 0, 0>

    // mid = in - low - high
    %neg1   = arith.constant -1.0 : f32
    %low_n  = crag.scale %low,  %neg1 : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>
    %high_n = crag.scale %high, %neg1 : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>
    %tmp = crag.sum %in, %low_n
               : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                 -> !crag.audio<f32, 0, 0>
    %mid = crag.sum %tmp, %high_n
               : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                 -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // dB → linear gain conversion:  gain_lin = exp(gain_db · ln(10) / 20)
    // -----------------------------------------------------------------------
    %kdb = arith.constant 0.11512925464970229 : f32

    %low_lin_e  = arith.mulf %low_gain_db,  %kdb : f32
    %low_gain   = math.exp  %low_lin_e : f32
    %mid_lin_e  = arith.mulf %mid_gain_db,  %kdb : f32
    %mid_gain   = math.exp  %mid_lin_e : f32
    %high_lin_e = arith.mulf %high_gain_db, %kdb : f32
    %high_gain  = math.exp  %high_lin_e : f32
    %out_lin_e  = arith.mulf %out_gain_db,  %kdb : f32
    %out_gain   = math.exp  %out_lin_e : f32

    // -----------------------------------------------------------------------
    // Apply per-band gains and recombine
    // -----------------------------------------------------------------------
    %low_g  = crag.scale %low,  %low_gain  : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>
    %mid_g  = crag.scale %mid,  %mid_gain  : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>
    %high_g = crag.scale %high, %high_gain : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>

    %lm  = crag.sum %low_g, %mid_g
               : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                 -> !crag.audio<f32, 0, 0>
    %mix = crag.sum %lm, %high_g
               : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                 -> !crag.audio<f32, 0, 0>

    // Apply overall output gain.
    %output = crag.scale %mix, %out_gain : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
