// 5.1-to-Stereo Downmix (ITU-R BS.775)
//
// Downmixes a 5.1 surround sound signal (6 channels) to stereo (2 channels)
// using the ITU-R BS.775 / SMPTE RP 2096 coefficients:
//
//   L_out = FL + 0.707·FC + 0.707·BL
//   R_out = FR + 0.707·FC + 0.707·BR
//
// The LFE channel is omitted from the downmix (no bass management is applied).
// Full-scale summing of correlated signals can exceed 0 dBFS; for broadcast use
// an additional −3 dB gain stage (scalar 0.707) is often applied to the output.
//
// 5.1 channel layout (ITU-R BS.775 / SMPTE convention):
//   ch 0: Front Left   (FL)
//   ch 1: Front Right  (FR)
//   ch 2: Front Centre (FC)
//   ch 3: LFE / Subwoofer       (ignored in this downmix)
//   ch 4: Back/Surround Left  (BL / SL)
//   ch 5: Back/Surround Right (BR / SR)
//
// Coefficients:
//   k_c  = 1/√2 ≈ 0.707  (centre and surround attenuation, −3 dB)
//
// Conversion: channels 6 → 2
//
// Usage via crag-inject-channel-mixers (preferred_channel_mixer = "51_to_stereo"):
//
//   crag.graph sample_rate = 48000 channels = 6
//              preferred_channel_mixer = "51_to_stereo" {
//     %in = ...
//     crag.output %in : !crag.audio<f32, 48000, 6>
//   }

module {
  crag.graph name = "51_to_stereo" sample_rate = 0 channels = 2 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 6>):

    // Extract the relevant channels.
    %fl = crag.channel_slice %in, 0 : !crag.audio<f32, 0, 6> -> !crag.audio<f32, 0, 1>
    %fr = crag.channel_slice %in, 1 : !crag.audio<f32, 0, 6> -> !crag.audio<f32, 0, 1>
    %fc = crag.channel_slice %in, 2 : !crag.audio<f32, 0, 6> -> !crag.audio<f32, 0, 1>
    // ch 3 (LFE) is omitted.
    %bl = crag.channel_slice %in, 4 : !crag.audio<f32, 0, 6> -> !crag.audio<f32, 0, 1>
    %br = crag.channel_slice %in, 5 : !crag.audio<f32, 0, 6> -> !crag.audio<f32, 0, 1>

    // Apply the ITU-R k_c = 1/√2 ≈ 0.707 attenuation to FC, BL, BR.
    %kc       = arith.constant 7.07106781e-01 : f32
    %fc_att   = crag.scale %fc, %kc : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %bl_att   = crag.scale %bl, %kc : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %br_att   = crag.scale %br, %kc : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // L_out = FL + 0.707·FC + 0.707·BL
    %l_out = crag.sum %fl, %fc_att, %bl_att
                 : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                   -> !crag.audio<f32, 0, 1>

    // R_out = FR + 0.707·FC + 0.707·BR
    %r_out = crag.sum %fr, %fc_att, %br_att
                 : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                   -> !crag.audio<f32, 0, 1>

    // Combine L and R into a stereo output.
    %stereo = crag.channel_join %l_out, %r_out
                  : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                    -> !crag.audio<f32, 0, 2>

    crag.output %stereo : !crag.audio<f32, 0, 2>
  }
}
