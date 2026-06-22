// Granulator
//
// A 6-voice granular synthesis engine.  Each voice reads a short overlapping
// "grain" from a bound audio file and applies a Hann-windowed envelope.  The
// six voices are staggered in phase so that the composite output has a smooth,
// sustained texture even at low grain rates.
//
// Algorithm (per voice i = 0..5):
//   1. Compute grain frequency f_i = grain_hz * (1 + spread * detuning_i)
//      where grain_hz = 1000 / grain_size_ms.
//   2. Evaluate the Hann envelope at the current time:
//        env_i = 0.5 − 0.5 · cos(2π · f_i · t + phase_i)
//      where phase_i = i · π/3.  Result is in [0, 1].
//   3. Read a grain block from the sampler starting at position:
//        pos_i = (position·len + frame·playback_speed + scatter_i·scatter·len)
//                mod len
//      where scatter_i ∈ [0, 1] is a fixed per-voice offset.
//   4. Scale by env_i / 6 · output_gain (normalise by voice count).
//   5. Pan with fixed per-voice L/R factors.
//
// Envelopes cycle at block rate (block-rate modulation), which is an
// acceptable approximation for grain sizes >> 1 block (≥ ~10 ms at 48 kHz
// with blockSize = 512).
//
// Parameters:
//   position      [0, 1]        – base read position as a fraction of source
//                                 length                         (default 0.1)
//   scatter       [0, 1]        – width of per-voice position spread
//                                                                 (default 0.1)
//   grain_size    [20, 500] ms  – grain duration (= 1 / grain_hz)
//                                                               (default 100.0)
//   playback_speed [-2, 2]      – source position advances at this many
//                                 samples per output sample      (default 0.0)
//   spread        [0, 1]        – per-voice grain frequency variation
//                                                                 (default 0.1)
//   output_gain   [0, 2]        – overall output level           (default 0.7)
//
// Sampler:
//   "audio" – bind a WAV file via crag_bind_audio_by_index(0, ptr, len)
//
// Output: !crag.audio<f32, 48000, 2> – stereo
//
// Visualizer:
//   "granulator_viz" – animated grain-envelope display (6 colour-coded bars).
//   The visualizer file must be co-included alongside this graph; the
//   generate_graph_docs.py script handles this automatically for documentation.
//
// Usage (after crag.include):
//   crag.include "standard-graphs/granulation/granulator.crag.mlir"
//       as "granulator"
//   crag.include_visualizer
//       "standard-graphs/granulation/granulator-viz.crag.mlir"
//       as "granulator_viz"
//   %out = crag.subgraph_ref "granulator"()
//              : () -> !crag.audio<f32, 48000, 2>

