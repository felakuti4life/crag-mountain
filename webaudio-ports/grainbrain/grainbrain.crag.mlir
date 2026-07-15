// grainBrain (Crag port)
// ======================
// A Crag port of grainBrain by Kowaldo — https://tools.analogmad.com/grainBrain.html
// (alpha v.7m "MultiLayer Granular + Doppler Engine").
//
// grainBrain is a GRANULAR PROCESSOR of an external buffer (a loaded WAV or the
// live mic), not a self-contained synth: it fires overlapping windowed grains
// read from a source buffer, runs them through the DOPPLER "passes" engine
// (amplitude envelope + pitch curve + damping filter shaped like a sound source
// passing the listener), then a master effects chain (stereo feedback delay ->
// convolver reverb -> parallel waveshaper -> limiter -> output -> master
// limiter).  Bind a WAV to the "audio" sampler to hear it:
//     crag_bind_audio_by_index(0, ptr, len)
// and bind the reverb impulse response (L IR then R IR, concatenated) to "ir":
//     crag_bind_audio_by_index(1, ptr, len)   // len = 2 * per-channel taps
//
// This port reproduces, faithfully:
//   * the grain engine — up to 16 overlapping windowed resampling readers with
//     a scrub window, per-grain pitch spread, stereo scatter, and
//     grain-synchronous parameter latching (no mid-grain tearing).
//   * the DOPPLER passes engine (physical model, 'pre' routing, loop mode):
//     per-pass amplitude envelope, per-sample Doppler pitch curve integrated
//     into each grain's read cursor, log-lerp damping filter, and the
//     waveshaper's apex-proximity drive coupling.  Pass geometry (speed /
//     distance / sym / shape / amount / break) matches the page's math.
//   * the per-layer high-pass and low-pass tone filters (2nd-order biquads).
//   * the signature stereo feedback DELAY (delTime / delFb / delMix).
//   * the CONVOLVER reverb — true partitioned FFT convolution against the
//     host-generated exp-decay noise IR, exactly like ConvolverNode (the host
//     regenerates + rebinds the IR when convSize changes).
//   * the parallel WAVESHAPER (drive / tone / mix, cos/sin-law parallel mix,
//     identical curve algebra to buildWaveShaperCurve()).
//   * BOTH DynamicsCompressor limiters (soft-knee feed-forward compressors with
//     WebAudio's parameters and Chrome's ^0.6 makeup-gain law; stereo-linked
//     peak detection).
//
// Approximated / omitted (see grainBrain.webaudio.json):
//   * stochastic per-grain jitter / drift LFOs / multilayer / tremolo (off by
//     default on the page) -> omitted; grain scatter is deterministic Halton.
//   * doppler pan (panAmt, default 0) and the random pass side -> omitted.
//   * DynamicsCompressor's lookahead + adaptive release -> fixed attack/release.
//
// Everything runs stereo at 48 kHz to match the granular core.

