// Stereo-to-5.1 Upmix (Phantom Centre)
//
// Upmixes a 2-channel (stereo) audio signal to 5.1 surround using a
// phantom-centre approach:
//
//   FL  (ch 0) = L
//   FR  (ch 1) = R
//   FC  (ch 2) = (L + R) / 2        ← phantom centre (sum / 2)
//   LFE (ch 3) = 0                   ← silent; no low-frequency content
//   BL  (ch 4) = L * 0.707           ← left surround (−3 dB for diffuse field)
//   BR  (ch 5) = R * 0.707           ← right surround
//
// This is a simple "Prologic"-style upmix.  The centre channel carries the
// average of L and R (equivalent to the M/S mid component) and is attenuated
// by 6 dB to avoid sum-loudness increase.  The surrounds carry the original
// L and R signals reduced by ~3 dB (0.707 ≈ 1/√2) to maintain an equal-energy
// distribution across the listening field.
//
// 5.1 channel layout (ITU-R BS.775 / SMPTE convention):
//   ch 0: Front Left   (FL)
//   ch 1: Front Right  (FR)
//   ch 2: Front Centre (FC)
//   ch 3: LFE / Subwoofer
//   ch 4: Back/Surround Left  (BL / SL)
//   ch 5: Back/Surround Right (BR / SR)
//
// Conversion: channels 2 → 6
//
// Usage via crag-inject-channel-mixers (preferred_channel_mixer = "stereo_to_51"):
//
//   crag.graph sample_rate = 48000 channels = 2
//              preferred_channel_mixer = "stereo_to_51" {
//     %in = ...
//     crag.output %in : !crag.audio<f32, 48000, 2>
//   }

module {
  crag.graph name = "stereo_to_51" sample_rate = 0 channels = 6 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 2>):

    // Extract left and right channels.
    %left  = crag.channel_slice %in, 0
                 : !crag.audio<f32, 0, 2> -> !crag.audio<f32, 0, 1>
    %right = crag.channel_slice %in, 1
                 : !crag.audio<f32, 0, 2> -> !crag.audio<f32, 0, 1>

    // FL = L  (channel 0, unchanged)
    // FR = R  (channel 1, unchanged)

    // FC = (L + R) / 2   (phantom centre)
    %lr_sum  = crag.sum %left, %right
                   : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                     -> !crag.audio<f32, 0, 1>
    %half    = arith.constant 5.000000e-01 : f32
    %centre  = crag.scale %lr_sum, %half
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // LFE = silence (zero signal)
    %zero    = arith.constant 0.0 : f32
    %lfe     = crag.scale %centre, %zero
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // BL = L * 0.707,  BR = R * 0.707
    %sqrt2inv = arith.constant 7.07106781e-01 : f32
    %bl      = crag.scale %left,  %sqrt2inv
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %br      = crag.scale %right, %sqrt2inv
                   : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // Interleave all six channels: FL, FR, FC, LFE, BL, BR.
    %out = crag.channel_join %left, %right, %centre, %lfe, %bl, %br
               : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                  !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                  !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                 -> !crag.audio<f32, 0, 6>

    crag.output %out : !crag.audio<f32, 0, 6>
  }
}
