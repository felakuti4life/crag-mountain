// Granulator 2
//
// A modern, N-grain granular synthesizer (N = 8) written against the
// mature Crag IR.  Every grain draws an *individual* value from a
// user-controlled [min, max] range for its playback speed, grain size
// (envelope period) and envelope skew, so the grain cloud is genuinely
// heterogeneous rather than copies of one voice.
//
// The grains share one crag.parallel body parameterised by a line index;
// each grain's distinct values arrive as capture tensors (u_win, u_spd, ...).
// crag-unroll-parallel expands the constant line count into 8 independent
// inlined grains at compile time.
//
// Each grain is a genuine *per-sample* resampling reader: inside a
// crag.per_sample region the read cursor advances by the grain's `speed`
// every output sample (with linear interpolation between neighbouring
// source samples) and the grain envelope is evaluated per sample.  This is
// what makes playback speed actually re-pitch the grain — a plain block
// read (crag.sample) can only advance the head one native sample per output
// sample, so it neither re-pitches nor stays continuous when the block
// start jumps.
//
// The read cursor is *derived from the envelope phase* rather than run as an
// independent free-running head:
//
//     read = base + speed * phase * grain_len_samples
//
// so each grain reads `grain_len_samples * speed` contiguous source samples
// starting at `base`, and the cursor snaps back to `base` exactly when the
// envelope phase wraps 0 — i.e. precisely where the envelope is ≈ 0.  The
// only read-position discontinuity therefore always coincides with an
// envelope zero, which makes every grain seam inaudible.  `base` places the
// grain within the scrub window (window_pos / window_size) with a per-grain
// scatter offset.
//
// The single per-sample state (envelope phase) is *seeded* each block from
// the absolute time, so it needs no cross-block storage and is continuous by
// construction: block N+1's seed equals block N's end-of-block phase.
//
// Controls
// --------
//   grains        [1, 8]      number of grains audible at once (runtime int)
//   window_pos    [0, 1]      scrub position of the source window (left edge)
//   window_size   [0.01, 1]   width of the source window as a fraction of the file
//   speed_min/max [-2, 2]     playback-speed range; grain i advances the read
//                             head at speed_i samples / output sample
//   grain_ms_min/max [20,500] grain duration range in ms (sets the envelope rate)
//   skew_min/max  [0.05,0.95] envelope skew range; 0.5 = symmetric, < 0.5 = fast
//                             attack / slow decay, > 0.5 = slow attack / fast decay
//   output_gain   [0, 2]      overall output level
//
// Each grain i derives value_i = min + u_i * (max - min) from its per-grain
// spread factor u_i; a runtime `grains` count gates which grains are audible
// (grain i is silent when i >= grains).
//
// Sampler:  "audio" - bind a WAV via crag_bind_audio_by_index(0, ptr, len).
// Output:   !crag.audio<f32, 48000, 2> - stereo.
//
// Visualizer: "granulator2_viz" - source waveform + scrub window + live grains.

