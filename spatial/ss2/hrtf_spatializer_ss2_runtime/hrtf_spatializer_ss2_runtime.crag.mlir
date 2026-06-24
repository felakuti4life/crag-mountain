// HRTF Spatializer (SS2, runtime-position renderer)
//
// Dataset-driven HRTF spatializer variant.
// Runtime-selectable counterpart to `hrtf_spatializer_ss2.crag.mlir`:
// instead of baking one position's IR pair into the binary at compile
// time, this template binds a single pair of concatenated-IR samplers
// (the `<subject>_L.wav` / `<subject>_R.wav` produced by
// `scripts/hrtf/prep.py`) and lets the host pick which 256-sample IR
// is active each block by writing the `position_index` parameter via
// `crag_set_param_int`.
//
// The dialect-level addition that makes this possible is
// `crag.overlap_save_conv_slice`; see `include/Crag/CragOps.td`.
//
// Same external ABI as the fixed-position SS2 renderer plus one new
// integer parameter:
//
//   - `position_index` (i32, default 0) — selects the active IR row in
//     the concatenated pack.  The lex-ordered cache layout means
//     index ↔ `(elevation, azimuth)` is deterministic and dataset-
//     independent; the host (or a downstream nearest-neighbour pass)
//     resolves az/el/dist → index.
//
// `azimuth_rad` / `elevation_rad` / `distance_m` are still declared so
// hosts can drive the same parameter names regardless of which renderer
// variant or dataset is loaded.  Only `distance_m` is applied here as
// an inverse-distance gain (SS2 IRs are nominally 1.5 m source range
// only); azimuth/elevation become host-side hints used when computing
// `position_index`.
//
// Citation (CC-BY-4.0; see `third_party/hrtf_sets/ss2/LICENSE`):
//   SS2 HRTF Dataset, Reality Labs Research / Meta.
//   https://github.com/facebookresearch/SS2_HRTF
//
// Sample rate: fixed at 48 kHz (matches the SS2 dataset's native rate).
//
// IR length budget:
//   The normalized cache pads SS2 IRs to 256 samples.  At
//   blockSize=512, a single OLS partition covers the full IR without
//   aliasing, so we set `num_partitions = 1` per ear.
//
// position_index range:
//   `max = 4095` matches the CIPIC runtime template; SS2 typically
//   ships ~793 measurement points per subject, well within range.
//   Bump if a future dataset is larger; over-cautious `max` only widens
//   the host-callable range and does not allocate any compile-time table.
//
// Usage:
//   crag-compile \
//     --inline-sampler-data hrir_ss2_pack_L:<subject>_L.wav \
//     --inline-sampler-data hrir_ss2_pack_R:<subject>_R.wav \
//     standard-graphs/spatial/ss2/hrtf_spatializer_ss2_runtime.crag.mlir
//
// `scripts/hrtf/render.py ss2 <subject_id> --mode runtime` automates
// this against a packed cache entry.

module {
  // Position visualizer — see naive reference template comment.
  crag.include_visualizer "visualizers/spatial/position-combined.crag.mlir"
                          as "position_combined"

  crag.graph name = "hrtf_spatializer_ss2_runtime" sample_rate = 48000
      channels = 1 default_visualizer = "phase-correlation" {
  ^bb0(%in: !crag.audio<f32, 48000, 1>):

    // Position parameters.  azimuth/elevation are kept for ABI parity;
    // the active IR is selected by `position_index`.
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

    // Per-ear concatenated-IR samplers.  Bind via:
    //   --inline-sampler-data hrir_ss2_pack_L:<subject>_L.wav
    //   --inline-sampler-data hrir_ss2_pack_R:<subject>_R.wav
    // each holding all per-position IRs end-to-end in the cache's lex order.
    %ir_l = crag.sampler "hrir_ss2_pack_L" : !crag.sampler<"hrir_ss2_pack_L">
    %ir_r = crag.sampler "hrir_ss2_pack_R" : !crag.sampler<"hrir_ss2_pack_R">

    %one        = arith.constant 1.0 : f32
    %dist_floor = arith.constant 0.1 : f32

    // ir_offset = position_index * ir_length (in samples).
    //   ir_length is the cache constant (256 samples per IR).
    //   position_index is i32 (range checked by crag_set_param_int);
    //   widen to i64 to match the overlap_save_conv_slice operand type.
    %ir_len     = arith.constant 256 : i64
    %pos_i64    = arith.extsi %pos_idx : i32 to i64
    %ir_offset  = arith.muli %pos_i64, %ir_len : i64

    // Convolve the dry mono input with each ear's runtime-selected IR.
    %wet_l = crag.overlap_save_conv_slice %in, %ir_l, %ir_offset, %ir_len
                 num_partitions = 1
                 : !crag.audio<f32, 48000, 1>,
                   !crag.sampler<"hrir_ss2_pack_L">,
                   i64, i64
                   -> !crag.audio<f32, 48000, 1>
    %wet_r = crag.overlap_save_conv_slice %in, %ir_r, %ir_offset, %ir_len
                 num_partitions = 1
                 : !crag.audio<f32, 48000, 1>,
                   !crag.sampler<"hrir_ss2_pack_R">,
                   i64, i64
                   -> !crag.audio<f32, 48000, 1>

    // Inverse-distance with safe floor.
    %dist_safe = arith.maximumf %distance, %dist_floor : f32
    %dist_gain = arith.divf %one, %dist_safe : f32

    %out_l = crag.scale %wet_l, %dist_gain
                 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %out_r = crag.scale %wet_r, %dist_gain
                 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>

    %binaural = crag.channel_join %out_l, %out_r
                    : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>)
                      -> !crag.audio<f32, 48000, 2, subtype = "binaural">

    // Position visualizer side-effect capture.
    crag.visualizer_ref "position_combined"(%in, %azimuth, %elevation, %distance)
        : (!crag.audio<f32, 48000, 1>, f32, f32, f32)

    crag.output %binaural : !crag.audio<f32, 48000, 2, subtype = "binaural">
  }
}
