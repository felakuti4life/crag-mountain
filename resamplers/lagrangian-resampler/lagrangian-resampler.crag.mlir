// Lagrangian Resampler (4-point Cubic Polynomial Interpolation)
//
// Implements block-level 4-point cubic Lagrange interpolation for sample-rate
// conversion.  Three previous audio blocks are stored in delay lines.  The
// Lagrange basis polynomial weights are evaluated at the fractional delay
// τ = ratio − 1 (where ratio = in_sr / out_sr) and used to blend the four
// consecutive blocks into the output.
//
// Algorithm (4-point cubic Lagrange with nodes at block positions {−3,−2,−1,0}):
//
//   τ = ratio − 1           ← fractional delay in [−1, 0]
//
//   L₀(τ) = −(τ+2)(τ+1)τ / 6       (weight for block[−3bs])
//   L₁(τ) =  (τ+3)(τ+1)τ / 2       (weight for block[−2bs])
//   L₂(τ) = −(τ+3)(τ+2)τ / 2       (weight for block[−1bs])
//   L₃(τ) =  (τ+3)(τ+2)(τ+1) / 6   (weight for current block)
//
//   y = L₀·d₃ + L₁·d₂ + L₂·d₁ + L₃·x
//
// where d₁, d₂, d₃ are the 1-, 2-, and 3-block-old delayed copies of the
// input, produced by three serial delay lines each of block_size samples.
//
// An anti-aliasing Butterworth lowpass filter is applied before the
// interpolation step.  The cutoff is set to ratio (normalised, where 1.0 =
// Nyquist) to suppress frequencies above the lower Nyquist limit.
//
// Parameters:
//   ratio  [0.01, 1.0]  in_sr / out_sr  (default ≈ 0.9188 = 44100/48000)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "lagrangian_resampler"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// Include from another module via:
//   crag.include "standard-graphs/resamplers/lagrangian-resampler.crag.mlir"
//               as "lagrangian_resampler"

module {
  crag.graph name = "lagrangian_resampler" sample_rate = 48000 channels = 1 default_visualizer = "oscilloscope" {
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
    %half  = arith.constant 0.5 : f32
    %cutoff_aa = arith.mulf %ratio, %half : f32
    %fb_aa, %ff_aa = crag.get_filter_coeffs %cutoff_aa order = 2 type = "lowpass"
                         : f32, !crag.coeff_vec, !crag.coeff_vec
    %x = crag.filter %input, %fb_aa, %ff_aa
             : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec)
               -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Three serial delay lines — each holds one block (512 samples)
    // -----------------------------------------------------------------------
    // d1 = x delayed by 1 block
    %dl1     = crag.delay_line : !crag.delay<f32, 48000, 1, 512>
    %d1      = crag.pop_delay %dl1 : !crag.delay<f32, 48000, 1, 512>
                   -> !crag.audio<f32, 0, 0>
    crag.push_delay %dl1, %x : !crag.delay<f32, 48000, 1, 512>,
                                !crag.audio<f32, 0, 0>

    // d2 = x delayed by 2 blocks (chain d1 through a second delay line)
    %dl2     = crag.delay_line : !crag.delay<f32, 48000, 1, 512>
    %d2      = crag.pop_delay %dl2 : !crag.delay<f32, 48000, 1, 512>
                   -> !crag.audio<f32, 0, 0>
    crag.push_delay %dl2, %d1 : !crag.delay<f32, 48000, 1, 512>,
                                 !crag.audio<f32, 0, 0>

    // d3 = x delayed by 3 blocks
    %dl3     = crag.delay_line : !crag.delay<f32, 48000, 1, 512>
    %d3      = crag.pop_delay %dl3 : !crag.delay<f32, 48000, 1, 512>
                   -> !crag.audio<f32, 0, 0>
    crag.push_delay %dl3, %d2 : !crag.delay<f32, 48000, 1, 512>,
                                 !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Compute Lagrange basis polynomial weights for τ = ratio − 1
    // Nodes: {−3, −2, −1, 0};  evaluation point: τ ∈ [−1, 0]
    // -----------------------------------------------------------------------
    %one   = arith.constant 1.0 : f32
    %two   = arith.constant 2.0 : f32
    %three = arith.constant 3.0 : f32
    %six   = arith.constant 6.0 : f32

    %tau   = arith.subf %ratio, %one : f32   // τ = ratio − 1

    %tp1   = arith.addf %tau, %one   : f32   // τ + 1
    %tp2   = arith.addf %tau, %two   : f32   // τ + 2
    %tp3   = arith.addf %tau, %three : f32   // τ + 3

    // L₀ = −(τ+2)(τ+1)τ / 6
    %l0_n  = arith.mulf %tp2, %tp1  : f32
    %l0_n2 = arith.mulf %l0_n, %tau : f32
    %l0_p  = arith.divf %l0_n2, %six : f32
    %l0    = arith.negf %l0_p : f32

    // L₁ =  (τ+3)(τ+1)τ / 2
    %l1_n  = arith.mulf %tp3, %tp1  : f32
    %l1_n2 = arith.mulf %l1_n, %tau : f32
    %l1    = arith.divf %l1_n2, %two : f32

    // L₂ = −(τ+3)(τ+2)τ / 2
    %l2_n  = arith.mulf %tp3, %tp2  : f32
    %l2_n2 = arith.mulf %l2_n, %tau : f32
    %l2_p  = arith.divf %l2_n2, %two : f32
    %l2    = arith.negf %l2_p : f32

    // L₃ =  (τ+3)(τ+2)(τ+1) / 6
    %l3_n  = arith.mulf %tp3, %tp2  : f32
    %l3_n2 = arith.mulf %l3_n, %tp1 : f32
    %l3    = arith.divf %l3_n2, %six : f32

    // -----------------------------------------------------------------------
    // Weighted block combination: y = L₀·d₃ + L₁·d₂ + L₂·d₁ + L₃·x
    // -----------------------------------------------------------------------
    %y0 = crag.scale %d3, %l0 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %y1 = crag.scale %d2, %l1 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %y2 = crag.scale %d1, %l2 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %y3 = crag.scale %x,  %l3 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>

    %output = crag.sum %y0, %y1, %y2, %y3
                  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>,
                     !crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                    -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
