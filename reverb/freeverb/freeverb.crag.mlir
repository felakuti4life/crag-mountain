// Freeverb-Inspired Reverb
//
// Based on the "Freeverb" algorithm by Jezar at Dreampoint, adapted for mono
// and simplified to 4 parallel comb filters + 4 series allpass diffusers.
//
// The key feature that distinguishes Freeverb from the original Schroeder
// design is per-comb lowpass filtering in the feedback path, which models
// frequency-dependent air absorption and produces smoother, less metallic
// sounding tails.
//
// Feedback Comb Filter (FBC) with lowpass damping:
//   The delay stores the comb output.  Each block:
//     1. Pop y[n-D] from delay.
//     2. Apply 1st-order Butterworth lowpass (cutoff from damping param)
//        to model high-frequency absorption in the feedback path.
//     3. Mix with dry input and push back: y[n] = x[n] + g * lpf(y[n-D])
//
// Allpass diffuser (Schroeder efficient form):
//   v[n] = x[n] + g_ap * v[n-D];  y[n] = v[n-D] - g_ap * x[n]
//
// Delay sizes at 48 kHz (adjusted so that all delays >= 512, the default
// block size; delays must be >= block_size to avoid a mid-block ring buffer
// underrun in the block-based delay implementation):
//   Comb:    1216, 1294, 1390, 1476 samples
//   Allpass:  605,  521,  541,  557 samples  (all prime, all ≥ 512)
//
// Parameters:
//   room_size  [0, 1]  – feedback gain (0.7 + room_size * 0.28)
//   damping    [0, 1]  – lowpass cutoff in feedback path
//                        (cutoff maps 0 → ~0.45 Nyquist, 1 → ~0.01 Nyquist)
//   wet_level  [0, 1]  – reverb wet mix amplitude
//   dry_level  [0, 1]  – dry (direct) signal amplitude
//
// Usage (after crag.include):
//   %wet = crag.subgraph_ref "freeverb"(%dry)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/reverb/freeverb.crag.mlir" as "freeverb"

