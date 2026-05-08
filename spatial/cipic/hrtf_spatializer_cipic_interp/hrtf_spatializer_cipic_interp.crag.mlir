// HRTF Spatializer (CIPIC, k=3 linear-interpolation renderer)
//
// Plan §6.2 graph-side linear-interpolation variant.  This is the
// runtime-position counterpart to `hrtf_spatializer_cipic_runtime.crag.mlir`
// extended with k=3 inverse-distance weighted blending of three
// concurrently-active HRIR rows, so the host can move the source between
// measurement points without the audible "switching" artefact a single
// nearest-neighbour `position_index` produces.
//
// The host computes the three (index, weight) tuples once per parameter
// update via `scripts.hrtf.lookup.linear_interp_positions(k=3)` and binds
// them through the per-slot parameters declared below.  The graph itself
// is dataset-agnostic: weights can come from any §6 lookup strategy.
// k=3 is the canonical HRTF interpolation arity (a spherical triangle);
// extending the template to higher k is a copy-and-paste exercise but is
// usually unnecessary in practice.
//
// External ABI is a strict superset of the runtime renderer:
//
//   * `azimuth_rad`, `elevation_rad`, `distance_m`  — same as before
//   * `position_index_0/1/2` (i32, default 0)  — IR rows in the pack
//   * `weight_0/1/2` (f32, default 1/3)       — inverse-distance weights
//
// Defaulting all three weights to 1/3 means a freshly-loaded binary that
// has not yet had its parameters driven still produces a coherent
// (mean-of-three-IRs) output instead of triple-convolving with the same
// row-0 IR; combined with the index defaults of 0/0/0 the bring-up cost
// is also predictable (no unbounded-output edge case).
//
// `azimuth_rad` / `elevation_rad` are kept declared for ABI parity with
// the fixed and runtime variants; only `distance_m` is applied here as
// an inverse-distance gain (CIPIC IRs are far-field-only).  az/el are
// host-side hints used to compute the (index, weight) tuples.
//
// Citation (per CIPIC's read_me.txt):
//   V. R. Algazi, R. O. Duda, D. M. Thompson, and C. Avendano,
//   "The CIPIC HRTF Database," Proc. 2001 IEEE Workshop on Applications
//   of Signal Processing to Audio and Acoustics (WASPAA'01),
//   pp. 99-102, New Paltz, NY, Oct. 2001.
//
// Sample rate / IR length / partition budget all match the runtime
// renderer (48 kHz; ir_length = 256 ≤ block size 512 ⇒ num_partitions = 1).
//
// position_index range:
//   `max = 4095` matches the runtime renderer (covers CIPIC's 1250
//   measurement points with ~3× headroom).
//
// Usage:
//   crag-compile \
//     --inline-sampler-data hrir_cipic_interp_pack_L:<subject>_L.wav \
//     --inline-sampler-data hrir_cipic_interp_pack_R:<subject>_R.wav \
//     standard-graphs/spatial/cipic/hrtf_spatializer_cipic_interp.crag.mlir
//
// `scripts/hrtf/render.py cipic <subject_id> --mode interp` automates
// this against a packed cache entry.

