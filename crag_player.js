/**
 * crag_player.js — Web Audio host for WASM crag graph binaries.
 *
 * Usage:
 *   const player = await CragPlayer.create('graph.wasm', 'graph.wasm.cragmeta');
 *   await player.start(); // begin audio output (returns a Promise)
 *   player.stop();        // stop audio output
 *   player.setParam(idx, value);
 *   player.getParam(idx) -> float
 *   player.meta          // parsed .cragmeta JSON
 *   player.numParams     // number of parameters
 *   player.numSamplers   // number of samplers
 *   player.samplerNames  // array of sampler name strings from .cragmeta
 *   player.blockSize     // audio block size
 *
 * Samplers:
 *   Graphs that contain crag.sampler ops export crag_num_audio() and
 *   crag_bind_audio_by_index(idx, ptr, len).  Use bindSamplerFromUrl() or
 *   bindSamplerFromArrayBuffer() to load a WAV file and bind it before (or
 *   while) the graph is playing.
 *
 *   player.bindSamplerFromUrl(idx, url) -> Promise<void>
 *     Fetch a WAV file, decode it, copy into WASM memory and bind.
 *   player.bindSamplerFromArrayBuffer(idx, arrayBuffer) -> void
 *     Decode an ArrayBuffer containing a WAV file and bind.
 *
 *   Supported WAV formats: 16-bit signed PCM or 32-bit IEEE-float PCM, mono
 *   or multi-channel.  Only channel 0 (left) is used.
 *
 * WASM math imports:
 *   The compiled crag WASM binary imports math functions (sinf, cosf, tanf,
 *   sqrtf, etc.) from the "env" module.  This module provides them from the
 *   standard JavaScript Math object.
 *
 * Memory layout:
 *   crag_output and crag_params are exported as WebAssembly.Global objects
 *   whose .value is the byte offset into WASM linear memory (exports.memory).
 *
 * malloc:
 *   crag graphs that use filters require a small heap for coefficient arrays.
 *   A simple bump allocator is provided; it initialises its pointer from the
 *   exported __heap_base symbol after instantiation.
 *
 * AudioWorklet:
 *   Audio processing runs in an AudioWorkletProcessor (dedicated audio thread).
 *   The WASM module is transferred to the worklet which instantiates its own
 *   copy.  Parameter / event / sampler changes are forwarded via MessagePort.
 *   Visualizer frames are rendered inside the worklet and posted back to the
 *   main thread as transferable ArrayBuffers.
 */

"use strict";

