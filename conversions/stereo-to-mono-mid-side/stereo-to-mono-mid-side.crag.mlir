// Stereo-to-Mono Mid/Side (M/S) Downmix — Mid extraction
//
// Computes the Mid component of a Mid/Side decomposition of the stereo signal
// and outputs it as a mono channel:
//
//   mid_out = (L + R) / 2
//
// The Mid signal represents the centre-panned, phase-coherent content of the
// mix.  The Side signal (L − R) is discarded by this mixer.
//
// Numerically this is equivalent to the "stereo_to_mono_average" mixer; the
// distinction is semantic: this mixer is intended for workflows that explicitly
// use M/S processing, where the source graph was recorded or processed in M/S
// format and the mid component is the desired mono output.
//
// Conversion: channels 2 → 1
//
// Usage via crag-inject-channel-mixers (preferred_channel_mixer = "stereo_to_mono_mid_side"):
//
//   crag.graph sample_rate = 48000 channels = 2
//              preferred_channel_mixer = "stereo_to_mono_mid_side" {
//     %in = ...
//     crag.output %in : !crag.audio<f32, 48000, 2>
//   }

module {
  crag.graph name = "stereo_to_mono_mid_side" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 2>):
    // Extract left (ch 0) and right (ch 1).
    %left  = crag.channel_slice %in, 0
                 : !crag.audio<f32, 0, 2> -> !crag.audio<f32, 0, 1>
    %right = crag.channel_slice %in, 1
                 : !crag.audio<f32, 0, 2> -> !crag.audio<f32, 0, 1>

    // Mid = (L + R) / 2
    %sum  = crag.sum %left, %right
                : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                  -> !crag.audio<f32, 0, 1>
    %half = arith.constant 5.000000e-01 : f32
    %mid  = crag.scale %sum, %half
                : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    crag.output %mid : !crag.audio<f32, 0, 1>
  }
}