module {
  crag.include_visualizer "granulation/granulator-viz.crag.mlir"
      as "granulator_viz"

  crag.graph name = "granulator" sample_rate = 48000 channels = 2
      default_visualizer = "granulator_viz" {

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    %position      = crag.param "position"       min = 0.0   max = 1.0
                         default = 0.1 : f32
    %scatter       = crag.param "scatter"        min = 0.0   max = 1.0
                         default = 0.1 : f32
    %grain_size_ms = crag.param "grain_size"     min = 20.0  max = 500.0
                         default = 100.0 unit = "ms" : f32
    %playback_speed = crag.param "playback_speed" min = -2.0  max = 2.0
                         default = 0.0 : f32
    %spread        = crag.param "spread"         min = 0.0   max = 1.0
                         default = 0.1 : f32
    %output_gain   = crag.param "output_gain"    min = 0.0   max = 2.0
                         default = 0.7 : f32

    // -------------------------------------------------------------------------
    // Sampler and length guard
    // -------------------------------------------------------------------------
    %s          = crag.sampler "audio" : !crag.sampler<"audio">
    %len_i64    = crag.sampler_length %s : !crag.sampler<"audio"> -> i64
    %c0_i64     = arith.constant 0 : i64
    %c1_i64     = arith.constant 1 : i64
    %len_ok     = arith.cmpi sgt, %len_i64, %c0_i64 : i64
    %safe_len   = arith.select %len_ok, %len_i64, %c1_i64 : i64
    %len_f      = arith.sitofp %safe_len : i64 to f32

    // -------------------------------------------------------------------------
    // Time and grain frequency
    // -------------------------------------------------------------------------
    %frame      = crag.curframe : i64
    %frame_f    = arith.sitofp %frame : i64 to f32

    %curtime    = crag.curtime : f64
    %curtime_f  = arith.truncf %curtime : f64 to f32

    %c1000f     = arith.constant 1000.0 : f32
    %grain_hz   = arith.divf %c1000f, %grain_size_ms : f32

    // -------------------------------------------------------------------------
    // Shared constants
    // -------------------------------------------------------------------------
    %c0f        = arith.constant 0.0 : f32
    %c1f        = arith.constant 1.0 : f32
    %c0p5       = arith.constant 0.5 : f32
    %neg0p5     = arith.constant -0.5 : f32
    %two_pi     = arith.constant 6.28318530 : f32
    %norm       = arith.constant 0.16666667 : f32   // 1/6 per voice
    %large_i64  = arith.constant 65536 : i64

    // base_ang = 2π · grain_hz · curtime_f
    %ang_scale  = arith.mulf %two_pi, %grain_hz : f32
    %base_ang   = arith.mulf %ang_scale, %curtime_f : f32

    // Center position including playback advance (in samples, wrapped)
    %base_pos_f   = arith.mulf %position, %len_f : f32
    %advance_f    = arith.mulf %frame_f, %playback_speed : f32
    %total_pos_f  = arith.addf %base_pos_f, %advance_f : f32
    %mod_a        = arith.remf %total_pos_f, %len_f : f32
    %mod_b        = arith.addf %mod_a, %len_f : f32
    %center_f     = arith.remf %mod_b, %len_f : f32

    // Scatter range (in samples)
    %scatter_rng  = arith.mulf %scatter, %len_f : f32

    // Per-voice normalization: env_i * norm * output_gain
    %norm_gain    = arith.mulf %norm, %output_gain : f32

    // =========================================================================
    // VOICE 0  — phase 0.00·π, scatter 0.00, spread  0.00, pan L0.90/R0.10
    // =========================================================================
    %sp0        = arith.constant 0.00 : f32
    %dev0       = arith.mulf %spread, %sp0 : f32
    %ratio0     = arith.addf %c1f, %dev0 : f32
    %f0         = arith.mulf %grain_hz, %ratio0 : f32
    %a0_step    = arith.mulf %two_pi, %f0 : f32
    %a0_t       = arith.mulf %a0_step, %curtime_f : f32
    %ph0        = arith.constant 0.0 : f32
    %ang0       = arith.addf %a0_t, %ph0 : f32
    %cos0       = math.cos %ang0 : f32
    %nc0        = arith.mulf %neg0p5, %cos0 : f32
    %env0_raw   = arith.addf %c0p5, %nc0 : f32
    %env0       = arith.maximumf %c0f, %env0_raw : f32
    %vol0       = arith.mulf %env0, %norm_gain : f32
    %sf0        = arith.constant 0.00 : f32
    %off0       = arith.mulf %scatter_rng, %sf0 : f32
    %rp0f       = arith.addf %center_f, %off0 : f32
    %rp0_m1     = arith.remf %rp0f, %len_f : f32
    %rp0_pl     = arith.addf %rp0_m1, %len_f : f32
    %rp0_w      = arith.remf %rp0_pl, %len_f : f32
    %rp0        = arith.fptosi %rp0_w : f32 to i64
    %rp0_end    = arith.addi %rp0, %large_i64 : i64
    %raw0       = crag.sample %s, %rp0, %rp0_end
                      : !crag.sampler<"audio">, i64, i64
                        -> !crag.audio<f32, 48000, 1>
    %g0         = crag.scale %raw0, %vol0
                      : !crag.audio<f32, 48000, 1>, f32
                        -> !crag.audio<f32, 48000, 1>
    %pl0        = arith.constant 0.90 : f32
    %pr0        = arith.constant 0.10 : f32
    %l0         = crag.scale %g0, %pl0 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %r0         = crag.scale %g0, %pr0 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>

    // =========================================================================
    // VOICE 1  — phase 0.33·π, scatter 0.57, spread -0.15, pan L0.10/R0.90
    // =========================================================================
    %sp1        = arith.constant -0.15 : f32
    %dev1       = arith.mulf %spread, %sp1 : f32
    %ratio1     = arith.addf %c1f, %dev1 : f32
    %f1         = arith.mulf %grain_hz, %ratio1 : f32
    %a1_step    = arith.mulf %two_pi, %f1 : f32
    %a1_t       = arith.mulf %a1_step, %curtime_f : f32
    %ph1        = arith.constant 1.04719755 : f32   // π/3
    %ang1       = arith.addf %a1_t, %ph1 : f32
    %cos1       = math.cos %ang1 : f32
    %nc1        = arith.mulf %neg0p5, %cos1 : f32
    %env1_raw   = arith.addf %c0p5, %nc1 : f32
    %env1       = arith.maximumf %c0f, %env1_raw : f32
    %vol1       = arith.mulf %env1, %norm_gain : f32
    %sf1        = arith.constant 0.57 : f32
    %off1       = arith.mulf %scatter_rng, %sf1 : f32
    %rp1f       = arith.addf %center_f, %off1 : f32
    %rp1_m1     = arith.remf %rp1f, %len_f : f32
    %rp1_pl     = arith.addf %rp1_m1, %len_f : f32
    %rp1_w      = arith.remf %rp1_pl, %len_f : f32
    %rp1        = arith.fptosi %rp1_w : f32 to i64
    %rp1_end    = arith.addi %rp1, %large_i64 : i64
    %raw1       = crag.sample %s, %rp1, %rp1_end
                      : !crag.sampler<"audio">, i64, i64
                        -> !crag.audio<f32, 48000, 1>
    %g1         = crag.scale %raw1, %vol1
                      : !crag.audio<f32, 48000, 1>, f32
                        -> !crag.audio<f32, 48000, 1>
    %pl1        = arith.constant 0.10 : f32
    %pr1        = arith.constant 0.90 : f32
    %l1         = crag.scale %g1, %pl1 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %r1         = crag.scale %g1, %pr1 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>

    // =========================================================================
    // VOICE 2  — phase 0.67·π, scatter 0.14, spread +0.20, pan L0.70/R0.30
    // =========================================================================
    %sp2        = arith.constant 0.20 : f32
    %dev2       = arith.mulf %spread, %sp2 : f32
    %ratio2     = arith.addf %c1f, %dev2 : f32
    %f2         = arith.mulf %grain_hz, %ratio2 : f32
    %a2_step    = arith.mulf %two_pi, %f2 : f32
    %a2_t       = arith.mulf %a2_step, %curtime_f : f32
    %ph2        = arith.constant 2.09439510 : f32   // 2π/3
    %ang2       = arith.addf %a2_t, %ph2 : f32
    %cos2       = math.cos %ang2 : f32
    %nc2        = arith.mulf %neg0p5, %cos2 : f32
    %env2_raw   = arith.addf %c0p5, %nc2 : f32
    %env2       = arith.maximumf %c0f, %env2_raw : f32
    %vol2       = arith.mulf %env2, %norm_gain : f32
    %sf2        = arith.constant 0.14 : f32
    %off2       = arith.mulf %scatter_rng, %sf2 : f32
    %rp2f       = arith.addf %center_f, %off2 : f32
    %rp2_m1     = arith.remf %rp2f, %len_f : f32
    %rp2_pl     = arith.addf %rp2_m1, %len_f : f32
    %rp2_w      = arith.remf %rp2_pl, %len_f : f32
    %rp2        = arith.fptosi %rp2_w : f32 to i64
    %rp2_end    = arith.addi %rp2, %large_i64 : i64
    %raw2       = crag.sample %s, %rp2, %rp2_end
                      : !crag.sampler<"audio">, i64, i64
                        -> !crag.audio<f32, 48000, 1>
    %g2         = crag.scale %raw2, %vol2
                      : !crag.audio<f32, 48000, 1>, f32
                        -> !crag.audio<f32, 48000, 1>
    %pl2        = arith.constant 0.70 : f32
    %pr2        = arith.constant 0.30 : f32
    %l2         = crag.scale %g2, %pl2 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %r2         = crag.scale %g2, %pr2 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>

    // =========================================================================
    // VOICE 3  — phase 1.00·π, scatter 0.71, spread -0.10, pan L0.30/R0.70
    // =========================================================================
    %sp3        = arith.constant -0.10 : f32
    %dev3       = arith.mulf %spread, %sp3 : f32
    %ratio3     = arith.addf %c1f, %dev3 : f32
    %f3         = arith.mulf %grain_hz, %ratio3 : f32
    %a3_step    = arith.mulf %two_pi, %f3 : f32
    %a3_t       = arith.mulf %a3_step, %curtime_f : f32
    %ph3        = arith.constant 3.14159265 : f32   // π
    %ang3       = arith.addf %a3_t, %ph3 : f32
    %cos3       = math.cos %ang3 : f32
    %nc3        = arith.mulf %neg0p5, %cos3 : f32
    %env3_raw   = arith.addf %c0p5, %nc3 : f32
    %env3       = arith.maximumf %c0f, %env3_raw : f32
    %vol3       = arith.mulf %env3, %norm_gain : f32
    %sf3        = arith.constant 0.71 : f32
    %off3       = arith.mulf %scatter_rng, %sf3 : f32
    %rp3f       = arith.addf %center_f, %off3 : f32
    %rp3_m1     = arith.remf %rp3f, %len_f : f32
    %rp3_pl     = arith.addf %rp3_m1, %len_f : f32
    %rp3_w      = arith.remf %rp3_pl, %len_f : f32
    %rp3        = arith.fptosi %rp3_w : f32 to i64
    %rp3_end    = arith.addi %rp3, %large_i64 : i64
    %raw3       = crag.sample %s, %rp3, %rp3_end
                      : !crag.sampler<"audio">, i64, i64
                        -> !crag.audio<f32, 48000, 1>
    %g3         = crag.scale %raw3, %vol3
                      : !crag.audio<f32, 48000, 1>, f32
                        -> !crag.audio<f32, 48000, 1>
    %pl3        = arith.constant 0.30 : f32
    %pr3        = arith.constant 0.70 : f32
    %l3         = crag.scale %g3, %pl3 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %r3         = crag.scale %g3, %pr3 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>

    // =========================================================================
    // VOICE 4  — phase 1.33·π, scatter 0.28, spread +0.10, pan L0.80/R0.20
    // =========================================================================
    %sp4        = arith.constant 0.10 : f32
    %dev4       = arith.mulf %spread, %sp4 : f32
    %ratio4     = arith.addf %c1f, %dev4 : f32
    %f4         = arith.mulf %grain_hz, %ratio4 : f32
    %a4_step    = arith.mulf %two_pi, %f4 : f32
    %a4_t       = arith.mulf %a4_step, %curtime_f : f32
    %ph4        = arith.constant 4.18879020 : f32   // 4π/3
    %ang4       = arith.addf %a4_t, %ph4 : f32
    %cos4       = math.cos %ang4 : f32
    %nc4        = arith.mulf %neg0p5, %cos4 : f32
    %env4_raw   = arith.addf %c0p5, %nc4 : f32
    %env4       = arith.maximumf %c0f, %env4_raw : f32
    %vol4       = arith.mulf %env4, %norm_gain : f32
    %sf4        = arith.constant 0.28 : f32
    %off4       = arith.mulf %scatter_rng, %sf4 : f32
    %rp4f       = arith.addf %center_f, %off4 : f32
    %rp4_m1     = arith.remf %rp4f, %len_f : f32
    %rp4_pl     = arith.addf %rp4_m1, %len_f : f32
    %rp4_w      = arith.remf %rp4_pl, %len_f : f32
    %rp4        = arith.fptosi %rp4_w : f32 to i64
    %rp4_end    = arith.addi %rp4, %large_i64 : i64
    %raw4       = crag.sample %s, %rp4, %rp4_end
                      : !crag.sampler<"audio">, i64, i64
                        -> !crag.audio<f32, 48000, 1>
    %g4         = crag.scale %raw4, %vol4
                      : !crag.audio<f32, 48000, 1>, f32
                        -> !crag.audio<f32, 48000, 1>
    %pl4        = arith.constant 0.80 : f32
    %pr4        = arith.constant 0.20 : f32
    %l4         = crag.scale %g4, %pl4 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %r4         = crag.scale %g4, %pr4 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>

    // =========================================================================
    // VOICE 5  — phase 1.67·π, scatter 0.85, spread +0.25, pan L0.20/R0.80
    // =========================================================================
    %sp5        = arith.constant 0.25 : f32
    %dev5       = arith.mulf %spread, %sp5 : f32
    %ratio5     = arith.addf %c1f, %dev5 : f32
    %f5         = arith.mulf %grain_hz, %ratio5 : f32
    %a5_step    = arith.mulf %two_pi, %f5 : f32
    %a5_t       = arith.mulf %a5_step, %curtime_f : f32
    %ph5        = arith.constant 5.23598776 : f32   // 5π/3
    %ang5       = arith.addf %a5_t, %ph5 : f32
    %cos5       = math.cos %ang5 : f32
    %nc5        = arith.mulf %neg0p5, %cos5 : f32
    %env5_raw   = arith.addf %c0p5, %nc5 : f32
    %env5       = arith.maximumf %c0f, %env5_raw : f32
    %vol5       = arith.mulf %env5, %norm_gain : f32
    %sf5        = arith.constant 0.85 : f32
    %off5       = arith.mulf %scatter_rng, %sf5 : f32
    %rp5f       = arith.addf %center_f, %off5 : f32
    %rp5_m1     = arith.remf %rp5f, %len_f : f32
    %rp5_pl     = arith.addf %rp5_m1, %len_f : f32
    %rp5_w      = arith.remf %rp5_pl, %len_f : f32
    %rp5        = arith.fptosi %rp5_w : f32 to i64
    %rp5_end    = arith.addi %rp5, %large_i64 : i64
    %raw5       = crag.sample %s, %rp5, %rp5_end
                      : !crag.sampler<"audio">, i64, i64
                        -> !crag.audio<f32, 48000, 1>
    %g5         = crag.scale %raw5, %vol5
                      : !crag.audio<f32, 48000, 1>, f32
                        -> !crag.audio<f32, 48000, 1>
    %pl5        = arith.constant 0.20 : f32
    %pr5        = arith.constant 0.80 : f32
    %l5         = crag.scale %g5, %pl5 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %r5         = crag.scale %g5, %pr5 : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>

    // -------------------------------------------------------------------------
    // Mix voices and produce stereo output
    // -------------------------------------------------------------------------
    %left_sum   = crag.sum %l0, %l1, %l2, %l3, %l4, %l5
                      : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>,
                         !crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>,
                         !crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>)
                        -> !crag.audio<f32, 48000, 1>
    %right_sum  = crag.sum %r0, %r1, %r2, %r3, %r4, %r5
                      : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>,
                         !crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>,
                         !crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>)
                        -> !crag.audio<f32, 48000, 1>

    %stereo     = crag.channel_join %left_sum, %right_sum
                      : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>)
                        -> !crag.audio<f32, 48000, 2>

    crag.output %stereo : !crag.audio<f32, 48000, 2>
  }
}
