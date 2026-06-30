/**
 * crag_debug_worker.js — Web Worker that runs a crag WASM graph in
 * single-block "debug mode" for the web debugger.
 *
 * Unlike crag_player.js (which runs the graph inside an AudioWorklet for
 * real-time audio playback), this worker runs in a regular Web Worker so
 * it can be paused between blocks, single-stepped, and inspected
 * arbitrarily — none of which are possible inside an AudioWorkletProcessor.
 *
 * Protocol — the debugger main thread sends messages of the form:
 *
 *   { type: "init", wasmBuffer: ArrayBuffer, meta: object,
 *                   debugInfo: object|null }
 *     Instantiates the WASM, parses meta + debug info, replies with
 *     { type: "ready", numProbes, numTexProbes, blockSize, sampleRate,
 *                       channels, hasInstability }.
 *
 *   { type: "runBlock" }
 *     Calls crag_process() once.  Replies with
 *     { type: "blockDone", samplePos, hit, output: Float32Array,
 *                          textures: Array<{ idx, width, height, rgba }>,
 *                          probeStats: { hasNaN, hasInf, peak } }.
 *
 *   { type: "setParam",    idx, value }
 *   { type: "setParamI32", idx, value }
 *   { type: "setBreakFlags", mask }    // bit0 NaN, bit1 Inf, bit2 instability
 *   { type: "clearHit" }
 *   { type: "setSwBreakpoints", bps }  // Array<{ probeIdx, kind, threshold }>
 *   { type: "setSpeed", delayMs }      // delay between blocks when running
 *   { type: "run" }                    // start free-running loop
 *   { type: "pause" }                  // stop the loop
 *   { type: "step", count }            // run N blocks then stop
 *   { type: "reset" }                  // re-instantiate the WASM (zero state)
 *
 * The debug-mode "hardware" breakpoints (NaN, Inf, instability) are
 * implemented entirely in JS by scanning the output buffer and reading
 * the existing `crag_is_stable` global after each block.  No new WASM
 * exports are required.  Per-op audio probes are reserved for a future
 * pass; until then "probes" map to the single output buffer at probe
 * index 0 so the debugger UI has something to display.
 */

"use strict";

