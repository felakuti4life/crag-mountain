// HRTF Spatializer (SS2, fixed-position renderer)
//
<<<<<<< HEAD
// Dataset-driven HRTF spatializer variant.  Same ABI as
=======
// Dataset-driven HRTF spatializer variant per the §4.2 plan.  Same ABI as
>>>>>>> main
// `standard-graphs/spatial/hrtf_spatializer.crag.mlir` and the CIPIC
// renderer (mono in, binaural-tagged stereo out, position exposed via
// three `crag.param` ops); the only delta versus the CIPIC fixed-position
// renderer is the per-ear sampler name (`hrir_ss2_L` / `hrir_ss2_R`) and
// the citation block.  Both samplers are bound at compile time through
// `--inline-sampler-data` against the per-ear single-IR WAVs that
<<<<<<< HEAD
// `scripts/hrtf/render.py` exports out of the normalized cache.
=======
// `scripts/hrtf/render.py` exports out of the §3.2 normalized cache.
>>>>>>> main
//
// As with CIPIC, this first-pass renderer is **fixed-position**: each
// compiled binary corresponds to one HRIR pair.  Runtime per-position IR
// selection lives in the sibling `hrtf_spatializer_ss2_runtime.crag.mlir`
// template.
//
// Citation (CC-BY-4.0; see `third_party/hrtf_sets/ss2/LICENSE`):
//   SS2 HRTF Dataset, Reality Labs Research / Meta.
//   https://github.com/facebookresearch/SS2_HRTF
//
// Sample rate: fixed at 48 kHz (matches the SS2 dataset's native rate;
// no resample is needed in `scripts/hrtf/prep.py`).
//
// IR length budget:
<<<<<<< HEAD
//   The normalized cache pads SS2 IRs to 256 samples.  At
=======
//   The §3.2 normalized cache pads SS2 IRs to 256 samples.  At
>>>>>>> main
//   blockSize=512, a single OLS partition covers the full IR without
//   aliasing, so we set `num_partitions = 1` per ear.  If a future
//   cache schema bumps `ir_length` above 512, increase this constant.
//
// Usage:
//   crag-compile \
//     --inline-sampler-data hrir_ss2_L:<...>_L_pos.wav \
//     --inline-sampler-data hrir_ss2_R:<...>_R_pos.wav \
//     standard-graphs/spatial/ss2/hrtf_spatializer_ss2.crag.mlir
//
// `scripts/hrtf/render.py ss2 <subject_id>` automates this against a
// packed cache entry.

module {
<<<<<<< HEAD
  // Position visualizer — see naive reference template comment.
=======
  // §8 / §9 position visualizer — see naive reference template comment.
>>>>>>> main
  crag.include_visualizer "visualizers/spatial/position-combined.crag.mlir"
                          as "position_combined"

  crag.graph name = "hrtf_spatializer_ss2" sample_rate = 48000 channels = 1
      default_visualizer = "phase-correlation" {
  ^bb0(%in: !crag.audio<f32, 48000, 1>):

    // Position parameters (same ABI as the naive reference graph).
    %azimuth   = crag.param "azimuth_rad"
                     min = -3.14159274 max = 3.14159274 default = 0.0
                     unit = "rad" : f32
    %elevation = crag.param "elevation_rad"
                     min = -1.57079632 max = 1.57079632 default = 0.0
                     unit = "rad" : f32
    %distance  = crag.param "distance_m"
                     min = 0.1 max = 10.0 default = 1.0
                     unit = "m" : f32

    // Per-ear HRIR samplers.  Bind at compile time via:
    //   --inline-sampler-data hrir_ss2_L:<L.wav>
    //   --inline-sampler-data hrir_ss2_R:<R.wav>
    %ir_l = crag.sampler "hrir_ss2_L" : !crag.sampler<"hrir_ss2_L">
    %ir_r = crag.sampler "hrir_ss2_R" : !crag.sampler<"hrir_ss2_R">

    %one        = arith.constant 1.0 : f32
    %two        = arith.constant 2.0 : f32
    %dist_floor = arith.constant 0.1 : f32

    // Convolve the dry mono input with each ear's HRIR.
    %wet_l = crag.overlap_save_conv %in, %ir_l num_partitions = 1
                 : !crag.audio<f32, 48000, 1>,
                   !crag.sampler<"hrir_ss2_L">
                   -> !crag.audio<f32, 48000, 1>
    %wet_r = crag.overlap_save_conv %in, %ir_r num_partitions = 1
                 : !crag.audio<f32, 48000, 1>,
                   !crag.sampler<"hrir_ss2_R">
                   -> !crag.audio<f32, 48000, 1>

    // Residual constant-power lateral pan (sin(az)·cos(el)) so this
    // fixed-position renderer still tracks azimuth/elevation around
<<<<<<< HEAD
    // the bound IR's anchor direction.  Once runtime IR selection
=======
    // the bound IR's anchor direction.  Once §6 runtime IR selection
>>>>>>> main
    // lands this whole block is replaced by an IR-index computation.
    %sin_az    = math.sin %azimuth   : f32
    %cos_el    = math.cos %elevation : f32
    %pan       = arith.mulf %sin_az, %cos_el : f32

    %one_minus = arith.subf %one, %pan : f32
    %one_plus  = arith.addf %one, %pan : f32
    %gl_sq     = arith.divf %one_minus, %two : f32
    %gr_sq     = arith.divf %one_plus,  %two : f32
    %gl_pan    = math.sqrt %gl_sq : f32
    %gr_pan    = math.sqrt %gr_sq : f32

    // Inverse-distance with safe floor (matches the naive reference).
    %dist_safe = arith.maximumf %distance, %dist_floor : f32
    %dist_gain = arith.divf %one, %dist_safe : f32

    %gain_l    = arith.mulf %gl_pan, %dist_gain : f32
    %gain_r    = arith.mulf %gr_pan, %dist_gain : f32

    %out_l = crag.scale %wet_l, %gain_l
                 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %out_r = crag.scale %wet_r, %gain_r
                 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>

    %binaural = crag.channel_join %out_l, %out_r
                    : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>)
                      -> !crag.audio<f32, 48000, 2, subtype = "binaural">

<<<<<<< HEAD
    // Position visualizer side-effect capture.
=======
    // §8 position visualizer side-effect capture.
>>>>>>> main
    crag.visualizer_ref "position_combined"(%in, %azimuth, %elevation, %distance)
        : (!crag.audio<f32, 48000, 1>, f32, f32, f32)

    crag.output %binaural : !crag.audio<f32, 48000, 2, subtype = "binaural">
  }
}
