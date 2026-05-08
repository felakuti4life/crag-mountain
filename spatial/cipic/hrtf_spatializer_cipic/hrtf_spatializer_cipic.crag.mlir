// HRTF Spatializer (CIPIC, fixed-position renderer)
//
// Dataset-driven HRTF spatializer variant per the §4.2 plan.  Same ABI as
// `standard-graphs/spatial/hrtf_spatializer.crag.mlir` (mono in, binaural-
// tagged stereo out, position exposed via three `crag.param` ops) but the
// "tap + per-ear gain" middle of the naive reference is replaced with a
// pair of `crag.overlap_save_conv` ops convolving the dry input with the
// CIPIC-derived left/right HRIRs bound through the `--inline-sampler-data`
// flow (see plan §4.3).
//
// This first-pass renderer is **fixed-position**: each compiled binary
// corresponds to the HRIRs bound to `hrir_cipic_L` / `hrir_cipic_R` at
// compile time, which the `scripts/hrtf/render.py` driver picks from the
// normalized cache by index (default = front, az=0°, el=0°).  Runtime
// per-position IR selection / interpolation (plan §6) is now supported at
// the dialect level via the `crag.overlap_save_conv_slice` (runtime-
// offset/length partitioned-FFT variant) and `crag.tap_loop_conv`
// (direct-form FIR over a runtime IR window) ops; a follow-up renderer
// template will swap this fixed-position middle for one that takes a
// position index and slices a single concatenated-IR sampler.
//
// The position parameters are still declared and applied as a residual
// constant-power lateral pan + inverse-distance gain so hosts can drive
// the same parameter names regardless of which renderer is loaded.  When
// runtime per-position IR selection lands, the pan/distance math here
// will collapse into the IR-selection logic; for now they let the
// fixed-position renderer respond meaningfully to azimuth changes around
// the bound IR's "anchor" direction.
//
// Citation (per CIPIC's read_me.txt):
//   V. R. Algazi, R. O. Duda, D. M. Thompson, and C. Avendano,
//   "The CIPIC HRTF Database," Proc. 2001 IEEE Workshop on Applications
//   of Signal Processing to Audio and Acoustics (WASPAA'01),
//   pp. 99-102, New Paltz, NY, Oct. 2001.
//
// Sample rate: fixed at 48 kHz (CIPIC IRs are resampled from 44.1 kHz to
// 48 kHz by `scripts/hrtf/prep.py` before binding — see plan §4.1.2).
//
// IR length budget:
//   The §3.2 normalized cache pads CIPIC IRs to 256 samples.  At
//   blockSize=512, a single OLS partition is enough to cover the full IR
//   without aliasing, so we set `num_partitions = 1` per ear.  If a
//   future cache schema bumps `ir_length` above 512, increase this
//   (and the renderer template will recompile transparently).
//
// Usage:
//   crag-compile \
//     --inline-sampler-data hrir_cipic_L:<...>_L_pos.wav \
//     --inline-sampler-data hrir_cipic_R:<...>_R_pos.wav \
//     standard-graphs/spatial/cipic/hrtf_spatializer_cipic.crag.mlir
//
// `scripts/hrtf/render.py` automates this against a packed cache entry.

module {
  // §8 / §9 position visualizer — see naive reference template comment.
  crag.include_visualizer "visualizers/spatial/position-combined.crag.mlir"
                          as "position_combined"

  crag.graph name = "hrtf_spatializer_cipic" sample_rate = 48000 channels = 1
      default_visualizer = "phase-correlation" {
  ^bb0(%in: !crag.audio<f32, 48000, 1>):

    // -----------------------------------------------------------------------
    // Position parameters (same ABI as the naive reference graph).
    // -----------------------------------------------------------------------
    %azimuth   = crag.param "azimuth_rad"
                     min = -3.14159274 max = 3.14159274 default = 0.0
                     unit = "rad" : f32
    %elevation = crag.param "elevation_rad"
                     min = -1.57079632 max = 1.57079632 default = 0.0
                     unit = "rad" : f32
    %distance  = crag.param "distance_m"
                     min = 0.1 max = 10.0 default = 1.0
                     unit = "m" : f32

    // -----------------------------------------------------------------------
    // Per-ear HRIR samplers.  At compile time, bind these via
    // --inline-sampler-data hrir_cipic_L:<L.wav>
    // --inline-sampler-data hrir_cipic_R:<R.wav>
    // -----------------------------------------------------------------------
    %ir_l = crag.sampler "hrir_cipic_L" : !crag.sampler<"hrir_cipic_L">
    %ir_r = crag.sampler "hrir_cipic_R" : !crag.sampler<"hrir_cipic_R">

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------
    %one        = arith.constant 1.0 : f32
    %two        = arith.constant 2.0 : f32
    %dist_floor = arith.constant 0.1 : f32

    // -----------------------------------------------------------------------
    // Convolve the dry mono input with each ear's HRIR.
    //
    // num_partitions = 1: §3.2 caps `ir_length` at 256, well under the
    // default blockSize of 512, so one partition covers the IR without
    // aliasing.  Bumping the cache schema's IR length above blockSize
    // requires bumping this constant in tandem.
    // -----------------------------------------------------------------------
    %wet_l = crag.overlap_save_conv %in, %ir_l num_partitions = 1
                 : !crag.audio<f32, 48000, 1>,
                   !crag.sampler<"hrir_cipic_L">
                   -> !crag.audio<f32, 48000, 1>
    %wet_r = crag.overlap_save_conv %in, %ir_r num_partitions = 1
                 : !crag.audio<f32, 48000, 1>,
                   !crag.sampler<"hrir_cipic_R">
                   -> !crag.audio<f32, 48000, 1>

    // -----------------------------------------------------------------------
    // Residual constant-power lateral pan (sin(az)·cos(el)) so this
    // fixed-position renderer still tracks azimuth/elevation around the
    // bound IR's anchor direction.  Once §6 runtime IR selection lands
    // this whole block is replaced by an IR-index computation.
    // -----------------------------------------------------------------------
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

    // §8 position visualizer side-effect capture.
    crag.visualizer_ref "position_combined"(%in, %azimuth, %elevation, %distance)
        : (!crag.audio<f32, 48000, 1>, f32, f32, f32)

    crag.output %binaural : !crag.audio<f32, 48000, 2, subtype = "binaural">
  }
}