// Minimal subset of crag_player's import-object builder, inlined so the
// worker is fully self-contained.  Kept in sync with crag_player.js.
function _makeImports(heapState, memState) {
  const M = Math;
  const memcpyLike = (dst, src, size) => {
    const n = typeof size === "bigint" ? Number(size) : size;
    const d = typeof dst  === "bigint" ? Number(dst)  : dst;
    const s = typeof src  === "bigint" ? Number(src)  : src;
    if (memState.memory && n > 0)
      new Uint8Array(memState.memory.buffer).copyWithin(d, s, s + n);
    return dst;
  };
  return {
    env: {
      malloc(size) {
        const sz = typeof size === "bigint" ? Number(size) : size;
        const aligned = (sz + 7) & ~7;
        const ptr = heapState.ptr;
        const next = ptr + aligned;
        // Grow the WASM linear memory if the bump pointer would run past the
        // current buffer.  Crucial for visualizers, whose kernels allocate
        // multi-MiB scratch textures via memref.alloc: the default 16 MiB
        // module memory is not enough for a 1024×512 RGBA-float canvas, so
        // without growing here crag_visualize() traps with "memory access out
        // of bounds" — which previously broke both the texture view and (once
        // the leaked viz allocations pushed crag_process past the limit) block
        // stepping itself.  Mirrors crag_player.js's AudioWorklet malloc.
        if (memState.memory && next > memState.memory.buffer.byteLength) {
          const pages = Math.ceil(
            (next - memState.memory.buffer.byteLength) / 65536,
          );
          if (memState.memory.grow(pages) < 0) return 0;
        }
        heapState.ptr = next;
        return ptr;
      },
      free() {},
      memset(dst, val, size) {
        const n = typeof size === "bigint" ? Number(size) : size;
        const d = typeof dst  === "bigint" ? Number(dst)  : dst;
        if (memState.memory && n > 0)
          new Uint8Array(memState.memory.buffer, d, n).fill(val & 0xff);
        return dst;
      },
      memcpy:  memcpyLike,
      memmove: memcpyLike,
      // Single-precision math
      sinf: M.sin.bind(M), cosf: M.cos.bind(M), tanf: M.tan.bind(M),
      asinf: M.asin.bind(M), acosf: M.acos.bind(M), atanf: M.atan.bind(M),
      atan2f: M.atan2.bind(M), sqrtf: M.sqrt.bind(M), cbrtf: M.cbrt.bind(M),
      expf: M.exp.bind(M), exp2f: M.pow.bind(M, 2), expm1f: M.expm1.bind(M),
      logf: M.log.bind(M), log2f: M.log2.bind(M), log10f: M.log10.bind(M),
      log1pf: M.log1p.bind(M), powf: M.pow.bind(M), fabsf: M.abs.bind(M),
      floorf: M.floor.bind(M), ceilf: M.ceil.bind(M), truncf: M.trunc.bind(M),
      roundf: M.round.bind(M),
      fmodf: (a, b) => a - M.trunc(a / b) * b,
      remainderf: (a, b) => a - M.round(a / b) * b,
      fminf: M.min.bind(M), fmaxf: M.max.bind(M), hypotf: M.hypot.bind(M),
      fmaf: (x, y, z) => x * y + z,
      copysignf: (a, b) => M.abs(a) * (b < 0 || (b === 0 && (1/b) === -Infinity) ? -1 : 1),
      sinhf: M.sinh.bind(M), coshf: M.cosh.bind(M), tanhf: M.tanh.bind(M),
      asinhf: M.asinh.bind(M), acoshf: M.acosh.bind(M), atanhf: M.atanh.bind(M),
      // Double-precision aliases
      sin: M.sin.bind(M), cos: M.cos.bind(M), tan: M.tan.bind(M),
      asin: M.asin.bind(M), acos: M.acos.bind(M), atan: M.atan.bind(M),
      atan2: M.atan2.bind(M), sqrt: M.sqrt.bind(M), cbrt: M.cbrt.bind(M),
      exp: M.exp.bind(M), exp2: M.pow.bind(M, 2), expm1: M.expm1.bind(M),
      log: M.log.bind(M), log2: M.log2.bind(M), log10: M.log10.bind(M),
      log1p: M.log1p.bind(M), pow: M.pow.bind(M), fabs: M.abs.bind(M),
      floor: M.floor.bind(M), ceil: M.ceil.bind(M), trunc: M.trunc.bind(M),
      round: M.round.bind(M),
      fmod: (a, b) => a - M.trunc(a / b) * b,
      remainder: (a, b) => a - M.round(a / b) * b,
      fmin: M.min.bind(M), fmax: M.max.bind(M), hypot: M.hypot.bind(M),
      fma: (x, y, z) => x * y + z,
      copysign: (a, b) => M.abs(a) * (b < 0 || (b === 0 && (1/b) === -Infinity) ? -1 : 1),
      sinh: M.sinh.bind(M), cosh: M.cosh.bind(M), tanh: M.tanh.bind(M),
      asinh: M.asinh.bind(M), acosh: M.acosh.bind(M), atanh: M.atanh.bind(M),

      // Crag runtime helper — see crag_player.js for full notes.  Provides
      // the principal branch W₀ of the Lambert W function via Halley's
      // iteration so WASM modules emitted from graphs containing
      // `crag.lambert_w` can instantiate inside the debug worker.
      crag_rt_lambert_w(x) {
        if (!isFinite(x)) return x;
        const minArg = -1.0 / Math.E;
        if (x < minArg) return NaN;
        if (x === 0)   return 0;
        let w = x < 1.0 ? x : Math.log(x);
        for (let i = 0; i < 32; i++) {
          const ew  = Math.exp(w);
          const wew = w * ew;
          const denom = ew * (w + 1) - ((w + 2) * (wew - x)) / (2 * w + 2);
          const dw  = (wew - x) / denom;
          w -= dw;
          if (Math.abs(dw) < 1e-7) break;
        }
        return w;
      },
    },
  };
}

