// Spectral Cross-Synthesis
//
// Multiplies the per-bin spectra of two live audio inputs, producing a signal
// whose spectrum is the element-wise product of the two source spectra.  In
// musical terms, the output keeps frequency content only where *both*
// sources have energy: each input acts as a frequency-domain mask on the
// other.  This is the underlying operation of classic "cross-synthesis"
// patches and is closely related to a crude vocoder where the modulator's
// magnitude shapes the carrier.
//
// Algorithm:
//   1. Forward FFT both input blocks.
//   2. Multiply the two spectra element-wise (`crag.freq_mul`).  Per bin
//      this is complex multiplication:
//         Y[k] = A[k] * B[k]
//             = |A[k]| · |B[k]| · exp(j · (arg(A[k]) + arg(B[k])))
//   3. Inverse FFT to recover the cross-synthesised time-domain block.
//
// Note on block length:
//   Like `standard-graphs/reverb/fft-convolution`, this is a single-block
//   (circular) cross-multiplication; no overlap is performed across block
//   boundaries.  For continuous streaming with proper linear convolution,
//   wrap the call in an overlap-add scheme or use `crag.overlap_save_conv`
//   with one of the inputs preloaded into a sampler.
//
// Parameters:
//   wet_level  [0, 1]  – cross-synthesised signal amplitude  (default 0.7)
//   dry_level  [0, 1]  – first-input dry passthrough         (default 0.0)
//
// Inputs:
//   %a  — the first audio block (often the "carrier"); also routed to the
//         dry-mix path so that wet_level / dry_level form a wet/dry control
//         centred on input A.
//   %b  — the second audio block (often the "modulator").  Only its spectrum
//         enters the cross-synthesis output; B is not summed into the dry
//         path.
//
// Output:
//   The cross-synthesised audio block, optionally blended with input A.
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "spectral_cross_synthesis"(%a, %b)
//              : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>)
//                -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/spectral/spectral_cross_synthesis.crag.mlir"
//       as "spectral_cross_synthesis"

module {
  crag.graph name = "spectral_cross_synthesis" sample_rate = 48000 channels = 1
      default_visualizer = "spectrometer" {
  ^bb0(%a: !crag.audio<f32, 0, 0>, %b: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %wet_level = crag.param "wet_level" min = 0.0 max = 1.0 default = 0.7 : f32
    %dry_level = crag.param "dry_level" min = 0.0 max = 1.0 default = 0.0 : f32

    // -----------------------------------------------------------------------
    // 1. Forward FFT both inputs
    // -----------------------------------------------------------------------
    %fa = crag.fft %a : !crag.audio<f32, 0, 0> -> !crag.freq<f32, 0, 0>
    %fb = crag.fft %b : !crag.audio<f32, 0, 0> -> !crag.freq<f32, 0, 0>

    // -----------------------------------------------------------------------
    // 2. Element-wise complex multiplication of the two spectra
    // -----------------------------------------------------------------------
    %prod = crag.freq_mul %fa, %fb
                : !crag.freq<f32, 0, 0>, !crag.freq<f32, 0, 0>
                  -> !crag.freq<f32, 0, 0>

    // -----------------------------------------------------------------------
    // 3. Inverse FFT back to the time domain
    // -----------------------------------------------------------------------
    %wet = crag.ifft %prod : !crag.freq<f32, 0, 0> -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Wet / dry mix (dry path is input A only)
    // -----------------------------------------------------------------------
    %wet_sc = crag.scale %wet, %wet_level
                  : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %dry_sc = crag.scale %a,   %dry_level
                  : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %output = crag.sum %dry_sc, %wet_sc
                  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                    -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
