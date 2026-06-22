// Convolution Reverb
//
// Applies the acoustic character of a physical space (or any linear system)
// to an audio signal by convolving it with an impulse response (IR) loaded
// from a sampler.  This models reverberation caused by reflections in a room,
// hallway, concert hall, or other acoustic environment.
//
// Algorithm:
//   Uses partitioned overlap-save FFT convolution (crag.overlap_save_conv)
//   with up to `num_partitions = 32` partitions.  At each block the op:
//     1. FFTs the input block and pushes it into an internal ring buffer.
//     2. Queries the runtime IR length to compute k = min(ceil(len/B), 32).
//     3. For each partition p in [0, k): multiplies the input history block
//        with the p-th partition of the IR in the frequency domain.
//     4. Accumulates all products and IFFTs to produce the reverberant signal.
//   This yields constant per-block cost regardless of IR length, and accurately
//   captures IRs of up to 32 * blockSize samples (≈ 341 ms at 48 kHz/512 B).
//
// Sampler:
//   Bind a mono WAV file containing the impulse response to the sampler named
//   "impulse_response" before rendering.  The file should be at the same
//   sample rate as the graph (48000 Hz by default).
//
// Parameters:
//   wet_level  [0, 1]  – reverberant (wet) signal amplitude  (default 0.5)
//   dry_level  [0, 1]  – original (dry) signal amplitude     (default 0.5)
//
// Usage (standalone — this is a top-level graph):
//   Compile this file directly.  At runtime, bind the IR WAV to sampler 0
//   ("impulse_response") via crag_bind_audio_by_index(0, ptr, len).
//
// Usage (as a named subgraph via crag.include):
//   crag.include "standard-graphs/reverb/convolution-reverb.crag.mlir" as "conv_reverb"
//   ...
//   %wet = crag.subgraph_ref "conv_reverb"(%dry)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>

module {
  crag.graph name = "convolution_reverb" sample_rate = 48000 channels = 1 default_visualizer = "spectrometer" {
  ^bb0(%dry: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %wet_level = crag.param "wet_level" min = 0.0 max = 1.0 default = 0.5 : f32
    %dry_level = crag.param "dry_level" min = 0.0 max = 1.0 default = 0.5 : f32

    // -----------------------------------------------------------------------
    // IR sampler handle
    // -----------------------------------------------------------------------
    %ir_sampler = crag.sampler "impulse_response"
                      : !crag.sampler<"impulse_response">

    // -----------------------------------------------------------------------
    // Partitioned overlap-save FFT convolution
    //
    // num_partitions = 32 allows IRs up to 32 * blockSize samples long
    // (≈ 341 ms at 48 kHz with blockSize = 512) to be processed exactly.
    // The actual number of partitions used each block is determined at
    // runtime from the bound IR length.
    // -----------------------------------------------------------------------
    %reverb = crag.overlap_save_conv %dry, %ir_sampler num_partitions = 32
                  : !crag.audio<f32, 0, 0>,
                    !crag.sampler<"impulse_response">
                    -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Wet / dry mix
    // -----------------------------------------------------------------------
    %wet_out = crag.scale %reverb, %wet_level : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %dry_out = crag.scale %dry, %dry_level    : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %output  = crag.sum %dry_out, %wet_out
                   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                     -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