// ---------------------------------------------------------------------------
// Worker state
// ---------------------------------------------------------------------------

let _wasmBuffer  = null;
let _meta        = null;
let _debugInfo   = null;
let _instance    = null;
let _exports     = null;
let _memory      = null;
let _heapState   = { ptr: 0 };
let _memState    = { memory: null };
let _blockSize   = 0;
let _sampleRate  = 0;
let _channels    = 0;
let _outputPtr   = 0;
let _paramsPtr   = 0;
let _paramsI32Ptr = 0;
let _vizFn        = null;
let _vizOutputPtr = 0;
let _vizWidthFn   = null;
let _vizHeightFn  = null;
let _numVisualizers = 0;
let _isStablePtr    = 0;
let _samplePos      = 0;
let _blockCount     = 0;
let _numSamplers    = 0;
let _bindSamplerFn  = null;
let _fireEventFn    = null;
let _fireEventF32Fn = null;
let _fireEventI32Fn = null;
let _fireEventStructFn = null;

// Debug-mode hit/break state (implemented in JS, not WASM).
let _hit            = 0;     // 0 = no hit; otherwise a probe id (1-based)
let _hitReason      = "";
let _breakFlags     = 0;     // bit0 NaN, bit1 Inf, bit2 instability
let _swBreakpoints  = [];    // [{probeIdx, kind, threshold}]
let _runMode        = "stopped"; // "stopped" | "running" | "stepping"
let _stepsRemaining = 0;
let _delayMs        = 0;
let _runTimer       = null;

// ---------------------------------------------------------------------------
// Instantiation
// ---------------------------------------------------------------------------

