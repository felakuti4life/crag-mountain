// Sinc Pitch Shifter (two read-head, windowed-sinc resampler)
//
// Time-domain pitch shifter that transposes a mono signal by up to +/-2 octaves
// WITHOUT changing its duration.  Input samples are streamed into a circular
// delay buffer; a read pointer advances at the pitch ratio r = 2^(semitones/12)
// while the write pointer advances at 1x, so the read/write gap (the delay)
// ramps by (1 - r) each output sample.  When that gap sweeps past the buffer
// span it wraps, which would click -- so TWO read heads offset by half the
// window (1024 samples) are cross-faded with a Hann window whose two
// lobes sum to unity, hiding the wrap.
//
// Each read head lands at a FRACTIONAL delay, reconstructed by the sinc
// resampler: a 4-tap Hann-windowed sinc interpolation kernel
//     y = sum_k x[n - (m + k)] * w(f - k) / sum_k w(f - k),   k in {-1,0,1,2}
//     w(a) = sinc(a) * 0.5*(1 + cos((pi/2) a)),   sinc(a) = sin(pi a)/(pi a)
// evaluated per output sample (m = floor(delay), f = frac(delay)).  The four
// integer taps are read from independent single-sample-stepped ring buffers
// (crag.short_delay, feedback 0) fed the same input, so tap d returns x[n-d].
//
// Because the read pointer moves continuously the transposition is smooth
// across block boundaries; the phase accumulator persists across crag_process
// blocks via crag.line_load / crag.line_store (group "pitch", slot 0).
//
// This is the classic real-time TIME-DOMAIN (granular / delay-line) approach to
// pitch shifting -- the method behind hardware harmonizers and most guitar-pedal
// "pitch"/"octave" effects -- built on windowed-sinc fractional resampling.  Its
// character and limitations follow from that lineage:
//
//   * FORMANTS ARE NOT PRESERVED.  A resampler scales the whole spectrum, so
//     large shifts give the "chipmunk" (up) / "monster" (down) timbre.  Use a
//     phase vocoder or PSOLA if formant-independent shifting is required.
//   * PITCH IS NOT SAMPLE-EXACT ON STEADY TONES.  Every crossfaded granular
//     shifter has a residual, input-frequency-dependent tuning error (the two
//     read heads are a fixed fraction of a period apart, so their splice pulls
//     the phase unless the grain happens to be pitch-synchronous).  On a pure
//     sine the transposition typically lands within a few percent of the ideal
//     ratio and warbles gently; on rich program material it is far less audible.
//     This graph is intended for musical transposition, doubling, detune, and
//     harmony -- NOT for tuning-critical monophonic correction (use PSOLA for
//     that).  Larger GRAIN windows reduce the tuning error at the cost of more
//     transient smearing.
//
// Parameters:
//   semitones  [-24, 24]  transposition in semitones      (default 0 = bypass)
//   mix        [0, 1]     dry/wet blend (1 = fully shifted, 0 = dry)  (default 1)
//
// NOTE: the read-head buffers are 4096 samples; the crossfade window (grain) is
// 2048 samples (~43 ms at 48 kHz).  The graph is pinned to mono at 48 kHz
// (crag.short_delay requires a single-channel per_sample body).  At semitones=0
// the ratio is 1.0 and the output is the input delayed by half the grain window.
//
// Usage (after crag.include):
//   %out = crag.subgraph_ref "sinc_pitch_shifter"(%in)
//              : (!crag.audio<f32, 48000, 1>) -> !crag.audio<f32, 48000, 1>
//
//   crag.include "standard-graphs/resamplers/sinc-pitch-shifter.crag.mlir"
//               as "sinc_pitch_shifter"