module {
  crag.graph name = "grainbrain" sample_rate = 48000 channels = 2 {

    // =====================================================================
    // Controls  (grainBrain UI defaults — the HTML data-default values, which
    // override the JS state table on page load)
    // =====================================================================
    %grains    = crag.param_int "grains"     min = 1 max = 16 default = 16 : i32
    %grain_ms  = crag.param "grain_ms"    min = 20.0  max = 2000.0 default = 1250.0 unit = "ms" : f32
    %pitch     = crag.param "pitch"       min = -24.0 max = 24.0   default = 0.0 : f32
    %spread    = crag.param "spread"      min = 0.0   max = 1.0    default = 0.05 : f32
    %win_pos   = crag.param "window_pos"  min = 0.0   max = 1.0    default = 0.25 : f32
    %win_size  = crag.param "window_size" min = 0.01  max = 1.0    default = 0.5 : f32
    %src_gain  = crag.param "src_gain"    min = 0.0   max = 2.0    default = 1.0 : f32

    %hp_cut    = crag.param "hp_cutoff"   min = 20.0  max = 2000.0  default = 20.0    unit = "hz" : f32
    %lp_cut    = crag.param "lp_cutoff"   min = 200.0 max = 20000.0 default = 20000.0 unit = "hz" : f32

    // Doppler "passes" engine (page: dopRoute='pre', dopModel='physical',
    // dopPlayMode='loop', dampMode='peakA'; pitchTilt=0.5, pitchRangeUp=12,
    // ampIn=ampOut=1, shapeScale=0, pitchShift=0 fixed at their defaults).
    %dop_byp   = crag.param_int "dop_bypass" min = 0 max = 1 default = 0 : i32
    %dop_speed = crag.param "dop_speed"    min = 0.5  max = 80.0    default = 5.5  unit = "m/s" : f32
    %dop_dist  = crag.param "dop_distance" min = 1.0  max = 80.0    default = 2.0  unit = "m" : f32
    %dop_sym   = crag.param "dop_sym"      min = -2.0 max = 2.0     default = -0.3 : f32
    %dop_shape = crag.param "dop_shape"    min = 0.3  max = 4.0     default = 1.0 : f32
    %dop_amt   = crag.param "dop_amount"   min = 0.0  max = 1.0     default = 0.5 : f32
    %dop_brk   = crag.param "dop_brk"      min = 0.0  max = 5000.0  default = 800.0 unit = "ms" : f32
    %dop_floor = crag.param "dop_filt_floor" min = 60.0 max = 20000.0 default = 20000.0 unit = "hz" : f32
    %dop_ceil  = crag.param "dop_filt_ceil"  min = 60.0 max = 20000.0 default = 20000.0 unit = "hz" : f32

    %del_ms    = crag.param "delay_ms"    min = 0.0 max = 1900.0 default = 120.0 unit = "ms" : f32
    %del_fb    = crag.param "delay_fb"    min = 0.0 max = 0.95   default = 0.1 : f32
    %del_mix   = crag.param "delay_mix"   min = 0.0 max = 1.0    default = 0.1 : f32

    %conv_mix  = crag.param "conv_mix"    min = 0.0 max = 1.0 default = 0.06 : f32

    %ws_act    = crag.param_int "ws_active" min = 0 max = 1 default = 0 : i32
    %ws_drive  = crag.param "ws_drive"    min = 0.0 max = 1.0 default = 0.0 : f32
    %ws_tone   = crag.param "ws_tone"     min = 0.0 max = 1.0 default = 0.0 : f32
    %ws_apex   = crag.param "ws_apex"     min = 0.0 max = 1.0 default = 1.0 : f32
    %ws_mix    = crag.param "ws_mix"      min = 0.0 max = 1.0 default = 1.0 : f32

    %lim_th    = crag.param "lim_thresh"  min = -30.0 max = 0.0 default = -3.0 unit = "dB" : f32

    %output    = crag.param "output"      min = 0.0 max = 2.0 default = 1.0 : f32

    // =====================================================================
    // Samplers  (source buffer + reverb IR pack)
    // =====================================================================
    %s        = crag.sampler "audio" : !crag.sampler<"audio">
    %len_i64  = crag.sampler_length %s : !crag.sampler<"audio"> -> i64
    %c0_i64   = arith.constant 0 : i64
    %c1_i64   = arith.constant 1 : i64
    %len_ok   = arith.cmpi sgt, %len_i64, %c0_i64 : i64
    %safe_len = arith.select %len_ok, %len_i64, %c1_i64 : i64
    %len_f    = arith.sitofp %safe_len : i64 to f32

    // Reverb IR: the host binds [L taps..., R taps...] (generateIR(), Chrome
    // ConvolverNode-normalized).  Per-channel length = bound length / 2.
    %irs      = crag.sampler "ir" : !crag.sampler<"ir">
    %ir_total = crag.sampler_length %irs : !crag.sampler<"ir"> -> i64
    %c2_i64   = arith.constant 2 : i64
    %ir_len   = arith.divsi %ir_total, %c2_i64 : i64
    %ir_offL  = arith.constant 0 : i64

    // =====================================================================
    // Time
    // =====================================================================
    %sr        = crag.sample_rate : f32
    %cf        = crag.curframe : i64

    // =====================================================================
    // Shared constants + density makeup gain.  grainBrain compensates
    // polyphony with 1/sqrt(overlap) per grain (triggerGrain's
    // polyphonyCompensation); our overlap count is the `grains` param itself.
    // The makeup constant re-centres the default level to the WebAudio
    // reference; src_gain trims around it.
    // =====================================================================
    %c0f    = arith.constant 0.0 : f32
    %c1f    = arith.constant 1.0 : f32
    %c1000f = arith.constant 1000.0 : f32
    %norm   = arith.constant 0.125 : f32
    %makeup = arith.constant 16.8 : f32

    // =====================================================================
    // Parameter smoothing.  Every control that shapes the grain sampling
    // (grain size, pitch, spread, scrub window, voice count) runs through a
    // block-rate one-pole (~25 ms) so a live knob move GLIDES instead of
    // tearing the grains.  Combined with the per-grain parameter LATCHING
    // below (each grain freezes its sampling params for its whole life), a
    // grain_ms / pitch / window move only takes effect at the next grain,
    // never mid-grain (which tore severely on the old design).
    // =====================================================================
    %sm = arith.constant 25.0 : f32
    %grain_ms_s = crag.smooth %grain_ms, %sm, %sm : f32, f32, f32 -> f32
    %pitch_s    = crag.smooth %pitch,    %sm, %sm : f32, f32, f32 -> f32
    %spread_sm  = crag.smooth %spread,   %sm, %sm : f32, f32, f32 -> f32
    %winpos_s   = crag.smooth %win_pos,  %sm, %sm : f32, f32, f32 -> f32
    %winsize_s  = crag.smooth %win_size, %sm, %sm : f32, f32, f32 -> f32
    %grains_f   = arith.sitofp %grains : i32 to f32
    %grains_s   = crag.smooth %grains_f, %sm, %sm : f32, f32, f32 -> f32

    // Effect controls (block-rate smoothed).
    %del_mix_s  = crag.smooth %del_mix,  %sm, %sm : f32, f32, f32 -> f32
    %conv_mix_s = crag.smooth %conv_mix, %sm, %sm : f32, f32, f32 -> f32
    %ws_drive_s = crag.smooth %ws_drive, %sm, %sm : f32, f32, f32 -> f32
    %ws_tone_s  = crag.smooth %ws_tone,  %sm, %sm : f32, f32, f32 -> f32
    %ws_mix_s   = crag.smooth %ws_mix,   %sm, %sm : f32, f32, f32 -> f32
    %ws_apex_s  = crag.smooth %ws_apex,  %sm, %sm : f32, f32, f32 -> f32
    %lim_th_s   = crag.smooth %lim_th,   %sm, %sm : f32, f32, f32 -> f32
    %dspd_s0    = crag.smooth %dop_speed, %sm, %sm : f32, f32, f32 -> f32
    %ddst_s0    = crag.smooth %dop_dist,  %sm, %sm : f32, f32, f32 -> f32
    %dsym_s     = crag.smooth %dop_sym,   %sm, %sm : f32, f32, f32 -> f32
    %dshp_s0    = crag.smooth %dop_shape, %sm, %sm : f32, f32, f32 -> f32
    %damt_s     = crag.smooth %dop_amt,   %sm, %sm : f32, f32, f32 -> f32

    // Polyphony compensation 1/sqrt(max(grains,1)) — grainBrain keeps the
    // summed level roughly constant as the voice count changes.
    %g_ge1   = arith.maximumf %grains_s, %c1f : f32
    %g_sqrt  = math.sqrt %g_ge1 : f32
    %gcomp   = arith.divf %c1f, %g_sqrt : f32
    %norm_mk   = arith.mulf %norm, %makeup : f32
    %norm_mkc  = arith.mulf %norm_mk, %gcomp : f32
    %norm_gain = arith.mulf %norm_mkc, %src_gain : f32

    // Per-grain pitch spread -> speed range (from the smoothed pitch/spread).
    %ln2_12   = arith.constant 0.0577623 : f32
    %sp12     = arith.constant 12.0 : f32
    %spread_semi = arith.mulf %spread_sm, %sp12 : f32
    %p_lo     = arith.subf %pitch_s, %spread_semi : f32
    %p_hi     = arith.addf %pitch_s, %spread_semi : f32
    %e_lo_x   = arith.mulf %p_lo, %ln2_12 : f32
    %e_hi_x   = arith.mulf %p_hi, %ln2_12 : f32
    %speed_min = math.exp %e_lo_x : f32
    %speed_max = math.exp %e_hi_x : f32
    %speed_rng = arith.subf %speed_max, %speed_min : f32

    // Grain length (samples) + grain frequency (Hz) from the smoothed grain_ms.
    // Clamp to the param range so the smoother's ramp-up from 0 at t=0 can't
    // divide by ~0 (which would spin the grain clock infinitely fast for a
    // block or two of startup garbage).
    %gms_lo   = arith.constant 20.0 : f32
    %gms_hi   = arith.constant 2000.0 : f32
    %gms_c0   = arith.maximumf %grain_ms_s, %gms_lo : f32
    %gms_c    = arith.minimumf %gms_c0, %gms_hi : f32
    %fhz   = arith.divf %c1000f, %gms_c : f32
    %glen  = arith.divf %sr, %fhz : f32

    // Envelope skew (symmetric, Hann-like).
    %skew   = arith.constant 0.5 : f32

    // Window geometry (scrub position/size), from the smoothed window params.
    %ws_c0     = arith.maximumf %winsize_s, %c0f : f32
    %ws_c      = arith.minimumf %ws_c0, %c1f : f32
    %win_len   = arith.mulf %ws_c, %len_f : f32
    %win_len_f = arith.maximumf %win_len, %c1f : f32
    %wp_c0     = arith.maximumf %winpos_s, %c0f : f32
    %wp_c      = arith.minimumf %wp_c0, %c1f : f32
    %max_start = arith.subf %len_f, %win_len_f : f32
    %max_start_ok = arith.maximumf %max_start, %c0f : f32
    %win_start = arith.mulf %wp_c, %max_start_ok : f32

    // Runtime grain count: ceil of the smoothed count so the fractional (top)
    // grain is spawned and faded in by its per-grain gate; clamped to [1, 16].
    %gceil  = math.ceil %grains_s : f32
    %gc_i   = arith.fptosi %gceil : f32 to i32
    %one_i32 = arith.constant 1 : i32
    %max_i32 = arith.constant 16 : i32
    %gc_lo  = arith.maxsi %gc_i, %one_i32 : i32
    %grain_count = arith.minsi %gc_lo, %max_i32 : i32

    // =====================================================================
    // DOPPLER pass geometry (block rate).  grainBrain's "passes" engine
    // (tickDopplerLive/passDoppler/passCurve, dopModel='physical'):
    //   passDur = clamp(4*distance/speed, 0.15, 15) s;   break = brk ms
    //   apex    = clamp(0.5 + sym*0.24, 0.02, 0.98)
    //   warp    = sym-skewed time warp;  d = pow(u, shape);  proximity = 1-d
    //   amp     = (1 - d^0.8) * edge fade      (ampIn = ampOut = 1)
    //   semis   = physical Doppler of a source passing at `speed` m/s at
    //             `distance` m, rescaled so the whole sweep spans
    //             pitchRangeUp (12) semitones, scaled by dopAmount.
    // The pass clock is curframe mod cycle — deterministic, no drift.
    // =====================================================================
    %c343   = arith.constant 343.0 : f32
    %c4f    = arith.constant 4.0 : f32
    %c12f   = arith.constant 12.0 : f32
    %chalf  = arith.constant 0.5 : f32
    %spd_lo = arith.constant 0.5 : f32
    %dspd_s = arith.maximumf %dspd_s0, %spd_lo : f32
    %ddst_s = arith.maximumf %ddst_s0, %c1f : f32
    %shp_lo = arith.constant 0.3 : f32
    %dshp_s = arith.maximumf %dshp_s0, %shp_lo : f32

    %pd_num   = arith.mulf %ddst_s, %c4f : f32
    %pd_raw   = arith.divf %pd_num, %dspd_s : f32
    %pd_min   = arith.constant 0.15 : f32
    %pd_max   = arith.constant 15.0 : f32
    %pd_c0    = arith.maximumf %pd_raw, %pd_min : f32
    %passDur  = arith.minimumf %pd_c0, %pd_max : f32
    %ms2s     = arith.constant 0.001 : f32
    %brk_s    = arith.mulf %dop_brk, %ms2s : f32
    %cyc_s    = arith.addf %passDur, %brk_s : f32
    %passSamps = arith.mulf %passDur, %sr : f32
    %cycSamps_raw = arith.mulf %cyc_s, %sr : f32
    %cyc_i0   = arith.fptosi %cycSamps_raw : f32 to i64
    %cyc_i    = arith.maxsi %cyc_i0, %c1_i64 : i64
    %tau_i    = arith.remsi %cf, %cyc_i : i64
    %tau_f    = arith.sitofp %tau_i : i64 to f32
    %cycSamps = arith.sitofp %cyc_i : i64 to f32

    // apex + warp exponents (warpTime()).
    %sym24    = arith.constant 0.24 : f32
    %apex_r   = arith.mulf %dsym_s, %sym24 : f32
    %apex_0   = arith.addf %chalf, %apex_r : f32
    %apex_lo  = arith.constant 0.02 : f32
    %apex_hi  = arith.constant 0.98 : f32
    %apex_c0  = arith.maximumf %apex_0, %apex_lo : f32
    %apex     = arith.minimumf %apex_c0, %apex_hi : f32
    %one_m_apex = arith.subf %c1f, %apex : f32
    %absS     = math.absf %dsym_s : f32
    %symNeg   = arith.cmpf olt, %dsym_s, %c0f : f32
    %onePabsS = arith.addf %c1f, %absS : f32
    %absS_h   = arith.mulf %absS, %chalf : f32
    %onePhalf = arith.addf %c1f, %absS_h : f32
    %invPhalf = arith.divf %c1f, %onePhalf : f32
    %expApp   = arith.select %symNeg, %onePabsS, %invPhalf : f32
    %expDep   = arith.select %symNeg, %invPhalf, %onePabsS : f32

    // physical pitch constants (pitchTilt = 0.5, pitchRangeUp = 12).
    %tilt     = arith.constant 0.51 : f32
    %pitchD   = arith.mulf %ddst_s, %tilt : f32
    %den0     = arith.subf %c343, %dspd_s : f32
    %den      = arith.maximumf %den0, %c1f : f32
    %ratioMax = arith.divf %c343, %den : f32
    %lgRM     = math.log2 %ratioMax : f32
    %trueMax  = arith.mulf %c12f, %lgRM : f32
    %tm_min   = arith.constant 0.01 : f32
    %tm_ok    = arith.cmpf ogt, %trueMax, %tm_min : f32
    %tm_safe  = arith.maximumf %trueMax, %tm_min : f32
    %sc_raw   = arith.divf %c12f, %tm_safe : f32
    %scalar   = arith.select %tm_ok, %sc_raw, %c1f : f32
    %scAmt    = arith.mulf %scalar, %damt_s : f32
    %xcoef    = arith.mulf %ddst_s, %c4f : f32

    %byp_i0   = arith.constant 0 : i32
    %byp      = arith.cmpi ne, %dop_byp, %byp_i0 : i32

    // Block-rate pass curve (for the damping filter + waveshaper proximity).
    %c0999    = arith.constant 0.999 : f32
    %tb_raw   = arith.divf %tau_f, %passSamps : f32
    %tb_c0    = arith.minimumf %tb_raw, %c0999 : f32
    %tb       = arith.maximumf %tb_c0, %c0f : f32
    %inPassB  = arith.cmpf olt, %tau_f, %passSamps : f32
    %twA_u    = arith.divf %tb, %apex : f32
    %twA_p    = math.powf %twA_u, %expApp : f32
    %twA      = arith.mulf %twA_p, %apex : f32
    %twD_n    = arith.subf %tb, %apex : f32
    %twD_u0   = arith.divf %twD_n, %one_m_apex : f32
    %twD_u    = arith.maximumf %twD_u0, %c0f : f32
    %twD_p    = math.powf %twD_u, %expDep : f32
    %twD_s    = arith.mulf %twD_p, %one_m_apex : f32
    %twD      = arith.addf %apex, %twD_s : f32
    %tbleA    = arith.cmpf ole, %tb, %apex : f32
    %twB      = arith.select %tbleA, %twA, %twD : f32
    %uA       = arith.subf %apex, %twB : f32
    %uA_n     = arith.divf %uA, %apex : f32
    %uD       = arith.subf %twB, %apex : f32
    %uD_n     = arith.divf %uD, %one_m_apex : f32
    %twLtA    = arith.cmpf olt, %twB, %apex : f32
    %uB_raw   = arith.select %twLtA, %uA_n, %uD_n : f32
    %uB_c0    = arith.maximumf %uB_raw, %c0f : f32
    %uB       = arith.minimumf %uB_c0, %c1f : f32
    %dB_      = math.powf %uB, %dshp_s : f32
    %proxRaw  = arith.subf %c1f, %dB_ : f32
    %ctrue    = arith.constant true
    %notByp   = arith.xori %byp, %ctrue : i1
    %proxGate = arith.andi %inPassB, %notByp : i1
    %proxB    = arith.select %proxGate, %proxRaw, %c0f : f32

    // Damping filter cutoff: logLerp(floor, ceil, proximity), clamped, forced
    // open on bypass (page tickDopplerLive bypass branch).
    %fl_1     = arith.maximumf %dop_floor, %c1f : f32
    %ce_1     = arith.maximumf %dop_ceil, %c1f : f32
    %lgFl     = math.log %fl_1 : f32
    %lgCe     = math.log %ce_1 : f32
    %lgD      = arith.subf %lgCe, %lgFl : f32
    %lgMix    = arith.mulf %lgD, %proxB : f32
    %lgHz     = arith.addf %lgFl, %lgMix : f32
    %fHz0     = math.exp %lgHz : f32
    %f60      = arith.constant 60.0 : f32
    %f20k     = arith.constant 20000.0 : f32
    %fHz_c0   = arith.maximumf %fHz0, %f60 : f32
    %fHz_c    = arith.minimumf %fHz_c0, %f20k : f32
    %dopHz    = arith.select %byp, %f20k, %fHz_c : f32

    // =====================================================================
    // DOPPLER per-sample control signals.  Two mono per_sample regions share
    // the same deterministic pass clock (seeded from curframe mod cycle every
    // block, +1 per sample):
    //   %dopEnv  — the pass amplitude envelope (dopplerEnvGain.gain)
    //   %dopRate — the per-sample playback-rate multiplier 2^(semis/12)
    //              (the page's 16-point setValueCurveAtTime rate curve,
    //               computed exactly instead of sampled)
    // =====================================================================
    %dummyE = crag.impulse : !crag.audio<f32, 48000, 1>
    %dopEnv, %cntE_e = crag.per_sample (%dummyE) states (%tau_f) {
      ^bbE(%dE: f32, %cnt: f32):
        %e1f   = arith.constant 1.0 : f32
        %e0f   = arith.constant 0.0 : f32
        %t_raw = arith.divf %cnt, %passSamps : f32
        %t_c0  = arith.minimumf %t_raw, %c0999 : f32
        %t     = arith.maximumf %t_c0, %e0f : f32
        %inp   = arith.cmpf olt, %cnt, %passSamps : f32
        // warpTime(t)
        %wA_u  = arith.divf %t, %apex : f32
        %wA_p  = math.powf %wA_u, %expApp : f32
        %wA    = arith.mulf %wA_p, %apex : f32
        %wD_n  = arith.subf %t, %apex : f32
        %wD_u0 = arith.divf %wD_n, %one_m_apex : f32
        %wD_u  = arith.maximumf %wD_u0, %e0f : f32
        %wD_p  = math.powf %wD_u, %expDep : f32
        %wD_s  = arith.mulf %wD_p, %one_m_apex : f32
        %wD    = arith.addf %apex, %wD_s : f32
        %tleA  = arith.cmpf ole, %t, %apex : f32
        %tw    = arith.select %tleA, %wA, %wD : f32
        // passCurve: u, d
        %puA   = arith.subf %apex, %tw : f32
        %puA_n = arith.divf %puA, %apex : f32
        %puD   = arith.subf %tw, %apex : f32
        %puD_n = arith.divf %puD, %one_m_apex : f32
        %twLt  = arith.cmpf olt, %tw, %apex : f32
        %pu_r  = arith.select %twLt, %puA_n, %puD_n : f32
        %pu_c0 = arith.maximumf %pu_r, %e0f : f32
        %pu    = arith.minimumf %pu_c0, %e1f : f32
        %pd_   = math.powf %pu, %dshp_s : f32
        // amp = 1 - d^0.8 (ampIn = ampOut = 1), floored at 0.0001
        %aExp  = arith.constant 0.8 : f32
        %dPow  = math.powf %pd_, %aExp : f32
        %amp0  = arith.subf %e1f, %dPow : f32
        %aMin  = arith.constant 1.0e-4 : f32
        %amp   = arith.maximumf %amp0, %aMin : f32
        // passMasterFade: 4% in, 6% out
        %fi_d  = arith.constant 0.04 : f32
        %fo_d  = arith.constant 0.06 : f32
        %fIn   = arith.divf %t, %fi_d : f32
        %omt   = arith.subf %e1f, %t : f32
        %fOut  = arith.divf %omt, %fo_d : f32
        %fMin  = arith.minimumf %fIn, %fOut : f32
        %fC1   = arith.minimumf %fMin, %e1f : f32
        %fade  = arith.maximumf %fC1, %e0f : f32
        %envP  = arith.mulf %amp, %fade : f32
        %envIn = arith.select %inp, %envP, %e0f : f32
        %env   = arith.select %byp, %e1f, %envIn : f32
        // advance + wrap the pass clock
        %cnt1  = arith.addf %cnt, %e1f : f32
        %wrapC = arith.cmpf oge, %cnt1, %cycSamps : f32
        %cntW  = arith.subf %cnt1, %cycSamps : f32
        %cntN  = arith.select %wrapC, %cntW, %cnt1 : f32
        crag.per_sample_yield %env, %cntN : f32, f32
    } : (!crag.audio<f32, 48000, 1>, f32) -> (!crag.audio<f32, 48000, 1>, f32)

    %dummyR = crag.impulse : !crag.audio<f32, 48000, 1>
    %dopRate, %cntR_e = crag.per_sample (%dummyR) states (%tau_f) {
      ^bbR(%dR: f32, %cnt: f32):
        %r1f   = arith.constant 1.0 : f32
        %r0f   = arith.constant 0.0 : f32
        %t_raw = arith.divf %cnt, %passSamps : f32
        %t_c0  = arith.minimumf %t_raw, %c0999 : f32
        %t     = arith.maximumf %t_c0, %r0f : f32
        %inp   = arith.cmpf olt, %cnt, %passSamps : f32
        // physical Doppler on the RAW pass time (passDoppler 'physical').
        %xr    = arith.subf %t, %apex : f32
        %x     = arith.mulf %xr, %xcoef : f32
        %x2    = arith.mulf %x, %x : f32
        %pd2   = arith.mulf %pitchD, %pitchD : f32
        %r2    = arith.addf %x2, %pd2 : f32
        %r_    = math.sqrt %r2 : f32
        %rMin  = arith.constant 1.0e-3 : f32
        %rS    = arith.maximumf %r_, %rMin : f32
        %xOr   = arith.divf %x, %rS : f32
        %vr    = arith.mulf %dspd_s, %xOr : f32
        %denR  = arith.addf %c343, %vr : f32
        %ratio = arith.divf %c343, %denR : f32
        %lgR   = math.log2 %ratio : f32
        %sem0  = arith.mulf %c12f, %lgR : f32
        %semis = arith.mulf %sem0, %scAmt : f32
        %inv12 = arith.constant 0.0833333 : f32
        %oct   = arith.mulf %semis, %inv12 : f32
        %rate0 = math.exp2 %oct : f32
        %rateP = arith.select %inp, %rate0, %r1f : f32
        %rate  = arith.select %byp, %r1f, %rateP : f32
        // advance + wrap (identical clock to the env block)
        %cnt1  = arith.addf %cnt, %r1f : f32
        %wrapC = arith.cmpf oge, %cnt1, %cycSamps : f32
        %cntW  = arith.subf %cnt1, %cycSamps : f32
        %cntN  = arith.select %wrapC, %cntW, %cnt1 : f32
        crag.per_sample_yield %rate, %cntN : f32, f32
    } : (!crag.audio<f32, 48000, 1>, f32) -> (!crag.audio<f32, 48000, 1>, f32)

    // ---------------------------------------------------------------------
    // Per-grain capture tensors (deterministic scatter — grainBrain jitters
    // these stochastically; a null test is impossible so we fix them).
    // ---------------------------------------------------------------------
    // 16-grain capture tables (Halton-scattered u* offsets + equal-power pan).
    // crag.dyn_parallel spawns only the first `grains` lines at run time.
    %t_uwin = arith.constant dense<[0.5, 0.25, 0.75, 0.125, 0.625, 0.375, 0.875, 0.0625, 0.5625, 0.3125, 0.8125, 0.1875, 0.6875, 0.4375, 0.9375, 0.0312]> : tensor<16xf32>
    %t_uspd = arith.constant dense<[0.3333, 0.6667, 0.1111, 0.4444, 0.7778, 0.2222, 0.5556, 0.8889, 0.037, 0.3704, 0.7037, 0.1481, 0.4815, 0.8148, 0.2593, 0.5926]> : tensor<16xf32>
    %t_usz  = arith.constant dense<[0.2, 0.4, 0.6, 0.8, 0.04, 0.24, 0.44, 0.64, 0.84, 0.08, 0.28, 0.48, 0.68, 0.88, 0.12, 0.32]> : tensor<16xf32>
    %t_usk  = arith.constant dense<[0.1429, 0.2857, 0.4286, 0.5714, 0.7143, 0.8571, 0.0204, 0.1633, 0.3061, 0.449, 0.5918, 0.7347, 0.8776, 0.0408, 0.1837, 0.3265]> : tensor<16xf32>
    %t_uph  = arith.constant dense<[0.0909, 0.1818, 0.2727, 0.3636, 0.4545, 0.5455, 0.6364, 0.7273, 0.8182, 0.9091, 0.0083, 0.0992, 0.1901, 0.281, 0.3719, 0.4628]> : tensor<16xf32>
    %t_panl = arith.constant dense<[0.9988, 0.9892, 0.97, 0.9415, 0.904, 0.8577, 0.8032, 0.741, 0.6716, 0.5957, 0.5141, 0.4276, 0.3369, 0.243, 0.1467, 0.0491]> : tensor<16xf32>
    %t_panr = arith.constant dense<[0.0491, 0.1467, 0.243, 0.3369, 0.4276, 0.5141, 0.5957, 0.6716, 0.741, 0.8032, 0.8577, 0.904, 0.9415, 0.97, 0.9892, 0.9988]> : tensor<16xf32>

    // =====================================================================
    // Grain engine — `grain_count` windowed resampling readers summed to stereo
    // via crag.dyn_parallel.  Each reader accumulates an exact-integer sample
    // counter (`fig`) for its envelope and a doppler-rate-integrated read
    // offset (`roff`), and re-triggers when fig reaches its own grain length.
    //
    // GRAIN-SYNCHRONOUS parameter latching: each grain LATCHES its grain length,
    // read base and playback speed at its own grain start (when fig wraps)
    // and HOLDS them for the whole grain, via per-line persistent state
    // (crag.line_load / crag.line_store).  Live moves of grain_ms / pitch /
    // window therefore only take effect at the next grain boundary — where the
    // envelope is zero — so the currently-firing grain finishes cleanly instead
    // of tearing mid-grain.  The top (fractional) grain is faded by a smooth
    // voice-count gate so changing `grains` never clicks.
    //
    // DOPPLER pitch: the per-sample %dopRate multiplier is integrated into the
    // read cursor (roff += speed * rate), exactly like the page's per-grain
    // playbackRate curve (triggerGrain's setValueCurveAtTime) but continuous.
    // (grainBrain: createBufferSource -> windowed GainNode -> StereoPanner)
    // =====================================================================
    %mix = crag.dyn_parallel %grain_count captures(
               %t_uwin, %t_uspd, %t_usz, %t_usk, %t_uph, %t_panl, %t_panr
               : tensor<16xf32>, tensor<16xf32>, tensor<16xf32>, tensor<16xf32>,
                 tensor<16xf32>, tensor<16xf32>, tensor<16xf32>)
               -> !crag.audio<f32, 48000, 2> {
      ^bb0(%i: index, %uwin: f32, %uspd: f32, %usz: f32, %usk: f32,
           %uph: f32, %panl: f32, %panr: f32):
        // Smooth voice-count fade gate: clamp(grains_smoothed - i, 0, 1).
        %ii32  = arith.index_cast %i : index to i32
        %iif   = arith.sitofp %ii32 : i32 to f32
        %gdiff = arith.subf %grains_s, %iif : f32
        %gate0 = arith.maximumf %gdiff, %c0f : f32
        %gate  = arith.minimumf %gate0, %c1f : f32
        %vol   = arith.mulf %norm_gain, %gate : f32

        // Per-line persistent grain state: fig(0) = envelope samples since this
        // grain started, its latched glen(1)/base(2)/speed(3), roff(4) = the
        // doppler-integrated read offset, and the per-line scatter sequences
        // uspd(5)/uwin(6).  fig counts exact integers (so the envelope stays
        // precise on long grains); roff integrates speed*rate per sample (the
        // doppler pitch chirp).  uspd/uwin take a golden-ratio hop at every
        // grain restart — the deterministic stand-in for the page drawing a
        // NEW random pitch offset + read jitter per grain trigger (without the
        // hop, 16 forever-fixed detunes sum coherently and ring as fixed
        // sidebands instead of the page's spectral smear).
        %fig0   = crag.line_load %i group = "grain" slot = 0 lines = 16 : index -> f32
        %glenL0 = crag.line_load %i group = "grain" slot = 1 lines = 16 : index -> f32
        %baseL0 = crag.line_load %i group = "grain" slot = 2 lines = 16 : index -> f32
        %spdL0  = crag.line_load %i group = "grain" slot = 3 lines = 16 : index -> f32
        %roff0  = crag.line_load %i group = "grain" slot = 4 lines = 16 : index -> f32
        %uspd0  = crag.line_load %i group = "grain" slot = 5 lines = 16 : index -> f32
        %uwin0  = crag.line_load %i group = "grain" slot = 6 lines = 16 : index -> f32

        %grain, %fig_e, %glenL_e, %baseL_e, %spdL_e, %roff_e, %uspd_e, %uwin_e =
            crag.per_sample (%dopRate) states (%fig0, %glenL0, %baseL0, %spdL0, %roff0, %uspd0, %uwin0) {
          ^bb1(%rateIn: f32, %fig: f32, %glenL: f32, %baseL: f32, %spdL: f32,
               %roff: f32, %uspdSt: f32, %uwinSt: f32):
            %one_f  = arith.constant 1.0 : f32
            %zero_f = arith.constant 0.0 : f32
            %one_i  = arith.constant 1 : i64
            %phi    = arith.constant 0.618034 : f32

            // Restart when the grain has run its full latched length, or on the
            // first-ever call (glenL still 0).  Latch the current smoothed params
            // then; otherwise hold the previous grain's values.
            %atEnd   = arith.cmpf oge, %fig, %glenL : f32
            %uninit  = arith.cmpf ole, %glenL, %zero_f : f32
            %restart = arith.ori %atEnd, %uninit : i1

            // Scatter-sequence hop: first-ever call seeds from the Halton
            // capture; each later restart advances u' = frac(u + phi).
            %us_h0  = arith.addf %uspdSt, %phi : f32
            %us_hf  = math.floor %us_h0 : f32
            %us_hop = arith.subf %us_h0, %us_hf : f32
            %us_new = arith.select %uninit, %uspd, %us_hop : f32
            %uspdN  = arith.select %restart, %us_new, %uspdSt : f32
            %uw_h0  = arith.addf %uwinSt, %phi : f32
            %uw_hf  = math.floor %uw_h0 : f32
            %uw_hop = arith.subf %uw_h0, %uw_hf : f32
            %uw_new = arith.select %uninit, %uwin, %uw_hop : f32
            %uwinN  = arith.select %restart, %uw_new, %uwinSt : f32

            // Per-grain values from the (hopped) scatter sequences + the
            // current smoothed ranges — latched at each grain start.
            %spd_d     = arith.mulf %uspdN, %speed_rng : f32
            %speed_cur = arith.addf %speed_min, %spd_d : f32
            %woff      = arith.mulf %uwinN, %win_len_f : f32
            %base_cur  = arith.addf %win_start, %woff : f32

            %glen_h  = arith.select %restart, %glen, %glenL : f32
            %base_h  = arith.select %restart, %base_cur, %baseL : f32
            %spd_h   = arith.select %restart, %speed_cur, %spdL : f32
            // fig for THIS sample: first-ever call -> uph*glen (staggered start
            // so the grains overlap); a normal restart -> 0; else carry.
            %stag    = arith.mulf %uph, %glen_h : f32
            %figR    = arith.select %uninit, %stag, %zero_f : f32
            %figUse  = arith.select %restart, %figR, %fig : f32
            // read offset: reset with fig (as if constant-rate from grain start)
            %roffR   = arith.mulf %spd_h, %figUse : f32
            %roffUse = arith.select %restart, %roffR, %roff : f32

            // read cursor = base_h + roff, wrapped into the buffer
            %rp  = arith.addf %base_h, %roffUse : f32
            %rm  = arith.remf %rp, %len_f : f32
            %rpl = arith.addf %rm, %len_f : f32
            %rpw = arith.remf %rpl, %len_f : f32
            %i0f = math.floor %rpw : f32
            %frac = arith.subf %rpw, %i0f : f32
            %i0  = arith.fptosi %i0f : f32 to i64
            %i1raw = arith.addi %i0, %one_i : i64
            %wrapn = arith.cmpi sge, %i1raw, %safe_len : i64
            %i1sub = arith.subi %i1raw, %safe_len : i64
            %i1  = arith.select %wrapn, %i1sub, %i1raw : i64
            %s0  = crag.sampler_read %s, %i0 : !crag.sampler<"audio">, i64 -> f32
            %s1  = crag.sampler_read %s, %i1 : !crag.sampler<"audio">, i64 -> f32
            %sdif = arith.subf %s1, %s0 : f32
            %sint = arith.mulf %frac, %sdif : f32
            %samp = arith.addf %s0, %sint : f32

            // envelope: skewed linear triangle, phase = fig/glen — matches the
            // page's 'hg' window (1 - |2t-1|), its default grain shape.
            %ph   = arith.divf %figUse, %glen_h : f32
            %rise = arith.divf %ph, %skew : f32
            %omph = arith.subf %one_f, %ph : f32
            %omsk = arith.subf %one_f, %skew : f32
            %fall = arith.divf %omph, %omsk : f32
            %trim = arith.minimumf %rise, %fall : f32
            %env  = arith.maximumf %trim, %zero_f : f32
            %outv = arith.mulf %samp, %env : f32

            // advance: fig by one envelope sample, roff by speed*dopplerRate
            %figNext = arith.addf %figUse, %one_f : f32
            %step    = arith.mulf %spd_h, %rateIn : f32
            %roffNext = arith.addf %roffUse, %step : f32
            crag.per_sample_yield %outv, %figNext, %glen_h, %base_h, %spd_h, %roffNext, %uspdN, %uwinN
                : f32, f32, f32, f32, f32, f32, f32, f32
        } : (!crag.audio<f32, 48000, 1>, f32, f32, f32, f32, f32, f32, f32)
              -> (!crag.audio<f32, 48000, 1>, f32, f32, f32, f32, f32, f32, f32)

        crag.line_store %i, %fig_e   group = "grain" slot = 0 lines = 16 : index, f32
        crag.line_store %i, %glenL_e group = "grain" slot = 1 lines = 16 : index, f32
        crag.line_store %i, %baseL_e group = "grain" slot = 2 lines = 16 : index, f32
        crag.line_store %i, %spdL_e  group = "grain" slot = 3 lines = 16 : index, f32
        crag.line_store %i, %roff_e  group = "grain" slot = 4 lines = 16 : index, f32
        crag.line_store %i, %uspd_e  group = "grain" slot = 5 lines = 16 : index, f32
        crag.line_store %i, %uwin_e  group = "grain" slot = 6 lines = 16 : index, f32

        %g     = crag.scale %grain, %vol : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
        %l     = crag.scale %g, %panl : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
        %r     = crag.scale %g, %panr : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
        %stereo = crag.channel_join %l, %r
                     : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>)
                       -> !crag.audio<f32, 48000, 2>
        crag.parallel_yield %stereo : !crag.audio<f32, 48000, 2>
    }

    // =====================================================================
    // Shared filter coefficients (per-layer HP 20 Hz + LP tone).
    // norm = cutoff / Nyquist, clamped to [0.001, 0.499].
    // Both filters are ORDER 2 (12 dB/oct) to match Web Audio's BiquadFilter,
    // which is always 2nd-order.  (An order-1 low-pass leaves far too much high
    // frequency vs the reference — measured +52 dB at 10-20 kHz with a 2 kHz LP;
    // order 2 closes that.)  grainBrain's 22 kHz LP sits above Nyquist/2, so a
    // "fully open" LP clamps near ~12 kHz.
    // =====================================================================
    %two     = arith.constant 2.0 : f32
    %nyq     = arith.divf %sr, %two : f32
    %cmin    = arith.constant 0.001 : f32
    %cmax    = arith.constant 0.499 : f32

    %hpn_raw = arith.divf %hp_cut, %nyq : f32
    %hpn_lo  = arith.maximumf %hpn_raw, %cmin : f32
    %hpn     = arith.minimumf %hpn_lo, %cmax : f32
    %fb_hp, %ff_hp = crag.get_filter_coeffs %hpn order = 2 type = "highpass"
                         : f32, !crag.coeff_vec, !crag.coeff_vec

    %lpn_raw = arith.divf %lp_cut, %nyq : f32
    %lpn_lo  = arith.maximumf %lpn_raw, %cmin : f32
    %lpn     = arith.minimumf %lpn_lo, %cmax : f32
    %fb_lp, %ff_lp = crag.get_filter_coeffs %lpn order = 2 type = "lowpass"
                         : f32, !crag.coeff_vec, !crag.coeff_vec

    // Per-layer HP -> LP on the stereo grain bus (page: layerGain -> hp -> lp
    // -> granularBus).
    %hp = crag.filter %mix, %fb_hp, %ff_hp
              : (!crag.audio<f32, 48000, 2>, !crag.coeff_vec, !crag.coeff_vec) -> !crag.audio<f32, 48000, 2>
    %lp = crag.filter %hp, %fb_lp, %ff_lp
              : (!crag.audio<f32, 48000, 2>, !crag.coeff_vec, !crag.coeff_vec) -> !crag.audio<f32, 48000, 2>

    // =====================================================================
    // DOPPLER routing 'pre' (page default): granularBus -> dopplerEnvGain ->
    // dopplerFilter -> busFx.  The env is a per-sample signal; the filter is
    // a block-rate lowpass whose cutoff log-lerps floor->ceil by proximity
    // (dampMode 'peakA').  Everything below runs as two mono rails (WebAudio's
    // nodes process stereo channel-wise; only the compressors are linked).
    // =====================================================================
    %dopn_raw = arith.divf %dopHz, %nyq : f32
    %dopn_lo  = arith.maximumf %dopn_raw, %cmin : f32
    %dopn     = arith.minimumf %dopn_lo, %cmax : f32
    %fb_dop, %ff_dop = crag.get_filter_coeffs %dopn order = 2 type = "lowpass"
                           : f32, !crag.coeff_vec, !crag.coeff_vec

    %lpL = crag.channel_slice %lp, 0 : !crag.audio<f32, 48000, 2> -> !crag.audio<f32, 48000, 1>
    %lpR = crag.channel_slice %lp, 1 : !crag.audio<f32, 48000, 2> -> !crag.audio<f32, 48000, 1>

    %envL = crag.per_sample (%lpL, %dopEnv) states () {
      ^bbEL(%x: f32, %e: f32):
        %y = arith.mulf %x, %e : f32
        crag.per_sample_yield %y : f32
    } : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
    %envR = crag.per_sample (%lpR, %dopEnv) states () {
      ^bbER(%x: f32, %e: f32):
        %y = arith.mulf %x, %e : f32
        crag.per_sample_yield %y : f32
    } : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>

    %dfL = crag.filter %envL, %fb_dop, %ff_dop
              : (!crag.audio<f32, 48000, 1>, !crag.coeff_vec, !crag.coeff_vec) -> !crag.audio<f32, 48000, 1>
    %dfR = crag.filter %envR, %fb_dop, %ff_dop
              : (!crag.audio<f32, 48000, 1>, !crag.coeff_vec, !crag.coeff_vec) -> !crag.audio<f32, 48000, 1>

    // =====================================================================
    // Signature stereo feedback delay (delTime / delFb / delMix),
    // SAMPLE-ACCURATE: each channel runs its feedback loop inside a per_sample
    // region driving a crag.short_delay (arbitrary sub-block delay times).
    //   per sample:  tail = short_delay(x, fb, delay_samps)
    //                out  = dry*x + mix*tail
    // =====================================================================
    %ms_scale   = arith.constant 0.001 : f32
    %sr_ms      = arith.mulf %sr, %ms_scale : f32
    %draw       = arith.mulf %del_ms, %sr_ms : f32
    %del_samps  = arith.fptosi %draw : f32 to i32
    %del_dry    = arith.subf %c1f, %del_mix_s : f32

    %delL = crag.per_sample (%dfL) states () {
      ^bbL(%xL: f32):
        %tL  = crag.short_delay %xL, %del_fb, %del_samps { max_samples = 96000 } : (f32, f32, i32) -> f32
        %wL  = arith.mulf %tL, %del_mix_s : f32
        %dL  = arith.mulf %xL, %del_dry : f32
        %yL  = arith.addf %dL, %wL : f32
        crag.per_sample_yield %yL : f32
    } : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>

    %delR = crag.per_sample (%dfR) states () {
      ^bbR2(%xR: f32):
        %tR  = crag.short_delay %xR, %del_fb, %del_samps { max_samples = 96000 } : (f32, f32, i32) -> f32
        %wR  = arith.mulf %tR, %del_mix_s : f32
        %dR  = arith.mulf %xR, %del_dry : f32
        %yR  = arith.addf %dR, %wR : f32
        crag.per_sample_yield %yR : f32
    } : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>

    // =====================================================================
    // CONVOLVER reverb (ConvolverNode with a 2-channel exp-decay noise IR).
    // True partitioned-FFT convolution per channel against the host-bound IR
    // pack ([L taps..., R taps...]); dry/wet like the page's convDry/convWet.
    // num_partitions = 384 caps the IR at 2.048 s per channel at a 256 block
    // (the page's convSize default is 1.6 s).
    // =====================================================================
    %cvL = crag.overlap_save_conv_slice %delL, %irs, %ir_offL, %ir_len num_partitions = 384
               : !crag.audio<f32, 48000, 1>, !crag.sampler<"ir">, i64, i64 -> !crag.audio<f32, 48000, 1>
    %cvR = crag.overlap_save_conv_slice %delR, %irs, %ir_len, %ir_len num_partitions = 384
               : !crag.audio<f32, 48000, 1>, !crag.sampler<"ir">, i64, i64 -> !crag.audio<f32, 48000, 1>

    %conv_dry = arith.subf %c1f, %conv_mix_s : f32
    %cdL = crag.scale %delL, %conv_dry : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %cwL = crag.scale %cvL, %conv_mix_s : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %cxL = crag.sum %cdL, %cwL : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
    %cdR = crag.scale %delR, %conv_dry : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %cwR = crag.scale %cvR, %conv_mix_s : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %cxR = crag.sum %cdR, %cwR : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>

    // =====================================================================
    // Parallel WAVESHAPER (buildWaveShaperCurve + tickWaveShaper):
    //   preGain  = (1 + drive*8) * (1 + wsApex*proximity*2)   [active only]
    //   curve(x) : tone<0.5  ->  blend(tanh-soft, cubic)
    //              tone>=0.5 ->  blend(cubic, hard-clip)      on x clamped ±1
    //   postGain = 1/(1 + drive*6)
    //   out      = dry*cos(mix*π/2) + shaped*sin(mix*π/2)     [cos/sin law]
    // Inactive (page default): dry = 1, wet = 0 — bit-transparent.
    // =====================================================================
    %wsA      = arith.cmpi ne, %ws_act, %byp_i0 : i32
    %kdrv     = arith.mulf %ws_drive_s, %two : f32
    %onepk    = arith.addf %c1f, %kdrv : f32
    %t1k      = math.tanh %onepk : f32
    %kc_raw   = arith.constant 0.1 : f32
    %kc0      = arith.mulf %kdrv, %kc_raw : f32
    %kc       = arith.minimumf %kc0, %c1f : f32
    %c8f      = arith.constant 8.0 : f32
    %drv8     = arith.mulf %ws_drive_s, %c8f : f32
    %baseDrv  = arith.addf %c1f, %drv8 : f32
    %apx2     = arith.mulf %ws_apex_s, %proxB : f32
    %apx2x    = arith.mulf %apx2, %two : f32
    %apxG     = arith.addf %c1f, %apx2x : f32
    %preP     = arith.mulf %baseDrv, %apxG : f32
    %pre      = arith.select %wsA, %preP, %c1f : f32
    %c6f      = arith.constant 6.0 : f32
    %drv6     = arith.mulf %ws_drive_s, %c6f : f32
    %onep6    = arith.addf %c1f, %drv6 : f32
    %postA    = arith.divf %c1f, %onep6 : f32
    %dmin     = arith.constant 0.001 : f32
    %drvTiny  = arith.cmpf olt, %ws_drive_s, %dmin : f32
    %wsOff    = arith.xori %wsA, %ctrue : i1
    %ident    = arith.ori %drvTiny, %wsOff : i1
    %post     = arith.select %ident, %c1f, %postA : f32
    %hpi      = arith.constant 1.5707963 : f32
    %ang      = arith.mulf %ws_mix_s, %hpi : f32
    %cosA     = math.cos %ang : f32
    %sinA     = math.sin %ang : f32
    %dryG     = arith.select %wsA, %cosA, %c1f : f32
    %wetG     = arith.select %wsA, %sinA, %c0f : f32
    %tlo      = arith.mulf %ws_tone_s, %two : f32
    %th_r     = arith.subf %ws_tone_s, %chalf : f32
    %thi      = arith.mulf %th_r, %two : f32
    %toneLo   = arith.cmpf olt, %ws_tone_s, %chalf : f32

    %wsL = crag.per_sample (%cxL) states () {
      ^bbWL(%x: f32):
        %w1  = arith.constant 1.0 : f32
        %wm1 = arith.constant -1.0 : f32
        %xp  = arith.mulf %x, %pre : f32
        %xc0 = arith.maximumf %xp, %wm1 : f32
        %xc  = arith.minimumf %xc0, %w1 : f32
        %sarg = arith.mulf %xc, %onepk : f32
        %sth  = math.tanh %sarg : f32
        %soft = arith.divf %sth, %t1k : f32
        %x2   = arith.mulf %xc, %xc : f32
        %ch15 = arith.constant 1.5 : f32
        %ch05 = arith.constant 0.5 : f32
        %x2kc = arith.mulf %x2, %kc : f32
        %hx2  = arith.mulf %x2kc, %ch05 : f32
        %cub0 = arith.subf %ch15, %hx2 : f32
        %cubic = arith.mulf %xc, %cub0 : f32
        %hc0  = arith.maximumf %sarg, %wm1 : f32
        %hard = arith.minimumf %hc0, %w1 : f32
        %omtl = arith.subf %w1, %tlo : f32
        %y1a  = arith.mulf %soft, %omtl : f32
        %y1b  = arith.mulf %cubic, %tlo : f32
        %y1   = arith.addf %y1a, %y1b : f32
        %omth = arith.subf %w1, %thi : f32
        %y2a  = arith.mulf %cubic, %omth : f32
        %y2b  = arith.mulf %hard, %thi : f32
        %y2   = arith.addf %y2a, %y2b : f32
        %yc   = arith.select %toneLo, %y1, %y2 : f32
        %ycI  = arith.select %ident, %xc, %yc : f32
        %y    = arith.mulf %ycI, %post : f32
        %dry  = arith.mulf %x, %dryG : f32
        %wet  = arith.mulf %y, %wetG : f32
        %out  = arith.addf %dry, %wet : f32
        crag.per_sample_yield %out : f32
    } : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>

    %wsR = crag.per_sample (%cxR) states () {
      ^bbWR(%x: f32):
        %w1  = arith.constant 1.0 : f32
        %wm1 = arith.constant -1.0 : f32
        %xp  = arith.mulf %x, %pre : f32
        %xc0 = arith.maximumf %xp, %wm1 : f32
        %xc  = arith.minimumf %xc0, %w1 : f32
        %sarg = arith.mulf %xc, %onepk : f32
        %sth  = math.tanh %sarg : f32
        %soft = arith.divf %sth, %t1k : f32
        %x2   = arith.mulf %xc, %xc : f32
        %ch15 = arith.constant 1.5 : f32
        %ch05 = arith.constant 0.5 : f32
        %x2kc = arith.mulf %x2, %kc : f32
        %hx2  = arith.mulf %x2kc, %ch05 : f32
        %cub0 = arith.subf %ch15, %hx2 : f32
        %cubic = arith.mulf %xc, %cub0 : f32
        %hc0  = arith.maximumf %sarg, %wm1 : f32
        %hard = arith.minimumf %hc0, %w1 : f32
        %omtl = arith.subf %w1, %tlo : f32
        %y1a  = arith.mulf %soft, %omtl : f32
        %y1b  = arith.mulf %cubic, %tlo : f32
        %y1   = arith.addf %y1a, %y1b : f32
        %omth = arith.subf %w1, %thi : f32
        %y2a  = arith.mulf %cubic, %omth : f32
        %y2b  = arith.mulf %hard, %thi : f32
        %y2   = arith.addf %y2a, %y2b : f32
        %yc   = arith.select %toneLo, %y1, %y2 : f32
        %ycI  = arith.select %ident, %xc, %yc : f32
        %y    = arith.mulf %ycI, %post : f32
        %dry  = arith.mulf %x, %dryG : f32
        %wet  = arith.mulf %y, %wetG : f32
        %out  = arith.addf %dry, %wet : f32
        crag.per_sample_yield %out : f32
    } : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>

    // =====================================================================
    // LIMITER (DynamicsCompressor, threshold = lim_thresh; WebAudio defaults
    // knee 30, ratio 12, attack 3 ms, release 250 ms) followed by the output
    // gain, then the MASTER LIMITER (thr -0.3, knee 5, ratio 6, attack 5 ms,
    // release 150 ms).  Both are stereo-linked soft-knee feed-forward peak
    // compressors with Chrome's fixed makeup law  makeup = (1/G(0dB))^0.6.
    // (Approximation: no lookahead, fixed rather than adaptive release.)
    // =====================================================================
    %lg2_10_20 = arith.constant 0.166096 : f32   // log2(10)/20
    %db_per_lg2 = arith.constant 6.0206 : f32    // 20*log10(2)

    // limiter constants
    %kneeL   = arith.constant 30.0 : f32
    %ratioL  = arith.constant 12.0 : f32
    %invRL   = arith.constant 0.0833333 : f32    // 1/12
    %aAtkL   = arith.constant 0.9930618 : f32    // exp(-1/(0.003*48000))
    %aRelL   = arith.constant 0.9999167 : f32    // exp(-1/(0.25*48000))
    // makeup from G(0dB): over2 = -2*thr; knee region when over2 <= 30.
    %mThrN   = arith.subf %c0f, %lim_th_s : f32          // -thr >= 0
    %mOver2  = arith.mulf %mThrN, %two : f32
    %mKneeHalf = arith.constant 15.0 : f32
    %mArg    = arith.addf %mThrN, %mKneeHalf : f32       // 0 - thr + knee/2
    %mArg2   = arith.mulf %mArg, %mArg : f32
    %cKneeL  = arith.constant -0.0152778 : f32           // (1/12-1)/(2*30)
    %mGknee  = arith.mulf %mArg2, %cKneeL : f32
    %mGabove0 = arith.mulf %mThrN, %invRL : f32          // (0-thr)/R
    %mGabove = arith.subf %lim_th_s, %mGabove0 : f32
    %mGabove1 = arith.addf %mGabove, %mThrN : f32        // thr + (0-thr)/R - 0...
    // NOTE: aboveG(0) = thr + (0-thr)/R - 0 = thr - thr/R
    %mInKnee = arith.cmpf ole, %mOver2, %kneeL : f32
    %mG0     = arith.select %mInKnee, %mGknee, %mGabove1 : f32
    %mMakeDb = arith.constant -0.6 : f32
    %mMk0    = arith.mulf %mG0, %mMakeDb : f32
    %mMkOct  = arith.mulf %mMk0, %lg2_10_20 : f32
    %makeupL = math.exp2 %mMkOct : f32

    %cLim0   = arith.constant 0 : index
    %limEnv0 = crag.line_load %cLim0 group = "lim" slot = 0 lines = 1 : index -> f32
    %limGain, %limEnv1 = crag.per_sample (%wsL, %wsR) states (%limEnv0) {
      ^bbLG(%xl: f32, %xr: f32, %ev: f32):
        %l1 = arith.constant 1.0 : f32
        %al = math.absf %xl : f32
        %ar = math.absf %xr : f32
        %lvl = arith.maximumf %al, %ar : f32
        %atk = arith.cmpf ogt, %lvl, %ev : f32
        %coef = arith.select %atk, %aAtkL, %aRelL : f32
        %dv  = arith.subf %ev, %lvl : f32
        %dvc = arith.mulf %coef, %dv : f32
        %ev1 = arith.addf %lvl, %dvc : f32
        %eMin = arith.constant 1.0e-5 : f32
        %evc = arith.maximumf %ev1, %eMin : f32
        %lg  = math.log2 %evc : f32
        %lvlDb = arith.mulf %lg, %db_per_lg2 : f32
        %ovr = arith.subf %lvlDb, %lim_th_s : f32
        %ovr2 = arith.mulf %ovr, %two : f32
        %negK = arith.constant -30.0 : f32
        %below = arith.cmpf olt, %ovr2, %negK : f32
        %inKn  = arith.cmpf ole, %ovr2, %kneeL : f32
        %kh    = arith.constant 15.0 : f32
        %kArg  = arith.addf %ovr, %kh : f32
        %kArg2 = arith.mulf %kArg, %kArg : f32
        %gKnee = arith.mulf %kArg2, %cKneeL : f32
        %ovrR  = arith.mulf %ovr, %invRL : f32
        %gAb0  = arith.addf %lim_th_s, %ovrR : f32
        %gAb   = arith.subf %gAb0, %lvlDb : f32
        %z0    = arith.constant 0.0 : f32
        %gSel  = arith.select %inKn, %gKnee, %gAb : f32
        %gDb   = arith.select %below, %z0, %gSel : f32
        %gOct  = arith.mulf %gDb, %lg2_10_20 : f32
        %glin  = math.exp2 %gOct : f32
        crag.per_sample_yield %glin, %ev1 : f32, f32
    } : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>, f32)
          -> (!crag.audio<f32, 48000, 1>, f32)
    crag.line_store %cLim0, %limEnv1 group = "lim" slot = 0 lines = 1 : index, f32

    // Lookahead: WebAudio's compressor applies its gain ~6 ms AHEAD of the
    // audio (Chrome's pre-delay buffer), which is what stops attack
    // overshoots.  Delay the audio path 256 samples against the detector
    // (short_delay with zero feedback = a pure delay line).
    %laZero  = arith.constant 0.0 : f32
    %laSamps = arith.constant 256 : i32
    %limLm = crag.per_sample (%wsL, %limGain) states () {
      ^bbLL(%x: f32, %g: f32):
        %xd = crag.short_delay %x, %laZero, %laSamps { max_samples = 512 } : (f32, f32, i32) -> f32
        %y = arith.mulf %xd, %g : f32
        crag.per_sample_yield %y : f32
    } : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
    %limRm = crag.per_sample (%wsR, %limGain) states () {
      ^bbLR(%x: f32, %g: f32):
        %xd = crag.short_delay %x, %laZero, %laSamps { max_samples = 512 } : (f32, f32, i32) -> f32
        %y = arith.mulf %xd, %g : f32
        crag.per_sample_yield %y : f32
    } : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
    %limL = crag.scale %limLm, %makeupL : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %limR = crag.scale %limRm, %makeupL : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>

    // Output gain (page: bus.gain), between the two compressors.
    %outL0 = crag.scale %limL, %output : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %outR0 = crag.scale %limR, %output : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>

    // MASTER LIMITER: thr -0.3, knee 5, ratio 6, atk 5 ms, rel 150 ms.
    // makeup = (1/G(0dB))^0.6 = 1.0462 (constant).
    %mthr    = arith.constant -0.3 : f32
    %mknee   = arith.constant 5.0 : f32
    %mInvR   = arith.constant 0.1666667 : f32    // 1/6
    %mAtk    = arith.constant 0.9958420 : f32    // exp(-1/(0.005*48000))
    %mRel    = arith.constant 0.9998611 : f32    // exp(-1/(0.15*48000))
    %cKneeM  = arith.constant -0.0833333 : f32   // (1/6-1)/(2*5)
    %makeupM = arith.constant 1.0462 : f32

    %cLim1   = arith.constant 0 : index
    %mstEnv0 = crag.line_load %cLim1 group = "lim" slot = 1 lines = 1 : index -> f32
    %mstGain, %mstEnv1 = crag.per_sample (%outL0, %outR0) states (%mstEnv0) {
      ^bbMG(%xl: f32, %xr: f32, %ev: f32):
        %al = math.absf %xl : f32
        %ar = math.absf %xr : f32
        %lvl = arith.maximumf %al, %ar : f32
        %atk = arith.cmpf ogt, %lvl, %ev : f32
        %coef = arith.select %atk, %mAtk, %mRel : f32
        %dv  = arith.subf %ev, %lvl : f32
        %dvc = arith.mulf %coef, %dv : f32
        %ev1 = arith.addf %lvl, %dvc : f32
        %eMin = arith.constant 1.0e-5 : f32
        %evc = arith.maximumf %ev1, %eMin : f32
        %lg  = math.log2 %evc : f32
        %lvlDb = arith.mulf %lg, %db_per_lg2 : f32
        %ovr = arith.subf %lvlDb, %mthr : f32
        %ovr2 = arith.mulf %ovr, %two : f32
        %negK = arith.constant -5.0 : f32
        %below = arith.cmpf olt, %ovr2, %negK : f32
        %inKn  = arith.cmpf ole, %ovr2, %mknee : f32
        %kh    = arith.constant 2.5 : f32
        %kArg  = arith.addf %ovr, %kh : f32
        %kArg2 = arith.mulf %kArg, %kArg : f32
        %gKnee = arith.mulf %kArg2, %cKneeM : f32
        %ovrR  = arith.mulf %ovr, %mInvR : f32
        %gAb0  = arith.addf %mthr, %ovrR : f32
        %gAb   = arith.subf %gAb0, %lvlDb : f32
        %z0    = arith.constant 0.0 : f32
        %gSel  = arith.select %inKn, %gKnee, %gAb : f32
        %gDb   = arith.select %below, %z0, %gSel : f32
        %gOct  = arith.mulf %gDb, %lg2_10_20 : f32
        %glin  = math.exp2 %gOct : f32
        crag.per_sample_yield %glin, %ev1 : f32, f32
    } : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>, f32)
          -> (!crag.audio<f32, 48000, 1>, f32)
    crag.line_store %cLim1, %mstEnv1 group = "lim" slot = 1 lines = 1 : index, f32

    %mstLm = crag.per_sample (%outL0, %mstGain) states () {
      ^bbML(%x: f32, %g: f32):
        %xd = crag.short_delay %x, %laZero, %laSamps { max_samples = 512 } : (f32, f32, i32) -> f32
        %y = arith.mulf %xd, %g : f32
        crag.per_sample_yield %y : f32
    } : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
    %mstRm = crag.per_sample (%outR0, %mstGain) states () {
      ^bbMR(%x: f32, %g: f32):
        %xd = crag.short_delay %x, %laZero, %laSamps { max_samples = 512 } : (f32, f32, i32) -> f32
        %y = arith.mulf %xd, %g : f32
        crag.per_sample_yield %y : f32
    } : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
    %finL = crag.scale %mstLm, %makeupM : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>
    %finR = crag.scale %mstRm, %makeupM : !crag.audio<f32, 48000, 1>, f32 -> !crag.audio<f32, 48000, 1>

    %final = crag.channel_join %finL, %finR
                 : (!crag.audio<f32, 48000, 1>, !crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 2>

    crag.output %final : !crag.audio<f32, 48000, 2>
  }
}