async function _doInit(wasmBuffer, meta, debugInfo) {
  _wasmBuffer = wasmBuffer;
  _meta       = meta || {};
  _debugInfo  = debugInfo || null;

  // Compile + instantiate.
  const module   = await WebAssembly.compile(wasmBuffer);
  const imports  = _makeImports(_heapState, _memState);
  const instance = await WebAssembly.instantiate(module, imports);
  _instance = instance;
  _exports  = instance.exports;
  _memory   = _exports.memory;
  _memState.memory = _memory;
  if (_exports.__heap_base) _heapState.ptr = _exports.__heap_base.value;

  _blockSize  = _exports.crag_block_size  ? _exports.crag_block_size()  : 512;
  _sampleRate = _exports.crag_sample_rate ? _exports.crag_sample_rate() : 48000;
  _channels   = _exports.crag_num_channels ? _exports.crag_num_channels() : 1;
  _outputPtr  = _exports.crag_output  ? _exports.crag_output.value  : 0;
  _paramsPtr  = _exports.crag_params  ? _exports.crag_params.value  : 0;
  _paramsI32Ptr = _exports.crag_params_i32 ? _exports.crag_params_i32.value : 0;
  _isStablePtr = _exports.crag_is_stable ? _exports.crag_is_stable.value : 0;

  _numVisualizers = _exports.crag_num_visualizers
                      ? _exports.crag_num_visualizers()
                      : (_exports.crag_has_visualizer && _exports.crag_has_visualizer() ? 1 : 0);
  _vizFn        = _exports.crag_visualize  || null;
  _vizOutputPtr = _exports.crag_viz_output ? _exports.crag_viz_output.value : 0;
  _vizWidthFn   = _exports.crag_viz_width  || null;
  _vizHeightFn  = _exports.crag_viz_height || null;

  // Sampler binding + event firing (so input-driven graphs — wave_player
  // wrappers, synths — can be driven with a test signal / note from the UI
  // instead of sitting silent).  Mirrors crag_player.js's export probing.
  _numSamplers       = _exports.crag_num_audio ? _exports.crag_num_audio() : 0;
  _bindSamplerFn     = _exports.crag_bind_audio_by_index || null;
  _fireEventFn       = _exports.crag_fire_event        || null;
  _fireEventF32Fn    = _exports.crag_fire_event_float  || null;
  _fireEventI32Fn    = _exports.crag_fire_event_int    || null;
  _fireEventStructFn = _exports.crag_fire_event_struct || null;

  // Apply parameter defaults from meta so the first runBlock matches the UI.
  if (_paramsPtr && _meta.parameters) {
    const f32 = new Float32Array(_memory.buffer);
    for (const p of _meta.parameters) {
      if (p.type === "float" && typeof p.float_index === "number")
        f32[(_paramsPtr >> 2) + p.float_index] = Number(p.default || 0);
    }
  }
  if (_paramsI32Ptr && _meta.parameters) {
    const i32 = new Int32Array(_memory.buffer);
    for (const p of _meta.parameters) {
      if ((p.type === "int" || p.type === "bool" || p.type === "enum")
          && typeof p.int_index === "number")
        i32[(_paramsI32Ptr >> 2) + p.int_index] = Number(p.default || 0) | 0;
    }
  }

  _samplePos  = 0;
  _blockCount = 0;
  _hit        = 0;
  _hitReason  = "";

  postMessage({
    type: "ready",
    blockSize:    _blockSize,
    sampleRate:   _sampleRate,
    channels:     _channels,
    numProbes:    1,                // synthesized probe 0 = crag_output
    numTexProbes: _numVisualizers,
    numSamplers:  _numSamplers,
    hasInstability: _isStablePtr !== 0,
  });
}

// ---------------------------------------------------------------------------
// Input driving (samplers + events)
// ---------------------------------------------------------------------------

/// Copy `samples` (a Float32Array) into a *persistent* heap region and bind it
/// to sampler slot `idx`.  Must be called while stopped, before stepping, so
/// the allocation sits below the per-block heap snapshot and is never reclaimed
/// by _runOneBlock's bump-pointer restore.
function _bindSamplerData(idx, samples) {
  if (!_bindSamplerFn || !_memory || !samples || !samples.length) return;
  const numSamples = samples.length;
  const byteLen = numSamples * 4;
  const aligned = (byteLen + 7) & ~7;
  const ptr = _heapState.ptr;
  const next = ptr + aligned;
  if (next > _memory.buffer.byteLength) {
    const pages = Math.ceil((next - _memory.buffer.byteLength) / 65536);
    if (_memory.grow(pages) < 0) return;
  }
  _heapState.ptr = next;
  new Float32Array(_memory.buffer, ptr, numSamples).set(samples);
  _bindSamplerFn(idx | 0, BigInt(ptr), numSamples);
}

/// Synthesize a short, sampler-conforming test signal and bind it to every
/// sampler slot, so wave_player-wrapped graphs (samplers + start/stop events)
/// produce a non-silent waveform in the debugger instead of reading an unbound
/// (zero) sample buffer.  The signal is generated at each sampler's own target
/// sample-rate / channel-count (read from the crag_sampler_<i>_target_* globals
/// the compiler emits) so it matches the flat read loop with no resampling.
function _driveTestInput(waveform, seconds) {
  if (!_bindSamplerFn || !_numSamplers) return 0;
  let bound = 0;
  for (let i = 0; i < _numSamplers; i++) {
    const srG = _exports["crag_sampler_" + i + "_target_sample_rate"];
    const chG = _exports["crag_sampler_" + i + "_target_channels"];
    const sr = srG && srG.value ? (srG.value | 0) : (_sampleRate || 48000);
    const ch = chG && chG.value ? (chG.value | 0) : 1;
    const frames = Math.max(1, Math.floor(sr * (seconds || 2)));
    const data = new Float32Array(frames * ch);
    const twoPiF = (2 * Math.PI * 220) / sr; // 220 Hz reference tone
    let phase = 0;
    for (let f = 0; f < frames; f++) {
      let s;
      if (waveform === "noise") {
        s = Math.random() * 2 - 1;
      } else {
        // 220 Hz sine with a slow tremolo so the waveform is visibly dynamic.
        const env = 0.6 * (0.6 + 0.4 * Math.sin((2 * Math.PI * 2 * f) / sr));
        s = env * Math.sin(phase);
        phase += twoPiF;
      }
      for (let c = 0; c < ch; c++) data[f * ch + c] = s;
    }
    _bindSamplerData(i, data);
    bound++;
  }
  return bound;
}

