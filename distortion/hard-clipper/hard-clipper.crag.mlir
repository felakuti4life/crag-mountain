// Hard Clipper
//
// Classic hard-clipping distortion: any sample whose absolute value exceeds
// the threshold is instantly cut to ±threshold.  Above the clip point the
// output is a flat (saturated) rail; below it the signal is unmodified.
//
// Algorithm:
//   y[n] = max(-threshold, min(+threshold, drive * x[n]))
//
// This is the simplest possible distortion nonlinearity.  It produces strong
// odd-order harmonics (3rd, 5th, 7th …) because the clipped waveform
// approximates a square wave, giving it a bright, aggressive, "transistor
// overdrive" quality.  The harmonic content grows rapidly as the drive is
// increased beyond the point where clipping begins.
//
// Pre-gain vs. post-gain:
//   The drive parameter amplifies the input before clipping; high drive values
//   push more of the waveform into saturation and create more distortion.
//   No automatic post-attenuation is applied, so increasing drive also raises
//   the output level slightly (the clipped portion contributes constant energy).
//   Use the wet_level knob to compensate if constant perceived loudness is
//   required.
//
// Parameters:
//   drive      [1, 20]   – pre-clip gain           (default 4.0)
//   threshold  [0.1, 1]  – clip ceiling             (default 1.0)
//   wet_level  [0, 1]    – distorted signal level   (default 1.0)
//   dry_level  [0, 1]    – clean (direct) level     (default 0.0)
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "hard_clipper"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
// This file contains only a named subgraph; it is not directly compilable as
// a standalone module.  Include it from another module via:
//   crag.include "standard-graphs/distortion/hard-clipper.crag.mlir" as "hard_clipper"

module {
  crag.graph name = "hard_clipper" sample_rate = 48000 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 0>):

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    %drive     = crag.param "drive"     min = 1.0  max = 20.0 default = 4.0  : f32
    %threshold = crag.param "threshold" min = 0.1  max = 1.0  default = 1.0  : f32
    %wet_p     = crag.param "wet_level" min = 0.0  max = 1.0  default = 1.0  : f32
    %dry_p     = crag.param "dry_level" min = 0.0  max = 1.0  default = 0.0  : f32

    // -----------------------------------------------------------------------
    // Pre-amp: amplify input by drive gain before clipping
    // -----------------------------------------------------------------------
    %driven = crag.scale %in, %drive : !crag.audio<f32, 0, 0>, f32
                  -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Hard clip: clamp every sample to [-threshold, +threshold]
    // -----------------------------------------------------------------------
    %clipped = crag.hard_clip %driven, %threshold
                   : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>

    // -----------------------------------------------------------------------
    // Wet / dry mix
    // -----------------------------------------------------------------------
    %wet_out = crag.scale %clipped, %wet_p : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %dry_out = crag.scale %in, %dry_p      : !crag.audio<f32, 0, 0>, f32
                   -> !crag.audio<f32, 0, 0>
    %output  = crag.sum %dry_out, %wet_out
                   : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>)
                     -> !crag.audio<f32, 0, 0>

    crag.output %output : !crag.audio<f32, 0, 0>
  }
}
