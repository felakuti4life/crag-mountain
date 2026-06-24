// Schroeder Reverberator
//
// Classic Schroeder reverb topology after M. R. Schroeder, "Natural Sounding
// Artificial Reverberation", JAES 1962.  The algorithm consists of:
//
//   - 4 parallel Feedback Comb (FBC) filters whose outputs are summed
//   - 2 series Schroeder Allpass diffusers
//   - Wet/dry level control
//
// Feedback Comb Filter (FBC):
//   y[n] = x[n] + g * y[n - D]
//
// Schroeder Allpass (efficient single-delay form):
//   Store v[n] = x[n] + g_ap * v[n-D];  output y[n] = v[n-D] - g_ap * x[n]
//
// Delay sizes at 48 kHz (approximately incommensurate for dense diffusion):
//   Comb:    1277, 1356, 1422, 1491 samples  (~26–31 ms)
//   Allpass:  605,  521 samples              (~10–13 ms)
//
// Parameters:
//   room_size  [0, 1]  – feedback gain scale (0.7 + room_size*0.28)
//   wet_level  [0, 1]  – reverb wet mix amplitude
//   dry_level  [0, 1]  – dry (direct) signal amplitude
//
// Usage (after crag.include):
//   %wet = crag.subgraph_ref "schroeder_reverb"(%dry)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/reverb/schroeder-reverb.crag.mlir" as "schroeder_reverb"

