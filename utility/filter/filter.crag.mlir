// Filter
//
// General-purpose IIR filter with runtime-selectable response type and
// slope, plus a resonance (Q) control.
//
// Structure:
//   - The base response comes from `crag.get_filter_coeffs` (Butterworth
//     design, Q = 1/√2) at the requested type and slope:
//       6 dB/oct  → one 1st-order stage (lowpass/highpass only — bandpass
//                   and notch have no 1st-order form, so their 6 dB setting
//                   falls back to the 12 dB 2nd-order response)
//       12 dB/oct → one 2nd-order stage
//       24 dB/oct → two cascaded 2nd-order stages (same coefficients,
//                   independent state)
//     All twelve type×slope variants are computed every block and one is
//     picked by a flat `crag.selector`; coefficient computations are shared
//     across branches of the same type.
//   - Q above the Butterworth baseline mixes in a two-pole resonator at the
//     cutoff frequency.  The resonator is normalised by its analytic peak
//     gain 1/((1-r)·√(1-2r·cos2θ+r²)) so the emphasis level tracks the Q
//     knob rather than exploding as the poles approach the unit circle.
//     At the default Q = 0.7071 the mix is zero and every type produces the
//     plain Butterworth response.  For the notch type the resonance mix is
//     disabled entirely: a peak at the notch centre would cancel the cut
//     that the notch exists to provide.
//
// Stability clamps (applied in-graph so out-of-range routed values cannot
// destabilise the filter):
//   - normalised cutoff clamped to [0.001, 0.499] × Nyquist — keeps the
//     coefficient computation away from the DC and Nyquist singularities
//   - Q clamped to [0.05, 8] — keeps the resonator poles strictly inside
//     the unit circle
//
// Parameters:
//   type       enum            – 0=lowpass, 1=highpass, 2=bandpass, 3=notch
//                                (default 0 = lowpass)
//   slope      enum            – 0=6dB, 1=12dB, 2=24dB per octave
//                                (default 1 = 12dB)
//   cutoff_hz  [20, 20000] Hz  – cutoff / centre frequency (default 1000)
//   q          [0.1, 8]        – resonance; 0.7071 = no added emphasis
//                                (default 0.7071)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "filter"(%in)
//              : (!crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>

