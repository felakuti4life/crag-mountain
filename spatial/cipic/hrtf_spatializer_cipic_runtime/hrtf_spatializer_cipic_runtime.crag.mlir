// HRTF Spatializer (CIPIC, runtime-position renderer)
//
<<<<<<< HEAD
// Dataset-driven HRTF spatializer variant.  This
=======
// Dataset-driven HRTF spatializer variant per the §4.2 / §6.1 plan.  This
>>>>>>> main
// is the *runtime-selectable* counterpart to
// `hrtf_spatializer_cipic.crag.mlir`: instead of baking one position's IR
// pair into the binary at compile time, it binds a single pair of
// concatenated-IR samplers (the `<subject>_L.wav` / `<subject>_R.wav`
// produced by `scripts/hrtf/prep.py pack_normalized_set`) and lets the
// host pick which 256-sample IR is active each audio block by writing the
// `position_index` parameter via `crag_set_param_int`.
//
// The dialect-level addition that makes this possible is
// `crag.overlap_save_conv_slice` (and its tap-loop sibling
// `crag.tap_loop_conv`); see `include/Crag/CragOps.td` and the lit tests
// `test/Crag/crag-overlap-save-conv-slice.mlir` /
// `test/Crag/crag-tap-loop-conv.mlir`.  Both ops accept an `i64`
// `ir_offset` + `ir_length` operand pair so a single sampler can be
// sliced at audio-block granularity.  This template uses the overlap-save
// variant because that is the same machinery the fixed-position renderer
// already exercised; the tap-loop variant is a drop-in alternative for
<<<<<<< HEAD
// the interpolation work where many short IR taps may be cheaper to
=======
// the §6 interpolation work where many short IR taps may be cheaper to
>>>>>>> main
// run direct-form.
//
// Same external ABI as `hrtf_spatializer_cipic.crag.mlir` plus one new
// integer parameter:
//
//   - `position_index` (i32, default 0) — selects the active IR row in
<<<<<<< HEAD
//     the concatenated pack.  The lex-ordered cache layout means
//     index ↔ `(elevation, azimuth)` is deterministic and dataset-
//     independent; the host (or a downstream nearest-neighbour pass)
=======
//     the concatenated pack.  The §3.2 lex-ordered cache layout means
//     index ↔ `(elevation, azimuth)` is deterministic and dataset-
//     independent; the host (or a downstream §6 nearest-neighbour pass)
>>>>>>> main
//     resolves az/el/dist → index.
//
// `azimuth_rad` / `elevation_rad` / `distance_m` are still declared so
// hosts can drive the same parameter names regardless of which renderer
// variant is loaded.  Of those, only `distance_m` is applied here as an
// inverse-distance gain (CIPIC IRs are far-field-only); azimuth/elevation
// become host-side hints used when computing `position_index`.
//
// Citation (per CIPIC's read_me.txt):
//   V. R. Algazi, R. O. Duda, D. M. Thompson, and C. Avendano,
//   "The CIPIC HRTF Database," Proc. 2001 IEEE Workshop on Applications
//   of Signal Processing to Audio and Acoustics (WASPAA'01),
//   pp. 99-102, New Paltz, NY, Oct. 2001.
//
// Sample rate: fixed at 48 kHz (CIPIC IRs are resampled from 44.1 kHz to
<<<<<<< HEAD
// 48 kHz by `scripts/hrtf/prep.py` before binding).
//
// IR length budget:
//   The normalized cache pads CIPIC IRs to 256 samples.  At
=======
// 48 kHz by `scripts/hrtf/prep.py` before binding — see plan §4.1.2).
//
// IR length budget:
//   The §3.2 normalized cache pads CIPIC IRs to 256 samples.  At
>>>>>>> main
//   blockSize=512, a single OLS partition covers the full IR without
//   aliasing, so we set `num_partitions = 1` per ear.  `ir_length = 256`
//   matches `prep.TARGET_IR_LENGTH`; bumping that constant in
//   `scripts/hrtf/prep.py` requires bumping it here too (and possibly
//   `num_partitions` if it crosses 512).
//
// position_index range:
//   CIPIC ships 25 azimuths × 50 elevations = 1250 positions per
//   subject.  The `max = 4095` upper bound here (chosen as 2^12 − 1
//   for tidy bit-width) gives ~3× headroom over CIPIC and covers
//   several CIPIC-sized packs without changing the template; if a
//   future dataset is larger, bump this attribute.  Out-of-range index
//   values are still trapped at runtime by `crag_set_param_int`'s
//   clamping, so an over-cautious `max` only widens the host-callable
//   range, it does not enlarge any compile-time table.
//
// Usage:
//   crag-compile \
//     --inline-sampler-data hrir_cipic_pack_L:<subject>_L.wav \
//     --inline-sampler-data hrir_cipic_pack_R:<subject>_R.wav \
//     standard-graphs/spatial/cipic/hrtf_spatializer_cipic_runtime.crag.mlir
//
// `scripts/hrtf/render.py --mode runtime` automates this against a
// packed cache entry.

