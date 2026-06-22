// Feed-Forward RMS Compressor
//
// Classic feed-forward dynamic range compressor with RMS level detection,
// asymmetric attack/release envelope following (via crag.smooth), dB-domain
// gain computation, and an optional wet/dry mix.
//
// ┌─────────┐     crag.rms     ┌──────────┐   dB math   ┌──────┐   crag.scale
// │  input  │ ───────────────► │ envelope │ ──────────► │ gain │ ──────────────►
// │         │                  │ follower │             │ comp │
// │         │──────────────────────────────────────────────────────────────────►
// └─────────┘                                                           (dry mix)
//
// Signal path:
//   1. Level detection:   crag.rms computes RMS amplitude for the current block.
//   2. Envelope follower: crag.smooth applies asymmetric 1-pole IIR at block rate.
//        if rms > env : env = atk_coef*env + (1-atk_coef)*rms  (attack phase)
//        if rms ≤ env : env = rel_coef*env + (1-rel_coef)*rms  (release phase)
//   3. Gain computation (dB domain):
//        env_dB  = ln(env) * 20/ln(10)  [using math.log for natural log]
//        gain_reduction_dB = (env_dB - threshold_dB) * (1/ratio - 1)
//          → negative when signal is above threshold (gain reduction)
//          → clamped to ≤ 0 so below-threshold signal is unaffected
//        total_gain_dB = gain_reduction_dB + makeup_gain_dB
//        gain_linear   = exp(total_gain_dB * ln(10)/20)
//   4. Apply gain:   crag.scale multiplies every sample by gain_linear.
//   5. Wet/dry mix:  blend compressed and dry signals.
//
// Parameters:
//   threshold_db   [-60, 0]      dBFS compression threshold   (default -18 dB)
//   ratio          [1,  20]      compression ratio             (default  4 : 1)
//   attack_ms      [0.1, 200]    attack  time constant in ms   (default  10 ms)
//   release_ms     [10, 2000]    release time constant in ms   (default 100 ms)
//   makeup_gain_db [-12, 24]     makeup gain in dB             (default   0 dB)
//   wet_level      [0, 1]        compressed signal level       (default   1.0)
//   dry_level      [0, 1]        bypass signal level           (default   0.0)
//
// Usage:
//   crag.include "standard-graphs/compressors/feed-forward-compressor.crag.mlir"
//       as "feed_forward_compressor"
//
//   %out = crag.subgraph_ref "feed_forward_compressor"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 0, 0>
//
// Note: The attack/release time constants are expressed in milliseconds and
// converted to 1-pole coefficients at compile time using the block size and
// sample rate.  With a 512-sample block at 48 kHz the minimum time constant
// is approximately 10.7 ms; shorter values are clipped to this minimum.

module {
  crag.graph name = "feed_forward_compressor"
             sample_rate = 48000 channels = 1 default_visualizer = "compressor-viz" {
  ^bb0(%input: !crag.audio<f32, 0, 0>):

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    %threshold_db    = crag.param "threshold_db"   min = -60.0 max = 0.0
                           default = -18.0 unit = "dB" : f32
    %ratio           = crag.param "ratio"           min = 1.0   max = 20.0
                           default = 4.0 : f32
    %attack_ms_p     = crag.param "attack_ms"       min = 0.1   max = 200.0
                           default = 10.0  unit = "ms" : f32
    %release_ms_p    = crag.param "release_ms"      min = 10.0  max = 2000.0
                           default = 100.0 unit = "ms" : f32
    %makeup_gain_db  = crag.param "makeup_gain_db"  min = -12.0 max = 24.0
                           default = 0.0   unit = "dB" : f32
    %wet_p           = crag.param "wet_level"       min = 0.0   max = 1.0
                           default = 1.0 : f32
    %dry_p           = crag.param "dry_level"       min = 0.0   max = 1.0
                           default = 0.0 : f32

    // -------------------------------------------------------------------------
    // RMS level detection
    // -------------------------------------------------------------------------
    %rms = crag.rms %input : !crag.audio<f32, 0, 0> -> f32

    // -------------------------------------------------------------------------
    // Envelope follower (asymmetric attack/release at block rate)
    // -------------------------------------------------------------------------
    %envelope = crag.smooth %rms, %attack_ms_p, %release_ms_p
                    : f32, f32, f32 -> f32

    // -------------------------------------------------------------------------
    // Gain computation in dB domain
    // -------------------------------------------------------------------------

    // Floor the envelope at -140 dBFS to avoid log(0).
    %tiny     = arith.constant 1.0e-7 : f32
    %env_safe = arith.maximumf %envelope, %tiny : f32

    // envelope_dB = 20 * log10(env) = ln(env) * 20/ln(10)
    %log_env   = math.log %env_safe : f32
    %k20_ln10  = arith.constant 8.6858896380650366 : f32   // 20 / ln(10)
    %env_db    = arith.mulf %log_env, %k20_ln10 : f32

    // gain_reduction_dB = (env_dB - threshold_dB) * (1/ratio - 1)
    //   (1/ratio - 1) is ≤ 0 for ratio ≥ 1, so the product is negative (gain cut)
    //   when env_dB > threshold_dB.
    %one        = arith.constant 1.0 : f32
    %inv_ratio  = arith.divf %one, %ratio : f32
    %ir_m1      = arith.subf %inv_ratio, %one : f32   // ≤ 0 for ratio ≥ 1
    %above_thr  = arith.subf %env_db, %threshold_db : f32

    // unclamped product: positive when below threshold (wrong direction) or
    // negative when above threshold (correct gain reduction).
    %gr_uncl    = arith.mulf %above_thr, %ir_m1 : f32

    // Clamp to ≤ 0: ensures below-threshold signal gets no gain change.
    %zero       = arith.constant 0.0 : f32
    %gr_db      = arith.minimumf %gr_uncl, %zero : f32

    // Total gain = gain_reduction + makeup gain.
    %total_db   = arith.addf %gr_db, %makeup_gain_db : f32

    // Convert dB to linear: gain = exp(total_dB * ln(10) / 20)
    %kln10_20   = arith.constant 0.11512925464970229 : f32  // ln(10) / 20
    %gain_log   = arith.mulf %total_db, %kln10_20 : f32
    %gain       = math.exp %gain_log : f32

    // -------------------------------------------------------------------------
    // Apply gain and wet/dry mix
    // -------------------------------------------------------------------------
    %compressed = crag.scale %input, %gain
                      : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %wet_sig    = crag.scale %compressed, %wet_p
                      : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %dry_sig    = crag.scale %input, %dry_p
                      : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %output     = crag.sum %wet_sig, %dry_sig
                      : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                        -> !crag.audio<f32, 0, 0>
    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