module {
  crag.graph name = "filter" sample_rate = 0 channels = 1
      default_visualizer = "spectrometer" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %type      = crag.param_enum "type"
                     values = ["lowpass", "highpass", "bandpass", "notch"]
                     default = 0 : i32
    %slope     = crag.param_enum "slope"
                     values = ["6dB", "12dB", "24dB"]
                     default = 1 : i32
    %cutoff_hz = crag.param "cutoff_hz" min = 20.0 max = 20000.0 default = 1000.0 unit = "hz" : f32
    %q         = crag.param "q"         min = 0.1  max = 8.0     default = 0.7071 : f32

    // -----------------------------------------------------------------------
    // Normalise and clamp the design parameters
    // -----------------------------------------------------------------------
    %sr       = crag.sample_rate : f32
    %two      = arith.constant 2.0 : f32
    %nyquist  = arith.divf %sr, %two : f32
    %norm_raw = arith.divf %cutoff_hz, %nyquist : f32
    %c_min    = arith.constant 0.001 : f32
    %c_max    = arith.constant 0.499 : f32
    %norm_lo  = arith.maximumf %norm_raw, %c_min : f32
    %norm     = arith.minimumf %norm_lo, %c_max : f32

    %q_min = arith.constant 0.05 : f32
    %q_max = arith.constant 8.0  : f32
    %q_lo  = arith.maximumf %q, %q_min : f32
    %q_cl  = arith.minimumf %q_lo, %q_max : f32

    // -----------------------------------------------------------------------
    // Base-response coefficients, shared across the selector branches.
    // Bandpass/notch only exist at order 2.
    // -----------------------------------------------------------------------
    %fb1_lp, %ff1_lp = crag.get_filter_coeffs %norm order = 1 type = "lowpass"
                           : f32, !crag.coeff_vec, !crag.coeff_vec
    %fb2_lp, %ff2_lp = crag.get_filter_coeffs %norm order = 2 type = "lowpass"
                           : f32, !crag.coeff_vec, !crag.coeff_vec
    %fb1_hp, %ff1_hp = crag.get_filter_coeffs %norm order = 1 type = "highpass"
                           : f32, !crag.coeff_vec, !crag.coeff_vec
    %fb2_hp, %ff2_hp = crag.get_filter_coeffs %norm order = 2 type = "highpass"
                           : f32, !crag.coeff_vec, !crag.coeff_vec
    %fb2_bp, %ff2_bp = crag.get_filter_coeffs %norm order = 2 type = "bandpass"
                           : f32, !crag.coeff_vec, !crag.coeff_vec
    %fb2_no, %ff2_no = crag.get_filter_coeffs %norm order = 2 type = "notch"
                           : f32, !crag.coeff_vec, !crag.coeff_vec

    // -----------------------------------------------------------------------
    // Pick the type×slope variant with one flat selector:
    //   index = type · 3 + slope
    // (branch order below is type-major: lp6, lp12, lp24, hp6, ... no24)
    // -----------------------------------------------------------------------
    %c3_i32  = arith.constant 3 : i32
    %type_x3 = arith.muli %type, %c3_i32 : i32
    %variant = arith.addi %type_x3, %slope : i32

    %base = crag.selector %variant : i32 -> !crag.audio<f32, 0, 0> (
      { // lowpass 6 dB
        %y = crag.filter %in, %fb1_lp, %ff1_lp
                 : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                   -> !crag.audio<f32, 0, 0>
        crag.selector_yield %y : !crag.audio<f32, 0, 0>
      }, { // lowpass 12 dB
        %y = crag.filter %in, %fb2_lp, %ff2_lp
                 : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                   -> !crag.audio<f32, 0, 0>
        crag.selector_yield %y : !crag.audio<f32, 0, 0>
      }, { // lowpass 24 dB
        %s1 = crag.filter %in, %fb2_lp, %ff2_lp
                  : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                    -> !crag.audio<f32, 0, 0>
        %y  = crag.filter %s1, %fb2_lp, %ff2_lp
                  : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                    -> !crag.audio<f32, 0, 0>
        crag.selector_yield %y : !crag.audio<f32, 0, 0>
      }, { // highpass 6 dB
        %y = crag.filter %in, %fb1_hp, %ff1_hp
                 : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                   -> !crag.audio<f32, 0, 0>
        crag.selector_yield %y : !crag.audio<f32, 0, 0>
      }, { // highpass 12 dB
        %y = crag.filter %in, %fb2_hp, %ff2_hp
                 : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                   -> !crag.audio<f32, 0, 0>
        crag.selector_yield %y : !crag.audio<f32, 0, 0>
      }, { // highpass 24 dB
        %s1 = crag.filter %in, %fb2_hp, %ff2_hp
                  : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                    -> !crag.audio<f32, 0, 0>
        %y  = crag.filter %s1, %fb2_hp, %ff2_hp
                  : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                    -> !crag.audio<f32, 0, 0>
        crag.selector_yield %y : !crag.audio<f32, 0, 0>
      }, { // bandpass 6 dB — no 1st-order form; same as 12 dB
        %y = crag.filter %in, %fb2_bp, %ff2_bp
                 : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                   -> !crag.audio<f32, 0, 0>
        crag.selector_yield %y : !crag.audio<f32, 0, 0>
      }, { // bandpass 12 dB
        %y = crag.filter %in, %fb2_bp, %ff2_bp
                 : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                   -> !crag.audio<f32, 0, 0>
        crag.selector_yield %y : !crag.audio<f32, 0, 0>
      }, { // bandpass 24 dB
        %s1 = crag.filter %in, %fb2_bp, %ff2_bp
                  : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                    -> !crag.audio<f32, 0, 0>
        %y  = crag.filter %s1, %fb2_bp, %ff2_bp
                  : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                    -> !crag.audio<f32, 0, 0>
        crag.selector_yield %y : !crag.audio<f32, 0, 0>
      }, { // notch 6 dB — no 1st-order form; same as 12 dB
        %y = crag.filter %in, %fb2_no, %ff2_no
                 : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                   -> !crag.audio<f32, 0, 0>
        crag.selector_yield %y : !crag.audio<f32, 0, 0>
      }, { // notch 12 dB
        %y = crag.filter %in, %fb2_no, %ff2_no
                 : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                   -> !crag.audio<f32, 0, 0>
        crag.selector_yield %y : !crag.audio<f32, 0, 0>
      }, { // notch 24 dB
        %s1 = crag.filter %in, %fb2_no, %ff2_no
                  : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                    -> !crag.audio<f32, 0, 0>
        %y  = crag.filter %s1, %fb2_no, %ff2_no
                  : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                    -> !crag.audio<f32, 0, 0>
        crag.selector_yield %y : !crag.audio<f32, 0, 0>
      })

    // -----------------------------------------------------------------------
    // Resonance: a peak-normalised two-pole resonator at the cutoff, mixed
    // in proportionally to how far Q sits above the Butterworth baseline.
    //
    // Resonator poles: radius r = e^(-π·cutoff/(2Q)), angle θ = π·cutoff.
    // Peak gain at ω = θ is 1/((1-r)·√(1-2r·cos2θ+r²)); multiplying by its
    // reciprocal gives a unity-peak resonant band regardless of Q.
    // -----------------------------------------------------------------------
    %fb_res, %ff_res = crag.get_filter_coeffs %norm
                           order = 2 q_runtime = %q_cl : f32
                           type = "two_pole_resonator"
                           : f32, !crag.coeff_vec, !crag.coeff_vec
    %res = crag.filter %in, %fb_res, %ff_res
               : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                 -> !crag.audio<f32, 0, 0>

    // r = e^(-π·norm/(2·Q)),  θ = π·norm
    %pi       = arith.constant 3.14159265359 : f32
    %theta    = arith.mulf %pi, %norm : f32
    %two_q    = arith.mulf %two, %q_cl : f32
    %exp_raw  = arith.divf %theta, %two_q : f32
    %exp_neg  = arith.negf %exp_raw : f32
    %r        = math.exp %exp_neg : f32

    // peak_inv = (1-r)·√(1 - 2r·cos(2θ) + r²)  — reciprocal of the peak gain
    %one      = arith.constant 1.0 : f32
    %one_m_r  = arith.subf %one, %r : f32
    %two_th   = arith.mulf %two, %theta : f32
    %cos2t    = math.cos %two_th : f32
    %r_cos    = arith.mulf %r, %cos2t : f32
    %two_rcos = arith.mulf %two, %r_cos : f32
    %mag2_a   = arith.subf %one, %two_rcos : f32
    %r_sq     = arith.mulf %r, %r : f32
    %mag2     = arith.addf %mag2_a, %r_sq : f32
    %mag      = math.sqrt %mag2 : f32
    %peak_inv = arith.mulf %one_m_r, %mag : f32

    // Mix amount: 0 at the Butterworth baseline Q, 1 at the Q ceiling.
    %q_base   = arith.constant 0.70710678 : f32
    %q_span   = arith.constant 7.29289322 : f32  // q_max - q_base
    %amt_num  = arith.subf %q_cl, %q_base : f32
    %amt_raw  = arith.divf %amt_num, %q_span : f32
    %zero     = arith.constant 0.0 : f32
    %amt_lo   = arith.maximumf %amt_raw, %zero : f32
    %amt01    = arith.minimumf %amt_lo, %one : f32

    // Resonance makes no sense on a notch (it would refill the cut), so the
    // mix is forced to zero for type = 3.
    %c_notch  = arith.constant 3 : i32
    %is_notch = arith.cmpi eq, %type, %c_notch : i32
    %amt      = arith.select %is_notch, %zero, %amt01 : f32

    // Up to +6 dB of emphasis at the Q ceiling.
    %boost    = arith.constant 2.0 : f32
    %amt_sc   = arith.mulf %amt, %boost : f32
    %res_gain = arith.mulf %amt_sc, %peak_inv : f32

    %res_sc = crag.scale %res, %res_gain
                  : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %out    = crag.sum %base, %res_sc
                  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                    -> !crag.audio<f32, 0, 0>

    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