module {
<<<<<<< HEAD
  // Position visualizer — see naive reference template comment.
=======
  // §8 / §9 position visualizer — see naive reference template comment.
>>>>>>> main
  crag.include_visualizer "visualizers/spatial/position-combined.crag.mlir"
                          as "position_combined"

  crag.graph name = "hrtf_spatializer_cipic_runtime" sample_rate = 48000
      channels = 1 default_visualizer = "phase-correlation" {
  ^bb0(%in: !crag.audio<f32, 48000, 1>):

    // -----------------------------------------------------------------------
    // Position parameters.  azimuth/elevation are kept for ABI parity
    // with the naive reference and the fixed-position renderer; the
    // active IR is selected by `position_index` instead.
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
    %pos_idx   = crag.param_int "position_index"
                     min = 0 max = 4095 default = 0 : i32

    // -----------------------------------------------------------------------
    // Per-ear concatenated-IR samplers.  At compile time, bind these via
    //   --inline-sampler-data hrir_cipic_pack_L:<subject>_L.wav
    //   --inline-sampler-data hrir_cipic_pack_R:<subject>_R.wav
<<<<<<< HEAD
    // each holding all per-position IRs end-to-end in the cache's lex order.
=======
    // each holding all per-position IRs end-to-end in the §3.2 lex order.
>>>>>>> main
    // -----------------------------------------------------------------------
    %ir_l = crag.sampler "hrir_cipic_pack_L" : !crag.sampler<"hrir_cipic_pack_L">
    %ir_r = crag.sampler "hrir_cipic_pack_R" : !crag.sampler<"hrir_cipic_pack_R">

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------
    %one        = arith.constant 1.0 : f32
    %dist_floor = arith.constant 0.1 : f32

    // -----------------------------------------------------------------------
    // ir_offset = position_index * ir_length (in samples).
    //
<<<<<<< HEAD
    //   ir_length is the cache constant (256 samples per IR).
=======
    //   ir_length is the §3.2 cache constant (256 samples per IR).
>>>>>>> main
    //   position_index is i32 (range checked by crag_set_param_int);
    //   widen to i64 to match the overlap_save_conv_slice operand type.
    // -----------------------------------------------------------------------
    %ir_len     = arith.constant 256 : i64
    %pos_i64    = arith.extsi %pos_idx : i32 to i64
    %ir_offset  = arith.muli %pos_i64, %ir_len : i64

    // -----------------------------------------------------------------------
    // Convolve the dry mono input with each ear's runtime-selected IR.
    //
<<<<<<< HEAD
    // num_partitions = 1: the cache caps `ir_length` at 256, well under the
=======
    // num_partitions = 1: §3.2 caps `ir_length` at 256, well under the
>>>>>>> main
    // default blockSize of 512, so one partition covers the IR without
    // aliasing.  Bumping the cache schema's IR length above blockSize
    // requires bumping this constant (and the constant 256 above) in
    // tandem.
    // -----------------------------------------------------------------------
    %wet_l = crag.overlap_save_conv_slice %in, %ir_l, %ir_offset, %ir_len
                 num_partitions = 1
                 : !crag.audio<f32, 48000, 1>,
                   !crag.sampler<"hrir_cipic_pack_L">,
                   i64, i64
                   -> !crag.audio<f32, 48000, 1>
    %wet_r = crag.overlap_save_conv_slice %in, %ir_r, %ir_offset, %ir_len
                 num_partitions = 1
                 : !crag.audio<f32, 48000, 1>,
                   !crag.sampler<"hrir_cipic_pack_R">,
                   i64, i64
                   -> !crag.audio<f32, 48000, 1>

    // -----------------------------------------------------------------------
    // Inverse-distance with safe floor (matches the naive reference and
    // the fixed-position renderer).  CIPIC IRs are far-field-only, so
    // distance is purely a gain — the IR itself does not change with
    // distance.
    // -----------------------------------------------------------------------
    %dist_safe = arith.maximumf %distance, %dist_floor : f32
    %dist_gain = arith.divf %one, %dist_safe : f32

    %out_l = crag.scale %wet_l, %dist_gain
                 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %out_r = crag.scale %wet_r, %dist_gain
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
