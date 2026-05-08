// Peak Limiter
//
// Brick-wall feed-forward peak limiter.  Detects the peak amplitude of each
// audio block and computes a gain factor to ensure the output never exceeds
// the configured threshold.
//
// ┌─────────┐    crag.peak    ┌──────────┐   gain   ┌───────────┐   crag.scale
// │  input  │ ─────────────► │ envelope │ ────────► │ min(1, T/E│ ─────────────►
// └─────────┘                │ follower │           └───────────┘
//
// Signal path:
//   1. Level detection:   crag.peak finds max|sample| in the current block.
//   2. Envelope follower: crag.smooth applies asymmetric 1-pole IIR at block rate.
//   3. Gain computation (linear domain — no log/exp on the envelope):
//        threshold_linear = exp(threshold_dB * ln(10)/20)
//        gain = min(1.0, threshold_linear / max(envelope, 1e-7))
//   4. Apply gain:   crag.scale multiplies every sample by the gain.
//
// Because gain is derived from the CURRENT block's peak (zero look-ahead),
// a short attack time (≈ 1 ms) is recommended for hard transient protection.
// Very short attacks can introduce low-frequency intermodulation; increase
// attack time if audible distortion occurs on bass-heavy material.
//
// Parameters:
//   threshold_db  [-24, 0]     dBFS limiting ceiling   (default  0 dB = unity)
//   attack_ms     [0.1, 50]    attack  time in ms       (default  1 ms)
//   release_ms    [10, 500]    release time in ms       (default 50 ms)
//
// Usage:
//   crag.include "standard-graphs/compressors/peak-limiter.crag.mlir" as "peak_limiter"
//
//   %limited = crag.subgraph_ref "peak_limiter"(%in)
//                  : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 0, 0>

module {
  crag.graph name = "peak_limiter"
             sample_rate = 48000 channels = 1 default_visualizer = "compressor-viz" {
  ^bb0(%input: !crag.audio<f32, 0, 0>):

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    %threshold_db = crag.param "threshold_db" min = -24.0 max = 0.0
                        default = 0.0  unit = "dB" : f32
    %attack_ms_p  = crag.param "attack_ms"    min = 0.1   max = 50.0
                        default = 1.0  unit = "ms" : f32
    %release_ms_p = crag.param "release_ms"   min = 10.0  max = 500.0
                        default = 50.0 unit = "ms" : f32

    // -------------------------------------------------------------------------
    // Convert threshold from dB to linear amplitude
    //   threshold_linear = 10^(threshold_dB / 20) = exp(threshold_dB * ln(10)/20)
    // -------------------------------------------------------------------------
    %kln10_20 = arith.constant 0.11512925464970229 : f32  // ln(10) / 20
    %thr_log  = arith.mulf %threshold_db, %kln10_20 : f32
    %thr_lin  = math.exp %thr_log : f32

    // -------------------------------------------------------------------------
    // Peak level detection
    // -------------------------------------------------------------------------
    %peak = crag.peak %input : !crag.audio<f32, 0, 0> -> f32

    // -------------------------------------------------------------------------
    // Envelope follower (asymmetric attack/release at block rate)
    // -------------------------------------------------------------------------
    %envelope = crag.smooth %peak, %attack_ms_p, %release_ms_p
                    : f32, f32, f32 -> f32

    // -------------------------------------------------------------------------
    // Compute limiting gain: min(1.0,  threshold / envelope)
    // Floor the envelope to avoid division by zero on silent blocks.
    // -------------------------------------------------------------------------
    %tiny     = arith.constant 1.0e-7 : f32
    %env_safe = arith.maximumf %envelope, %tiny : f32
    %raw_gain = arith.divf %thr_lin, %env_safe : f32
    %one      = arith.constant 1.0 : f32
    %gain     = arith.minimumf %raw_gain, %one : f32

    // -------------------------------------------------------------------------
    // Apply gain
    // -------------------------------------------------------------------------
    %output = crag.scale %input, %gain
                  : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