module {
  crag.include_visualizer "granulation/granulator2-viz.crag.mlir"
      as "granulator2_viz"

  crag.graph name = "granulator2" sample_rate = 48000 channels = 2
      default_visualizer = "granulator2_viz" {

    // ---------------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------------
    %grains      = crag.param_int "grains"      min = 1 max = 8 default = 6 : i32
    %window_pos  = crag.param "window_pos"   min = 0.0   max = 1.0   default = 0.1 : f32
    %window_size = crag.param "window_size"  min = 0.01  max = 1.0   default = 0.25 : f32
    %speed_min   = crag.param "speed_min"    min = -2.0  max = 2.0   default = 1.0 : f32
    %speed_max   = crag.param "speed_max"    min = -2.0  max = 2.0   default = 1.0 : f32
    %gms_min     = crag.param "grain_ms_min" min = 20.0  max = 500.0 default = 80.0  unit = "ms" : f32
    %gms_max     = crag.param "grain_ms_max" min = 20.0  max = 500.0 default = 140.0 unit = "ms" : f32
    %skew_min    = crag.param "skew_min"     min = 0.05  max = 0.95  default = 0.5 : f32
    %skew_max    = crag.param "skew_max"     min = 0.05  max = 0.95  default = 0.5 : f32
    %output_gain = crag.param "output_gain"  min = 0.0   max = 2.0   default = 0.7 : f32

    // ---------------------------------------------------------------------
    // Sampler and length guard
    // ---------------------------------------------------------------------
    %s        = crag.sampler "audio" : !crag.sampler<"audio">
    %len_i64  = crag.sampler_length %s : !crag.sampler<"audio"> -> i64
    %c0_i64   = arith.constant 0 : i64
    %c1_i64   = arith.constant 1 : i64
    %len_ok   = arith.cmpi sgt, %len_i64, %c0_i64 : i64
    %safe_len = arith.select %len_ok, %len_i64, %c1_i64 : i64
    %len_f    = arith.sitofp %safe_len : i64 to f32

    // ---------------------------------------------------------------------
    // Time
    // ---------------------------------------------------------------------
    %frame   = crag.curframe : i64
    %frame_f = arith.sitofp %frame : i64 to f32
    %curtime   = crag.curtime : f64
    %curtime_f = arith.truncf %curtime : f64 to f32
    %sr        = crag.sample_rate : f32

    // ---------------------------------------------------------------------
    // Shared constants
    // ---------------------------------------------------------------------
    %c0f       = arith.constant 0.0 : f32
    %c1f       = arith.constant 1.0 : f32
    %c1000f    = arith.constant 1000.0 : f32
    %skew_lo   = arith.constant 0.02 : f32
    %skew_hi   = arith.constant 0.98 : f32
    %norm      = arith.constant 0.125 : f32   // 1 / N
    %norm_gain = arith.mulf %norm, %output_gain : f32

    // ---------------------------------------------------------------------
    // Window geometry (shared by every grain)
    //   window_len   = clamp(window_size,0,1) * len
    //   window_start = clamp(window_pos,0,1) * (len - window_len)
    // Grains are scattered across [window_start, window_start + window_len);
    // each grain then reads *forward* from its base at the grain's speed.
    // ---------------------------------------------------------------------
    %ws_c0     = arith.maximumf %window_size, %c0f : f32
    %ws_c      = arith.minimumf %ws_c0, %c1f : f32
    %win_len   = arith.mulf %ws_c, %len_f : f32
    %win_len_f = arith.maximumf %win_len, %c1f : f32   // avoid 0-width window
    %wp_c0     = arith.maximumf %window_pos, %c0f : f32
    %wp_c      = arith.minimumf %wp_c0, %c1f : f32
    %max_start = arith.subf %len_f, %win_len_f : f32
    %max_start_ok = arith.maximumf %max_start, %c0f : f32
    %win_start = arith.mulf %wp_c, %max_start_ok : f32

    // Per-grain speed / size / skew ranges
    %speed_rng = arith.subf %speed_max, %speed_min : f32
    %gms_rng   = arith.subf %gms_max, %gms_min : f32
    %skew_rng  = arith.subf %skew_max, %skew_min : f32

    // ---------------------------------------------------------------------
    // Per-grain capture tensors (one value per grain line)
    // ---------------------------------------------------------------------
    %lines  = arith.constant 8 : index
    %t_uwin = arith.constant dense<[0.0, 0.63, 0.27, 0.85, 0.12, 0.74, 0.42, 0.95]> : tensor<8xf32>
    %t_uspd = arith.constant dense<[0.5, 0.18, 0.83, 0.35, 0.66, 0.05, 0.95, 0.42]> : tensor<8xf32>
    %t_usz  = arith.constant dense<[0.3, 0.72, 0.1, 0.55, 0.9, 0.22, 0.66, 0.44]> : tensor<8xf32>
    %t_usk  = arith.constant dense<[0.5, 0.25, 0.8, 0.4, 0.65, 0.15, 0.9, 0.55]> : tensor<8xf32>
    %t_uph  = arith.constant dense<[0.0, 0.37, 0.71, 0.13, 0.55, 0.88, 0.29, 0.62]> : tensor<8xf32>
    %t_panl = arith.constant dense<[0.9724, 0.9239, 0.8526, 0.7604, 0.6494, 0.5225, 0.3827, 0.2334]> : tensor<8xf32>
    %t_panr = arith.constant dense<[0.2334, 0.3827, 0.5225, 0.6494, 0.7604, 0.8526, 0.9239, 0.9724]> : tensor<8xf32>

    // ---------------------------------------------------------------------
    // One grain body, summed over 8 parallel lines -> stereo
    // ---------------------------------------------------------------------
    %mix = crag.parallel %lines captures(
               %t_uwin, %t_uspd, %t_usz, %t_usk, %t_uph, %t_panl, %t_panr
               : tensor<8xf32>, tensor<8xf32>, tensor<8xf32>, tensor<8xf32>,
                 tensor<8xf32>, tensor<8xf32>, tensor<8xf32>)
               -> !crag.audio<f32, 48000, 2> {
      ^bb0(%i: index, %uwin: f32, %uspd: f32, %usz: f32, %usk: f32,
           %uph: f32, %panl: f32, %panr: f32):
        // per-grain speed / grain size / skew
        %spd_d = arith.mulf %uspd, %speed_rng : f32
        %speed = arith.addf %speed_min, %spd_d : f32
        %sz_d  = arith.mulf %usz, %gms_rng : f32
        %gms   = arith.addf %gms_min, %sz_d : f32
        %fhz   = arith.divf %c1000f, %gms : f32
        %dph   = arith.divf %fhz, %sr : f32           // env phase step / sample
        %glen  = arith.divf %sr, %fhz : f32           // grain length in samples
        %sk_d  = arith.mulf %usk, %skew_rng : f32
        %skewr = arith.addf %skew_min, %sk_d : f32
        %skewc = arith.maximumf %skewr, %skew_lo : f32
        %skew  = arith.minimumf %skewc, %skew_hi : f32

        // Envelope phase seed for this block: ph0 = frac(fhz*curtime + uph)
        %praw  = arith.mulf %fhz, %curtime_f : f32
        %pph   = arith.addf %praw, %uph : f32
        %pfl   = math.floor %pph : f32
        %ph0   = arith.subf %pph, %pfl : f32

        // Grain read base (float source index): scrub window start + this
        // grain's fixed scatter offset within the window.
        %woff  = arith.mulf %uwin, %win_len_f : f32
        %base  = arith.addf %win_start, %woff : f32
        // per-sample read step = speed * grain_len, folded into the phase.
        %step  = arith.mulf %speed, %glen : f32

        // Active gate: grain i is silent when i >= grains.
        %ii    = arith.index_cast %i : index to i32
        %on    = arith.cmpi slt, %ii, %grains : i32
        %gate  = arith.select %on, %c1f, %c0f : f32
        %vol   = arith.mulf %gate, %norm_gain : f32

        // Per-sample grain: interpolated read + per-sample envelope.  The
        // read cursor is derived from the phase, so it snaps back to `base`
        // exactly at the envelope zero.
        %dummy = crag.impulse : !crag.audio<f32, 48000, 1>
        %grain, %ph_end =
            crag.per_sample (%dummy) states (%ph0) {
          ^bb1(%d: f32, %ph: f32):
            %one_f  = arith.constant 1.0 : f32
            %zero_f = arith.constant 0.0 : f32
            %one_i  = arith.constant 1 : i64

            // Read cursor within the grain: rp = base + step*ph, wrapped into
            // the whole asset [0, len) so it is always in bounds.
            %off   = arith.mulf %step, %ph : f32
            %rp    = arith.addf %base, %off : f32
            %rm    = arith.remf %rp, %len_f : f32
            %rpl   = arith.addf %rm, %len_f : f32
            %rpw   = arith.remf %rpl, %len_f : f32
            %i0f   = math.floor %rpw : f32
            %frac  = arith.subf %rpw, %i0f : f32
            %i0    = arith.fptosi %i0f : f32 to i64
            %i1raw = arith.addi %i0, %one_i : i64
            %wrapn = arith.cmpi sge, %i1raw, %safe_len : i64
            %i1sub = arith.subi %i1raw, %safe_len : i64
            %i1    = arith.select %wrapn, %i1sub, %i1raw : i64
            %s0    = crag.sampler_read %s, %i0 : !crag.sampler<"audio">, i64 -> f32
            %s1    = crag.sampler_read %s, %i1 : !crag.sampler<"audio">, i64 -> f32
            %sdif  = arith.subf %s1, %s0 : f32
            %sint  = arith.mulf %frac, %sdif : f32
            %samp  = arith.addf %s0, %sint : f32

            // Skewed-triangle envelope, squared: env = max(0, min(ph/skew,
            // (1-ph)/(1-skew)))^2
            %rise  = arith.divf %ph, %skew : f32
            %omph  = arith.subf %one_f, %ph : f32
            %omsk  = arith.subf %one_f, %skew : f32
            %fall  = arith.divf %omph, %omsk : f32
            %trim  = arith.minimumf %rise, %fall : f32
            %tri   = arith.maximumf %trim, %zero_f : f32
            %env   = arith.mulf %tri, %tri : f32
            %outv  = arith.mulf %samp, %env : f32

            // Advance envelope phase (wrap [0, 1)) by dph.
            %phadv = arith.addf %ph, %dph : f32
            %phfl  = math.floor %phadv : f32
            %phnext = arith.subf %phadv, %phfl : f32

            crag.per_sample_yield %outv, %phnext : f32, f32
        } : (!crag.audio<f32, 48000, 1>, f32)
              -> (!crag.audio<f32, 48000, 1>, f32)

        %g     = crag.scale %grain, %vol : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
        %l     = crag.scale %g, %panl : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
        %r     = crag.scale %g, %panr : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
        %stereo = crag.channel_join %l, %r
                     : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>)
                       -> !crag.audio<f32, 48000, 2>
        crag.parallel_yield %stereo : !crag.audio<f32, 48000, 2>
    }

    crag.output %mix : !crag.audio<f32, 48000, 2>
  }
}