module {
  crag.graph name = "sinc_pitch_shifter" sample_rate = 48000 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 48000, 1>):

    // ---- parameters ----
    %semis = crag.param "semitones" min = -24.0 max = 24.0 default = 0.0 unit = "st" : f32
    %mix   = crag.param "mix"       min = 0.0   max = 1.0  default = 1.0 : f32

    // ratio r = 2^(semitones / 12); phase increment per sample = 1 - r.
    %inv12   = arith.constant 0.0833333358 : f32
    %oct     = arith.mulf %semis, %inv12 : f32
    %ratio   = math.exp2 %oct : f32
    %onef    = arith.constant 1.0 : f32
    %delta   = arith.subf %onef, %ratio : f32
    %mixdry  = arith.subf %onef, %mix : f32

    // persistent read/write-gap phase accumulator (survives across blocks).
    %c0  = arith.constant 0 : index
    %ph0 = crag.line_load %c0 group = "pitch" slot = 0 lines = 1 : index -> f32

    %shift, %phe = crag.per_sample (%in) states (%ph0) {
      ^bb(%x: f32, %ph: f32):
        // region-shared constants
        %pi     = arith.constant 3.14159265 : f32
        %halfpi = arith.constant 1.57079633 : f32
        %two    = arith.constant 2.0 : f32
        %one    = arith.constant 1.0 : f32
        %half   = arith.constant 0.5 : f32
        %eps    = arith.constant 1.0e-6 : f32
        %z0     = arith.constant 0.0 : f32
        %i1     = arith.constant 1 : i32
        %i2     = arith.constant 2 : i32
        %Wr     = arith.constant 2048.0 : f32
        %halfWr = arith.constant 1024.0 : f32
        %twoPiOverW = arith.constant 3.0679615758e-03 : f32

        // head B delay = wrap(ph + W/2) into [0, W)
        %phB0  = arith.addf %ph, %halfWr : f32
        %phB_ge = arith.cmpf oge, %phB0, %Wr : f32
        %phB_s  = arith.subf %phB0, %Wr : f32
        %phB    = arith.select %phB_ge, %phB_s, %phB0 : f32
        // ---- read head A: fractional delay = %ph ----
        %A_mi = arith.fptosi %ph : f32 to i32
        %A_mf = arith.sitofp %A_mi : i32 to f32
        %A_f  = arith.subf %ph, %A_mf : f32
        %A_dm1 = arith.subi %A_mi, %i1 : i32
        %A_d1  = arith.addi %A_mi, %i1 : i32
        %A_d2  = arith.addi %A_mi, %i2 : i32
        %A_tm1 = crag.short_delay %x, %z0, %A_dm1 { max_samples = 4096 } : (f32, f32, i32) -> f32
        %A_t0  = crag.short_delay %x, %z0, %A_mi  { max_samples = 4096 } : (f32, f32, i32) -> f32
        %A_t1  = crag.short_delay %x, %z0, %A_d1  { max_samples = 4096 } : (f32, f32, i32) -> f32
        %A_t2  = crag.short_delay %x, %z0, %A_d2  { max_samples = 4096 } : (f32, f32, i32) -> f32
        %A_am1 = arith.addf %A_f, %one : f32
        %A_a1  = arith.subf %A_f, %one : f32
        %A_a2  = arith.subf %A_f, %two : f32
        %A_wm1_pa   = arith.mulf %pi, %A_am1 : f32
        %A_wm1_sin  = math.sin %A_wm1_pa : f32
        %A_wm1_sc0  = arith.divf %A_wm1_sin, %A_wm1_pa : f32
        %A_wm1_aab  = math.absf %A_am1 : f32
        %A_wm1_tiny = arith.cmpf olt, %A_wm1_aab, %eps : f32
        %A_wm1_sinc = arith.select %A_wm1_tiny, %one, %A_wm1_sc0 : f32
        %A_wm1_wpa  = arith.mulf %halfpi, %A_am1 : f32
        %A_wm1_wco  = math.cos %A_wm1_wpa : f32
        %A_wm1_w1c  = arith.addf %one, %A_wm1_wco : f32
        %A_wm1_win  = arith.mulf %half, %A_wm1_w1c : f32
        %A_wm1_w    = arith.mulf %A_wm1_sinc, %A_wm1_win : f32
        %A_w0_pa   = arith.mulf %pi, %A_f : f32
        %A_w0_sin  = math.sin %A_w0_pa : f32
        %A_w0_sc0  = arith.divf %A_w0_sin, %A_w0_pa : f32
        %A_w0_aab  = math.absf %A_f : f32
        %A_w0_tiny = arith.cmpf olt, %A_w0_aab, %eps : f32
        %A_w0_sinc = arith.select %A_w0_tiny, %one, %A_w0_sc0 : f32
        %A_w0_wpa  = arith.mulf %halfpi, %A_f : f32
        %A_w0_wco  = math.cos %A_w0_wpa : f32
        %A_w0_w1c  = arith.addf %one, %A_w0_wco : f32
        %A_w0_win  = arith.mulf %half, %A_w0_w1c : f32
        %A_w0_w    = arith.mulf %A_w0_sinc, %A_w0_win : f32
        %A_w1_pa   = arith.mulf %pi, %A_a1 : f32
        %A_w1_sin  = math.sin %A_w1_pa : f32
        %A_w1_sc0  = arith.divf %A_w1_sin, %A_w1_pa : f32
        %A_w1_aab  = math.absf %A_a1 : f32
        %A_w1_tiny = arith.cmpf olt, %A_w1_aab, %eps : f32
        %A_w1_sinc = arith.select %A_w1_tiny, %one, %A_w1_sc0 : f32
        %A_w1_wpa  = arith.mulf %halfpi, %A_a1 : f32
        %A_w1_wco  = math.cos %A_w1_wpa : f32
        %A_w1_w1c  = arith.addf %one, %A_w1_wco : f32
        %A_w1_win  = arith.mulf %half, %A_w1_w1c : f32
        %A_w1_w    = arith.mulf %A_w1_sinc, %A_w1_win : f32
        %A_w2_pa   = arith.mulf %pi, %A_a2 : f32
        %A_w2_sin  = math.sin %A_w2_pa : f32
        %A_w2_sc0  = arith.divf %A_w2_sin, %A_w2_pa : f32
        %A_w2_aab  = math.absf %A_a2 : f32
        %A_w2_tiny = arith.cmpf olt, %A_w2_aab, %eps : f32
        %A_w2_sinc = arith.select %A_w2_tiny, %one, %A_w2_sc0 : f32
        %A_w2_wpa  = arith.mulf %halfpi, %A_a2 : f32
        %A_w2_wco  = math.cos %A_w2_wpa : f32
        %A_w2_w1c  = arith.addf %one, %A_w2_wco : f32
        %A_w2_win  = arith.mulf %half, %A_w2_w1c : f32
        %A_w2_w    = arith.mulf %A_w2_sinc, %A_w2_win : f32
        %A_sw01 = arith.addf %A_wm1_w, %A_w0_w : f32
        %A_sw23 = arith.addf %A_w1_w, %A_w2_w : f32
        %A_sw   = arith.addf %A_sw01, %A_sw23 : f32
        %A_pm1  = arith.mulf %A_tm1, %A_wm1_w : f32
        %A_p0   = arith.mulf %A_t0,  %A_w0_w : f32
        %A_p1   = arith.mulf %A_t1,  %A_w1_w : f32
        %A_p2   = arith.mulf %A_t2,  %A_w2_w : f32
        %A_n01  = arith.addf %A_pm1, %A_p0 : f32
        %A_n23  = arith.addf %A_p1,  %A_p2 : f32
        %A_num  = arith.addf %A_n01, %A_n23 : f32
        %A_val  = arith.divf %A_num, %A_sw : f32
        %A_epa  = arith.mulf %twoPiOverW, %ph : f32
        %A_eco  = math.cos %A_epa : f32
        %A_e1c  = arith.subf %one, %A_eco : f32
        %A_env  = arith.mulf %half, %A_e1c : f32

        // ---- read head B: fractional delay = %phB ----
        %B_mi = arith.fptosi %phB : f32 to i32
        %B_mf = arith.sitofp %B_mi : i32 to f32
        %B_f  = arith.subf %phB, %B_mf : f32
        %B_dm1 = arith.subi %B_mi, %i1 : i32
        %B_d1  = arith.addi %B_mi, %i1 : i32
        %B_d2  = arith.addi %B_mi, %i2 : i32
        %B_tm1 = crag.short_delay %x, %z0, %B_dm1 { max_samples = 4096 } : (f32, f32, i32) -> f32
        %B_t0  = crag.short_delay %x, %z0, %B_mi  { max_samples = 4096 } : (f32, f32, i32) -> f32
        %B_t1  = crag.short_delay %x, %z0, %B_d1  { max_samples = 4096 } : (f32, f32, i32) -> f32
        %B_t2  = crag.short_delay %x, %z0, %B_d2  { max_samples = 4096 } : (f32, f32, i32) -> f32
        %B_am1 = arith.addf %B_f, %one : f32
        %B_a1  = arith.subf %B_f, %one : f32
        %B_a2  = arith.subf %B_f, %two : f32
        %B_wm1_pa   = arith.mulf %pi, %B_am1 : f32
        %B_wm1_sin  = math.sin %B_wm1_pa : f32
        %B_wm1_sc0  = arith.divf %B_wm1_sin, %B_wm1_pa : f32
        %B_wm1_aab  = math.absf %B_am1 : f32
        %B_wm1_tiny = arith.cmpf olt, %B_wm1_aab, %eps : f32
        %B_wm1_sinc = arith.select %B_wm1_tiny, %one, %B_wm1_sc0 : f32
        %B_wm1_wpa  = arith.mulf %halfpi, %B_am1 : f32
        %B_wm1_wco  = math.cos %B_wm1_wpa : f32
        %B_wm1_w1c  = arith.addf %one, %B_wm1_wco : f32
        %B_wm1_win  = arith.mulf %half, %B_wm1_w1c : f32
        %B_wm1_w    = arith.mulf %B_wm1_sinc, %B_wm1_win : f32
        %B_w0_pa   = arith.mulf %pi, %B_f : f32
        %B_w0_sin  = math.sin %B_w0_pa : f32
        %B_w0_sc0  = arith.divf %B_w0_sin, %B_w0_pa : f32
        %B_w0_aab  = math.absf %B_f : f32
        %B_w0_tiny = arith.cmpf olt, %B_w0_aab, %eps : f32
        %B_w0_sinc = arith.select %B_w0_tiny, %one, %B_w0_sc0 : f32
        %B_w0_wpa  = arith.mulf %halfpi, %B_f : f32
        %B_w0_wco  = math.cos %B_w0_wpa : f32
        %B_w0_w1c  = arith.addf %one, %B_w0_wco : f32
        %B_w0_win  = arith.mulf %half, %B_w0_w1c : f32
        %B_w0_w    = arith.mulf %B_w0_sinc, %B_w0_win : f32
        %B_w1_pa   = arith.mulf %pi, %B_a1 : f32
        %B_w1_sin  = math.sin %B_w1_pa : f32
        %B_w1_sc0  = arith.divf %B_w1_sin, %B_w1_pa : f32
        %B_w1_aab  = math.absf %B_a1 : f32
        %B_w1_tiny = arith.cmpf olt, %B_w1_aab, %eps : f32
        %B_w1_sinc = arith.select %B_w1_tiny, %one, %B_w1_sc0 : f32
        %B_w1_wpa  = arith.mulf %halfpi, %B_a1 : f32
        %B_w1_wco  = math.cos %B_w1_wpa : f32
        %B_w1_w1c  = arith.addf %one, %B_w1_wco : f32
        %B_w1_win  = arith.mulf %half, %B_w1_w1c : f32
        %B_w1_w    = arith.mulf %B_w1_sinc, %B_w1_win : f32
        %B_w2_pa   = arith.mulf %pi, %B_a2 : f32
        %B_w2_sin  = math.sin %B_w2_pa : f32
        %B_w2_sc0  = arith.divf %B_w2_sin, %B_w2_pa : f32
        %B_w2_aab  = math.absf %B_a2 : f32
        %B_w2_tiny = arith.cmpf olt, %B_w2_aab, %eps : f32
        %B_w2_sinc = arith.select %B_w2_tiny, %one, %B_w2_sc0 : f32
        %B_w2_wpa  = arith.mulf %halfpi, %B_a2 : f32
        %B_w2_wco  = math.cos %B_w2_wpa : f32
        %B_w2_w1c  = arith.addf %one, %B_w2_wco : f32
        %B_w2_win  = arith.mulf %half, %B_w2_w1c : f32
        %B_w2_w    = arith.mulf %B_w2_sinc, %B_w2_win : f32
        %B_sw01 = arith.addf %B_wm1_w, %B_w0_w : f32
        %B_sw23 = arith.addf %B_w1_w, %B_w2_w : f32
        %B_sw   = arith.addf %B_sw01, %B_sw23 : f32
        %B_pm1  = arith.mulf %B_tm1, %B_wm1_w : f32
        %B_p0   = arith.mulf %B_t0,  %B_w0_w : f32
        %B_p1   = arith.mulf %B_t1,  %B_w1_w : f32
        %B_p2   = arith.mulf %B_t2,  %B_w2_w : f32
        %B_n01  = arith.addf %B_pm1, %B_p0 : f32
        %B_n23  = arith.addf %B_p1,  %B_p2 : f32
        %B_num  = arith.addf %B_n01, %B_n23 : f32
        %B_val  = arith.divf %B_num, %B_sw : f32
        %B_epa  = arith.mulf %twoPiOverW, %phB : f32
        %B_eco  = math.cos %B_epa : f32
        %B_e1c  = arith.subf %one, %B_eco : f32
        %B_env  = arith.mulf %half, %B_e1c : f32

        // cross-fade the two heads (Hann lobes sum to unity)
        %wetA = arith.mulf %A_env, %A_val : f32
        %wetB = arith.mulf %B_env, %B_val : f32
        %wet  = arith.addf %wetA, %wetB : f32

        // dry/wet blend
        %wetm = arith.mulf %mix, %wet : f32
        %drym = arith.mulf %mixdry, %x : f32
        %out  = arith.addf %wetm, %drym : f32

        // advance + wrap phase into [0, W)
        %ph1   = arith.addf %ph, %delta : f32
        %ge    = arith.cmpf oge, %ph1, %Wr : f32
        %ph1s  = arith.subf %ph1, %Wr : f32
        %ph1a  = arith.select %ge, %ph1s, %ph1 : f32
        %lt    = arith.cmpf olt, %ph1a, %z0 : f32
        %ph1aw = arith.addf %ph1a, %Wr : f32
        %phn   = arith.select %lt, %ph1aw, %ph1a : f32

        crag.per_sample_yield %out, %phn : f32, f32
    } : (!crag.audio<f32, 48000, 1>, f32) -> (!crag.audio<f32, 48000, 1>, f32)

    crag.line_store %c0, %phe group = "pitch" slot = 0 lines = 1 : index, f32

    crag.output %shift : !crag.audio<f32, 48000, 1>
  }
}
