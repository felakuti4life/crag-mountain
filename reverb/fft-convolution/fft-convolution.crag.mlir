// FFT Convolution
//
// Performs linear convolution of two audio blocks in the frequency domain.
// This is the fundamental building block of all FFT-based convolution engines.
//
// Algorithm (block convolution / overlap-add concept):
//   1. Transform the input signal block to the frequency domain via FFT.
//   2. Transform the impulse-response block to the frequency domain via FFT.
//   3. Multiply the two frequency-domain representations element-wise
//      (complex multiplication — equivalent to convolution in time domain).
//   4. Transform the product back to the time domain via IFFT.
//
// Note on block length:
//   True overlap-add convolution requires a zero-padded FFT size of at least
//   2 * blockSize - 1.  This graph operates on single blocks of the compiled
//   block size, so it is best used for spectral shaping (e.g. applying a
//   short impulse response that fits within one block) or as a subgraph
//   inside a larger overlap-add or overlap-save scheme.
//
// Inputs:
//   %signal  — the block of audio to be convolved
//   %impulse — the impulse-response block (same length as %signal)
//
// Output:
//   The convolved audio block.
//
// Usage (after crag.include):
//   %convolved = crag.subgraph_ref "fft_convolution"(%signal, %impulse)
//                    : (!crag.audio<f32, 48000, 1>,
//                       !crag.audio<f32, 48000, 1>)
//                      -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/reverb/fft-convolution.crag.mlir" as "fft_convolution"

module {
  crag.graph name = "fft_convolution" sample_rate = 48000 channels = 1 default_visualizer = "spectrometer" {
  ^bb0(%signal: !crag.audio<f32, 0, 0>, %impulse: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // 1. Forward FFT of both input blocks
    // -----------------------------------------------------------------------
    %signal_freq  = crag.fft %signal  : !crag.audio<f32, 0, 0> -> !crag.freq<f32, 0, 0>
    %impulse_freq = crag.fft %impulse : !crag.audio<f32, 0, 0> -> !crag.freq<f32, 0, 0>

    // -----------------------------------------------------------------------
    // 2. Frequency-domain complex multiplication
    //    Pointwise: conv_freq[k] = signal_freq[k] * impulse_freq[k]
    // -----------------------------------------------------------------------
    %conv_freq = crag.freq_mul %signal_freq, %impulse_freq
                     : !crag.freq<f32, 0, 0>, !crag.freq<f32, 0, 0>
                       -> !crag.freq<f32, 0, 0>

    // -----------------------------------------------------------------------
    // 3. Inverse FFT to recover the convolved time-domain signal
    // -----------------------------------------------------------------------
    %conv_audio = crag.ifft %conv_freq : !crag.freq<f32, 0, 0> -> !crag.audio<f32, 0, 0>

    crag.output %conv_audio : !crag.audio<f32, 0, 0>
  }
}
