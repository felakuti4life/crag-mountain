// Envelope-Driven Filter (Auto-Wah)
//
// A classic "envelope follower → filter cutoff" effect: the instantaneous
// amplitude envelope of the input modulates the cutoff frequency of a
// 2nd-order lowpass filter.  Louder transients open the filter (bright,
// quack-like timbre) while softer passages let it close (dark, muted).
// This is the building block of the auto-wah / envelope-follower pedals
// used on funk guitars, clavinets, and synth basses.
//
// Algorithm (per block):
//   1. Detect the input level with `crag.rms` and smooth it through an
//      asymmetric attack/release one-pole follower (`crag.smooth`).
//   2. Normalise the smoothed envelope by `sensitivity` so that increasing
//      sensitivity opens the filter on quieter input:
//        env_norm = clamp(env · sensitivity, 0, 1)
//   3. Map the normalised envelope into the cutoff range and add a fixed
//      base cutoff so that the filter never fully closes:
//        cutoff = base_cutoff + env_norm · sweep_range
//      The result is then clamped into the (0, 1) Nyquist-normalised
//      range required by `crag.get_filter_coeffs`.
//   4. Compute 2nd-order lowpass coefficients for that cutoff and pass the
//      audio through two cascaded filter stages (independent state) for a
//      steeper, more vocal-sounding response.
//   5. Mix: out = dry_level · in + wet_level · filtered
//
// Cutoff range (normalised to Nyquist = 1.0):
//   base_cutoff ≈ 0.02     (~480 Hz @ 48 kHz, closed-filter floor)
//   sweep_range ≈ 0.40     (~9.6 kHz @ 48 kHz, full envelope opens to ~10 kHz)
//
// Parameters:
//   sensitivity [0.5, 50]  – envelope gain into the cutoff map (default 8.0)
//                              Higher values open the filter on quieter input.
//   attack_ms   [0.1, 50]  – envelope attack time in ms        (default 5.0)
//   release_ms  [10, 1000] – envelope release time in ms       (default 120.0)
//   base_cutoff [0.005, 0.2]  – closed-filter cutoff (norm. freq) (default 0.02)
//   sweep_range [0.05, 0.45]  – envelope-driven cutoff span      (default 0.40)
//   wet_level   [0, 1]     – filtered (wet) mix amplitude     (default 1.0)
//   dry_level   [0, 1]     – dry pass-through amplitude       (default 0.0)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "envelope_filter"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/filtering/envelope-filter.crag.mlir"
//       as "envelope_filter"

module {
  crag.graph name = "envelope_filter" sample_rate = 48000 channels = 1 preferred_channel_mixer = "parallel"
      default_visualizer = "spectrometer" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %sensitivity = crag.param "sensitivity" min = 0.5    max = 50.0   default = 8.0   : f32
    %attack_ms   = crag.param "attack_ms"   min = 0.1    max = 50.0   default = 5.0   unit = "ms" : f32
    %release_ms  = crag.param "release_ms"  min = 10.0   max = 1000.0 default = 120.0 unit = "ms" : f32
    %base_cutoff = crag.param "base_cutoff" min = 0.005  max = 0.2    default = 0.02  : f32
    %sweep_range = crag.param "sweep_range" min = 0.05   max = 0.45   default = 0.40  : f32
    %wet_level   = crag.param "wet_level"   min = 0.0    max = 1.0    default = 1.0   : f32
    %dry_level   = crag.param "dry_level"   min = 0.0    max = 1.0    default = 0.0   : f32

    // -----------------------------------------------------------------------
    // Envelope detector: RMS → asymmetric one-pole smoother
    // -----------------------------------------------------------------------
    %rms_level = crag.rms %in : !crag.audio<f32, 0, 0> -> f32
    %env       = crag.smooth %rms_level, %attack_ms, %release_ms
                     : f32, f32, f32 -> f32

    // -----------------------------------------------------------------------
    // Map envelope → cutoff and clamp into the legal (0, 1) Nyquist range.
    //   env_norm = clamp(env · sensitivity, 0, 1)
    //   cutoff   = clamp(base_cutoff + env_norm · sweep_range, 0.001, 0.499)
    // -----------------------------------------------------------------------
    %zero_f = arith.constant 0.0   : f32
    %one_f  = arith.constant 1.0   : f32
    %c_min  = arith.constant 0.001 : f32
    %c_max  = arith.constant 0.499 : f32

    %env_g    = arith.mulf %env, %sensitivity : f32
    %env_lo   = arith.maximumf %env_g, %zero_f : f32
    %env_norm = arith.minimumf %env_lo, %one_f : f32

    %sweep   = arith.mulf %env_norm, %sweep_range : f32
    %c_raw   = arith.addf %base_cutoff, %sweep : f32
    %c_lo    = arith.maximumf %c_raw, %c_min : f32
    %cutoff  = arith.minimumf %c_lo, %c_max : f32

    // -----------------------------------------------------------------------
    // Compute 2nd-order lowpass coefficients and apply two cascaded stages
    // (independent state memories for a sharper effective slope).
    // -----------------------------------------------------------------------
    %fb, %ff = crag.get_filter_coeffs %cutoff order = 2 type = "lowpass"
                   : f32, !crag.coeff_vec, !crag.coeff_vec

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