(function (root, factory) {
  if (typeof module !== "undefined" && module.exports) {
    module.exports = factory();
  } else {
    root.CragPlayer = factory();
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {

  // ---------------------------------------------------------------------------
  // WASM import object builder
  // ---------------------------------------------------------------------------

  // Default arena size for the bump allocator: 256 MiB.  Large enough to
  // hold multi-minute audio samples bound through `bindSamplerFromArrayBuffer`
  // without overflowing the WASM linear memory and triggering the wasm-side
  // "RuntimeError: index out of bounds" trap.  Configurable per-page via
  // CragPlayer.create(wasmUrl, metaUrl, { arenaSize: <bytes> }).
  const DEFAULT_ARENA_BYTES = 256 * 1024 * 1024;
  const WASM_PAGE_BYTES     = 65536;

  /**
   * Grow the given WebAssembly.Memory so its buffer is at least *requiredBytes*
   * long.  Returns the (possibly increased) byteLength.  Throws if grow() fails
   * (e.g. when the host runs out of memory or the requested size exceeds the
   * 4 GiB wasm32 limit).
   *
   * @param {WebAssembly.Memory} memory
   * @param {number}             requiredBytes
   */
  function growMemoryTo(memory, requiredBytes) {
    const have = memory.buffer.byteLength;
    if (have >= requiredBytes) return have;
    const pages = Math.ceil((requiredBytes - have) / WASM_PAGE_BYTES);
    const prev  = memory.grow(pages);
    if (prev < 0)
      throw new Error(
        `[crag] Unable to grow WASM memory by ${pages} pages ` +
        `(${(pages * WASM_PAGE_BYTES) >> 20} MiB) to satisfy arena size`
      );
    return memory.buffer.byteLength;
  }

  /**
   * Build the WebAssembly import object for a crag WASM module.
   * Math functions are supplied from JavaScript's Math object.
   *
   * The bump allocator is *bounded* by the arena described in heapState:
   * malloc throws a JS Error when an allocation would exceed heapState.end,
   * surfacing the overflow at the call site instead of returning an
   * out-of-bounds pointer that would later trap inside the wasm module with
   * "RuntimeError: index out of bounds".  The allocator also tracks a peak
   * usage high-water mark and an allocation count for instrumentation
   * (exposed via CragPlayer.getAllocatorStats()).
   *
   * @param {object} heapState  Mutable bump-arena state.  Fields:
   *                              ptr         current bump pointer (bytes)
   *                              base        arena base = post-init __heap_base
   *                              end         exclusive upper bound = base+arenaSize
   *                              peak        max ptr ever observed
   *                              allocCount  number of successful mallocs
   *                              lastError   string|null (most recent OOM msg)
   *                            Caller updates base/ptr/end after instantiation.
   * @param {object} memState   Mutable object: { memory: WebAssembly.Memory|null }
   *                            The caller sets memory from instance.exports.memory
   *                            after instantiation so that memset/memcpy/memmove
   *                            have access to the linear memory buffer.
   */
  function makeCragImports(heapState, memState) {
    return {
      env: {
        // ----------------------------------------------------------------
        // malloc — instrumented, bounded bump allocator.
        // The WASM ABI may pass i32 or i64 sizes; handle both.
        // ----------------------------------------------------------------
        malloc(size) {
          const sz = typeof size === "bigint" ? Number(size) : size;
          if (!Number.isFinite(sz) || sz < 0) {
            const msg = "[crag] malloc: invalid size " + size;
            heapState.lastError = msg;
            throw new RangeError(msg);
          }
          const aligned = (sz + 7) & ~7;
          const ptr     = heapState.ptr;
          const next    = ptr + aligned;
          if (heapState.end && next > heapState.end) {
            const msg =
              "[crag] arena exhausted: requested " + sz +
              " bytes (aligned " + aligned + "), have " +
              (heapState.end - ptr) + " bytes free of " +
              (heapState.end - heapState.base) +
              " byte arena. Increase via CragPlayer.create(" +
              "wasmUrl, metaUrl, { arenaSize: <bytes> }).";
            heapState.lastError = msg;
            throw new RangeError(msg);
          }
          heapState.ptr        = next;
          heapState.allocCount = (heapState.allocCount | 0) + 1;
          if (next > (heapState.peak | 0)) heapState.peak = next;
          return ptr;
        },
        free(_ptr) { /* bump allocator: no-op */ },

        // ----------------------------------------------------------------
        // C memory builtins — require access to WASM linear memory.
        // memState.memory is populated from instance.exports.memory after
        // WebAssembly.instantiate resolves.
        // ----------------------------------------------------------------
        memset(dst, val, size) {
          const n = typeof size === "bigint" ? Number(size) : size;
          const d = typeof dst  === "bigint" ? Number(dst)  : dst;
          if (memState.memory && n > 0)
            new Uint8Array(memState.memory.buffer, d, n).fill(val & 0xff);
          return dst;
        },
        memcpy(dst, src, size) {
          const n  = typeof size === "bigint" ? Number(size) : size;
          const d  = typeof dst  === "bigint" ? Number(dst)  : dst;
          const s  = typeof src  === "bigint" ? Number(src)  : src;
          if (memState.memory && n > 0) {
            const mem = new Uint8Array(memState.memory.buffer);
            mem.copyWithin(d, s, s + n);
          }
          return dst;
        },
        memmove(dst, src, size) {
          const n  = typeof size === "bigint" ? Number(size) : size;
          const d  = typeof dst  === "bigint" ? Number(dst)  : dst;
          const s  = typeof src  === "bigint" ? Number(src)  : src;
          if (memState.memory && n > 0) {
            const mem = new Uint8Array(memState.memory.buffer);
            // copyWithin handles overlapping regions correctly.
            mem.copyWithin(d, s, s + n);
          }
          return dst;
        },

        // ----------------------------------------------------------------
        // Math (single-precision names used by clang-generated LLVM IR)
        // ----------------------------------------------------------------
        sinf: Math.sin.bind(Math),
        cosf: Math.cos.bind(Math),
        tanf: Math.tan.bind(Math),
        asinf: Math.asin.bind(Math),
        acosf: Math.acos.bind(Math),
        atanf: Math.atan.bind(Math),
        atan2f: Math.atan2.bind(Math),
        sqrtf: Math.sqrt.bind(Math),
        cbrtf: Math.cbrt.bind(Math),
        expf: Math.exp.bind(Math),
        exp2f: Math.pow.bind(Math, 2),
        expm1f: Math.expm1.bind(Math),
        logf: Math.log.bind(Math),
        log2f: Math.log2.bind(Math),
        log10f: Math.log10.bind(Math),
        log1pf: Math.log1p.bind(Math),
        powf: Math.pow.bind(Math),
        fabsf: Math.abs.bind(Math),
        floorf: Math.floor.bind(Math),
        ceilf: Math.ceil.bind(Math),
        truncf: Math.trunc.bind(Math),
        roundf: Math.round.bind(Math),
        fmodf: (a, b) => a - Math.trunc(a / b) * b,
        remainderf: (a, b) => a - Math.round(a / b) * b,
        fminf: Math.min.bind(Math),
        fmaxf: Math.max.bind(Math),
        // Fused multiply-add (no native WASM op → emitted as a libcall by LLVM).
        // JS has no single-rounding FMA; x*y+z matches the host's other math
        // approximations (this is the preview host, not the bit-exact reference).
        fmaf: (x, y, z) => x * y + z,
        hypotf: Math.hypot.bind(Math),
        copysignf: (mag, sgn) => Math.abs(mag) * (sgn < 0 || (sgn === 0 && (1/sgn) === -Infinity) ? -1 : 1),
        sinhf: Math.sinh.bind(Math),
        coshf: Math.cosh.bind(Math),
        tanhf: Math.tanh.bind(Math),
        asinhf: Math.asinh.bind(Math),
        acoshf: Math.acosh.bind(Math),
        atanhf: Math.atanh.bind(Math),

        // Double-precision variants (occasionally emitted by LLVM)
        sin: Math.sin.bind(Math),
        cos: Math.cos.bind(Math),
        tan: Math.tan.bind(Math),
        asin: Math.asin.bind(Math),
        acos: Math.acos.bind(Math),
        atan: Math.atan.bind(Math),
        atan2: Math.atan2.bind(Math),
        sqrt: Math.sqrt.bind(Math),
        cbrt: Math.cbrt.bind(Math),
        exp: Math.exp.bind(Math),
        exp2: Math.pow.bind(Math, 2),
        expm1: Math.expm1.bind(Math),
        log: Math.log.bind(Math),
        log2: Math.log2.bind(Math),
        log10: Math.log10.bind(Math),
        log1p: Math.log1p.bind(Math),
        pow: Math.pow.bind(Math),
        fabs: Math.abs.bind(Math),
        floor: Math.floor.bind(Math),
        ceil: Math.ceil.bind(Math),
        trunc: Math.trunc.bind(Math),
        round: Math.round.bind(Math),
        fmod: (a, b) => a - Math.trunc(a / b) * b,
        remainder: (a, b) => a - Math.round(a / b) * b,
        fmin: Math.min.bind(Math),
        fmax: Math.max.bind(Math),
        fma: (x, y, z) => x * y + z,
        hypot: Math.hypot.bind(Math),
        copysign: (mag, sgn) => Math.abs(mag) * (sgn < 0 || (sgn === 0 && (1/sgn) === -Infinity) ? -1 : 1),
        sinh: Math.sinh.bind(Math),
        cosh: Math.cosh.bind(Math),
        tanh: Math.tanh.bind(Math),
        asinh: Math.asinh.bind(Math),
        acosh: Math.acosh.bind(Math),
        atanh: Math.atanh.bind(Math),

        // ----------------------------------------------------------------
        // Crag runtime helpers — emitted as external function imports by
        // crag-compile when the corresponding op is not handled by the
        // inline-runtime-functions code path.  Provide JS implementations
        // here so the WASM module instantiates successfully.
        // ----------------------------------------------------------------
        // Principal branch W₀ of the Lambert W function (real input only).
        // Uses Halley's iteration; converges to ~1e-7 in a handful of steps
        // for the input range exercised by audio (typically 0…20).
        crag_rt_lambert_w(x) {
          if (!isFinite(x)) return x;
          const minArg = -1.0 / Math.E;
          if (x < minArg) return NaN;
          if (x === 0)   return 0;
          // Initial guess: log(x) for large x, otherwise x itself.
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
  // Minimal WAV decoder
  // ---------------------------------------------------------------------------

  /**
   * Decode an ArrayBuffer containing a WAV file (PCM-16 or IEEE-float-32,
   * mono or multi-channel) and return a Float32Array of all interleaved
   * samples normalised to [-1, 1].
   *
   * Throws an Error if the buffer is not a valid/supported WAV.
   *
   * @param {ArrayBuffer} buf
   * @returns {Float32Array}
   */
  function decodeWavToFloat32(buf) {
    const dv = new DataView(buf);

    // RIFF / WAVE header
    if (dv.getUint32(0, false) !== 0x52494646)  // "RIFF"
      throw new Error("Not a RIFF file");
    if (dv.getUint32(8, false) !== 0x57415645)  // "WAVE"
      throw new Error("Not a WAVE file");

    let audioFormat   = 0;
    let bitsPerSample = 0;
    let dataOffset    = 0;
    let dataSize      = 0;

    // Walk chunk list starting after the 12-byte RIFF/WAVE header.
    let pos = 12;
    while (pos + 8 <= buf.byteLength) {
      const chunkId = dv.getUint32(pos, false);
      const chunkSz = dv.getUint32(pos + 4, true);
      pos += 8;

      if (chunkId === 0x666d7420) {           // "fmt "
        audioFormat   = dv.getUint16(pos,      true);
        // numChannels at pos + 2 — not needed; all channels are decoded
        // sampleRate  at pos + 4 — not needed for decode
        bitsPerSample = dv.getUint16(pos + 14, true);
        pos += chunkSz;
      } else if (chunkId === 0x64617461) {    // "data"
        dataOffset = pos;
        dataSize   = chunkSz;
        break;
      } else {
        pos += chunkSz;
      }
    }

    if (!dataOffset)
      throw new Error("No data chunk found in WAV");

    const bytesPerSample = bitsPerSample >>> 3;
    const totalSamples   = Math.floor(dataSize / bytesPerSample);
    const out            = new Float32Array(totalSamples);

    if (audioFormat === 3 && bitsPerSample === 32) {
      // IEEE 32-bit float — read via DataView to handle any byte alignment.
      for (let i = 0; i < totalSamples; i++)
        out[i] = dv.getFloat32(dataOffset + i * 4, true);
    } else if (audioFormat === 1 && bitsPerSample === 16) {
      // Signed 16-bit PCM — normalise to [-1, 1].
      for (let i = 0; i < totalSamples; i++)
        out[i] = dv.getInt16(dataOffset + i * 2, true) / 32767.0;
    } else {
      throw new Error(
        `Unsupported WAV format: audioFormat=${audioFormat}, bits=${bitsPerSample}`
      );
    }

    return out;
  }

  // ---------------------------------------------------------------------------
  // AudioWorklet processor source (embedded as a string; loaded via Blob URL).
  // Must be fully self-contained — no references to outer-scope variables.
  // ---------------------------------------------------------------------------

  const _CRAG_WORKLET_CODE = `"use strict";

// Identical import-object builder to makeCragImports on the main thread.
// Duplicated here because the worklet scope cannot access the outer factory.
function _makeCragWorkletImports(heapState, memState) {
  return {
    env: {
      // Bounded, instrumented bump allocator (mirror of makeCragImports on
      // the main thread).  Throws a JS error when the arena is exhausted
      // so the caller sees a clear "arena exhausted" message instead of a
      // wasm "RuntimeError: index out of bounds" from a downstream load.
      malloc(size) {
        const sz      = typeof size === "bigint" ? Number(size) : size;
        if (!Number.isFinite(sz) || sz < 0) {
          const msg = "[crag] malloc: invalid size " + size;
          heapState.lastError = msg;
          throw new RangeError(msg);
        }
        const aligned = (sz + 7) & ~7;
        const ptr     = heapState.ptr;
        const next    = ptr + aligned;
        if (heapState.end && next > heapState.end) {
          const msg =
            "[crag] arena exhausted in AudioWorklet: requested " + sz +
            " bytes (aligned " + aligned + "), have " +
            (heapState.end - ptr) + " bytes free of " +
            (heapState.end - heapState.base) +
            " byte arena. Increase via CragPlayer.create(" +
            "wasmUrl, metaUrl, { arenaSize: <bytes> }).";
          heapState.lastError = msg;
          throw new RangeError(msg);
        }
        heapState.ptr        = next;
        heapState.allocCount = (heapState.allocCount | 0) + 1;
        if (next > (heapState.peak | 0)) heapState.peak = next;
        return ptr;
      },
      free(_ptr) {},
      memset(dst, val, size) {
        const n = typeof size === "bigint" ? Number(size) : size;
        const d = typeof dst  === "bigint" ? Number(dst)  : dst;
        if (memState.memory && n > 0)
          new Uint8Array(memState.memory.buffer, d, n).fill(val & 0xff);
        return dst;
      },
      memcpy(dst, src, size) {
        const n = typeof size === "bigint" ? Number(size) : size;
        const d = typeof dst  === "bigint" ? Number(dst)  : dst;
        const s = typeof src  === "bigint" ? Number(src)  : src;
        if (memState.memory && n > 0)
          new Uint8Array(memState.memory.buffer).copyWithin(d, s, s + n);
        return dst;
      },
      memmove(dst, src, size) {
        const n = typeof size === "bigint" ? Number(size) : size;
        const d = typeof dst  === "bigint" ? Number(dst)  : dst;
        const s = typeof src  === "bigint" ? Number(src)  : src;
        if (memState.memory && n > 0)
          new Uint8Array(memState.memory.buffer).copyWithin(d, s, s + n);
        return dst;
      },
      sinf: Math.sin.bind(Math),   cosf: Math.cos.bind(Math),
      tanf: Math.tan.bind(Math),   asinf: Math.asin.bind(Math),
      acosf: Math.acos.bind(Math), atanf: Math.atan.bind(Math),
      atan2f: Math.atan2.bind(Math), sqrtf: Math.sqrt.bind(Math),
      cbrtf: Math.cbrt.bind(Math), expf: Math.exp.bind(Math),
      exp2f: Math.pow.bind(Math, 2), expm1f: Math.expm1.bind(Math),
      logf: Math.log.bind(Math),   log2f: Math.log2.bind(Math),
      log10f: Math.log10.bind(Math), log1pf: Math.log1p.bind(Math),
      powf: Math.pow.bind(Math),   fabsf: Math.abs.bind(Math),
      floorf: Math.floor.bind(Math), ceilf: Math.ceil.bind(Math),
      truncf: Math.trunc.bind(Math), roundf: Math.round.bind(Math),
      fmodf:      (a, b) => a - Math.trunc(a / b) * b,
      remainderf: (a, b) => a - Math.round(a / b) * b,
      fminf: Math.min.bind(Math),  fmaxf: Math.max.bind(Math),
      fmaf: (x, y, z) => x * y + z,
      hypotf: Math.hypot.bind(Math),
      copysignf: (mag, sgn) => Math.abs(mag) * (sgn < 0 || (sgn === 0 && (1/sgn) === -Infinity) ? -1 : 1),
      sinhf: Math.sinh.bind(Math), coshf: Math.cosh.bind(Math),
      tanhf: Math.tanh.bind(Math), asinhf: Math.asinh.bind(Math),
      acoshf: Math.acosh.bind(Math), atanhf: Math.atanh.bind(Math),
      sin: Math.sin.bind(Math),    cos: Math.cos.bind(Math),
      tan: Math.tan.bind(Math),    asin: Math.asin.bind(Math),
      acos: Math.acos.bind(Math),  atan: Math.atan.bind(Math),
      atan2: Math.atan2.bind(Math), sqrt: Math.sqrt.bind(Math),
      cbrt: Math.cbrt.bind(Math),  exp: Math.exp.bind(Math),
      exp2: Math.pow.bind(Math, 2), expm1: Math.expm1.bind(Math),
      log: Math.log.bind(Math),    log2: Math.log2.bind(Math),
      log10: Math.log10.bind(Math), log1p: Math.log1p.bind(Math),
      pow: Math.pow.bind(Math),    fabs: Math.abs.bind(Math),
      floor: Math.floor.bind(Math), ceil: Math.ceil.bind(Math),
      trunc: Math.trunc.bind(Math), round: Math.round.bind(Math),
      fmod:      (a, b) => a - Math.trunc(a / b) * b,
      remainder: (a, b) => a - Math.round(a / b) * b,
      fmin: Math.min.bind(Math),   fmax: Math.max.bind(Math),
      fma: (x, y, z) => x * y + z,
      hypot: Math.hypot.bind(Math),
      copysign: (mag, sgn) => Math.abs(mag) * (sgn < 0 || (sgn === 0 && (1/sgn) === -Infinity) ? -1 : 1),
      sinh: Math.sinh.bind(Math),  cosh: Math.cosh.bind(Math),
      tanh: Math.tanh.bind(Math),  asinh: Math.asinh.bind(Math),
      acosh: Math.acosh.bind(Math), atanh: Math.atanh.bind(Math),

      // Crag runtime helper — see top of this file for full notes.
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

class CragProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this._ready            = false;
    this._instance         = null;
    this._memory           = null;
    this._process          = null;
    this._outputPtr        = 0;
    this._paramsPtr        = 0;
    this._paramsI32Ptr     = 0;
    this._blockSize        = 0;
    this._channels         = 1;
    this._accumulator      = null;
    this._accumFill        = 0;
    this._heapState        = { ptr: 0 };
    this._fireEventFn      = null;
    this._fireEventF32Fn   = null;
    this._fireEventI32Fn   = null;
    this._fireEventStructFn = null;
    this._bindSamplerFn    = null;
    this._isStablePtr      = 0;
    this._unstableCheckIdxPtr = 0;
    this._vizFn            = null;
    this._vizOutputPtr     = 0;
    this._vizWidthFn       = null;
    this._vizHeightFn      = null;
    this._numVisualizers   = 0;
    this._vizDisabled      = new Set();
    this.port.onmessage    = (ev) => { this._onMessage(ev.data); };
    // Announce that the processor is constructed and its port is listening.
    // Chromium/Edge do NOT reliably deliver a message posted to the node's
    // port before the processor exists on the render thread — such a message
    // is silently dropped — so the main thread waits for this "hello" before
    // posting the heavy "init" payload (WASM module + seed params).  Firefox
    // queues the early message correctly, but the handshake is harmless there.
    // See _startInternal().
    this.port.postMessage({ type: "hello" });
  }

  _onMessage(msg) {
    switch (msg.type) {
      case "init":
        this._handleInit(msg).catch((err) => {
          this.port.postMessage({ type: "error", message: err.message || String(err) });
        });
        break;
      case "setParam":
        this._setParam(msg.idx, msg.value);
        break;
      case "setParamInt":
        this._setParamInt(msg.idx, msg.value);
        break;
      case "bindSampler":
        this._bindSampler(msg);
        break;
      case "fireEvent":
        if (this._fireEventFn)
          this._fireEventFn(msg.idx, msg.sampleOffset | 0);
        break;
      case "fireEventFloat":
        if (this._fireEventF32Fn)
          this._fireEventF32Fn(msg.idx, msg.sampleOffset | 0, +msg.value);
        break;
      case "fireEventInt":
        if (this._fireEventI32Fn)
          this._fireEventI32Fn(msg.idx, msg.sampleOffset | 0, msg.value | 0);
        break;
      case "fireEventStruct":
        this._fireWorkletEventStruct(msg);
        break;
      case "visualize":
        this._handleVisualize(msg.idx);
        break;
    }
  }

  async _handleInit(msg) {
    const { wasmBytes, heapPtr, channels,
            outputPtr, paramsPtr, paramsI32Ptr,
            initialParams, initialParamsI32,
            arenaSize } = msg;

    this._channels      = channels;
    // Re-initialise the arena state.  Bounds are populated below once
    // __heap_base is known, but seed ptr from the value the main thread
    // computed so that allocations made before instantiation completes
    // (none today, but defensive) start at a sane offset.
    this._heapState.ptr        = heapPtr;
    this._heapState.base       = heapPtr;
    this._heapState.end        = 0; // disabled until base + arenaSize is fixed
    this._heapState.peak       = heapPtr;
    this._heapState.allocCount = 0;
    this._heapState.lastError  = null;

    const heapState = this._heapState;
    const memState  = { memory: null };
    const imports   = _makeCragWorkletImports(heapState, memState);

    // Compile + instantiate from the raw bytes inside the worklet.  Passing a
    // BufferSource (not a Module) returns { module, instance }; we only need
    // the instance.  This is the cross-engine-safe path (Chromium/Edge cannot
    // receive a WebAssembly.Module over the AudioWorklet port).
    const { instance: inst } = await WebAssembly.instantiate(wasmBytes, imports);
    this._instance = inst;
    const e = inst.exports;

    memState.memory    = e.memory;
    this._memory       = e.memory;
    this._process      = e.crag_process;
    this._blockSize    = e.crag_block_size();

    // Honour the compiled __heap_base so the bump allocator doesn't collide
    // with WASM static data.
    if (e.__heap_base) heapState.ptr = e.__heap_base.value;

    // Establish the arena bounds and pre-grow linear memory so the entire
    // arena is backed before any malloc happens.  This prevents the wasm
    // module from trapping with "RuntimeError: index out of bounds" when a
    // large sampler payload pushes the bump pointer past the initial
    // memory size.
    const requestedArena = (typeof arenaSize === "number" && arenaSize > 0)
      ? arenaSize
      : ${DEFAULT_ARENA_BYTES};
    heapState.base = heapState.ptr;
    heapState.end  = heapState.base + requestedArena;
    heapState.peak = heapState.ptr;
    {
      const have = e.memory.buffer.byteLength;
      if (heapState.end > have) {
        const pages = Math.ceil((heapState.end - have) / 65536);
        const prev  = e.memory.grow(pages);
        if (prev < 0)
          throw new Error(
            "[crag] AudioWorklet: failed to grow WASM memory by " + pages +
            " pages for " + (requestedArena >> 20) + " MiB arena"
          );
      }
    }

    this._outputPtr    = e.crag_output    ? e.crag_output.value    : outputPtr;
    this._paramsPtr    = e.crag_params    ? e.crag_params.value    : paramsPtr;
    this._paramsI32Ptr = e.crag_params_i32 ? e.crag_params_i32.value : paramsI32Ptr;

    this._fireEventFn    = e.crag_fire_event        || null;
    this._fireEventF32Fn = e.crag_fire_event_float  || null;
    this._fireEventI32Fn = e.crag_fire_event_int    || null;
    this._fireEventStructFn = e.crag_fire_event_struct || null;
    this._bindSamplerFn  = e.crag_bind_audio_by_index || null;

    this._isStablePtr         = e.crag_is_stable          ? e.crag_is_stable.value          : 0;
    this._unstableCheckIdxPtr = e.crag_unstable_check_idx ? e.crag_unstable_check_idx.value : 0;

    this._vizFn        = e.crag_visualize  || null;
    this._vizOutputPtr = e.crag_viz_output ? e.crag_viz_output.value : 0;
    this._vizWidthFn   = e.crag_viz_width  || null;
    this._vizHeightFn  = e.crag_viz_height || null;
    this._numVisualizers = e.crag_num_visualizers ? e.crag_num_visualizers()
                         : (e.crag_has_visualizer && e.crag_has_visualizer() !== 0 ? 1 : 0);

    this._metersPtr    = e.crag_meters    ? e.crag_meters.value    : 0;
    this._metersI32Ptr = e.crag_meters_i32 ? e.crag_meters_i32.value : 0;
    this._numMeters    = e.crag_num_meters    ? e.crag_num_meters()    : 0;
    this._numMetersI32 = e.crag_num_meters_i32 ? e.crag_num_meters_i32() : 0;

    // Seed parameter values sent from the main thread.
    if (initialParams && this._paramsPtr) {
      const f32 = new Float32Array(this._memory.buffer);
      for (let i = 0; i < initialParams.length; i++)
        f32[(this._paramsPtr >> 2) + i] = initialParams[i];
    }
    if (initialParamsI32 && this._paramsI32Ptr) {
      const i32 = new Int32Array(this._memory.buffer);
      for (let i = 0; i < initialParamsI32.length; i++)
        i32[(this._paramsI32Ptr >> 2) + i] = initialParamsI32[i];
    }

    this._accumulator = new Float32Array(this._channels * this._blockSize * 4);
    // × 4 gives headroom so the ring buffer can hold multiple crag blocks,
    // which is needed when crag's block size is smaller than the Web Audio
    // quantum (128 samples).
    this._accumFill   = 0;
    this._ready       = true;

    this.port.postMessage({ type: "ready" });
  }

  _setParam(idx, value) {
    if (!this._ready || !this._paramsPtr) return;
    new Float32Array(this._memory.buffer)[(this._paramsPtr >> 2) + idx] = value;
  }

  _setParamInt(idx, value) {
    if (!this._ready || !this._paramsI32Ptr) return;
    new Int32Array(this._memory.buffer)[(this._paramsI32Ptr >> 2) + idx] = value | 0;
  }

  _bindSampler({ idx, samples }) {
    if (!this._ready || !this._bindSamplerFn) return;
    const numSamples = samples.length;
    const byteLen    = numSamples * 4;
    const aligned    = (byteLen + 7) & ~7;
    const mem        = this._memory;
    const heapState  = this._heapState;
    const ptr        = heapState.ptr;
    const next       = ptr + aligned;
    if (heapState.end && next > heapState.end) {
      const msg =
        "[crag] arena exhausted in AudioWorklet sampler bind: requested " +
        byteLen + " bytes (" + (byteLen >> 20) + " MiB), have " +
        (heapState.end - ptr) + " bytes free of " +
        (heapState.end - heapState.base) +
        " byte arena. Increase via CragPlayer.create(" +
        "wasmUrl, metaUrl, { arenaSize: <bytes> }).";
      heapState.lastError = msg;
      this.port.postMessage({ type: "error", message: msg });
      return;
    }
    if (next > mem.buffer.byteLength) {
      const pages = Math.ceil((next - mem.buffer.byteLength) / 65536);
      if (mem.grow(pages) < 0) {
        const msg = "[crag] AudioWorklet: failed to grow memory for sampler";
        heapState.lastError = msg;
        this.port.postMessage({ type: "error", message: msg });
        return;
      }
    }
    heapState.ptr = next;
    if (next > (heapState.peak | 0)) heapState.peak = next;
    new Float32Array(mem.buffer, ptr, numSamples).set(samples);
    this._bindSamplerFn(idx, BigInt(ptr), numSamples);
  }

  _fireWorkletEventStruct({ idx, sampleOffset, bytes }) {
    if (!this._ready || !this._fireEventStructFn) return;
    const byteLen = bytes.byteLength;
    if (byteLen <= 0 || byteLen > 65536) return; // sanity check — struct payloads are small
    const aligned   = (byteLen + 7) & ~7;
    const mem       = this._memory;
    const heapState = this._heapState;
    const ptr       = heapState.ptr;
    const next      = ptr + aligned;
    if (heapState.end && next > heapState.end) {
      heapState.lastError =
        "[crag] arena exhausted in AudioWorklet fireEventStruct";
      return;
    }
    if (next > mem.buffer.byteLength) {
      const pages = Math.ceil((next - mem.buffer.byteLength) / 65536);
      if (mem.grow(pages) < 0) return;
    }
    heapState.ptr = next;
    if (next > (heapState.peak | 0)) heapState.peak = next;
    new Uint8Array(mem.buffer, ptr, byteLen).set(bytes);
    this._fireEventStructFn(idx | 0, sampleOffset | 0, BigInt(ptr), byteLen);
  }

  _handleVisualize(idx) {
    if (!this._vizFn || !this._vizOutputPtr) return;
    idx = idx | 0;
    if (idx < 0 || idx >= this._numVisualizers) return;
    if (this._vizDisabled.has(idx)) return;
    // Save the bump-allocator pointer before calling crag_visualize so that
    // any heap allocations made inside the visualizer (e.g. the multiview
    // canvas and sub-texture memrefs allocated via memref.alloc) are reclaimed
    // after each frame.  Without this, 14+ MiB of textures would accumulate
    // in the arena on every visualize call and exhaust WASM memory.
    const heapBefore = this._heapState.ptr;
    try {
      this._vizFn(idx);
    } catch (_err) {
      // A buggy visualizer implementation should not kill audio playback.
      // Disable this index for the rest of this worklet lifetime.
      // Restoring the heap pointer here is safe: heapBefore was captured
      // before the call so it is always ≤ the current ptr (the bump
      // allocator only moves forward).  Restoring it reclaims any partial
      // allocations that happened before the trap, leaving the arena in the
      // same state as before the call.
      this._heapState.ptr = heapBefore;
      this._vizDisabled.add(idx);
      return;
    }
    this._heapState.ptr = heapBefore;
    const w = this._vizWidthFn  ? (this._vizWidthFn(idx)  | 0) : 0;
    const h = this._vizHeightFn ? (this._vizHeightFn(idx) | 0) : 0;
    if (w === 0 || h === 0) return;
    const pixels = w * h * 4;
    const bytesNeeded = pixels * 4;
    if (pixels <= 0 || bytesNeeded <= 0) return;
    const byteOffset = this._vizOutputPtr | 0;
    if ((byteOffset + bytesNeeded) > this._memory.buffer.byteLength) return;
    const f32 = new Float32Array(this._memory.buffer, byteOffset, pixels);
    const u8  = new Uint8ClampedArray(pixels);
    for (let i = 0; i < pixels; i++)
      u8[i] = Math.round(Math.min(Math.max(f32[i], 0), 1) * 255);
    // Transfer the backing ArrayBuffer to avoid a copy.
    this.port.postMessage(
      { type: "vizData", idx, data: u8.buffer, width: w, height: h },
      [u8.buffer]
    );
  }

  _checkInstability() {
    if (!this._isStablePtr) return null;
    const i32 = new Int32Array(this._memory.buffer);
    if (i32[this._isStablePtr >> 2] !== 0) return null;
    const checkIdx = this._unstableCheckIdxPtr
      ? i32[this._unstableCheckIdxPtr >> 2] : -1;
    let graphName = "<unknown>";
    if (checkIdx >= 0 && this._instance) {
      const nameSym    = "crag_instability_" + checkIdx + "_name";
      const nameExport = this._instance.exports[nameSym];
      if (nameExport) {
        const nameOffset = nameExport.value;
        const u8         = new Uint8Array(this._memory.buffer);
        let   name       = "";
        for (let i = nameOffset; u8[i] !== 0 && i < nameOffset + 256; i++)
          name += String.fromCharCode(u8[i]);
        graphName = name;
      }
    }
    return { checkIdx, graphName };
  }

  process(_inputs, outputs) {
    if (!this._ready || outputs[0].length === 0) return true;

    const bufSize = outputs[0][0].length;   // typically 128 samples per quantum

    while (this._accumFill < bufSize * this._channels) {
      // Snapshot/restore the bump-allocator pointer around crag_process so
      // that transient per-block memref.alloc allocations (whose paired
      // memref.dealloc lowers to a no-op free in this host) do not leak
      // across blocks.  Without this, the WASM linear memory fills up and
      // a memref store eventually traps with "RuntimeError: index out of
      // bounds".  Persistent state (sampler bindings, parameters, output
      // buffer) lives in static globals or in heap regions allocated
      // outside crag_process, so it is unaffected by the restore.
      const heapBefore = this._heapState.ptr;
      this._process();
      this._heapState.ptr = heapBefore;

      // Post meter values to main thread every 8 blocks.
      if (this._numMeters > 0 || this._numMetersI32 > 0) {
        this._meterPostCounter = (this._meterPostCounter || 0) + 1;
        if (this._meterPostCounter >= 8) {
          this._meterPostCounter = 0;
          const f32Arr = this._metersPtr
            ? new Float32Array(this._memory.buffer, this._metersPtr, this._numMeters).slice()
            : new Float32Array(0);
          const i32Arr = this._metersI32Ptr
            ? new Int32Array(this._memory.buffer, this._metersI32Ptr, this._numMetersI32).slice()
            : new Int32Array(0);
          const f32Buf = f32Arr.buffer;
          const i32Buf = i32Arr.buffer;
          this.port.postMessage({ type: "meterData", f32: f32Buf, i32: i32Buf },
                                [f32Buf, i32Buf]);
        }
      }

      const instability = this._checkInstability();
      if (instability) {
        this.port.postMessage({ type: "instability", ...instability });
        this._ready = false;
        // Return false to signal the processor should be removed.
        return false;
      }

      // crag_block_size() (this._blockSize) already returns the TOTAL
      // interleaved sample count of crag_output (frames * channels), so the
      // view length is this._blockSize — NOT this._blockSize * channels.
      // Multiplying by channels again reads twice the real buffer and splices
      // the uninitialised back half into the output every block: for stereo
      // (channels = 2) graphs that is audible block-rate zippering. (Mono
      // graphs were unaffected because * 1 is a no-op.)
      const view = new Float32Array(
        this._memory.buffer, this._outputPtr, this._blockSize
      );
      const needed = Math.min(view.length, this._accumulator.length - this._accumFill);
      this._accumulator.set(view.subarray(0, needed), this._accumFill);
      this._accumFill += needed;
    }

    for (let ch = 0; ch < outputs[0].length; ch++) {
      const chData = outputs[0][ch];
      for (let i = 0; i < bufSize; i++)
        chData[i] = this._accumulator[i * this._channels + ch] || 0;
    }

    const consumed = bufSize * this._channels;
    this._accumulator.copyWithin(0, consumed);
    this._accumFill -= consumed;
    if (this._accumFill < 0) this._accumFill = 0;

    return true;
  }
}

registerProcessor("crag-processor", CragProcessor);
`;

  // ---------------------------------------------------------------------------
  // CragPlayer class
  // ---------------------------------------------------------------------------

  class CragPlayer {
    /**
     * @param {WebAssembly.Instance} instance    Instantiated WASM module.
     * @param {object}               meta         Parsed .cragmeta JSON.
     * @param {object}               heapState    Bump-allocator state { ptr }.
     * @param {WebAssembly.Module}   [wasmModule] Compiled module (main-thread instance).
     */
    constructor(instance, meta, heapState, wasmModule) {
      this._instance = instance;
      this.meta = meta;
      this._heapState = heapState;
      this._wasmModule = wasmModule || null;
      // Raw WASM bytes, retained so start() can hand them to the AudioWorklet.
      // The worklet compiles its own instance from these because Chromium/Edge
      // cannot clone a WebAssembly.Module across the AudioWorklet message port
      // (an ArrayBuffer clones fine).  Set by CragPlayer.create().
      this._wasmBytes = null;

      const e = instance.exports;
      this._memory    = e.memory;
      this._process   = e.crag_process;
      this._blockSize = e.crag_block_size();
      this._numParams = e.crag_num_params();
      this._outputPtr = e.crag_output ? e.crag_output.value : 0;
      this._paramsPtr = e.crag_params ? e.crag_params.value : 0;

      // Int/bool/enum parameter support.
      this._numParamsI32 = e.crag_num_params_i32 ? e.crag_num_params_i32() : 0;
      this._paramsI32Ptr = e.crag_params_i32 ? e.crag_params_i32.value : 0;

      // Event support (optional — only present when the graph uses event ops).
      this._numEvents     = e.crag_num_events     ? e.crag_num_events()     : 0;
      this._numEventsF32  = e.crag_num_events_f32 ? e.crag_num_events_f32() : 0;
      this._numEventsI32  = e.crag_num_events_i32 ? e.crag_num_events_i32() : 0;
      this._fireEvent     = e.crag_fire_event      || null;
      this._fireEventF32  = e.crag_fire_event_float || null;
      this._fireEventI32  = e.crag_fire_event_int  || null;
      this._fireEventStruct = e.crag_fire_event_struct || null;

      // Meter support (optional — only present when the graph uses meter ops).
      this._numMeters    = e.crag_num_meters    ? e.crag_num_meters()    : 0;
      this._numMetersI32 = e.crag_num_meters_i32 ? e.crag_num_meters_i32() : 0;
      this._metersPtr    = e.crag_meters    ? e.crag_meters.value    : 0;
      this._metersI32Ptr = e.crag_meters_i32 ? e.crag_meters_i32.value : 0;

      // Sampler support (optional — only present when the graph uses
      // crag.sampler ops).
      this._numSamplers = e.crag_num_audio ? e.crag_num_audio() : 0;
      this._bindSamplerByIndex = e.crag_bind_audio_by_index || null;
      this._samplerNames = (meta.samplers || []).slice();

      // Instability-check support (optional — only present when the graph was
      // compiled with crag-inject-instability-check).
      this._isStablePtr         = e.crag_is_stable ? e.crag_is_stable.value : 0;
      this._unstableCheckIdxPtr = e.crag_unstable_check_idx
                                    ? e.crag_unstable_check_idx.value : 0;
      this._instabilityCheckCount =
          e.crag_instability_check_count ? e.crag_instability_check_count() : 0;

      // Visualizer support (optional — only present when compiled with
      // --inject-visualizer).
      // crag_num_visualizers() returns the count; crag_has_visualizer() is a
      // backward-compat alias returning 1 if any visualizer is present.
      this._numVisualizers = e.crag_num_visualizers ? e.crag_num_visualizers()
                           : (e.crag_has_visualizer && e.crag_has_visualizer() !== 0 ? 1 : 0);
      this._hasVisualizer  = this._numVisualizers > 0;
      // crag_viz_width / crag_viz_height now take an index.
      this._vizW = this._hasVisualizer && e.crag_viz_width  ? e.crag_viz_width(0)  : 0;
      this._vizH = this._hasVisualizer && e.crag_viz_height ? e.crag_viz_height(0) : 0;
      this._vizOutputPtr = e.crag_viz_output ? e.crag_viz_output.value : 0;
      this._crag_visualize = e.crag_visualize || null;
      this._crag_viz_width_fn  = e.crag_viz_width  || null;
      this._crag_viz_height_fn = e.crag_viz_height || null;

      this._audioCtx    = null;
      this._workletNode = null;
      this._workletReady = false;
      this._startAbort  = null;   // abort callback while awaiting start()
      this._starting    = false;  // true while start() is in flight
      // idx -> ImageData; populated by vizData messages from the worklet.
      this._vizCache    = new Map();
      // idx -> Float32Array; kept so samplers bound before start() can be
      // replayed to the worklet after it initialises.
      this._samplerData = new Map();
      this._running     = false;
    }

    get blockSize() { return this._blockSize; }
    get numParams() { return this._numParams; }
    get numParamsI32() { return this._numParamsI32; }
    get numSamplers() { return this._numSamplers; }
    get samplerNames() { return this._samplerNames; }
    get numVisualizers() { return this._numVisualizers; }
    get hasVisualizer() { return this._hasVisualizer; }
    get vizWidth()  { return this._vizW; }
    get vizHeight() { return this._vizH; }
    get numEvents()    { return this._numEvents; }
    get numEventsF32() { return this._numEventsF32; }
    get numEventsI32() { return this._numEventsI32; }
    get numMeters()    { return this._numMeters; }
    get numMetersI32() { return this._numMetersI32; }

    /**
     * Set a float parameter by index.
     * @param {number} idx   Parameter index (0-based).
     * @param {number} value Float value.
     */
    setParam(idx, value) {
      if (idx < 0 || idx >= this._numParams) return;
      const view = new Float32Array(this._memory.buffer);
      view[(this._paramsPtr >> 2) + idx] = value;
      if (this._workletNode && this._workletReady)
        this._workletNode.port.postMessage({ type: "setParam", idx, value });
    }

    /**
     * Get a float parameter by index.
     * @param {number} idx  Parameter index (0-based).
     * @returns {number}
     */
    getParam(idx) {
      if (idx < 0 || idx >= this._numParams) return 0;
      const view = new Float32Array(this._memory.buffer);
      return view[(this._paramsPtr >> 2) + idx];
    }

    /**
     * Set an integer/boolean/enum parameter by index.
     * @param {number} idx   Int-param index (0-based, separate from float idx).
     * @param {number} value Integer value (0/1 for bool, enum index for enum).
     */
    setParamInt(idx, value) {
      if (idx < 0 || idx >= this._numParamsI32) return;
      const view = new Int32Array(this._memory.buffer);
      view[(this._paramsI32Ptr >> 2) + idx] = value | 0;
      if (this._workletNode && this._workletReady)
        this._workletNode.port.postMessage({ type: "setParamInt", idx, value: value | 0 });
    }

    /**
     * Get an integer/boolean/enum parameter by index.
     * @param {number} idx  Int-param index (0-based).
     * @returns {number}
     */
    getParamInt(idx) {
      if (idx < 0 || idx >= this._numParamsI32) return 0;
      const view = new Int32Array(this._memory.buffer);
      return view[(this._paramsI32Ptr >> 2) + idx];
    }

    /**
     * Read a float meter by index.
     * @param {number} idx  Meter index (0-based).
     * @returns {number}
     */
    getMeter(idx) {
      if (idx < 0 || idx >= this._numMeters || !this._metersPtr) return 0;
      const view = new Float32Array(this._memory.buffer);
      return view[(this._metersPtr >> 2) + idx];
    }

    /**
     * Read an integer/boolean/enum meter by index.
     * @param {number} idx  Int-meter index (0-based).
     * @returns {number}
     */
    getMeterInt(idx) {
      if (idx < 0 || idx >= this._numMetersI32 || !this._metersI32Ptr) return 0;
      const view = new Int32Array(this._memory.buffer);
      return view[(this._metersI32Ptr >> 2) + idx];
    }

    /**
     * Fire a void event at a specific sample within the next audio block.
     *
     * The event is consumed exactly once — calling this before the next
     * `crag_process()` call causes the graph to see `fired=true` and
     * `sample_offset=sampleOffset` in that block.  Calling it multiple times
     * before the next process call retains only the most recent value (last
     * wins; the graph always consumes at most one trigger per block).
     *
     * @param {number} idx          Void-event index (0-based).
     * @param {number} [sampleOffset=0]  Sample within the block where the
     *                                   event fires (0 = first sample).
     */
    fireEvent(idx, sampleOffset = 0) {
      if (idx < 0 || idx >= this._numEvents) return;
      if (this._fireEvent) {
        this._fireEvent(idx, sampleOffset | 0);
      }
      if (this._workletNode && this._workletReady)
        this._workletNode.port.postMessage({ type: "fireEvent", idx, sampleOffset: sampleOffset | 0 });
    }

    /**
     * Fire a float-valued event at a specific sample within the next block.
     *
     * @param {number} idx           Float-event index (0-based).
     * @param {number} sampleOffset  Sample offset within the block.
     * @param {number} value         Float payload value.
     */
    fireEventFloat(idx, sampleOffset, value) {
      if (idx < 0 || idx >= this._numEventsF32) return;
      if (this._fireEventF32) {
        this._fireEventF32(idx, sampleOffset | 0, +value);
      }
      if (this._workletNode && this._workletReady)
        this._workletNode.port.postMessage({ type: "fireEventFloat", idx, sampleOffset: sampleOffset | 0, value: +value });
    }

    /**
     * Fire an integer/boolean/enum event at a specific sample within the
     * next block.
     *
     * @param {number} idx           Int-event index (0-based).
     * @param {number} sampleOffset  Sample offset within the block.
     * @param {number} value         Integer payload (0/1 for bool, enum index
     *                                for enum).
     */
    fireEventInt(idx, sampleOffset, value) {
      if (idx < 0 || idx >= this._numEventsI32) return;
      if (this._fireEventI32) {
        this._fireEventI32(idx, sampleOffset | 0, value | 0);
      }
      if (this._workletNode && this._workletReady)
        this._workletNode.port.postMessage({ type: "fireEventInt", idx, sampleOffset: sampleOffset | 0, value: value | 0 });
    }

    /**
     * Fire a struct event at a specific sample within the next block.
     *
     * The *bytes* argument is a Uint8Array whose contents match the struct
     * payload expected by the graph (same field order, natural C alignment,
     * little-endian).  The caller is responsible for building the correct
     * payload — typically via a DataView with setFloat32/setInt32 calls at
     * the byte offsets listed in the .cragmeta struct_fields array.
     *
     * @param {number}     idx           Int-event index (from struct event's
     *                                   int_index in .cragmeta).
     * @param {number}     sampleOffset  Sample offset within the block.
     * @param {Uint8Array} bytes         Packed struct payload bytes.
     */
    fireEventStruct(idx, sampleOffset, bytes) {
      if (!this._fireEventStruct && !(this._workletNode && this._workletReady)) return;
      const byteLen = bytes.byteLength;
      if (byteLen <= 0 || byteLen > 65536) return; // sanity check — struct payloads are small
      if (this._fireEventStruct) {
        // Write the struct bytes into the main-thread WASM linear memory using
        // the bump allocator and call the exported function.
        const mem       = this._memory;
        const aligned   = (byteLen + 7) & ~7;
        const heapState = this._heapState;
        const ptr       = heapState.ptr;
        const next      = ptr + aligned;
        if (heapState.end && next > heapState.end) {
          const msg =
            "[crag] arena exhausted in fireEventStruct: requested " +
            byteLen + " bytes, have " + (heapState.end - ptr) +
            " bytes free of " + (heapState.end - heapState.base) +
            " byte arena. Increase via CragPlayer.create(" +
            "wasmUrl, metaUrl, { arenaSize: <bytes> }).";
          heapState.lastError = msg;
          throw new RangeError(msg);
        }
        if (next > mem.buffer.byteLength) {
          const pages = Math.ceil((next - mem.buffer.byteLength) / 65536);
          if (mem.grow(pages) < 0)
            throw new Error("[crag] failed to grow WASM memory for fireEventStruct");
        }
        heapState.ptr = next;
        if (next > (heapState.peak | 0)) heapState.peak = next;
        new Uint8Array(mem.buffer, ptr, byteLen).set(bytes);
        this._fireEventStruct(idx | 0, sampleOffset | 0, BigInt(ptr), byteLen);
      }
      if (this._workletNode && this._workletReady) {
        // Transfer a copy to the worklet so it can write the bytes into its
        // own WASM linear memory before calling crag_fire_event_struct.
        const copy = bytes.slice();
        this._workletNode.port.postMessage(
          { type: "fireEventStruct", idx, sampleOffset: sampleOffset | 0, bytes: copy },
          [copy.buffer]
        );
      }
    }

    /**
     * Create an HTML `<button>` element that fires the void event at index
     * *idx* when clicked.  The button is appended to *container* (if given)
     * and returned so the caller can style it.
     *
     * The click fires at sample offset 0 (beginning of the next block).
     *
     * @param {number}      idx        Void-event index (0-based).
     * @param {string}      [label]    Button label.  Defaults to the event
     *                                 name from the .cragmeta if available,
     *                                 otherwise "Trigger".
     * @param {HTMLElement} [container] Parent element to append to.
     * @returns {HTMLButtonElement}
     */
    createEventButton(idx, label, container) {
      const evMeta  = (this.meta.events || [])[idx];
      const btnLabel = label
        || (evMeta && evMeta.name ? evMeta.name : "Trigger");
      const btn = document.createElement("button");
      btn.textContent = btnLabel;
      btn.addEventListener("click", () => this.fireEvent(idx, 0));
      if (container) container.appendChild(btn);
      return btn;
    }

    /**
     * Check whether the compiled graph has signalled instability.
     * Returns null if the graph is stable, or an info object if unstable:
     *   { checkIdx: number, graphName: string, params: number[] }
     * Only meaningful when the graph was compiled with
     * crag-inject-instability-check.
     * @returns {object|null}
     */
    checkInstability() {
      // When the AudioWorklet is running, instability is detected and reported
      // inside the worklet.  The main-thread instance never calls crag_process()
      // in that mode, so its stability flag is never updated.
      if (this._workletNode) return null;
      if (!this._isStablePtr) return null;
      const i32View = new Int32Array(this._memory.buffer);
      const isStable = i32View[this._isStablePtr >> 2];
      if (isStable !== 0) return null;

      const checkIdx = this._unstableCheckIdxPtr
        ? i32View[this._unstableCheckIdxPtr >> 2]
        : -1;

      // Read the graph name from @crag_instability_N_name (null-terminated).
      let graphName = "<unknown>";
      if (checkIdx >= 0) {
        const nameSym = "crag_instability_" + checkIdx + "_name";
        const nameExport = this._instance.exports[nameSym];
        if (nameExport) {
          const nameOffset = nameExport.value;
          const u8 = new Uint8Array(this._memory.buffer);
          let name = "";
          for (let i = nameOffset; u8[i] !== 0 && i < nameOffset + 256; i++)
            name += String.fromCharCode(u8[i]);
          graphName = name;
        }
      }

      // Collect all current parameter values.
      const params = [];
      for (let pi = 0; pi < this._numParams; pi++)
        params.push(this.getParam(pi));

      return { checkIdx, graphName, params };
    }

    /**
     * Fetch a WAV file from a URL, decode it, copy into WASM linear memory,
     * and bind it to sampler slot *idx* via crag_bind_audio_by_index.
     *
     * The WAV must be 16-bit signed PCM or 32-bit IEEE-float PCM.
     *
     * @param {number}         idx  Sampler index (0-based).
     * @param {string|URL}     url  URL of the WAV file to load.
     * @returns {Promise<void>}
     */
    async bindSamplerFromUrl(idx, url) {
      const resp = await fetch(url);
      if (!resp.ok)
        throw new Error(`Failed to fetch sampler WAV ${url}: ${resp.status}`);
      const arrayBuffer = await resp.arrayBuffer();
      this.bindSamplerFromArrayBuffer(idx, arrayBuffer);
    }

    /**
     * Decode a WAV ArrayBuffer, copy samples into WASM linear memory, and
     * bind to sampler slot *idx* via crag_bind_audio_by_index.
     *
     * The WAV must be 16-bit signed PCM or 32-bit IEEE-float PCM.
     *
     * @param {number}      idx          Sampler index (0-based).
     * @param {ArrayBuffer} arrayBuffer  ArrayBuffer containing a WAV file.
     */
    bindSamplerFromArrayBuffer(idx, arrayBuffer) {
      if (idx < 0 || idx >= this._numSamplers)
        throw new RangeError(
          `Sampler index ${idx} out of range (0–${this._numSamplers - 1})`
        );
      if (!this._bindSamplerByIndex)
        throw new Error("crag_bind_audio_by_index not exported by this WASM module");

      const samples = decodeWavToFloat32(arrayBuffer);

      // Keep a copy so samplers bound before start() can be replayed to the
      // worklet during initialisation, and those bound after start() can be
      // forwarded immediately.
      this._samplerData.set(idx, samples);

      if (this._workletNode && this._workletReady) {
        // Transfer a copy to the worklet (transfer to avoid an extra copy of
        // the backing buffer; slice() keeps the main-thread copy intact).
        const copy = samples.slice();
        this._workletNode.port.postMessage(
          { type: "bindSampler", idx, samples: copy },
          [copy.buffer]
        );
      }
    }

    /**
     * Start real-time audio output via an AudioWorkletNode.
     * Requires a user gesture to satisfy browser autoplay policies.
     * Returns a Promise that resolves once the worklet is ready and audio has
     * begun.  Callers that do not need to await the start are free to ignore
     * the returned Promise.
     * @returns {Promise<void>}
     */
    async start() {
      if (this._running || this._starting) return;
      if (!this._wasmBytes)
        throw new Error("[crag] No WASM bytes available for AudioWorklet. " +
          "Ensure CragPlayer.create() was used to construct this player.");

      this._starting = true;
      try {
        await this._startInternal();
      } catch (e) {
        // Clean up any partially-initialised state so that a subsequent
        // start() call can try again from a clean slate.
        this._startAbort = null;
        if (this._workletNode) {
          this._workletNode.port.onmessage = null;
          this._workletNode.disconnect();
          this._workletNode  = null;
          this._workletReady = false;
        }
        if (this._audioCtx) {
          this._audioCtx.close();
          this._audioCtx = null;
        }
        throw e;
      } finally {
        this._starting = false;
      }
    }

    async _startInternal() {
      const sampleRate = this.meta.sample_rate || 48000;
      const channels   = this.meta.channels    || 1;

      this._audioCtx = new (window.AudioContext || window.webkitAudioContext)(
        { sampleRate }
      );

      // Resume the context if it was created while suspended (e.g. before a
      // user gesture in some browsers).  This is a no-op when already running.
      await this._audioCtx.resume();

      // Load the inline worklet processor via a temporary Blob URL so that
      // no separate .js file is required.
      const blob    = new Blob([_CRAG_WORKLET_CODE], { type: "application/javascript" });
      const blobUrl = URL.createObjectURL(blob);
      try {
        await this._audioCtx.audioWorklet.addModule(blobUrl);
      } finally {
        URL.revokeObjectURL(blobUrl);
      }

      const workletNode = new AudioWorkletNode(this._audioCtx, "crag-processor", {
        numberOfInputs:     0,
        numberOfOutputs:    1,
        outputChannelCount: [channels],
      });

      // Connect the node and store the reference *before* sending "init".
      // Some browsers only dispatch port messages on the audio thread once the
      // node is part of the audio graph; connecting here avoids a deadlock
      // where "init" is sent but the worklet never processes it.  stop() uses
      // this._workletNode for cleanup even while init is in flight.
      workletNode.connect(this._audioCtx.destination);
      this._workletNode = workletNode;

      // Collect current parameter values to seed the worklet's WASM instance.
      const initialParams = [];
      for (let i = 0; i < this._numParams; i++)
        initialParams.push(this.getParam(i));
      const initialParamsI32 = [];
      for (let i = 0; i < this._numParamsI32; i++)
        initialParamsI32.push(this.getParamInt(i));

      // Wait for the worklet to instantiate its WASM copy and signal "ready".
      // 10 s is generous; WASM instantiation typically completes in < 100 ms.
      await new Promise((resolve, reject) => {
        const timeout = setTimeout(
          () => reject(new Error("[crag] AudioWorklet initialisation timed out")),
          10000
        );

        // Store an abort function so stop() can cancel the pending Promise.
        this._startAbort = () => {
          clearTimeout(timeout);
          reject(new Error("[crag] start() aborted by stop()"));
        };

        workletNode.port.onmessage = (ev) => {
          const msg = ev.data;
          switch (msg.type) {
            case "hello":
              // The processor is constructed and its port is listening, so it
              // is now safe to send the init payload.  Posting it earlier (right
              // after `new AudioWorkletNode`) races processor construction and
              // is dropped by Chromium/Edge — only Firefox queues it.
              workletNode.port.postMessage({
                type:            "init",
                wasmBytes:       this._wasmBytes,
                heapPtr:         this._heapState.ptr,
                arenaSize:       this._arenaSize || DEFAULT_ARENA_BYTES,
                channels,
                outputPtr:       this._outputPtr,
                paramsPtr:       this._paramsPtr,
                paramsI32Ptr:    this._paramsI32Ptr,
                initialParams,
                initialParamsI32,
              });
              break;
            case "ready":
              clearTimeout(timeout);
              this._startAbort    = null;
              this._workletReady  = true;
              // Replay any sampler data that was bound before start().
              for (const [samplerIdx, samples] of this._samplerData) {
                const copy = samples.slice();
                workletNode.port.postMessage(
                  { type: "bindSampler", idx: samplerIdx, samples: copy },
                  [copy.buffer]
                );
              }
              // Do NOT clear _samplerData so samplers are replayed on restart.
              resolve();
              break;
            case "error":
              clearTimeout(timeout);
              this._startAbort = null;
              reject(new Error("[crag] AudioWorklet init failed: " + msg.message));
              break;
            case "instability":
              console.error(
                "[crag] INSTABILITY DETECTED in graph: '" +
                msg.graphName + "' (check index " + msg.checkIdx + ")"
              );
              this.stop();
              break;
            case "vizData": {
              const u8 = new Uint8ClampedArray(msg.data);
              this._vizCache.set(msg.idx, new ImageData(u8, msg.width, msg.height));
              break;
            }
            case "meterData": {
              if (msg.f32 && msg.f32.byteLength > 0 && this._metersPtr) {
                const f32 = new Float32Array(msg.f32);
                const view = new Float32Array(this._memory.buffer);
                for (let i = 0; i < f32.length; i++)
                  view[(this._metersPtr >> 2) + i] = f32[i];
              }
              if (msg.i32 && msg.i32.byteLength > 0 && this._metersI32Ptr) {
                const i32 = new Int32Array(msg.i32);
                const view = new Int32Array(this._memory.buffer);
                for (let i = 0; i < i32.length; i++)
                  view[(this._metersI32Ptr >> 2) + i] = i32[i];
              }
              break;
            }
          }
        };

        // The init payload is sent in response to the worklet's "hello"
        // handshake above (see the "hello" case) rather than here, so it is
        // never posted before the processor's port is listening.
      });

      this._running = true;
    }

    /**
     * Request a visualizer frame from the AudioWorklet and return the most
     * recently received ImageData for visualizer index *idx*.
     *
     * The call is non-blocking: it asks the worklet to render the current
     * frame and post back pixel data, then returns whatever was cached from
     * the previous request (null on the very first call before any data has
     * arrived).  In a requestAnimationFrame loop this produces smooth output
     * with at most one frame of latency.
     *
     * Returns null if no visualizer is present or idx is out of range.
     * @param {number} [idx=0]  Visualizer index (0-based).
     * @returns {ImageData|null}
     */
    visualize(idx = 0) {
      if (!this._hasVisualizer) return null;
      if (idx < 0 || idx >= this._numVisualizers) return null;
      if (this._workletNode && this._workletReady)
        this._workletNode.port.postMessage({ type: "visualize", idx });
      return this._vizCache.get(idx) || null;
    }

    /** Stop real-time audio output. */
    stop() {
      if (!this._running && !this._startAbort) return;
      // If stop() is called while awaiting start(), abort the pending Promise.
      if (this._startAbort) {
        this._startAbort();
        this._startAbort = null;
      }
      if (this._workletNode) {
        this._workletNode.port.onmessage = null;
        this._workletNode.disconnect();
        this._workletNode  = null;
        this._workletReady = false;
      }
      if (this._audioCtx) {
        this._audioCtx.close();
        this._audioCtx = null;
      }
      this._running = false;
    }

    /**
     * Return a snapshot of the bump-arena instrumentation for the
     * **main-thread** WASM instance.  Useful for diagnosing
     * "RuntimeError: index out of bounds" failures originating from large
     * sampler binds or other allocations: a `peak` close to `end` indicates
     * the arena is too small and `arenaSize` should be increased via
     * `CragPlayer.create(wasm, meta, { arenaSize: <bytes> })`.
     *
     * @returns {{
     *   base: number,
     *   ptr: number,
     *   end: number,
     *   peak: number,
     *   used: number,
     *   capacity: number,
     *   free: number,
     *   allocCount: number,
     *   memoryBytes: number,
     *   lastError: (string|null)
     * }}
     */
    getAllocatorStats() {
      const h = this._heapState;
      const memBytes = this._memory ? this._memory.buffer.byteLength : 0;
      return {
        base:        h.base | 0,
        ptr:         h.ptr  | 0,
        end:         h.end  | 0,
        peak:        h.peak | 0,
        used:        (h.ptr  - h.base) | 0,
        capacity:    (h.end  - h.base) | 0,
        free:        (h.end  - h.ptr ) | 0,
        allocCount:  h.allocCount | 0,
        memoryBytes: memBytes,
        lastError:   h.lastError || null,
      };
    }

    // -------------------------------------------------------------------------
    // Factory
    // -------------------------------------------------------------------------

    /**
     * Load and instantiate a crag WASM graph.
     *
     * @param {string|URL} wasmUrl   URL of the .wasm file.
     * @param {string|URL} metaUrl   URL of the .wasm.cragmeta file.
     *                               If omitted, "<wasmUrl>.cragmeta" is used.
     * @param {object}     [options]
     * @param {number}     [options.arenaSize]  Size in bytes of the bump
     *                     allocator's arena.  Defaults to 256 MiB
     *                     ({@link DEFAULT_ARENA_BYTES}).  WASM linear memory
     *                     is pre-grown to fit `__heap_base + arenaSize` so
     *                     large `bindSamplerFromArrayBuffer` payloads do not
     *                     trap with "RuntimeError: index out of bounds".
     * @returns {Promise<CragPlayer>}
     */
    static async create(wasmUrl, metaUrl, options) {
      if (!metaUrl) metaUrl = wasmUrl + ".cragmeta";
      const opts      = options || {};
      const arenaSize = (typeof opts.arenaSize === "number" && opts.arenaSize > 0)
        ? opts.arenaSize
        : DEFAULT_ARENA_BYTES;

      // Fetch metadata.
      const meta = await fetch(metaUrl).then((r) => {
        if (!r.ok) throw new Error(`Failed to fetch ${metaUrl}: ${r.status}`);
        return r.json();
      });

      // Instrumented bump-arena state shared between the import object and
      // the post-init fixup.  Bounds (base/end) and counters are populated
      // once __heap_base is known.
      const heapState = {
        ptr:        8 * 1024 * 1024, // provisional until __heap_base fixup
        base:       0,
        end:        0,               // disabled until base is finalised
        peak:       0,
        allocCount: 0,
        lastError:  null,
      };
      // Memory state: populated from instance.exports.memory after instantiation
      // so that memset/memcpy/memmove have access to WASM linear memory.
      const memState = { memory: null };

      const importObj = makeCragImports(heapState, memState);

      // Fetch the WASM bytes once.  We instantiate the main-thread instance
      // from these bytes AND retain them to hand to the AudioWorklet at
      // start() (see CragPlayer._wasmBytes): Chromium/Edge silently drop an
      // AudioWorklet-port message carrying a WebAssembly.Module, but an
      // ArrayBuffer clones fine, so the worklet compiles its own instance.
      // (instantiateStreaming is skipped here because we need the bytes in
      // hand; the module is small and this runs once at load.)
      const wasmBytes = await fetch(wasmUrl).then((r) => {
        if (!r.ok) throw new Error(`Failed to fetch ${wasmUrl}: ${r.status}`);
        return r.arrayBuffer();
      });
      const { instance, module: wasmModule } =
        await WebAssembly.instantiate(wasmBytes, importObj);

      // Fix up heap pointer from the exported __heap_base symbol.
      if (instance.exports.__heap_base) {
        heapState.ptr = instance.exports.__heap_base.value;
      }
      // Populate the memory reference for memset/memcpy/memmove.
      if (instance.exports.memory) {
        memState.memory = instance.exports.memory;
      }

      // Establish the arena bounds and pre-grow WASM linear memory so the
      // entire arena (default 256 MiB) is backed up front.  This is what
      // prevents large sampler binds from pushing the bump pointer past the
      // initial 16 KiB linear memory and trapping with
      // "RuntimeError: index out of bounds" inside the wasm module.
      heapState.base = heapState.ptr;
      heapState.peak = heapState.ptr;
      heapState.end  = heapState.base + arenaSize;
      if (memState.memory) {
        growMemoryTo(memState.memory, heapState.end);
      }

      // Apply default parameter values from metadata.
      const player = new CragPlayer(instance, meta, heapState, wasmModule);
      player._wasmBytes = wasmBytes;
      player._arenaSize = arenaSize;
      let floatIdx = 0, intIdx = 0;
      (meta.parameters || []).forEach((p) => {
        const type = p.type || "float";
        if (type === "float") {
          const idx = p.float_index !== undefined ? p.float_index : floatIdx;
          player.setParam(idx, p.default !== undefined ? p.default : 0);
          if (p.float_index === undefined) floatIdx++;
        } else {
          // int, bool, enum — use int_index if present, else sequential
          const idx = p.int_index !== undefined ? p.int_index : intIdx;
          player.setParamInt(idx, p.default !== undefined ? p.default : 0);
          if (p.int_index === undefined) intIdx++;
        }
      });

      return player;
    }
  }

  return CragPlayer;
});
