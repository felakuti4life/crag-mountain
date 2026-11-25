/**
 * crag_face.js - draws a compiled Crag panel (.cragface) on a canvas and
 * connects it to a CragPlayer.
 *
 *   const player = await CragPlayer.create('synth.wasm', 'synth.wasm.cragmeta');
 *   const face   = await CragFace.mount(canvas, player, 'synth.cragface');
 *
 * The panel logic is the same C runtime native hosts use (face/runtime/
 * crag_face.c), built to crag_face.wasm; this file loads it, forwards pointer
 * and keyboard input, applies what the user did to the player, and draws the
 * instance list with WebGL2 in one instanced call.  The shaders are
 * face/render/*.glsl.
 *
 * The panel reflows to the canvas: it is laid out for the canvas's CSS width,
 * so rows wrap on a narrow page, and it only scales down below the narrowest
 * layout it has.  Every pointer is followed separately (chords on a touch
 * keyboard, two sliders at once).  The canvas takes keyboard focus: Tab moves
 * between controls, arrows change them, and typing a number sets a value.
 *
 * No dependencies.  crag_face.wasm must sit next to this file, or pass
 * { wasmUrl }.  Without a player the face still works: pass null and listen
 * with { onAction }.
 */
"use strict";

(function (root, factory) {
  if (typeof module !== "undefined" && module.exports) module.exports = factory();
  else root.CragFace = factory();
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  const scriptUrl = (typeof document !== "undefined" && document.currentScript && document.currentScript.src) || "";

  // ---- shaders: face/render/face.vert.glsl and face.frag.glsl, GL flavour -------------
  const VERT = `#version 300 es
uniform vec4 uView;
layout(location = 0) in vec2 aCorner;
layout(location = 1) in vec4 iRect;
layout(location = 2) in vec4 iP;
layout(location = 3) in vec4 iQ;
layout(location = 4) in vec4 iFill;
layout(location = 5) in vec4 iLine;
layout(location = 6) in vec2 iMisc;
out vec2 vPos;
out vec2 vUV;
flat out vec4 vP;
flat out vec4 vQ;
flat out vec4 vFill;
flat out vec4 vLine;
flat out vec2 vMisc;
void main() {
  vPos = iRect.xy + aCorner * iRect.zw;
  vUV = aCorner;
  vP = iP; vQ = iQ; vFill = iFill; vLine = iLine; vMisc = iMisc;
  gl_Position = vec4(vPos.x * uView.x - 1.0, (vPos.y * abs(uView.y) - 1.0) * sign(uView.y), 0.0, 1.0);
}`;
  const FRAG = `#version 300 es
precision highp float;
uniform vec4 uView;
uniform sampler2D uAtlas;
uniform sampler2D uImage;
uniform sampler2D uTex[8];
in vec2 vPos;
in vec2 vUV;
flat in vec4 vP;
flat in vec4 vQ;
flat in vec4 vFill;
flat in vec4 vLine;
flat in vec2 vMisc;
layout(location = 0) out vec4 outColor;
float sdRRect(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}
float sdArc(vec2 v, float r, float hw, float a0, float a1) {
  float mid = 0.5 * (a0 + a1), ap = min(0.5 * (a1 - a0), 3.14159265);
  vec2 m = vec2(sin(mid), -cos(mid));
  vec2 p = vec2(abs(v.x * -m.y + v.y * m.x), dot(v, m));
  vec2 sc = vec2(sin(ap), cos(ap));
  float d = (sc.y * p.x > sc.x * p.y) ? length(p - sc * r) : abs(length(p) - r);
  return d - hw;
}
float sdSegment(vec2 p, vec2 a, vec2 b) {
  vec2 pa = p - a, ba = b - a;
  float len = dot(ba, ba);
  float h = len > 0.0 ? clamp(dot(pa, ba) / len, 0.0, 1.0) : 0.0;
  return length(pa - ba * h);
}
float cross2(vec2 a, vec2 b) { return a.x * b.y - a.y * b.x; }
float sdTri(vec2 p, vec2 a, vec2 b, vec2 c) {
  float d = min(sdSegment(p, a, b), min(sdSegment(p, b, c), sdSegment(p, c, a)));
  float s0 = cross2(b - a, p - a), s1 = cross2(c - b, p - b), s2 = cross2(a - c, p - c);
  bool inside = (s0 >= 0.0 && s1 >= 0.0 && s2 >= 0.0) || (s0 <= 0.0 && s1 <= 0.0 && s2 <= 0.0);
  return inside ? -d : d;
}
vec4 hostTexture(int slot, vec2 uv) {
  if (slot == 0) return textureLod(uTex[0], uv, 0.0);
  if (slot == 1) return textureLod(uTex[1], uv, 0.0);
  if (slot == 2) return textureLod(uTex[2], uv, 0.0);
  if (slot == 3) return textureLod(uTex[3], uv, 0.0);
  if (slot == 4) return textureLod(uTex[4], uv, 0.0);
  if (slot == 5) return textureLod(uTex[5], uv, 0.0);
  if (slot == 6) return textureLod(uTex[6], uv, 0.0);
  return textureLod(uTex[7], uv, 0.0);
}
void main() {
  float scale = uView.z;
  int kind = int(vMisc.y + 0.5);
  vec4 col = vFill;
  float cov = 0.0;
  if (kind == 0) {
    float d = sdRRect(vPos - vP.xy, vP.zw, vQ.x);
    cov = clamp(0.5 - d * scale, 0.0, 1.0);
    if (vMisc.x > 0.0) {
      float s = clamp(0.5 + (d + vMisc.x) * scale, 0.0, 1.0);
      float fa = vFill.a * (1.0 - s), la = vLine.a * s, a = fa + la;
      col = vec4(a > 0.0 ? (vFill.rgb * fa + vLine.rgb * la) / a : vec3(0.0), a);
    }
  } else if (kind == 1) {
    cov = clamp(0.5 - sdArc(vPos - vP.xy, vP.z, vP.w, vQ.x, vQ.y) * scale, 0.0, 1.0);
  } else if (kind == 2) {
    cov = clamp(0.5 - (sdSegment(vPos, vP.xy, vP.zw) - vQ.x) * scale, 0.0, 1.0);
  } else if (kind == 3) {
    cov = clamp(0.5 - sdTri(vPos, vP.xy, vP.zw, vQ.xy) * scale, 0.0, 1.0);
  } else if (kind == 4) {
    vec2 uv = mix(vQ.xy, vQ.zw, vUV) / vec2(textureSize(uAtlas, 0));
    cov = clamp(0.5 - (0.5 - texture(uAtlas, uv).r) * vP.x * scale, 0.0, 1.0);
  } else if (kind == 6) {
    vec2 uv = mix(vQ.xy, vQ.zw, vUV) / vec2(textureSize(uImage, 0));
    outColor = textureLod(uImage, uv, 0.0) * vec4(vFill.rgb * vFill.a, vFill.a);
    return;
  } else {
    vec2 half_size = 0.5 * fwidth(vPos) / max(fwidth(vUV), vec2(1e-6));
    float d = sdRRect((vUV - 0.5) * 2.0 * half_size, half_size, vP.y);
    cov = clamp(0.5 - d * scale, 0.0, 1.0);
    col = vec4(hostTexture(int(vP.x + 0.5), mix(vQ.xy, vQ.zw, vUV)).rgb, 1.0);
  }
  float a = col.a * cov;
  outColor = vec4(col.rgb * a, a);
}`;

  // Offsets into CragFaceHeader / CragFacePin / CragFaceInstance (face/include/crag_face.h).
  const MAGIC = 0x43414643, INSTANCE_BYTES = 64, PIN_BYTES = 64, MAX_TEXTURES = 8;
  const H_TEXTURE_COUNT = 132, H_TEXTURE_OFF = 136, H_MAX_INSTANCES = 144;
  const PIN = { FLOAT: 0, INT: 1, BOOL: 2, ENUM: 3, EVENT: 4, NOTE: 5, METER: 6,
                EVENT_FLOAT: 7, EVENT_INT: 8, EVENT_BOOL: 9, EVENT_ENUM: 10, EVENT_STRUCT: 11, FIELD: 12 };
  const ACTION = { SET: 1, BEGIN: 2, END: 3, FIRE: 4, NOTE_ON: 5, NOTE_OFF: 6, SEND: 7 };
  const CURSORS = ["default", "pointer", "ns-resize", "ew-resize"];
  // KeyboardEvent.key -> CRAG_FACE_KEY_*
  const KEYS = { ArrowUp: 3, ArrowDown: 4, ArrowLeft: 5, ArrowRight: 6, PageUp: 7, PageDown: 8, Home: 9, End: 10,
                 Enter: 11, Escape: 12, Backspace: 13, Delete: 14 };

  let wasmModulePromise = null;
  function loadRuntime(url) {
    if (!wasmModulePromise || wasmModulePromise.url !== url) {
      wasmModulePromise = fetch(url).then((r) => {
        if (!r.ok) throw new Error("CragFace: cannot load " + url + " (" + r.status + ")");
        return r.arrayBuffer();
      }).then((bytes) => WebAssembly.compile(bytes));
      wasmModulePromise.url = url;
    }
    return wasmModulePromise;
  }

  class CragFace {
    /**
     * @param {HTMLCanvasElement} canvas  Sized by CSS width; its height follows the panel's aspect.
     * @param {CragPlayer|null}   player  The running graph, or null.
     * @param {string|ArrayBuffer|Uint8Array} face  URL or bytes of the .cragface.
     * @param {object} [options]
     * @param {string}   [options.wasmUrl]   Location of crag_face.wasm.
     * @param {function} [options.onAction]  Called with {type, pin, name, value, aux} for everything the user does.
     * @param {boolean}  [options.reflow=true]  Lay the panel out for the canvas's width.  false: always the
     *                                          design layout, scaled to fit.
     * @param {number}   [options.zoom=1]       CSS px per design px when reflowing.
     * @param {boolean}  [options.keyboard=true]  Take keyboard focus (Tab, arrows, typed values).
     * @param {object|number[]} [options.visualizers]  Which visualizer each `viz` shows, by the name the layout
     *                                          gave it ({ scope: 1 }) or by slot ([1, 0]).  Default: the index
     *                                          the panel was compiled with (the graph's visualizer of that name).
     * @param {number}   [options.visualizer]   Shorthand for the visualizer of the first slot.
     */
    static async mount(canvas, player, face, options = {}) {
      const wasmUrl = options.wasmUrl || (scriptUrl ? new URL("crag_face.wasm", scriptUrl).href : "crag_face.wasm");
      let bytes = face;
      if (typeof face === "string") {
        const r = await fetch(face);
        if (!r.ok) throw new Error("CragFace: cannot load " + face + " (" + r.status + ")");
        bytes = await r.arrayBuffer();
      }
      bytes = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
      const module = await loadRuntime(wasmUrl);
      const f32 = Math.fround;
      const instance = await WebAssembly.instantiate(module, {
        env: {
          crag_face_host_sin: (x) => f32(Math.sin(x)),
          crag_face_host_cos: (x) => f32(Math.cos(x)),
          crag_face_host_pow: (x, y) => f32(Math.pow(x, y)),
          crag_face_host_log: (x) => f32(Math.log(x)),
        },
      });
      return new CragFace(canvas, player, bytes, instance.exports, options);
    }

    constructor(canvas, player, bytes, x, options) {
      this.canvas = canvas;
      this.player = player;
      this.options = options;
      this._x = x;
      this._heap = (x.__heap_base.value + 15) & ~15;
      this._destroyed = false;

      this._blob = this._alloc(bytes.length);
      new Uint8Array(x.memory.buffer, this._blob, bytes.length).set(bytes);
      const stateSize = x.crag_face_state_size(this._blob, bytes.length);
      if (!stateSize) throw new Error("CragFace: not a .cragface this runtime can read");
      this._face = x.crag_face_init(this._alloc(stateSize), stateSize, this._blob, bytes.length);
      if (!this._face) throw new Error("CragFace: the panel file is damaged");
      this._action = this._alloc(16);
      this._text = this._alloc(64);
      this._payload = this._alloc(4096);

      let h = this._view();
      if (h.getUint32(this._blob, true) !== MAGIC) throw new Error("CragFace: bad magic");
      /** Design size in px: the layout with all the room it wants. */
      this.designWidth = h.getFloat32(this._blob + 12, true);
      this.designHeight = h.getFloat32(this._blob + 16, true);
      /** Size of the layout shown now, in design px.  Follows the canvas when the panel reflows. */
      this.width = this.designWidth;
      this.height = this.designHeight;
      /** The narrowest the layout goes; a narrower canvas scales it down. */
      this.minWidth = x.crag_face_min_width(this._face);
      this.name = this._string(h.getUint32(this._blob + 20, true));
      this._maxInstances = h.getUint32(this._blob + H_MAX_INSTANCES, true);
      this._instances = this._alloc(this._maxInstances * INSTANCE_BYTES);
      // That allocation may have grown the memory, which detaches every view
      // of it taken before.
      h = this._view();

      // The pins this panel uses, by id.
      const pinCount = h.getUint32(this._blob + 24, true), pinOff = this._blob + h.getUint32(this._blob + 28, true);
      this.pins = [];
      this._pinByName = new Map();
      for (let i = 0; i < pinCount; ++i) {
        const o = pinOff + i * PIN_BYTES, v = this._view();
        const pin = {
          id: i, kind: v.getUint32(o, true), metaIndex: v.getUint32(o + 4, true), slot: v.getUint32(o + 8, true),
          name: this._string(v.getUint32(o + 12, true)), label: this._string(v.getUint32(o + 16, true)),
          unit: this._string(v.getUint32(o + 20, true)),
          min: v.getFloat32(o + 24, true), max: v.getFloat32(o + 28, true), default: v.getFloat32(o + 32, true),
          parent: v.getUint32(o + 56, true), // FIELD: the id of its struct event
        };
        this.pins.push(pin);
        this._pinByName.set(pin.name, pin);
      }
      this._meters = this.pins.filter((p) => p.kind === PIN.METER);

      /** The visualizers the panel shows, by texture slot: [{ name, source }]. */
      this.textures = [];
      const texCount = h.getUint32(this._blob + H_TEXTURE_COUNT, true), texOff = this._blob + h.getUint32(this._blob + H_TEXTURE_OFF, true);
      for (let i = 0; i < texCount && i < MAX_TEXTURES; ++i) {
        const v = this._view();
        const name = this._string(v.getUint32(texOff + i * 8, true));
        let source = this._view().getUint32(texOff + i * 8 + 4, true);
        const pick = options.visualizers;
        if (Array.isArray(pick) && typeof pick[i] === "number") source = pick[i];
        else if (pick && !Array.isArray(pick) && typeof pick[name] === "number") source = pick[name];
        else if (i === 0 && typeof options.visualizer === "number") source = options.visualizer;
        this.textures.push({ name, source });
      }

      this._initGL(h);
      this._bindInput();
      this._resize = () => this._layout();
      this._observer = typeof ResizeObserver !== "undefined" ? new ResizeObserver(this._resize) : null;
      if (this._observer) this._observer.observe(canvas);
      this._layout();
      this._frame = this._frame.bind(this);
      this._raf = requestAnimationFrame(this._frame);
    }

    // ---- public -------------------------------------------------------------------

    /** Sets a pin from the host side (a preset, automation).  Does not call the player. */
    setValue(name, value) {
      const pin = this._pinByName.get(name);
      if (pin) this._x.crag_face_set_value(this._face, pin.id, value);
    }
    getValue(name) {
      const pin = this._pinByName.get(name);
      return pin ? this._x.crag_face_value(this._face, pin.id) : undefined;
    }
    /** The value as the panel shows it, e.g. "1.20 kHz". */
    formatValue(name) {
      const pin = this._pinByName.get(name);
      if (!pin) return "";
      const n = this._x.crag_face_format_value(this._face, pin.id, this._text, 64);
      return new TextDecoder().decode(new Uint8Array(this._x.memory.buffer, this._text, n));
    }
    /** Where a pin's control is now, in design px: {x, y, w, h}, or null if it has none. */
    rectOf(name) {
      const pin = this._pinByName.get(name);
      if (!pin) return null;
      const h = this._view(), count = h.getUint32(this._blob + 32, true), off = this._blob + h.getUint32(this._blob + 36, true);
      for (let i = 0; i < count; ++i) {
        const w = off + i * 96, v = this._view(), n = v.getUint32(w + 48, true); // CragFaceWidget
        for (let k = 0; k < n && k < 4; ++k) {
          if (v.getUint32(w + 32 + k * 4, true) !== pin.id) continue;
          this._x.crag_face_widget_rect(this._face, i, this._text);
          const r = new Float32Array(this._x.memory.buffer, this._text, 4);
          return { x: r[0], y: r[1], w: r[2], h: r[3] };
        }
      }
      return null;
    }
    /** Keyboard input from code: key is a KeyboardEvent.key ("Tab", "ArrowUp", "Enter", or a character). */
    key(key, shift = false) {
      const x = this._x;
      let used = 0;
      if (key === "Tab") used = x.crag_face_key(this._face, shift ? 2 : 1, 0);
      else if (KEYS[key]) used = x.crag_face_key(this._face, KEYS[key], shift ? 1 : 0);
      else if (key.length >= 1 && key.codePointAt(0) >= 32 && [...key].length === 1) used = x.crag_face_text(this._face, key.codePointAt(0));
      this._pump();
      return !!used;
    }
    /** The name of the pin with keyboard focus, or null. */
    get focused() {
      const pin = this.pins[this._x.crag_face_focus_pin(this._face)];
      return pin ? pin.name : null;
    }
    /** Lights a key without firing an event (incoming MIDI). */
    showNote(note, on) { this._x.crag_face_show_note(this._face, note | 0, on ? 1 : 0); }
    /** Number of instances in the last frame drawn. */
    get instanceCount() { return this._count || 0; }

    destroy() {
      this._destroyed = true;
      cancelAnimationFrame(this._raf);
      if (this._observer) this._observer.disconnect();
      for (const [type, fn] of this._listeners) this.canvas.removeEventListener(type, fn);
      const gl = this.gl;
      gl.deleteProgram(this._program); gl.deleteBuffer(this._quad); gl.deleteBuffer(this._instanceBuffer);
      gl.deleteTexture(this._atlas); gl.deleteTexture(this._imageTex); gl.deleteVertexArray(this._vao);
      for (const t of this._vizTex) gl.deleteTexture(t);
    }

    // ---- memory -------------------------------------------------------------------

    _alloc(n) {
      const ptr = this._heap;
      this._heap = (ptr + n + 15) & ~15;
      const mem = this._x.memory, need = this._heap - mem.buffer.byteLength;
      if (need > 0) mem.grow(Math.ceil(need / 65536));
      return ptr;
    }
    _view() { return new DataView(this._x.memory.buffer); }
    _string(id) {
      const ptr = this._x.crag_face_string(this._face || 0, id);
      if (!this._face) return "";
      const mem = new Uint8Array(this._x.memory.buffer);
      let end = ptr;
      while (mem[end]) ++end;
      return new TextDecoder().decode(mem.subarray(ptr, end));
    }

    // ---- GL -------------------------------------------------------------------------

    _initGL(h) {
      const gl = this.canvas.getContext("webgl2", { premultipliedAlpha: true, antialias: false, alpha: true });
      if (!gl) throw new Error("CragFace: WebGL2 is not available");
      this.gl = gl;
      const compile = (type, src) => {
        const s = gl.createShader(type);
        gl.shaderSource(s, src); gl.compileShader(s);
        if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error("CragFace shader: " + gl.getShaderInfoLog(s));
        return s;
      };
      const prog = gl.createProgram();
      gl.attachShader(prog, compile(gl.VERTEX_SHADER, VERT));
      gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, FRAG));
      gl.linkProgram(prog);
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error("CragFace link: " + gl.getProgramInfoLog(prog));
      this._program = prog;
      this._uView = gl.getUniformLocation(prog, "uView");
      gl.useProgram(prog);
      gl.uniform1i(gl.getUniformLocation(prog, "uAtlas"), 0);
      gl.uniform1i(gl.getUniformLocation(prog, "uImage"), 1);
      gl.uniform1iv(gl.getUniformLocation(prog, "uTex[0]"), [2, 3, 4, 5, 6, 7, 8, 9]);

      this._vao = gl.createVertexArray();
      gl.bindVertexArray(this._vao);
      this._quad = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, this._quad);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 1, 1]), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      this._instanceBuffer = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, this._instanceBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, this._maxInstances * INSTANCE_BYTES, gl.DYNAMIC_DRAW);
      const attr = (loc, size, type, norm, off) => {
        gl.enableVertexAttribArray(loc);
        gl.vertexAttribPointer(loc, size, type, norm, INSTANCE_BYTES, off);
        gl.vertexAttribDivisor(loc, 1);
      };
      attr(1, 4, gl.FLOAT, false, 0);          // rect
      attr(2, 4, gl.FLOAT, false, 16);         // p
      attr(3, 4, gl.FLOAT, false, 32);         // q
      attr(4, 4, gl.UNSIGNED_BYTE, true, 48);  // fill
      attr(5, 4, gl.UNSIGNED_BYTE, true, 52);  // line
      attr(6, 2, gl.FLOAT, false, 56);         // line width, kind
      gl.bindVertexArray(null);

      const linear = () => {
        for (const [k, v] of [[gl.TEXTURE_MIN_FILTER, gl.LINEAR], [gl.TEXTURE_MAG_FILTER, gl.LINEAR],
                              [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]])
          gl.texParameteri(gl.TEXTURE_2D, k, v);
      };
      const x = this._x, dims = this._text;
      // The glyph atlas: one 8-bit sdf channel.
      let ptr = x.crag_face_atlas(this._face, dims, dims + 4);
      let v = this._view(), aw = v.getUint32(dims, true), ah = v.getUint32(dims + 4, true);
      this._atlas = gl.createTexture();
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, this._atlas);
      gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, aw, ah, 0, gl.RED, gl.UNSIGNED_BYTE, new Uint8Array(x.memory.buffer, ptr, aw * ah));
      linear();

      // The image atlas (filmstrips and pictures), premultiplied; one clear pixel if the panel has none.
      ptr = x.crag_face_images(this._face, dims, dims + 4);
      v = this._view(); aw = v.getUint32(dims, true); ah = v.getUint32(dims + 4, true);
      this._imageTex = gl.createTexture();
      gl.activeTexture(gl.TEXTURE1);
      gl.bindTexture(gl.TEXTURE_2D, this._imageTex);
      gl.pixelStorei(gl.UNPACK_ALIGNMENT, 4);
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
      if (ptr) gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, aw, ah, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(x.memory.buffer, ptr, aw * ah * 4));
      else gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(4));
      linear();

      // One texture per visualizer slot: a dark pixel until the player has a frame.
      this._vizTex = [];
      this._vizFrame = [];
      for (let i = 0; i < MAX_TEXTURES; ++i) {
        const t = gl.createTexture();
        gl.activeTexture(gl.TEXTURE2 + i);
        gl.bindTexture(gl.TEXTURE_2D, t);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([0, 0, 0, 255]));
        linear();
        this._vizTex.push(t);
        this._vizFrame.push(null);
      }
    }

    _layout() {
      const x = this._x;
      const cssW = this.canvas.clientWidth || this.designWidth;
      const dpr = (typeof devicePixelRatio !== "undefined" && devicePixelRatio) || 1;
      if (this.options.reflow !== false) {
        // One design px per CSS px (times zoom): a narrow canvas wraps the rows
        // instead of shrinking them, down to the narrowest layout there is.
        x.crag_face_resize(this._face, cssW / (this.options.zoom || 1), 0);
        x.crag_face_size(this._face, this._text, this._text + 4);
        const v = this._view();
        this.width = v.getFloat32(this._text, true);
        this.height = v.getFloat32(this._text + 4, true);
      }
      const w = Math.max(1, Math.round(cssW * dpr)), hgt = Math.max(1, Math.round(cssW * dpr * this.height / this.width));
      this.canvas.style.height = (cssW * this.height / this.width) + "px";
      if (this.canvas.width !== w || this.canvas.height !== hgt) { this.canvas.width = w; this.canvas.height = hgt; }
      this._scale = w / this.width;
      this._force = true;
    }

    _draw() {
      const gl = this.gl, x = this._x;
      this._count = x.crag_face_build(this._face, this._instances, this._maxInstances);
      const data = new Uint8Array(x.memory.buffer, this._instances, this._count * INSTANCE_BYTES);
      gl.viewport(0, 0, this.canvas.width, this.canvas.height);
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
      gl.useProgram(this._program);
      gl.uniform4f(this._uView, 2 / this.width, -2 / this.height, this._scale, 0);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, this._atlas);
      gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, this._imageTex);
      for (let i = 0; i < MAX_TEXTURES; ++i) { gl.activeTexture(gl.TEXTURE2 + i); gl.bindTexture(gl.TEXTURE_2D, this._vizTex[i]); }
      gl.bindVertexArray(this._vao);
      gl.bindBuffer(gl.ARRAY_BUFFER, this._instanceBuffer);
      gl.bufferSubData(gl.ARRAY_BUFFER, 0, data);
      gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, this._count);
      gl.bindVertexArray(null);
    }

    // ---- input ------------------------------------------------------------------------

    _bindInput() {
      const c = this.canvas, x = this._x;
      c.style.touchAction = "none";
      const pos = (e) => {
        const r = c.getBoundingClientRect(), k = this.width / (r.width || 1);
        return [(e.clientX - r.left) * k, (e.clientY - r.top) * k];
      };
      const on = (type, fn) => { c.addEventListener(type, fn); this._listeners.push([type, fn]); };
      this._listeners = [];
      // Each pointer (the mouse, every finger) is followed by its own id.
      const id = (e) => e.pointerId >>> 0;
      on("pointermove", (e) => { const [px, py] = pos(e); x.crag_face_pointer_move(this._face, id(e), px, py, e.shiftKey ? 1 : 0); this._pump(); });
      on("pointerdown", (e) => {
        if (e.button !== 0) return;
        const [px, py] = pos(e);
        try { c.setPointerCapture(e.pointerId); } catch (_) {}
        x.crag_face_pointer_down(this._face, id(e), px, py, e.detail >= 2 ? 1 : 0);
        this._pump();
        if (this.options.keyboard !== false && typeof c.focus === "function") c.focus({ preventScroll: true });
        e.preventDefault();
      });
      const up = (e) => {
        x.crag_face_pointer_up(this._face, id(e));
        if (e.pointerType && e.pointerType !== "mouse") x.crag_face_pointer_leave(this._face, id(e)); // a lifted finger is gone
        this._pump();
      };
      on("pointerup", up);
      on("pointercancel", up);
      on("pointerleave", (e) => { x.crag_face_pointer_leave(this._face, id(e)); this._pump(); });

      if (this.options.keyboard === false) return;
      if (!c.hasAttribute("tabindex")) c.tabIndex = 0;
      c.style.outline = "none"; // the panel draws its own ring, round the control
      on("keydown", (e) => {
        if (e.ctrlKey || e.metaKey || e.altKey) return;
        if (this.key(e.key, e.shiftKey)) e.preventDefault();
      });
      on("blur", () => { x.crag_face_blur(this._face); this._pump(); });
    }

    // Applies everything the user did since the last call.
    _pump() {
      const x = this._x;
      while (x.crag_face_poll(this._face, this._action)) {
        const v = this._view();
        const type = v.getUint32(this._action, true), pin = this.pins[v.getUint32(this._action + 4, true)];
        const value = v.getFloat32(this._action + 8, true), aux = v.getFloat32(this._action + 12, true);
        if (!pin) continue;
        const p = this.player;
        if (p) {
          if (type === ACTION.SET) {
            if (pin.kind === PIN.FLOAT) p.setParam(pin.slot, value);
            else if (pin.kind <= PIN.ENUM) p.setParamInt(pin.slot, Math.round(value));
            // a SET on a field or a value event only changes what will be sent
          } else if (type === ACTION.SEND) {
            if (pin.kind === PIN.EVENT_FLOAT) { if (p.fireEventFloat) p.fireEventFloat(pin.slot, 0, value); }
            else if (p.fireEventInt) p.fireEventInt(pin.slot, 0, Math.round(value));
          } else if (type === ACTION.FIRE) {
            if (pin.kind === PIN.EVENT_STRUCT) { // its fields, packed by the runtime
              const n = x.crag_face_event_payload(this._face, pin.id, this._payload, 4096);
              if (n && p.fireEventStruct) p.fireEventStruct(pin.slot, 0, new Uint8Array(x.memory.buffer, this._payload, n).slice());
            } else p.fireEvent(pin.slot, 0);
          }
          else if (type === ACTION.NOTE_ON) this._fireNote(pin, value, aux);
          else if (type === ACTION.NOTE_OFF) this._fireNote(pin, value, 0);
        }
        if (this.options.onAction) this.options.onAction({ type, pin: pin.id, name: pin.name, value, aux });
      }
      this.canvas.style.cursor = CURSORS[x.crag_face_cursor(this._face)] || "default";
    }

    // A note is a struct event; its payload layout comes from the .cragmeta.
    _fireNote(pin, pitch, velocity) {
      const p = this.player, ev = p && p.meta && p.meta.events && p.meta.events[pin.metaIndex];
      if (!ev || !p.fireEventStruct) return;
      const fields = ev.struct_fields || [];
      const size = ev.struct_payload_bytes || fields.length * 4;
      const bytes = new Uint8Array(size), dv = new DataView(bytes.buffer);
      let off = 0;
      for (const f of fields) {
        const at = typeof f.offset === "number" ? f.offset : off;
        const val = f.name === "pitch" ? pitch : f.name === "velocity" ? velocity : 0;
        if (at + 4 <= size) {
          if (f.type === "f32") dv.setFloat32(at, val, true); else dv.setInt32(at, Math.round(val), true);
        }
        off = at + 4;
      }
      p.fireEventStruct(pin.slot, 0, bytes);
    }

    _frame() {
      if (this._destroyed) return;
      this._raf = requestAnimationFrame(this._frame);
      const x = this._x, p = this.player;
      if (p) {
        for (const m of this._meters) {
          const v = p.getMeter ? p.getMeter(m.slot) : undefined;
          if (typeof v === "number" && Number.isFinite(v)) x.crag_face_set_value(this._face, m.id, v);
        }
        if (p.visualize) {
          for (let i = 0; i < this.textures.length; ++i) { // each slot shows its own visualizer
            const frame = p.visualize(this.textures[i].source);
            if (!frame || frame === this._vizFrame[i]) continue;
            const gl = this.gl;
            this._vizFrame[i] = frame;
            gl.activeTexture(gl.TEXTURE2 + i);
            gl.bindTexture(gl.TEXTURE_2D, this._vizTex[i]);
            gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, frame);
            this._force = true;
          }
        }
      }
      if (this._force || x.crag_face_dirty(this._face)) { this._force = false; this._draw(); }
    }
  }

  CragFace.ACTION = ACTION;
  CragFace.PIN = PIN;
  return CragFace;
});