/// Fire a void / float / int / struct event by index at `sampleOffset`.
function _fireEvent(idx, sampleOffset, value, subtype, structBytes) {
  const off = sampleOffset | 0;
  if (subtype === "struct" && _fireEventStructFn && structBytes &&
      structBytes.byteLength > 0) {
    const bytes = new Uint8Array(structBytes);
    const aligned = (bytes.byteLength + 7) & ~7;
    const ptr = _heapState.ptr;
    const next = ptr + aligned;
    if (next > _memory.buffer.byteLength) {
      const pages = Math.ceil((next - _memory.buffer.byteLength) / 65536);
      if (_memory.grow(pages) < 0) return;
    }
    _heapState.ptr = next;
    new Uint8Array(_memory.buffer, ptr, bytes.byteLength).set(bytes);
    _fireEventStructFn(idx | 0, off, BigInt(ptr), bytes.byteLength);
  } else if (subtype === "float" && _fireEventF32Fn) {
    _fireEventF32Fn(idx | 0, off, Number(value));
  } else if ((subtype === "int" || subtype === "bool" || subtype === "enum") &&
             _fireEventI32Fn) {
    _fireEventI32Fn(idx | 0, off, Number(value) | 0);
  } else if (_fireEventFn) {
    _fireEventFn(idx | 0, off);
  }
}

// ---------------------------------------------------------------------------
// Block execution
// ---------------------------------------------------------------------------

/// Snapshot the output buffer as a Float32Array for transfer to main thread.
function _snapshotOutput() {
  if (!_outputPtr) return new Float32Array(0);
  const len = _blockSize * _channels;
  const src = new Float32Array(_memory.buffer, _outputPtr, len);
  return new Float32Array(src);  // copy detaches from WASM memory
}

/// Snapshot one visualizer texture as an RGBA Uint8ClampedArray.
///
/// The visualizer writes its canvas to `crag_viz_output` as **float** RGBA in
/// the 0..1 range (w*h*4 floats), exactly like the AudioWorklet path in
/// crag_player.js — so we read Float32 and clamp to bytes here (the previous
/// code read the float bytes directly as Uint8, producing garbage colors).
/// The bump pointer is snapshotted before the call and restored afterwards
/// (on success *and* trap) so the multi-MiB scratch buffers the kernel
/// allocates are reclaimed every frame instead of leaking the arena away.
function _snapshotTexture(idx) {
  if (!_vizFn || !_vizOutputPtr || !_vizWidthFn || !_vizHeightFn) return null;
  const heapBefore = _heapState.ptr;
  try {
    _vizFn(idx);
  } catch (e) {
    _heapState.ptr = heapBefore;
    return null;
  }
  _heapState.ptr = heapBefore;
  const w = _vizWidthFn(idx)  | 0;
  const h = _vizHeightFn(idx) | 0;
  if (w <= 0 || h <= 0) return null;
  const pixels = w * h * 4;                    // RGBA components
  const byteOffset = _vizOutputPtr | 0;
  if (byteOffset + pixels * 4 > _memory.buffer.byteLength) return null;
  const f32 = new Float32Array(_memory.buffer, byteOffset, pixels);
  const rgba = new Uint8ClampedArray(pixels);
  for (let i = 0; i < pixels; i++)
    rgba[i] = Math.round(Math.min(Math.max(f32[i], 0), 1) * 255);
  return { idx, width: w, height: h, rgba };
}

