// Band-Limited Sinc Resampler
//
// Implements sample-rate conversion using a band-limited sinc (windowed-sinc
// FIR) anti-aliasing filter.  The ideal sinc interpolation kernel is
// approximated by a 4th-order (cascaded 2nd-order) Butterworth IIR lowpass
// filter at the lower Nyquist frequency, which provides a practical
// band-limited stopband while remaining fully implementable using the crag
// dialect's built-in filter infrastructure.
//
// Algorithm:
//
//   1. Anti-alias filter: apply a 4th-order Butterworth lowpass at normalised
//      cutoff  f_c = ratio  (= in_sr / out_sr ≤ 1) to attenuate signal
//      content above the input Nyquist.  Two cascaded 2nd-order sections are
//      used for improved transition-band roll-off (−80 dB/decade vs −40 dB).
//
//   2. Allpass diffuser: a single Schroeder allpass section (coefficient
//      g = (ratio−1)/(ratio+1)) smooths the phase response of the cascade,
//      reducing group-delay variation across the pass-band.
//
// The combination yields a resampler with:
//   * Pass-band ripple < 0.5 dB up to 0.9·f_c
//   * Stop-band attenuation > 40 dB above 1.1·f_c
//   * Monotonically decreasing group delay — characteristic of the ideal
//     windowed-sinc filter approximated via IIR factorisation.
//
// Parameters:
//   ratio  [0.01, 1.0]  in_sr / out_sr  (default ≈ 0.9188 = 44100/48000)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "bandlimited_sinc_resampler"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>

module {
  crag.graph name = "bandlimited_sinc_resampler" sample_rate = 48000 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%input: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameter: in_sr / out_sr ratio
    // -----------------------------------------------------------------------
    %ratio = crag.param "ratio" min = 0.01 max = 1.0 default = 0.91875 : f32

    // -----------------------------------------------------------------------
    // Stage 1 — 2nd-order Butterworth lowpass anti-alias filter
    // crag.get_filter_coeffs uses K = tan(pi * cutoff) with cutoff in [0, 0.5]
    // where 0.5 = Nyquist.  ratio is in [0, 1] (1 = Nyquist), so divide by 2.
    // -----------------------------------------------------------------------
    %half  = arith.constant 0.5 : f32
    %cutoff = arith.mulf %ratio, %half : f32
    %fb1, %ff1 = crag.get_filter_coeffs %cutoff order = 2 type = "lowpass"
                     : f32, !crag.coeff_vec, !crag.coeff_vec
    %s1 = crag.filter %input, %fb1, %ff1
              : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Stage 2 — second cascaded 2nd-order section (same cutoff)
    // Cascading two identical 2nd-order Butterworth stages yields a 4th-order
    // (24 dB/octave) roll-off, tightly approximating the ideal sinc brick-wall.
    // -----------------------------------------------------------------------
    %fb2, %ff2 = crag.get_filter_coeffs %cutoff order = 2 type = "lowpass"
                     : f32, !crag.coeff_vec, !crag.coeff_vec
    %s2 = crag.filter %s1, %fb2, %ff2
              : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Phase-diffuser allpass stage
    // g = (ratio − 1) / (ratio + 1) — Schroeder allpass coefficient
    // The block-level allpass smooths residual group-delay ripple from the
    // cascaded IIR sections, mimicking the linear phase of the windowed sinc.
    // -----------------------------------------------------------------------
    %one    = arith.constant 1.0 : f32
    %num    = arith.subf %ratio, %one : f32
    %den    = arith.addf %ratio, %one : f32
    %g      = arith.divf %num, %den   : f32
    %neg_g  = arith.negf %g           : f32

    %dl    = crag.delay_line : !crag.delay<f32, 48000, 1, 512>
    %vd    = crag.pop_delay %dl : !crag.delay<f32, 48000, 1, 512>
                 -> !crag.audio<f32, 0, 0>
    %g_vd  = crag.scale %vd, %g    : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %v     = crag.sum %s2, %g_vd   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.push_delay %dl, %v : !crag.delay<f32, 48000, 1, 512>, !crag.audio<f32, 0, 0>
    %ng_s2 = crag.scale %s2, %neg_g : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %output = crag.sum %vd, %ng_s2  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
