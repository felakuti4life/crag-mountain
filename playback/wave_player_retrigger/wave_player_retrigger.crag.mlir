// Wave Player Retrigger
//
// A wave_player variant that adds a sample-accurate seek event.  The graph
// otherwise behaves identically to wave_player: looping playback with
// start/stop gating and a bound "audio" sampler asset.
//
// The key difference is that playback position is maintained by an internal
// per-sample accumulator rather than being derived from crag.curframe.  This
// allows the `seek` event to jump the read head to an arbitrary time in the
// asset within the same audio block it fires.
//
// Seek semantics:
//   When `seek` fires with value `t` (in seconds), the read position is set
//   so that the sample at the event's intra-block offset `seek_at` reads from
//   frame floor(t * sample_rate) of the bound asset.  Samples earlier in the
//   same block that have already been computed are left unchanged (they played
//   from the pre-seek position).
//
// Position accumulator precision:
//   The accumulator is f32.  f32 can represent every integer frame exactly up
//   to 2^24 = 16,777,216 frames (≈ 349 s at 48 kHz).  Beyond that boundary
//   successive integer values are no longer representable, so sub-sample drift
//   can accumulate.  For typical instrument assets this is not a concern; for
//   very long non-looping playback, firing `seek` resets the accumulator and
//   restores full precision.
//
// Parameters:
//   loop  [0, 1]  — 1 = loop continuously, 0 = play once (default 1)
//
// Events:
//   start (void)         — resume / un-mute playback
//   stop  (void)         — pause / mute playback
//   seek  (event_float)  — seek to t seconds into the asset (f32 seconds)
//
// Sampler:
//   "audio" — bind a WAV file via crag_bind_audio_by_index(0, ptr, len)
//
// Output: !crag.audio<f32, 0, 1> — mono audio (or silence when muted / past end)
//
// Usage (after crag.include):
//   crag.include "standard-graphs/playback/wave_player_retrigger.crag.mlir"
//       as "wave_player_retrigger"
//   ...
//   %audio = crag.subgraph_ref "wave_player_retrigger"()
//                : () -> !crag.audio<f32, 0, 1>