/// Compute simple stats over the output buffer (NaN/Inf/peak).
function _statsOver(buf) {
  let hasNaN = false, hasInf = false, peak = 0;
  for (let i = 0; i < buf.length; i++) {
    const v = buf[i];
    if (Number.isNaN(v)) { hasNaN = true; }
    else if (!Number.isFinite(v)) { hasInf = true; }
    else { const a = v < 0 ? -v : v; if (a > peak) peak = a; }
  }
  return { hasNaN, hasInf, peak };
}

/// Read crag_is_stable global (0 = unstable detected, !=0 = stable).
function _readStable() {
  if (!_isStablePtr) return true;
  const v = new Int32Array(_memory.buffer)[_isStablePtr >> 2];
  return v !== 0;
}

/// Evaluate user software breakpoints against the current output buffer.
function _evalSwBreakpoints(buf) {
  for (const bp of _swBreakpoints) {
    if (bp.kind === "nan") {
      for (let i = 0; i < buf.length; i++)
        if (Number.isNaN(buf[i])) return bp;
    } else if (bp.kind === "gt") {
      const t = bp.threshold;
      for (let i = 0; i < buf.length; i++)
        if (buf[i] > t) return bp;
    } else if (bp.kind === "lt") {
      const t = bp.threshold;
      for (let i = 0; i < buf.length; i++)
        if (buf[i] < t) return bp;
    } else if (bp.kind === "abs_gt") {
      const t = bp.threshold;
      for (let i = 0; i < buf.length; i++) {
        const a = buf[i] < 0 ? -buf[i] : buf[i];
        if (a > t) return bp;
      }
    }
  }
  return null;
}

function _runOneBlock() {
  if (!_exports || !_exports.crag_process) return;
  // The bump allocator's free() is a no-op (see _makeImports above), so every
  // malloc made by crag_process() — typically the transient per-block buffers
  // that One-Shot Bufferize inserts (memref.alloc / memref.dealloc pairs) —
  // would otherwise leak.  With the default 16 MiB WASM linear memory the
  // accumulated leak crosses the memory boundary after ~1.1 k blocks and the
  // next memref store traps with `RuntimeError: index out of bounds`.
  // Snapshot/restore the heap pointer around the call to give the no-op free
  // proper LIFO-stack semantics for intra-block allocations, while leaving
  // persistent state (sampler bindings, parameter buffers) — which lives in
  // static globals or in heap regions allocated outside crag_process — alone.
  const heapBefore = _heapState.ptr;
  _exports.crag_process();
  _heapState.ptr = heapBefore;
  _blockCount += 1;
  _samplePos  += _blockSize;

  const out   = _snapshotOutput();
  const stats = _statsOver(out);

  // Hardware-style break flags evaluated in JS.
  let hit = 0, reason = "";
  if ((_breakFlags & 1) && stats.hasNaN) { hit = 1; reason = "NaN in output"; }
  else if ((_breakFlags & 2) && stats.hasInf) { hit = 1; reason = "Inf in output"; }
  else if ((_breakFlags & 4) && !_readStable()) { hit = 1; reason = "instability detected"; }

  // User software breakpoints.
  if (!hit) {
    const bp = _evalSwBreakpoints(out);
    if (bp) {
      hit = (bp.probeIdx | 0) + 1;
      reason = `sw: ${bp.kind}` + (bp.kind === "nan" ? "" : ` (${bp.threshold})`);
    }
  }

  _hit       = hit;
  _hitReason = reason;

  // Halt immediately on breakpoint hit so execution stops even if anything in
  // the reporting path below (texture snapshotting / postMessage) fails.
  if (hit) {
    _runMode = "stopped";
    _stopRunLoop();
  }

  // Texture snapshots (one per visualizer).
  const textures = [];
  for (let i = 0; i < _numVisualizers; i++) {
    const t = _snapshotTexture(i);
    if (t) textures.push(t);
  }

  postMessage({
    type:       "blockDone",
    blockCount: _blockCount,
    samplePos:  _samplePos,
    hit,
    hitReason:  reason,
    output:     out,
    textures,
    probeStats: stats,
    stable:     _readStable(),
  });

}

