/**
 * crag_player.js — Web Audio host for WASM crag graph binaries.
 *
 * Usage:
 *   const player = await CragPlayer.create('graph.wasm', 'graph.wasm.cragmeta');
 *   player.start();      // begin audio output
 *   player.stop();       // stop audio output
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

  /**
   * Build the WebAssembly import object for a crag WASM module.
   * Math functions are supplied from JavaScript's Math object.
   * A simple bump-allocator handles malloc.
   *
   * @param {object} heapState  Mutable object: { ptr: number }
   *                            The caller updates ptr from __heap_base after
   *                            instantiation.
   * @param {object} memState   Mutable object: { memory: WebAssembly.Memory|null }
   *                            The caller sets memory from instance.exports.memory
   *                            after instantiation so that memset/memcpy/memmove
   *                            have access to the linear memory buffer.
   */
  function makeCragImports(heapState, memState) {
    return {
      env: {
        // ----------------------------------------------------------------
        // malloc — bump allocator; heapState.ptr is updated post-init.
        // The WASM ABI may pass i32 or i64 sizes; handle both.
        // ----------------------------------------------------------------
        malloc(size) {
          const sz = typeof size === "bigint" ? Number(size) : size;
          const aligned = (sz + 7) & ~7;
          const ptr = heapState.ptr;
          heapState.ptr += aligned;
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
        hypot: Math.hypot.bind(Math),
        copysign: (mag, sgn) => Math.abs(mag) * (sgn < 0 || (sgn === 0 && (1/sgn) === -Infinity) ? -1 : 1),
        sinh: Math.sinh.bind(Math),
        cosh: Math.cosh.bind(Math),
        tanh: Math.tanh.bind(Math),
        asinh: Math.asinh.bind(Math),
        acosh: Math.acosh.bind(Math),
        atanh: Math.atanh.bind(Math),
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
  // CragPlayer class
  // ---------------------------------------------------------------------------

  class CragPlayer {
    /**
     * @param {WebAssembly.Instance} instance  Instantiated WASM module.
     * @param {object}               meta       Parsed .cragmeta JSON.
     * @param {object}               heapState  Bump-allocator state { ptr }.
     */
    constructor(instance, meta, heapState) {
      this._instance = instance;
      this.meta = meta;
      this._heapState = heapState;

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
      this._scriptNode  = null;
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

    /**
     * Set a float parameter by index.
     * @param {number} idx   Parameter index (0-based).
     * @param {number} value Float value.
     */
    setParam(idx, value) {
      if (idx < 0 || idx >= this._numParams) return;
      const view = new Float32Array(this._memory.buffer);
      view[(this._paramsPtr >> 2) + idx] = value;
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
      const numSamples = samples.length;
      const byteLen    = numSamples * 4;   // f32 = 4 bytes/sample

      // Grow WASM linear memory if the current buffer is too small to hold
      // the sample data at the current heap pointer.
      const mem = this._memory;
      const needed = this._heapState.ptr + byteLen;
      if (needed > mem.buffer.byteLength) {
        // WebAssembly pages are 64 KiB each.
        const pages = Math.ceil((needed - mem.buffer.byteLength) / 65536);
        mem.grow(pages);
      }

      // Allocate from the bump allocator.
      const ptr = this._heapState.ptr;
      this._heapState.ptr += (byteLen + 7) & ~7;  // keep 8-byte alignment

      // Copy Float32 samples into WASM memory.
      const dest = new Float32Array(mem.buffer, ptr, numSamples);
      dest.set(samples);

      // crag_bind_audio_by_index(i32 idx, i64 ptr, i32 len)
      // i64 is represented as BigInt in the WASM JS API.
      this._bindSamplerByIndex(idx, BigInt(ptr), numSamples);
    }

    /**
     * Start real-time audio output.
     * Requires a user gesture to satisfy browser autoplay policies.
     */
    start() {
      if (this._running) return;

      const sampleRate = this.meta.sample_rate || 48000;
      const channels   = this.meta.channels    || 1;

      this._audioCtx = new (window.AudioContext || window.webkitAudioContext)(
        { sampleRate }
      );

      // ScriptProcessorNode (deprecated but universally supported).
      // bufferSize must be a power-of-two; use the crag block size if it
      // qualifies, otherwise fall back to 4096.
      const validSizes = [256, 512, 1024, 2048, 4096, 8192, 16384];
      const bufSize = validSizes.includes(this._blockSize)
        ? this._blockSize
        : 4096;

      const node = this._audioCtx.createScriptProcessor(bufSize, 0, channels);

      // Samples to accumulate / discard when crag block size ≠ bufSize.
      let accumulator = new Float32Array(channels * bufSize * 4);
      let accumFill = 0;

      node.onaudioprocess = (ev) => {
        // Fill accumulator until we have enough for the output buffer.
        while (accumFill < bufSize * channels) {
          this._process();

          // Check for instability after each crag_process() call.
          const instability = this.checkInstability();
          if (instability) {
            console.error(
              "[crag] INSTABILITY DETECTED in graph: '" +
              instability.graphName + "' (check index " +
              instability.checkIdx + ")"
            );
            const paramStr = instability.params
              .map((v, i) => "param[" + i + "]=" + v.toFixed(6))
              .join(", ");
            console.error("[crag] Current parameter values: " + paramStr);
            this.stop();
            return;
          }

          const view = new Float32Array(
            this._memory.buffer, this._outputPtr, this._blockSize * channels
          );
          const needed = Math.min(
            view.length,
            accumulator.length - accumFill
          );
          accumulator.set(view.subarray(0, needed), accumFill);
          accumFill += needed;
        }

        // Copy accumulator to Web Audio output channels.
        for (let ch = 0; ch < channels; ch++) {
          const chData = ev.outputBuffer.getChannelData(ch);
          for (let i = 0; i < bufSize; i++) {
            chData[i] = accumulator[i * channels + ch] || 0;
          }
        }

        // Shift remaining samples down.
        const consumed = bufSize * channels;
        accumulator.copyWithin(0, consumed);
        accumFill -= consumed;
        if (accumFill < 0) accumFill = 0;
      };

      node.connect(this._audioCtx.destination);
      this._scriptNode = node;
      this._running = true;
    }

    /**
     * Run the visualizer at the given index and return an ImageData with the
     * current frame.  Returns null if no visualizer is present or idx is out
     * of range.
     * @param {number} [idx=0]  Visualizer index (0-based).
     * @returns {ImageData|null}
     */
    visualize(idx = 0) {
      if (!this._hasVisualizer || !this._crag_visualize || !this._vizOutputPtr)
        return null;
      if (idx < 0 || idx >= this._numVisualizers)
        return null;
      // crag_visualize(idx) writes to crag_viz_output for visualizer at idx.
      this._crag_visualize(idx);
      const w = this._crag_viz_width_fn ? this._crag_viz_width_fn(idx) : this._vizW;
      const h = this._crag_viz_height_fn ? this._crag_viz_height_fn(idx) : this._vizH;
      const f32 = new Float32Array(this._memory.buffer, this._vizOutputPtr, w * h * 4);
      const u8  = new Uint8ClampedArray(w * h * 4);
      for (let i = 0; i < w * h * 4; ++i)
        u8[i] = Math.round(Math.min(Math.max(f32[i], 0), 1) * 255);
      return new ImageData(u8, w, h);
    }

    /** Stop real-time audio output. */
    stop() {
      if (!this._running) return;
      if (this._scriptNode) {
        this._scriptNode.disconnect();
        this._scriptNode = null;
      }
      if (this._audioCtx) {
        this._audioCtx.close();
        this._audioCtx = null;
      }
      this._running = false;
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
     * @returns {Promise<CragPlayer>}
     */
    static async create(wasmUrl, metaUrl) {
      if (!metaUrl) metaUrl = wasmUrl + ".cragmeta";

      // Fetch metadata.
      const meta = await fetch(metaUrl).then((r) => {
        if (!r.ok) throw new Error(`Failed to fetch ${metaUrl}: ${r.status}`);
        return r.json();
      });

      // Heap state shared between import object and post-init fixup.
      const heapState = { ptr: 8 * 1024 * 1024 }; // 8 MB default
      // Memory state: populated from instance.exports.memory after instantiation
      // so that memset/memcpy/memmove have access to WASM linear memory.
      const memState = { memory: null };

      const importObj = makeCragImports(heapState, memState);

      // Instantiate — use instantiateStreaming when available.
      let instance;
      if (typeof WebAssembly.instantiateStreaming === "function") {
        const resp = fetch(wasmUrl);
        const result = await WebAssembly.instantiateStreaming(resp, importObj);
        instance = result.instance;
      } else {
        const buf = await fetch(wasmUrl).then((r) => r.arrayBuffer());
        const result = await WebAssembly.instantiate(buf, importObj);
        instance = result.instance;
      }

      // Fix up heap pointer from the exported __heap_base symbol.
      if (instance.exports.__heap_base) {
        heapState.ptr = instance.exports.__heap_base.value;
      }
      // Populate the memory reference for memset/memcpy/memmove.
      if (instance.exports.memory) {
        memState.memory = instance.exports.memory;
      }

      // Apply default parameter values from metadata.
      const player = new CragPlayer(instance, meta, heapState);
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