module {
  crag.graph name = "schroeder_reverb" sample_rate = 48000 channels = 1 preferred_channel_mixer = "parallel" default_visualizer = "spectrometer" {
  ^bb0(%dry: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %room  = crag.param "room_size" min = 0.0 max = 1.0 default = 0.5 : f32
    %wet_p = crag.param "wet_level" min = 0.0 max = 1.0 default = 0.3 : f32
    %dry_p = crag.param "dry_level" min = 0.0 max = 1.0 default = 0.7 : f32

    // Feedback gain: g = 0.7 + room_size * 0.28  (stays well below 1.0)
    %base_g  = arith.constant 0.7  : f32
    %g_range = arith.constant 0.28 : f32
    %g_inc   = arith.mulf %room, %g_range : f32
    %g       = arith.addf %base_g, %g_inc : f32

    // Allpass gain (fixed at 0.5 for good diffusion)
    %g_ap = arith.constant 0.5 : f32

    // -----------------------------------------------------------------------
    // Comb filter 1  (D = 1277)
    // -----------------------------------------------------------------------
    %d1      = crag.delay_line : !crag.delay<f32, 48000, 1, 1277>
    %pop1    = crag.pop_delay %d1 : !crag.delay<f32, 48000, 1, 1277>
                   -> !crag.audio<f32, 0, 0>
    %fb1     = crag.scale %pop1, %g : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %comb1   = crag.sum %dry, %fb1
                   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                     -> !crag.audio<f32, 0, 0>
    crag.push_delay %d1, %comb1 : !crag.delay<f32, 48000, 1, 1277>,
                                   !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Comb filter 2  (D = 1356)
    // -----------------------------------------------------------------------
    %d2      = crag.delay_line : !crag.delay<f32, 48000, 1, 1356>
    %pop2    = crag.pop_delay %d2 : !crag.delay<f32, 48000, 1, 1356>
                   -> !crag.audio<f32, 0, 0>
    %fb2     = crag.scale %pop2, %g : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %comb2   = crag.sum %dry, %fb2
                   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                     -> !crag.audio<f32, 0, 0>
    crag.push_delay %d2, %comb2 : !crag.delay<f32, 48000, 1, 1356>,
                                   !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Comb filter 3  (D = 1422)
    // -----------------------------------------------------------------------
    %d3      = crag.delay_line : !crag.delay<f32, 48000, 1, 1422>
    %pop3    = crag.pop_delay %d3 : !crag.delay<f32, 48000, 1, 1422>
                   -> !crag.audio<f32, 0, 0>
    %fb3     = crag.scale %pop3, %g : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %comb3   = crag.sum %dry, %fb3
                   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                     -> !crag.audio<f32, 0, 0>
    crag.push_delay %d3, %comb3 : !crag.delay<f32, 48000, 1, 1422>,
                                   !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Comb filter 4  (D = 1491)
    // -----------------------------------------------------------------------
    %d4      = crag.delay_line : !crag.delay<f32, 48000, 1, 1491>
    %pop4    = crag.pop_delay %d4 : !crag.delay<f32, 48000, 1, 1491>
                   -> !crag.audio<f32, 0, 0>
    %fb4     = crag.scale %pop4, %g : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %comb4   = crag.sum %dry, %fb4
                   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                     -> !crag.audio<f32, 0, 0>
    crag.push_delay %d4, %comb4 : !crag.delay<f32, 48000, 1, 1491>,
                                   !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Sum the 4 comb outputs and attenuate by 0.25 before diffusion
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
    //   v[n]  = ap_in[n] + g_ap * v[n-D]
    //   y1[n] = v[n-D]   - g_ap * ap_in[n]
    // -----------------------------------------------------------------------
    %ap1d        = crag.delay_line : !crag.delay<f32, 48000, 1, 605>
    %ap1_v_old   = crag.pop_delay %ap1d : !crag.delay<f32, 48000, 1, 605>
                       -> !crag.audio<f32, 0, 0>
    %ap1_gv_old  = crag.scale %ap1_v_old, %g_ap : !crag.audio<f32, 0, 0>, f32
                       -> !crag.audio<f32, 0, 0>
    %ap1_v_new   = crag.sum %ap_in, %ap1_gv_old
                       : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                         -> !crag.audio<f32, 0, 0>
    crag.push_delay %ap1d, %ap1_v_new : !crag.delay<f32, 48000, 1, 605>,
                                         !crag.audio<f32, 0, 0>
    %neg_gap1    = arith.negf %g_ap : f32
    %ap1_neg_gx  = crag.scale %ap_in, %neg_gap1 : !crag.audio<f32, 0, 0>, f32
                       -> !crag.audio<f32, 0, 0>
    %ap1_out     = crag.sum %ap1_v_old, %ap1_neg_gx
                       : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                         -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Allpass 2  (D = 521)
    // Note: the original Schroeder value was 480 samples (~10 ms at 48 kHz),
    // but 480 < 512 (the default block size), causing a buffer underrun in
    // the block-based delay implementation.  521 is the next prime above 512,
    // preserves the approximately incommensurate relationship with allpass 1
    // (D = 605), and remains perceptually equivalent (~10.9 ms at 48 kHz).
    // -----------------------------------------------------------------------
    %ap2d        = crag.delay_line : !crag.delay<f32, 48000, 1, 521>
    %ap2_v_old   = crag.pop_delay %ap2d : !crag.delay<f32, 48000, 1, 521>
                       -> !crag.audio<f32, 0, 0>
    %ap2_gv_old  = crag.scale %ap2_v_old, %g_ap : !crag.audio<f32, 0, 0>, f32
                       -> !crag.audio<f32, 0, 0>
    %ap2_v_new   = crag.sum %ap1_out, %ap2_gv_old
                       : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                         -> !crag.audio<f32, 0, 0>
    crag.push_delay %ap2d, %ap2_v_new : !crag.delay<f32, 48000, 1, 521>,
                                         !crag.audio<f32, 0, 0>
    %neg_gap2    = arith.negf %g_ap : f32
    %ap2_neg_gx  = crag.scale %ap1_out, %neg_gap2 : !crag.audio<f32, 0, 0>, f32
                       -> !crag.audio<f32, 0, 0>
    %reverb_wet  = crag.sum %ap2_v_old, %ap2_neg_gx
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