function _startRunLoop() {
  _stopRunLoop();
  if (_runMode === "stopped") return;
  const tick = () => {
    if (_runMode === "stopped") return;
    _runOneBlock();
    if (_runMode === "stepping") {
      _stepsRemaining -= 1;
      if (_stepsRemaining <= 0) { _runMode = "stopped"; return; }
    }
    if (_runMode === "stopped") return;
    _runTimer = setTimeout(tick, _delayMs);
  };
  _runTimer = setTimeout(tick, 0);
}

function _stopRunLoop() {
  if (_runTimer) { clearTimeout(_runTimer); _runTimer = null; }
}

// ---------------------------------------------------------------------------
// Message dispatch
// ---------------------------------------------------------------------------

self.onmessage = async (ev) => {
  const m = ev.data;
  try {
    switch (m.type) {
      case "init":
        await _doInit(m.wasmBuffer, m.meta, m.debugInfo);
        break;
      case "runBlock":
        _runOneBlock();
        break;
      case "run":
        _runMode = "running";
        _startRunLoop();
        break;
      case "pause":
        _runMode = "stopped";
        _stopRunLoop();
        break;
      case "step":
        _stepsRemaining = Math.max(1, m.count | 0);
        _runMode = "stepping";
        _startRunLoop();
        break;
      case "setSpeed":
        _delayMs = Math.max(0, Number(m.delayMs) || 0);
        break;
      case "bindSampler":
        _bindSamplerData(m.idx | 0, m.samples);
        break;
      case "driveTestInput": {
        const n = _driveTestInput(m.waveform || "tone", Number(m.seconds) || 2);
        postMessage({ type: "drivenInput", numSamplers: n });
        break;
      }
      case "fireEvent":
        _fireEvent(m.idx | 0, m.sampleOffset | 0, m.value,
                   m.subtype || "void", m.structBytes || null);
        break;
      case "setParam":
        if (_paramsPtr && _memory)
          new Float32Array(_memory.buffer)[(_paramsPtr >> 2) + (m.idx|0)]
            = Number(m.value);
        break;
      case "setParamI32":
        if (_paramsI32Ptr && _memory)
          new Int32Array(_memory.buffer)[(_paramsI32Ptr >> 2) + (m.idx|0)]
            = (Number(m.value) | 0);
        break;
      case "setBreakFlags":
        _breakFlags = (m.mask | 0);
        break;
      case "clearHit":
        // Clear any pending breakpoint-hit state.  Called by the host before
        // a fresh run/step so a previously hit breakpoint doesn't immediately
        // re-trigger and stall progress.
        _hit = 0; _hitReason = "";
        break;
      case "setSwBreakpoints":
        _swBreakpoints = Array.isArray(m.bps) ? m.bps.slice() : [];
        break;
      case "reset":
        _stopRunLoop();
        _runMode = "stopped";
        _heapState = { ptr: 0 };
        _memState  = { memory: null };
        await _doInit(_wasmBuffer, _meta, _debugInfo);
        break;
      default:
        postMessage({ type: "error", error: "unknown message type: " + m.type });
    }
  } catch (e) {
    postMessage({ type: "error", error: String(e && e.message || e),
                  stack: e && e.stack || "" });
  }
};