module {
  // §8 / §9 position visualizer — see naive reference template comment.
  crag.include_visualizer "visualizers/spatial/position-combined.crag.mlir"
                          as "position_combined"

  crag.graph name = "hrtf_spatializer_cipic_interp" sample_rate = 48000
      channels = 1 default_visualizer = "phase-correlation" {
  ^bb0(%in: !crag.audio<f32, 48000, 1>):

    // ABI-parity float params (host-side hints).
    %azimuth   = crag.param "azimuth_rad"
                     min = -3.14159274 max = 3.14159274 default = 0.0
                     unit = "rad" : f32
    %elevation = crag.param "elevation_rad"
                     min = -1.57079632 max = 1.57079632 default = 0.0
                     unit = "rad" : f32
    %distance  = crag.param "distance_m"
                     min = 0.1 max = 10.0 default = 1.0
                     unit = "m" : f32

    // k=3 IR-row indices.
    %pos_idx_0 = crag.param_int "position_index_0"
                     min = 0 max = 4095 default = 0 : i32
    %pos_idx_1 = crag.param_int "position_index_1"
                     min = 0 max = 4095 default = 0 : i32
    %pos_idx_2 = crag.param_int "position_index_2"
                     min = 0 max = 4095 default = 0 : i32

    // k=3 blend weights (host normalises to sum to 1.0 ‒ see
    // scripts/hrtf/lookup.linear_interp_positions).  Defaults to 1/3
    // each so an unparameterised binary still produces a coherent
    // mean-of-three-IRs output.
    %w_0 = crag.param "weight_0"
               min = 0.0 max = 1.0 default = 0.33333333 unit = "" : f32
    %w_1 = crag.param "weight_1"
               min = 0.0 max = 1.0 default = 0.33333333 unit = "" : f32
    %w_2 = crag.param "weight_2"
               min = 0.0 max = 1.0 default = 0.33333333 unit = "" : f32

    // Per-ear concatenated-IR samplers.  Bound via:
    //   --inline-sampler-data hrir_cipic_interp_pack_L:<subject>_L.wav
    //   --inline-sampler-data hrir_cipic_interp_pack_R:<subject>_R.wav
    // each holding all per-position IRs end-to-end in the §3.2 lex order.
    // These names are deliberately distinct from the runtime renderer's
    // `hrir_cipic_pack_{L,R}` so the test_render.py "no sampler-name
    // collision across modes" sanity check stays a true cross-mode
    // namespace separation.
    %ir_l = crag.sampler "hrir_cipic_interp_pack_L"
                : !crag.sampler<"hrir_cipic_interp_pack_L">
    %ir_r = crag.sampler "hrir_cipic_interp_pack_R"
                : !crag.sampler<"hrir_cipic_interp_pack_R">

    %one        = arith.constant 1.0 : f32
    %dist_floor = arith.constant 0.1 : f32

    // ir_offset_k = position_index_k * ir_length (256 samples per IR).
    %ir_len   = arith.constant 256 : i64
    %p0_i64   = arith.extsi %pos_idx_0 : i32 to i64
    %p1_i64   = arith.extsi %pos_idx_1 : i32 to i64
    %p2_i64   = arith.extsi %pos_idx_2 : i32 to i64
    %off_0    = arith.muli %p0_i64, %ir_len : i64
    %off_1    = arith.muli %p1_i64, %ir_len : i64
    %off_2    = arith.muli %p2_i64, %ir_len : i64

    // Three independent OLS-slice convolutions per ear, then blended by
    // the host-supplied weights.  num_partitions = 1 because ir_length
    // (256) is ≤ block size (512); see runtime template for the
    // rationale.  Bumping prep.TARGET_IR_LENGTH above blockSize requires
    // bumping num_partitions here in tandem.
    %wet_l_0 = crag.overlap_save_conv_slice %in, %ir_l, %off_0, %ir_len
                   num_partitions = 1
                   : !crag.audio<f32, 48000, 1>,
                     !crag.sampler<"hrir_cipic_interp_pack_L">,
                     i64, i64
                     -> !crag.audio<f32, 48000, 1>
    %wet_l_1 = crag.overlap_save_conv_slice %in, %ir_l, %off_1, %ir_len
                   num_partitions = 1
                   : !crag.audio<f32, 48000, 1>,
                     !crag.sampler<"hrir_cipic_interp_pack_L">,
                     i64, i64
                     -> !crag.audio<f32, 48000, 1>
    %wet_l_2 = crag.overlap_save_conv_slice %in, %ir_l, %off_2, %ir_len
                   num_partitions = 1
                   : !crag.audio<f32, 48000, 1>,
                     !crag.sampler<"hrir_cipic_interp_pack_L">,
                     i64, i64
                     -> !crag.audio<f32, 48000, 1>

    %wet_r_0 = crag.overlap_save_conv_slice %in, %ir_r, %off_0, %ir_len
                   num_partitions = 1
                   : !crag.audio<f32, 48000, 1>,
                     !crag.sampler<"hrir_cipic_interp_pack_R">,
                     i64, i64
                     -> !crag.audio<f32, 48000, 1>
    %wet_r_1 = crag.overlap_save_conv_slice %in, %ir_r, %off_1, %ir_len
                   num_partitions = 1
                   : !crag.audio<f32, 48000, 1>,
                     !crag.sampler<"hrir_cipic_interp_pack_R">,
                     i64, i64
                     -> !crag.audio<f32, 48000, 1>
    %wet_r_2 = crag.overlap_save_conv_slice %in, %ir_r, %off_2, %ir_len
                   num_partitions = 1
                   : !crag.audio<f32, 48000, 1>,
                     !crag.sampler<"hrir_cipic_interp_pack_R">,
                     i64, i64
                     -> !crag.audio<f32, 48000, 1>

    // Weighted sum: sum(sum(scale*w0, scale*w1), scale*w2).  crag.sum
    // is binary so we associate left-to-right.
    %sl0 = crag.scale %wet_l_0, %w_0
               : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %sl1 = crag.scale %wet_l_1, %w_1
               : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %sl2 = crag.scale %wet_l_2, %w_2
               : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %sl01 = crag.sum %sl0, %sl1
                : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>)
                  -> !crag.audio<f32, 48000, 1>
    %mix_l = crag.sum %sl01, %sl2
                 : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>)
                   -> !crag.audio<f32, 48000, 1>

    %sr0 = crag.scale %wet_r_0, %w_0
               : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %sr1 = crag.scale %wet_r_1, %w_1
               : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %sr2 = crag.scale %wet_r_2, %w_2
               : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %sr01 = crag.sum %sr0, %sr1
                : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>)
                  -> !crag.audio<f32, 48000, 1>
    %mix_r = crag.sum %sr01, %sr2
                 : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>)
                   -> !crag.audio<f32, 48000, 1>

    // Inverse-distance gain.
    %dist_safe = arith.maximumf %distance, %dist_floor : f32
    %dist_gain = arith.divf %one, %dist_safe : f32

    %out_l = crag.scale %mix_l, %dist_gain
                 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %out_r = crag.scale %mix_r, %dist_gain
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
