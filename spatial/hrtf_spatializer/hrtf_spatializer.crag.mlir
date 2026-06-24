// HRTF Spatializer (Naive ITD/ILD Reference)
//
// Canonical core graph defining the HRTF spatializer ABI used by all dataset-
// driven variants (e.g. SS2_HRTF, CIPIC).  This file ships a minimal, dataset-
// free reference implementation based on the Woodworth interaural time-delay
// (ITD) approximation plus a simple constant-power interaural level-difference
// (ILD) panner and inverse-distance gain.  Future variants will replace this
// "spatialize" body with dataset-driven HRIR convolution while keeping the
// same input contract and `subtype="binaural"` output, so any caller can swap
// renderers without changing wiring.
//
// Contract (the "core HRTF spatializer ABI"):
//
//   Inputs (block arguments):
//     %in : !crag.audio<f32, 0, 1>     -- mono source signal
//
//   Position (per-graph parameters; not subgraph audio inputs because
//   crag.subgraph_ref accepts only audio operands):
//     azimuth_rad     [-π, π]          0 = front, +π/2 = right, ±π = behind
//     elevation_rad   [-π/2, π/2]      0 = horizon, +π/2 = above
//     distance_m      [0.1, 10]        meters from listener (1 = neutral gain)
//
//   Output:
//     stereo binaural signal carried as
//       !crag.audio<f32, 0, 2, subtype = "binaural">
//
//   The "binaural" subtype is a free-form tag on the existing
//   AudioSignalType.subtype field (no dialect change required).  Downstream
//   visualizers and renderers may look for this subtype to distinguish
//   ear-referenced stereo from generic L/R stereo.
//
// Naive model (placeholder until dataset-driven variants land):
//
//   ITD (Woodworth approximation, head radius r ≈ 0.0875 m, c = 343 m/s):
//     itd_seconds = (r/c) · sin(azimuth) · cos(elevation)
//     itd_samples = itd_seconds · sample_rate                   (signed)
//
//   Per-ear delays, both biased by max_itd/2 of common latency so that the
//   centre position (azimuth = 0) yields equal contralateral/ipsilateral
//   read offsets and no audible asymmetry:
//
//     delay_left  = base + max_itd/2 + itd_samples/2
//     delay_right = base + max_itd/2 - itd_samples/2
//
//   ILD (constant-power lateral pan with elevation tilt):
//     pan         = sin(azimuth) · cos(elevation)               (-1..+1)
//     gain_left   = sqrt((1 - pan) / 2)
//     gain_right  = sqrt((1 + pan) / 2)
//
//   Distance attenuation (inverse-distance with safe floor):
//     dist_gain   = 1 / max(distance_m, 0.1)
//
// Buffer sizing:
//   The shared circular buffer must be at least the block size (512 samples)
//   per the CragLowerAudioToTensor underrun check, and large enough to hold
//   max_itd_samples plus the centre `base` latency.  At 48 kHz the maximum
//   ITD is r/c · sr ≈ 12.25 samples; we allocate 1024 samples of headroom.
//
// Sample rate:
//   This template is currently fixed at 48 kHz because `CragResolveAudioRates`
//   resolves placeholder zeros only on `!crag.audio` and `!crag.freq` types —
//   not on `!crag.delay`.  Hosts running at a different sample rate should
//   resample upstream of this graph (or future work can extend the rate
//   resolution pass to cover `!crag.delay` so this graph can become rate-
//   agnostic like the ambisonics utilities).
//
// Usage (after crag.include):
//   crag.include "standard-graphs/spatial/hrtf_spatializer.crag.mlir"
//                as "hrtf_spatializer"
//   ...
//   %binaural = crag.subgraph_ref "hrtf_spatializer"(%mono)
//                   : (!crag.audio<f32, 0, 1>)
//                     -> !crag.audio<f32, 0, 2, subtype = "binaural">