module {
  crag.graph name = "wave_player_retrigger" sample_rate = 0 channels = 1 {

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    %loop = crag.param "loop" min = 0.0 max = 1.0 default = 1.0 : f32

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    %start_fired, %start_at = crag.event_void "start" : i1, i32
    %stop_fired,  %stop_at  = crag.event_void "stop"  : i1, i32

    // seek: fires with the desired playback time in seconds.  Range hint spans
    // a typical clip length so the host knob lands in seconds, not 0..1.
    %seek_fired, %seek_at, %seek_val = crag.event_float "seek" min = 0.0 max = 30.0 : i1, i32, f32

    // SR latch: set by "start", reset by "stop".
    // Initialised to 1 so playback begins immediately.
    %playing    = crag.latch %start_fired, %stop_fired : i1, i1 -> i1
    %playing_f32 = arith.uitofp %playing : i1 to f32

    // -------------------------------------------------------------------------
    // Sampler
    // -------------------------------------------------------------------------
    %s   = crag.sampler "audio" : !crag.sampler<"audio">
    %len = crag.sampler_length %s : !crag.sampler<"audio"> -> i64

    // Guard against zero-length asset.
    %c0      = arith.constant 0   : i64
    %c1      = arith.constant 1   : i64
    %half    = arith.constant 0.5 : f32
    %len_ok  = arith.cmpi sgt, %len, %c0 : i64
    %safe_len = arith.select %len_ok, %len, %c1 : i64

    // -------------------------------------------------------------------------
    // Seek target in frames (f32)
    // -------------------------------------------------------------------------
    // Convert seek_val (seconds) to frames.  Computed at block rate; the
    // per-sample loop captures it to reset the accumulator at seek_at.
    %sr_f32     = crag.sample_rate : f32
    %target_f32 = arith.mulf %seek_val, %sr_f32 : f32

    // -------------------------------------------------------------------------
    // Block-size helpers
    // -------------------------------------------------------------------------
    %bs_i64 = crag.block_size : i64
    %bs_f32 = arith.sitofp %bs_i64 : i64 to f32
    %bs_i32 = arith.trunci %bs_i64 : i64 to i32

    // -------------------------------------------------------------------------
    // Per-sample position accumulator
    // -------------------------------------------------------------------------
    // State 1 (%s0_pos / %pos_end_f): f32 frame count, advanced by 1 each
    //   sample and reset to (target+1) at the seek event's sample offset so
    //   that the read position at seek_at equals floor(seek_val * sr).
    // State 2 (%s0_idx / %idx_hold): i32 within-block sample counter used to
    //   identify the exact sample at which the seek event fires.
    %dummy  = crag.impulse : !crag.audio<f32, 0, 1>
    %s0_pos = arith.constant 0.0 : f32
    %s0_idx = arith.constant 0   : i32

    %dummy_out, %pos_end_f, %idx_hold =
        crag.per_sample (%dummy) states (%s0_pos, %s0_idx) {
    ^bb0(%x: f32, %cur_pos_f: f32, %idx: i32):
      // Advance frame counter by one sample.
      %one_f  = arith.constant 1.0 : f32
      %next_f = arith.addf %cur_pos_f, %one_f : f32

      // When seek fires at this sample, jump the counter to target + 1.
      // (After this sample the counter equals target+1, so the block start
      //  computed below lands exactly on target at sample seek_at.)
      %is_seek  = arith.cmpi eq, %idx, %seek_at : i32
      %do_seek  = arith.andi %seek_fired, %is_seek : i1
      %seek_nxt = arith.addf %target_f32, %one_f : f32
      %new_pos  = arith.select %do_seek, %seek_nxt, %next_f : f32

      // Within-block sample counter, wrapping at block_size.
      %one_i32  = arith.constant 1   : i32
      %raw_idx  = arith.addi %idx, %one_i32 : i32
      %next_idx = arith.remsi %raw_idx, %bs_i32 : i32

      crag.per_sample_yield %x, %new_pos, %next_idx : f32, f32, i32
    } : (!crag.audio<f32, 0, 1>, f32, i32) -> (!crag.audio<f32, 0, 1>, f32, i32)

    // -------------------------------------------------------------------------
    // Derive the block start position
    // -------------------------------------------------------------------------
    // %pos_end_f is the accumulator value AFTER the last sample of this block,
    // i.e. the start position of the next block.  Subtracting block_size
    // gives the start frame for crag.sample this block.
    %pos_start_f   = arith.subf %pos_end_f, %bs_f32 : f32
    %pos_start_i64 = arith.fptosi %pos_start_f : f32 to i64

    // -------------------------------------------------------------------------
    // Loop mode: wrap position modulo asset length
    // -------------------------------------------------------------------------
    %loop_on = arith.cmpf ogt, %loop, %half : f32

    // Signed-safe positive modulo: handles the (rare) case where a seek fires
    // mid-block with a target near frame 0, yielding a negative block start.
    %pos_mod_raw = arith.remsi %pos_start_i64, %safe_len : i64
    %is_neg      = arith.cmpi slt, %pos_mod_raw, %c0 : i64
    %pos_adj     = arith.addi %pos_mod_raw, %safe_len : i64
    %pos_mod     = arith.select %is_neg, %pos_adj, %pos_mod_raw : i64

    %pos      = arith.select %loop_on, %pos_mod, %pos_start_i64 : i64
    %wrap_len = arith.select %loop_on, %safe_len, %c0 : i64

    // -------------------------------------------------------------------------
    // Read audio from the sampler
    // -------------------------------------------------------------------------
    // Pinned MONO for the same reason as wave_player: the runtime asset is a
    // flat interleaved buffer; pinning to <f32, 0, 1> ensures nSamp == blockSize
    // per block and lets crag-inject-channel-mixers upmix at the wrapper boundary.
    %audio_raw = crag.sample %s, %pos, %wrap_len
                     : !crag.sampler<"audio">, i64, i64
                       -> !crag.audio<f32, 0, 1>

    // -------------------------------------------------------------------------
    // Gate by playing state
    // -------------------------------------------------------------------------
    %audio = crag.scale %audio_raw, %playing_f32
                 : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // -------------------------------------------------------------------------
    // Progress meter: normalized playback position [0, 1]
    // -------------------------------------------------------------------------
    %len_f32  = arith.sitofp %safe_len : i64 to f32
    %pos_f32  = arith.sitofp %pos : i64 to f32
    %progress = arith.divf %pos_f32, %len_f32 : f32
    crag.meter "progress" %progress min = 0.0 max = 1.0 : f32

    crag.output %audio : !crag.audio<f32, 0, 1>
  }
}
