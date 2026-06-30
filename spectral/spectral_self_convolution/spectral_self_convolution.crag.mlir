// Spectral Self-Convolution
//
// Convolves an audio signal with itself in the frequency domain.  In the time
// domain this is equivalent to convolving the signal block with a flipped
// copy of itself (auto-convolution, related to but distinct from
// auto-correlation).  The audible result is a darker, smeared, "energy-
// emphasised" version of the input: tonal content with strong fundamentals
// is reinforced, transients are softened, and the output spectrum is the
// magnitude-squared of the input spectrum (with doubled phase).
//
// Algorithm:
//   1. Forward FFT the input block.
//   2. Multiply the spectrum by itself (`crag.freq_mul %X, %X`).  Per bin
//      this computes  Y[k] = X[k]^2 = |X[k]|^2 · exp(j · 2·arg(X[k])).
//   3. Inverse FFT to recover a time-domain block.
//   4. Mix the result with the dry signal under user control.
//
// Note on block length:
//   This op operates on a single block (length = compiled blockSize); like
//   `standard-graphs/reverb/fft-convolution`, it is best understood as
//   *circular* self-convolution within one block.  For full linear
//   self-convolution of a continuous stream, wrap this in an overlap-add
//   scheme.  The effect is still musically useful here as a per-block
//   spectral coloration.
//
// Parameters:
//   wet_level  [0, 1]  – self-convolved signal amplitude  (default 0.5)
//   dry_level  [0, 1]  – original signal amplitude        (default 0.5)
//
// Input:
//   %in  — the audio block to self-convolve in the frequency domain.
//
// Output:
//   The mixed dry + self-convolved audio block.
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "spectral_self_convolution"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/spectral/spectral_self_convolution.crag.mlir"
//       as "spectral_self_convolution"

module {
  crag.graph name = "spectral_self_convolution" sample_rate = 48000 channels = 1
      default_visualizer = "spectrometer" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %wet_level = crag.param "wet_level" min = 0.0 max = 1.0 default = 0.5 : f32
    %dry_level = crag.param "dry_level" min = 0.0 max = 1.0 default = 0.5 : f32

    // -----------------------------------------------------------------------
    // 1. Forward FFT
    // -----------------------------------------------------------------------
    %freq = crag.fft %in : !crag.audio<f32, 0, 0> -> !crag.freq<f32, 0, 0>

    // -----------------------------------------------------------------------
    // 2. Per-bin self-multiplication (X[k] * X[k] = X[k]^2)
    //    The operand is used twice — both ports of crag.freq_mul reference
    //    the same SSA value.  This is the core of self-convolution.
    // -----------------------------------------------------------------------
    %squared = crag.freq_mul %freq, %freq
                   : !crag.freq<f32, 0, 0>, !crag.freq<f32, 0, 0>
                     -> !crag.freq<f32, 0, 0>

    // -----------------------------------------------------------------------
    // 3. Inverse FFT to recover the time-domain self-convolved block
    // -----------------------------------------------------------------------
    %wet = crag.ifft %squared : !crag.freq<f32, 0, 0> -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // 4. Wet / dry mix
    // -----------------------------------------------------------------------
    %wet_sc = crag.scale %wet, %wet_level
                  : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %dry_sc = crag.scale %in,  %dry_level
                  : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %output = crag.sum %dry_sc, %wet_sc
                  : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                    -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