module {
<<<<<<< HEAD
  // Position visualizer: every HRTF spatializer renderer ships
  // the combined top/side/rear position view alongside its audio output
  // so docs pages and host UIs can inspect the source position without
  // any additional wiring.  See the four standalone
=======
  // §8 / §9 position visualizer: every HRTF spatializer renderer ships
  // the combined top/side/rear position view alongside its audio output
  // so docs pages and host UIs can inspect the source position without
  // any additional wiring.  See plan §8 and the four standalone
>>>>>>> main
  // standard-graphs/visualizers/spatial/position-{top,side,rear,combined}
  // visualizers for the projection rules.
  crag.include_visualizer "visualizers/spatial/position-combined.crag.mlir"
                          as "position_combined"

  crag.graph name = "hrtf_spatializer" sample_rate = 48000 channels = 1
      default_visualizer = "phase-correlation" {
  ^bb0(%in: !crag.audio<f32, 48000, 1>):

    // -----------------------------------------------------------------------
    // Position parameters (azimuth/elevation/distance).
    //
    // Subgraphs cannot accept non-audio block arguments, so the source
    // position is exposed via crag.param ops.  Hosts drive these like any
    // other parameter; the visualizer plan (top/left/rear/combined) reads
    // the same values to render the source position.
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
    // Constants
    // -----------------------------------------------------------------------
    %head_radius = arith.constant 0.0875 : f32  // ~ 8.75 cm
    %c_inv       = arith.constant 0.00291545 : f32  // 1 / 343 m/s
    %sr_f32      = crag.sample_rate : f32
    %half        = arith.constant 0.5 : f32
    %one         = arith.constant 1.0 : f32
    %two         = arith.constant 2.0 : f32
    %dist_floor  = arith.constant 0.1 : f32
<<<<<<< HEAD
    // Maximum valid peek_delay offset = bufSize - blockSize.  The strict
    // bounds check requires `offset ∈ [0, bufSize - blockSize]` so the
    // whole block read fits within one circular wrap.  With bufSize=1024
    // and blockSize=512 this is 512.
    %off_max_f   = arith.constant 512.0 : f32
    %off_min_f   = arith.constant 0.0 : f32
=======
    %buf_f       = arith.constant 1024.0 : f32  // bufSize as f32
>>>>>>> main

    // -----------------------------------------------------------------------
    // Trig of position
    // -----------------------------------------------------------------------
    %sin_az  = math.sin %azimuth   : f32
    %cos_el  = math.cos %elevation : f32

    // -----------------------------------------------------------------------
    // ITD: signed sample delay.  Positive = source to the right, so the
    // left ear should be delayed (we read further back in the buffer).
    //
    //   itd_seconds = (r / c) · sin(az) · cos(el)
    //   itd_samples = itd_seconds · sr
    // -----------------------------------------------------------------------
    %r_over_c    = arith.mulf %head_radius, %c_inv : f32
    %itd_sec_az  = arith.mulf %r_over_c, %sin_az   : f32
    %itd_sec     = arith.mulf %itd_sec_az, %cos_el : f32
    %itd_samp    = arith.mulf %itd_sec, %sr_f32    : f32
    %itd_half    = arith.mulf %itd_samp, %half     : f32

    // Maximum ITD (in samples) for the head_radius·sr/c bound, used to bias
    // both ears by half so neither runs out of buffer at extreme azimuths.
    %max_itd_sec  = arith.mulf %head_radius, %c_inv : f32
    %max_itd_samp = arith.mulf %max_itd_sec, %sr_f32 : f32
    %max_itd_half = arith.mulf %max_itd_samp, %half  : f32

    // Common latency base: small fixed bias so positive/negative ITDs both
    // remain inside the buffer once max_itd_half is added.  16 samples is
    // well clear of zero and cheap.
    %base_delay = arith.constant 16.0 : f32

    // delay_l = base + max_itd_half + itd_half
    %delay_l_a = arith.addf %base_delay,  %max_itd_half : f32
    %delay_l   = arith.addf %delay_l_a,   %itd_half     : f32

    // delay_r = base + max_itd_half - itd_half
    %delay_r_a = arith.addf %base_delay,  %max_itd_half : f32
    %delay_r   = arith.subf %delay_r_a,   %itd_half     : f32

<<<<<<< HEAD
    // peek_delay offset semantics: with bufSize=1024 and blockSize=512,
    // valid offsets are in [0, bufSize - blockSize] = [0, 512].  Offset 0
    // reads the oldest available block (1024 samples back from "now");
    // offset (bufSize - blockSize) reads the most-recently-pushed block
    // (0 samples of delay relative to the current input).  Hence:
    //
    //   off = (bufSize - blockSize) - delay_samples
    //       = off_max_f - delay_samples
    //
    // With delay_{l,r} ≈ 16 ± 6 samples, off ≈ 496 ± 6 — well within range.
    // The clamp guards against extreme ITD values that could otherwise drive
    // off below 0 (delay > 512) and trip the strict bounds check.
    %off_l_raw = arith.subf %off_max_f, %delay_l : f32
    %off_r_raw = arith.subf %off_max_f, %delay_r : f32
    %off_l_lo  = arith.maximumf %off_l_raw, %off_min_f : f32
    %off_r_lo  = arith.maximumf %off_r_raw, %off_min_f : f32
    %off_l_f   = arith.minimumf %off_l_lo,  %off_max_f : f32
    %off_r_f   = arith.minimumf %off_r_lo,  %off_max_f : f32
    %off_l     = arith.fptosi %off_l_f : f32 to i32
    %off_r     = arith.fptosi %off_r_f : f32 to i32
=======
    // peek_delay offset = bufSize - delay
    %off_l_f = arith.subf %buf_f, %delay_l : f32
    %off_r_f = arith.subf %buf_f, %delay_r : f32
    %off_l   = arith.fptosi %off_l_f : f32 to i32
    %off_r   = arith.fptosi %off_r_f : f32 to i32
>>>>>>> main

    // -----------------------------------------------------------------------
    // Push the dry mono input into a shared 1024-sample circular buffer
    // and peek at the per-ear offsets.
    // -----------------------------------------------------------------------
    %dl = crag.delay_line : !crag.delay<f32, 48000, 1, 1024>
    crag.push_delay %dl, %in : !crag.delay<f32, 48000, 1, 1024>,
                                !crag.audio<f32, 48000, 1>
    %tap_l = crag.peek_delay %dl, %off_l
                 : !crag.delay<f32, 48000, 1, 1024>, i32
                   -> !crag.audio<f32, 0, 1>
    %tap_r = crag.peek_delay %dl, %off_r
                 : !crag.delay<f32, 48000, 1, 1024>, i32
                   -> !crag.audio<f32, 0, 1>

    // -----------------------------------------------------------------------
    // ILD: constant-power lateral pan modulated by elevation cosine.
    //
    //   pan       = sin(az) · cos(el)            in [-1, +1]
    //   gain_left = sqrt((1 - pan) / 2)
    //   gain_right= sqrt((1 + pan) / 2)
    // -----------------------------------------------------------------------
    %pan        = arith.mulf %sin_az, %cos_el : f32

    %one_minus  = arith.subf %one, %pan : f32
    %one_plus   = arith.addf %one, %pan : f32
    %gl_sq      = arith.divf %one_minus, %two : f32
    %gr_sq      = arith.divf %one_plus,  %two : f32
    %gl_pan     = math.sqrt %gl_sq : f32
    %gr_pan     = math.sqrt %gr_sq : f32

    // -----------------------------------------------------------------------
    // Distance attenuation: inverse-distance with safe floor.
    // -----------------------------------------------------------------------
    %dist_safe  = arith.maximumf %distance, %dist_floor : f32
    %dist_gain  = arith.divf %one, %dist_safe : f32

    %gain_l     = arith.mulf %gl_pan, %dist_gain : f32
    %gain_r     = arith.mulf %gr_pan, %dist_gain : f32

    // -----------------------------------------------------------------------
    // Apply per-ear gain and join into the binaural stereo output.
    // -----------------------------------------------------------------------
    %out_l = crag.scale %tap_l, %gain_l
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %out_r = crag.scale %tap_r, %gain_r
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    %binaural = crag.channel_join %out_l, %out_r
                    : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                      -> !crag.audio<f32, 0, 2, subtype = "binaural">

    // Side-effect op: capture (azimuth, elevation, distance) into the
<<<<<<< HEAD
    // position_combined visualizer's per-instance buffer.
=======
    // position_combined visualizer's per-instance buffer (see §8).
>>>>>>> main
    crag.visualizer_ref "position_combined"(%in, %azimuth, %elevation, %distance)
        : (!crag.audio<f32, 48000, 1>, f32, f32, f32)

    crag.output %binaural : !crag.audio<f32, 0, 2, subtype = "binaural">
  }
}