module {
  crag.graph name = "freeverb" sample_rate = 48000 channels = 1 default_visualizer = "spectrometer" {
  ^bb0(%dry: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %room  = crag.param "room_size" min = 0.0 max = 1.0 default = 0.5 : f32
    %damp  = crag.param "damping"   min = 0.0 max = 1.0 default = 0.5 : f32
    %wet_p = crag.param "wet_level" min = 0.0 max = 1.0 default = 0.3 : f32
    %dry_p = crag.param "dry_level" min = 0.0 max = 1.0 default = 0.7 : f32

    // Feedback gain: g = 0.7 + room_size * 0.28
    %base_g  = arith.constant 0.7  : f32
    %g_range = arith.constant 0.28 : f32
    %g_inc   = arith.mulf %room, %g_range : f32
    %g       = arith.addf %base_g, %g_inc : f32

    // Lowpass cutoff for feedback damping:
    // crag.get_filter_coeffs expects a normalised frequency in (0, 0.5) where
    // 0.5 = Nyquist (half the sample rate).  Map damping=[0,1] to cutoff:
    //   damping=0 → cutoff≈0.45  (nearly full bandwidth, ~21.6 kHz @ 48 kHz)
    //   damping=1 → cutoff≈0.01  (heavy absorption,     ~480 Hz  @ 48 kHz)
    %c_hi  = arith.constant 0.45 : f32
    %c_lo  = arith.constant 0.01 : f32
    %c_rng = arith.constant 0.44 : f32
    %c_sc  = arith.mulf %damp, %c_rng : f32
    %cutoff = arith.subf %c_hi, %c_sc : f32

    // 1st-order Butterworth lowpass coefficients for the feedback damping path.
    // All 4 comb filters share the same coefficients (they share the same
    // damping parameter) but have independent per-instance filter states.
    %fb_lp, %ff_lp = crag.get_filter_coeffs %cutoff order = 1 type = "lowpass"
                         : f32, !crag.coeff_vec, !crag.coeff_vec

    // Allpass gain (fixed at 0.5)
    %g_ap = arith.constant 0.5 : f32

    // -----------------------------------------------------------------------
    // Comb filter 1  (D = 1216)
    // -----------------------------------------------------------------------
    %d1       = crag.delay_line : !crag.delay<f32, 48000, 1, 1216>
    %pop1     = crag.pop_delay %d1 : !crag.delay<f32, 48000, 1, 1216>
                    -> !crag.audio<f32, 0, 0>
    %lp1      = crag.filter %pop1, %fb_lp, %ff_lp
                    : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                      -> !crag.audio<f32, 0, 0>
    %fb_sc1   = crag.scale %lp1, %g : !crag.audio<f32, 0, 0>, f32
                    -> !crag.audio<f32, 0, 0>
    %comb1    = crag.sum %dry, %fb_sc1
                    : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                      -> !crag.audio<f32, 0, 0>
    crag.push_delay %d1, %comb1 : !crag.delay<f32, 48000, 1, 1216>,
                                   !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Comb filter 2  (D = 1294)
    // -----------------------------------------------------------------------
    %d2       = crag.delay_line : !crag.delay<f32, 48000, 1, 1294>
    %pop2     = crag.pop_delay %d2 : !crag.delay<f32, 48000, 1, 1294>
                    -> !crag.audio<f32, 0, 0>
    %lp2      = crag.filter %pop2, %fb_lp, %ff_lp
                    : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                      -> !crag.audio<f32, 0, 0>
    %fb_sc2   = crag.scale %lp2, %g : !crag.audio<f32, 0, 0>, f32
                    -> !crag.audio<f32, 0, 0>
    %comb2    = crag.sum %dry, %fb_sc2
                    : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                      -> !crag.audio<f32, 0, 0>
    crag.push_delay %d2, %comb2 : !crag.delay<f32, 48000, 1, 1294>,
                                   !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Comb filter 3  (D = 1390)
    // -----------------------------------------------------------------------
    %d3       = crag.delay_line : !crag.delay<f32, 48000, 1, 1390>
    %pop3     = crag.pop_delay %d3 : !crag.delay<f32, 48000, 1, 1390>
                    -> !crag.audio<f32, 0, 0>
    %lp3      = crag.filter %pop3, %fb_lp, %ff_lp
                    : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                      -> !crag.audio<f32, 0, 0>
    %fb_sc3   = crag.scale %lp3, %g : !crag.audio<f32, 0, 0>, f32
                    -> !crag.audio<f32, 0, 0>
    %comb3    = crag.sum %dry, %fb_sc3
                    : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                      -> !crag.audio<f32, 0, 0>
    crag.push_delay %d3, %comb3 : !crag.delay<f32, 48000, 1, 1390>,
                                   !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Comb filter 4  (D = 1476)
    // -----------------------------------------------------------------------
    %d4       = crag.delay_line : !crag.delay<f32, 48000, 1, 1476>
    %pop4     = crag.pop_delay %d4 : !crag.delay<f32, 48000, 1, 1476>
                    -> !crag.audio<f32, 0, 0>
    %lp4      = crag.filter %pop4, %fb_lp, %ff_lp
                    : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                      -> !crag.audio<f32, 0, 0>
    %fb_sc4   = crag.scale %lp4, %g : !crag.audio<f32, 0, 0>, f32
                    -> !crag.audio<f32, 0, 0>
    %comb4    = crag.sum %dry, %fb_sc4
                    : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                      -> !crag.audio<f32, 0, 0>
    crag.push_delay %d4, %comb4 : !crag.delay<f32, 48000, 1, 1476>,
                                   !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Sum comb outputs; attenuate by 0.25 before entering the allpass chain
    // -----------------------------------------------------------------------
    %comb_sum = crag.sum %comb1, %comb2, %comb3, %comb4
                    : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>,
                       !crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                      -> !crag.audio<f32, 0, 0>
    %quarter  = arith.constant 0.25 : f32
    %ap_in    = crag.scale %comb_sum, %quarter : !crag.audio<f32, 0, 0>, f32
                    -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Allpass 1  (D = 605)
    // -----------------------------------------------------------------------
    %ap1d       = crag.delay_line : !crag.delay<f32, 48000, 1, 605>
    %ap1_v_old  = crag.pop_delay %ap1d : !crag.delay<f32, 48000, 1, 605>
                      -> !crag.audio<f32, 0, 0>
    %ap1_gv     = crag.scale %ap1_v_old, %g_ap : !crag.audio<f32, 0, 0>, f32
                      -> !crag.audio<f32, 0, 0>
    %ap1_v_new  = crag.sum %ap_in, %ap1_gv
                      : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                        -> !crag.audio<f32, 0, 0>
    crag.push_delay %ap1d, %ap1_v_new : !crag.delay<f32, 48000, 1, 605>,
                                         !crag.audio<f32, 0, 0>
    %neg_gap1   = arith.negf %g_ap : f32
    %ap1_neg_gx = crag.scale %ap_in, %neg_gap1 : !crag.audio<f32, 0, 0>, f32
                      -> !crag.audio<f32, 0, 0>
    %ap1_out    = crag.sum %ap1_v_old, %ap1_neg_gx
                      : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                        -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Allpass 2  (D = 521)
    // Original Freeverb value was 480 samples (~10 ms at 48 kHz), but
    // 480 < 512 (the default block size) causes a buffer underrun.
    // 521 is the next prime above 512, preserving incommensurability (~10.9 ms).
    // -----------------------------------------------------------------------
    %ap2d       = crag.delay_line : !crag.delay<f32, 48000, 1, 521>
    %ap2_v_old  = crag.pop_delay %ap2d : !crag.delay<f32, 48000, 1, 521>
                      -> !crag.audio<f32, 0, 0>
    %ap2_gv     = crag.scale %ap2_v_old, %g_ap : !crag.audio<f32, 0, 0>, f32
                      -> !crag.audio<f32, 0, 0>
    %ap2_v_new  = crag.sum %ap1_out, %ap2_gv
                      : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                        -> !crag.audio<f32, 0, 0>
    crag.push_delay %ap2d, %ap2_v_new : !crag.delay<f32, 48000, 1, 521>,
                                         !crag.audio<f32, 0, 0>
    %neg_gap2   = arith.negf %g_ap : f32
    %ap2_neg_gx = crag.scale %ap1_out, %neg_gap2 : !crag.audio<f32, 0, 0>, f32
                      -> !crag.audio<f32, 0, 0>
    %ap2_out    = crag.sum %ap2_v_old, %ap2_neg_gx
                      : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                        -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Allpass 3  (D = 541)
    // Original Freeverb value was 371 samples (~7.7 ms at 48 kHz), but
    // 371 < 512 (the default block size) causes a buffer underrun.
    // 541 is a prime > 512 that is incommensurate with 521 and 605 (~11.3 ms).
    // -----------------------------------------------------------------------
    %ap3d       = crag.delay_line : !crag.delay<f32, 48000, 1, 541>
    %ap3_v_old  = crag.pop_delay %ap3d : !crag.delay<f32, 48000, 1, 541>
                      -> !crag.audio<f32, 0, 0>
    %ap3_gv     = crag.scale %ap3_v_old, %g_ap : !crag.audio<f32, 0, 0>, f32
                      -> !crag.audio<f32, 0, 0>
    %ap3_v_new  = crag.sum %ap2_out, %ap3_gv
                      : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                        -> !crag.audio<f32, 0, 0>
    crag.push_delay %ap3d, %ap3_v_new : !crag.delay<f32, 48000, 1, 541>,
                                         !crag.audio<f32, 0, 0>
    %neg_gap3   = arith.negf %g_ap : f32
    %ap3_neg_gx = crag.scale %ap2_out, %neg_gap3 : !crag.audio<f32, 0, 0>, f32
                      -> !crag.audio<f32, 0, 0>
    %ap3_out    = crag.sum %ap3_v_old, %ap3_neg_gx
                      : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                        -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Allpass 4  (D = 557)
    // Original Freeverb value was 245 samples (~5.1 ms at 48 kHz), but
    // 245 < 512 (the default block size) causes a buffer underrun.
    // 557 is a prime > 512 that is incommensurate with 521, 541, and 605 (~11.6 ms).
    // -----------------------------------------------------------------------
    %ap4d       = crag.delay_line : !crag.delay<f32, 48000, 1, 557>
    %ap4_v_old  = crag.pop_delay %ap4d : !crag.delay<f32, 48000, 1, 557>
                      -> !crag.audio<f32, 0, 0>
    %ap4_gv     = crag.scale %ap4_v_old, %g_ap : !crag.audio<f32, 0, 0>, f32
                      -> !crag.audio<f32, 0, 0>
    %ap4_v_new  = crag.sum %ap3_out, %ap4_gv
                      : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                        -> !crag.audio<f32, 0, 0>
    crag.push_delay %ap4d, %ap4_v_new : !crag.delay<f32, 48000, 1, 557>,
                                         !crag.audio<f32, 0, 0>
    %neg_gap4   = arith.negf %g_ap : f32
    %ap4_neg_gx = crag.scale %ap3_out, %neg_gap4 : !crag.audio<f32, 0, 0>, f32
                      -> !crag.audio<f32, 0, 0>
    %reverb_wet = crag.sum %ap4_v_old, %ap4_neg_gx
                      : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                        -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Wet/dry mix
    // -----------------------------------------------------------------------
    %dry_out = crag.scale %dry, %dry_p : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %wet_out = crag.scale %reverb_wet, %wet_p : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %output  = crag.sum %dry_out, %wet_out
                   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                     -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
