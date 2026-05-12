// Spectral Block Delay
//
// Delays the input audio signal by an integer number of *blocks* by routing
// it through a ring buffer of frequency-domain blocks.  Each call:
//
//   1. Forward-FFTs the current input block.
//   2. Pushes the spectrum into a `crag.freq_delay_line` (16-slot ring).
//   3. Peeks at the spectrum stored `delay_blocks` slots back.
//   4. Inverse-FFTs the peeked spectrum to recover audio.
//
// Because the spectrum of a real audio block is a complete representation,
// peeking N slots back and IFFT'ing yields the audio block that was input
// `N` blocks ago — i.e. a delay of `delay_blocks · blockSize` samples.  This
// is functionally equivalent to a sample-domain block delay but is
// implemented entirely through the spectral pipeline, demonstrating how
// `crag.freq_delay_line` can be used to defer arbitrary frequency-domain
// processing in time.  It is also a useful building block for spectral
// freeze-style effects, latency compensation across spectral branches, and
// constant-cost partitioned overlap-save schemes.
//
// Latency:
//   With a 512-sample block at 48 kHz, the per-block delay step is ≈ 10.7
//   ms.  Setting `delay_blocks = 0` returns the most recently pushed block
//   (zero added latency beyond one block of FFT round-trip), and
//   `delay_blocks = 15` gives a maximum delay of ≈ 160 ms.
//
// Parameters:
//   delay_blocks  [0, 15]  – number of blocks to delay   (default 4)
//   wet_level     [0, 1]   – delayed signal amplitude    (default 0.7)
//   dry_level     [0, 1]   – original signal amplitude   (default 0.5)
//
// The bounds on `delay_blocks` are kept strictly within
// [0, num_partitions − 1] (= 15) so the strict-bounds-check pass on
// `crag.peek_freq_delay` is satisfied at compile time.
//
// Input:
//   %in  — the audio block to delay through the frequency-domain ring buffer.
//
// Output:
//   The mixed dry + delayed audio block.
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "spectral_block_delay"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/spectral/spectral_block_delay.crag.mlir"
//       as "spectral_block_delay"

module {
  crag.graph name = "spectral_block_delay" sample_rate = 48000 channels = 1
      default_visualizer = "spectrometer" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %delay_blocks = crag.param_int "delay_blocks"
                        min = 0 max = 15 default = 4 : i32
    %wet_level    = crag.param "wet_level"
                        min = 0.0 max = 1.0 default = 0.7 : f32
    %dry_level    = crag.param "dry_level"
                        min = 0.0 max = 1.0 default = 0.5 : f32

    // -----------------------------------------------------------------------
    // Frequency-domain ring buffer (16 slots).
    // 16 slots @ 512-sample blocks @ 48 kHz ≈ 170 ms of spectral history.
    // -----------------------------------------------------------------------
    %fd = crag.freq_delay_line : !crag.freq_delay<f32, 48000, 1, 16>

    // -----------------------------------------------------------------------
    // 1. Forward FFT and push the spectrum into the ring buffer
    // -----------------------------------------------------------------------
    %freq = crag.fft %in : !crag.audio<f32, 0, 0> -> !crag.freq<f32, 0, 0>
    crag.push_freq_delay %fd, %freq
        : !crag.freq_delay<f32, 48000, 1, 16>, !crag.freq<f32, 0, 0>

    // -----------------------------------------------------------------------
    // 2. Peek at the spectrum delayed `delay_blocks` slots back.
    //    partition_idx = 0 → the block we just pushed (newest);
    //    partition_idx = N → the block pushed N calls ago.
    // -----------------------------------------------------------------------
    %past = crag.peek_freq_delay %fd, %delay_blocks
                : !crag.freq_delay<f32, 48000, 1, 16>, i32
                  -> !crag.freq<f32, 0, 0>

    // -----------------------------------------------------------------------
    // 3. Inverse FFT to recover the delayed audio block
    // -----------------------------------------------------------------------
    %wet = crag.ifft %past : !crag.freq<f32, 0, 0> -> !crag.audio<f32, 0, 0>

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
