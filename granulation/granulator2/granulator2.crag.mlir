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

    // ---------------------------------------------------------------------
    // Shared constants
    // ---------------------------------------------------------------------
    %c0f       = arith.constant 0.0 : f32
    %c1f       = arith.constant 1.0 : f32
    %c1000f    = arith.constant 1000.0 : f32
    %large_i64 = arith.constant 65536 : i64
    %skew_lo   = arith.constant 0.02 : f32
    %skew_hi   = arith.constant 0.98 : f32
    %norm      = arith.constant 0.125 : f32   // 1 / N
    %norm_gain = arith.mulf %norm, %output_gain : f32

    // ---------------------------------------------------------------------
    // Window geometry (shared by every grain)
    //   window_len   = clamp(window_size,0,1) * len
    //   window_start = clamp(window_pos,0,1) * (len - window_len)
    // ---------------------------------------------------------------------
    %ws_c0     = arith.maximumf %window_size, %c0f : f32
    %ws_c      = arith.minimumf %ws_c0, %c1f : f32
    %win_len   = arith.mulf %ws_c, %len_f : f32
    %win_len_ok = arith.maximumf %win_len, %c1f : f32   // avoid 0-width window
    %wp_c0     = arith.maximumf %window_pos, %c0f : f32
    %wp_c      = arith.minimumf %wp_c0, %c1f : f32
    %max_start = arith.subf %len_f, %win_len_ok : f32
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
        %sk_d  = arith.mulf %usk, %skew_rng : f32
        %skewr = arith.addf %skew_min, %sk_d : f32
        %skewc = arith.maximumf %skewr, %skew_lo : f32
        %skew  = arith.minimumf %skewc, %skew_hi : f32
        // envelope: env = (max(0, min(ph/skew, (1-ph)/(1-skew))))^2
        %praw  = arith.mulf %fhz, %curtime_f : f32
        %pph   = arith.addf %praw, %uph : f32
        %pfl   = math.floor %pph : f32
        %ph    = arith.subf %pph, %pfl : f32
        %rise  = arith.divf %ph, %skew : f32
        %omph  = arith.subf %c1f, %ph : f32
        %omsk  = arith.subf %c1f, %skew : f32
        %fall  = arith.divf %omph, %omsk : f32
        %trim  = arith.minimumf %rise, %fall : f32
        %tri   = arith.maximumf %trim, %c0f : f32
        %env   = arith.mulf %tri, %tri : f32
        // read position within the window
        %woff  = arith.mulf %uwin, %win_len_ok : f32
        %adv   = arith.mulf %frame_f, %speed : f32
        %lraw  = arith.addf %woff, %adv : f32
        %lm    = arith.remf %lraw, %win_len_ok : f32
        %lp    = arith.addf %lm, %win_len_ok : f32
        %local = arith.remf %lp, %win_len_ok : f32
        %pos   = arith.addf %win_start, %local : f32
        %st    = arith.fptosi %pos : f32 to i64
        %end   = arith.addi %st, %large_i64 : i64
        %raw   = crag.sample %s, %st, %end
                     : !crag.sampler<"audio">, i64, i64 -> !crag.audio<f32, 48000, 1>
        // active gate: grain i is silent when i >= grains
        %ii    = arith.index_cast %i : index to i32
        %on    = arith.cmpi slt, %ii, %grains : i32
        %gate  = arith.select %on, %c1f, %c0f : f32
        %ev    = arith.mulf %env, %gate : f32
        %vol   = arith.mulf %ev, %norm_gain : f32
        %g     = crag.scale %raw, %vol : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
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
