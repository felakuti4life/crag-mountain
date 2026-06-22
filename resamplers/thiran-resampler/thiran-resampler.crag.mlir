// Thiran Resampler (Allpass-Chain Fractional Delay)
//
// Implements sample-rate conversion using a chain of four first-order Thiran
// allpass sections.  Thiran allpass filters provide maximally-flat group delay
// (to first order) at zero frequency and low phase distortion, making them
// well-suited for fractional-delay resampling.
//
// Algorithm (single first-order Thiran allpass section as Schroeder allpass):
//
//   Given fractional delay D = ratio = in_sr / out_sr and the Thiran
//   first-order allpass coefficient:
//
//     g = (D − 1) / (D + 1)
//
//   Each section implements the Schroeder allpass recurrence:
//
//     v[n] =  x[n] + g · v[n − B]       (B = block_size, in samples)
//     y[n] =  v[n − B] − g · x[n]
//
//   Four sections are chained: the output of section k feeds the input of
//   section k+1.  Chaining increases the effective group-delay flatness and
//   roll-off steepness of the combined transfer function.
//
//   An anti-aliasing 2nd-order Butterworth lowpass (cutoff = ratio) is
//   applied to the input before the allpass chain.
//
// Parameters:
//   ratio  [0.01, 1.0]  in_sr / out_sr  (default ≈ 0.9188 = 44100/48000)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "thiran_resampler"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>

module {
  crag.graph name = "thiran_resampler" sample_rate = 48000 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%input: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameter: in_sr / out_sr ratio
    // -----------------------------------------------------------------------
    %ratio = crag.param "ratio" min = 0.01 max = 1.0 default = 0.91875 : f32

    // -----------------------------------------------------------------------
    // Anti-aliasing lowpass at normalised cutoff = ratio / 2
    // crag.get_filter_coeffs uses K = tan(pi * cutoff) with cutoff in [0, 0.5]
    // where 0.5 = Nyquist.  ratio is in [0, 1] (1 = Nyquist), so divide by 2.
    // -----------------------------------------------------------------------
    %half   = arith.constant 0.5 : f32
    %cutoff_aa = arith.mulf %ratio, %half : f32
    %fb_aa, %ff_aa = crag.get_filter_coeffs %cutoff_aa order = 2 type = "lowpass"
                         : f32, !crag.coeff_vec, !crag.coeff_vec
    %aa = crag.filter %input, %fb_aa, %ff_aa
              : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
                -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Thiran coefficient: g = (ratio − 1) / (ratio + 1)
    // -----------------------------------------------------------------------
    %one   = arith.constant 1.0 : f32
    %num   = arith.subf %ratio, %one : f32   // ratio − 1
    %den   = arith.addf %ratio, %one : f32   // ratio + 1
    %g     = arith.divf %num, %den : f32     // g = (ratio−1)/(ratio+1)
    %neg_g = arith.negf %g : f32             // −g

    // -----------------------------------------------------------------------
    // Thiran allpass section 1
    //   v[n] =  x[n] + g · v[n−B]
    //   y[n] =  v[n−B] − g · x[n]
    // -----------------------------------------------------------------------
    %dl1  = crag.delay_line : !crag.delay<f32, 48000, 1, 512>
    %v1d  = crag.pop_delay %dl1 : !crag.delay<f32, 48000, 1, 512>
                -> !crag.audio<f32, 0, 0>
    %g_v1d  = crag.scale %v1d, %g    : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %v1     = crag.sum %aa, %g_v1d   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.push_delay %dl1, %v1 : !crag.delay<f32, 48000, 1, 512>, !crag.audio<f32, 0, 0>
    %ng_aa  = crag.scale %aa, %neg_g : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %s1     = crag.sum %v1d, %ng_aa  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Thiran allpass section 2
    // -----------------------------------------------------------------------
    %dl2  = crag.delay_line : !crag.delay<f32, 48000, 1, 512>
    %v2d  = crag.pop_delay %dl2 : !crag.delay<f32, 48000, 1, 512>
                -> !crag.audio<f32, 0, 0>
    %g_v2d  = crag.scale %v2d, %g    : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %v2     = crag.sum %s1, %g_v2d   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.push_delay %dl2, %v2 : !crag.delay<f32, 48000, 1, 512>, !crag.audio<f32, 0, 0>
    %ng_s1  = crag.scale %s1, %neg_g : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %s2     = crag.sum %v2d, %ng_s1  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Thiran allpass section 3
    // -----------------------------------------------------------------------
    %dl3  = crag.delay_line : !crag.delay<f32, 48000, 1, 512>
    %v3d  = crag.pop_delay %dl3 : !crag.delay<f32, 48000, 1, 512>
                -> !crag.audio<f32, 0, 0>
    %g_v3d  = crag.scale %v3d, %g    : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %v3     = crag.sum %s2, %g_v3d   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.push_delay %dl3, %v3 : !crag.delay<f32, 48000, 1, 512>, !crag.audio<f32, 0, 0>
    %ng_s2  = crag.scale %s2, %neg_g : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %s3     = crag.sum %v3d, %ng_s2  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Thiran allpass section 4
    // -----------------------------------------------------------------------
    %dl4  = crag.delay_line : !crag.delay<f32, 48000, 1, 512>
    %v4d  = crag.pop_delay %dl4 : !crag.delay<f32, 48000, 1, 512>
                -> !crag.audio<f32, 0, 0>
    %g_v4d  = crag.scale %v4d, %g    : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %v4     = crag.sum %s3, %g_v4d   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.push_delay %dl4, %v4 : !crag.delay<f32, 48000, 1, 512>, !crag.audio<f32, 0, 0>
    %ng_s3  = crag.scale %s3, %neg_g : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %output = crag.sum %v4d, %ng_s3  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
