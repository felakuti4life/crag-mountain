# HRTF Spatializer Crag Graphs — Experiment Plan

## Overview

The goal of this experiment is to build crag graphs that perform HRTF-based binaural spatialisation. The primary graph accepts a `crag.audio` input and a 3D position relative to the listener's ears and produces a stereo `crag.audio` output annotated with `"binaural"`.

---

## 1. HRTF Data Set Submodules

Add the following public HRTF repositories as git submodules so that IR data is versioned alongside the crag graphs that consume it.

| Submodule path | Upstream URL |
|---|---|
| `data/hrtf/sadie-ii` | https://github.com/facebookresearch/SS2_HRTF |
| `data/hrtf/cipic` | https://github.com/amini-allight/cipic-hrtf-database |

Both submodules should be pinned to a known-good commit and updated deliberately rather than tracking `HEAD`.

---

## 2. Sampler-Data Inlining Tooling

To produce self-contained, distributable WASM binaries for each HRTF data set, a build step is needed that invokes the crag compiler with the `--inline-sampler-data` flag.

- For every subject/measurement in a given data set, the left-ear IR and right-ear IR are baked into the compiled binary at build time via `--inline-sampler-data`.
- One independent crag graph binary is produced per data set (e.g. `hrtf-sadie-ii.wasm`, `hrtf-cipic.wasm`), each carrying its full IR table internally.
- A build script (e.g. `tools/build_hrtf_graphs.sh`) iterates over the data sets and invokes the compiler, writing outputs into an `spatializers/hrtf/` directory that mirrors the layout of `reverb/`, `compressors/`, etc.
- Each compiled graph ships with a `.wasm.cragmeta` sidecar that exposes the azimuth, elevation, and distance parameters as well as the `binaural` output annotation.

---

## 3. Core HRTF Crag Graph

### 3.1 Graph Interface

```
inputs:
  crag.audio  (mono, any sample rate — resampled internally to the HRTF measurement rate)
  azimuth     float  [-π, π]   radians, listener-relative
  elevation   float  [-π/2, π/2]  radians, listener-relative
  distance    float  [0, ∞)    metres

outputs:
  crag.audio  stereo, annotated "binaural"
```

### 3.2 IR Selection and Interpolation — Templated Schemes

The core graph is parameterised by the interpolation scheme used to blend between measured IRs at a requested angle. The following schemes should each be realised as a separate graph variant (or as a compile-time template parameter):

| Scheme | Description |
|---|---|
| **Nearest-neighbour** | Select the single closest measured direction; no blending. |
| **Bilinear (spherical grid)** | Weighted blend of the four surrounding measurements on the azimuth/elevation grid. |
| **Magnitude-phase VBAP** | Vector-base amplitude panning applied to the complex spectra of the surrounding IRs before IFFT. |
| **Spherical harmonic projection** | Re-encode the IR set into spherical harmonics and decode at the target direction for smooth, order-limited interpolation. |

Each scheme is implemented as a sub-graph that receives the IR table (or its SH projection), the target direction, and emits left/right impulse responses to be convolved with the dry signal.

### 3.3 Convolution Stage

Convolution is performed using the existing `fft-convolution` primitive from `reverb/fft-convolution/`. A stereo wrapper drives one instance per ear.

---

## 4. HRTF IR Post-Processing Pipeline

A separate crag graph (or family of graphs) handles offline pre-processing of the raw measured IRs before they are inlined. Post-processing steps include:

- **ITD removal** — strip the inter-aural time difference from the minimum-phase component so that ITD can be re-applied analytically at render time, reducing spectral smearing during interpolation.
- **Diffuse-field equalisation** — divide by the diffuse-field mean to flatten the common spectral shape; this can be optionally re-applied as a listener EQ stage.
- **Time-domain windowing** — apply a fade-out window to reduce the IR to a practical length (e.g. 256 or 512 taps) while minimising ringing artefacts.
- **Sample-rate conversion** — resample IRs to the target render rate using the `bandlimited-sinc-resampler` if the measurement rate differs.

The post-processing graph writes its output IRs to files (or to a packed binary blob) that is then consumed by the inlining build step.

---

## 5. Test Harness

### 5.1 Automated Correctness Tests

- **Impulse response round-trip** — feed a known impulse through the HRTF graph at a set of cardinal directions (front, rear, left, right, above) and verify the output matches reference IRs stored in `test_signals/hrtf_reference/`.
- **ITD accuracy** — measure the cross-correlation lag between the left and right output channels and compare against the expected ITD at each test direction.
- **Spectral flatness at on-axis** — at azimuth=0, elevation=0 (front-centre) the output should closely match the diffuse-field EQ'd target; verify magnitude deviation is within a tolerance band.
- **Continuity under parameter sweep** — sweep azimuth from −π to π in small steps and verify the output power and phase vary smoothly (no discontinuities beyond threshold).

### 5.2 Perceptual Smoke Test

A listening-test page (`spatializers/hrtf/test/index.html`) provides an informal A/B comparison: it loads the white-noise or sine-sweep test signal from `test_signals/`, routes it through the graph at user-selected directions, and plays back through headphones. This is not automated but is documented as a required manual step before any HRTF graph is promoted to the main branch.

---

## 6. HRTF Visualizers

Four new visualizer components should be added, following the same `has_visualizer` / `viz_width` / `viz_height` convention used by existing graphs.

### 6.1 Top View (XZ plane)

Renders the listener's head as seen from directly above. The current source position is drawn as a point on the horizontal circle. Azimuth is read from the graph's azimuth parameter; distance is reflected in the radius. The active HRTF measurement grid is drawn as faint dots.

### 6.2 Side View (YZ plane — left)

Renders the listener's head as seen from the left side. The current source position is plotted on the median sagittal plane using elevation and distance. Useful for distinguishing front/back and up/down elevation.

### 6.3 Rear View (XY plane)

Renders the listener's head as seen from behind. Combines azimuth and elevation into a posterior perspective. Useful for confirming that rear-hemisphere directions are handled correctly.

### 6.4 Composite Overlay Visualizer

A single visualizer that tiles all three views (top, side, rear) in a 3-panel layout within the standard `viz_width × viz_height` canvas. The shared active-direction marker is synchronised across all three panels. This is the default visualizer attached to the main HRTF graph binaries.

All four visualizers conform to the existing visualizer protocol (RGBA pixel buffer written to WASM memory, dimensions declared in `.cragmeta`).

---

## 7. Graph Documentation Visualizer — HRTF Routing Feature

The existing graph documentation visualizer (the interactive `index.html` pages for each graph) should gain a new capability: **"Render through HRTF spatializer"**.

When this feature is enabled, the graph's stereo output is routed through whichever HRTF spatializer graph the user selects (from the compiled graphs in `spatializers/hrtf/`). The spatializer direction can be controlled via the same azimuth/elevation sliders that appear in the composite overlay visualizer. This allows any graph's audio output to be previewed binaurally directly from its documentation page, with no extra configuration.

Implementation notes:
- `crag_player.js` will need a mechanism to chain two graph instances (source graph → HRTF spatializer) such that the output `SharedArrayBuffer` of the first is the input sampler of the second.
- The HRTF spatializer list is populated dynamically by fetching `spatializers/hrtf/manifest.json` (a file generated at build time listing available spatializer binaries and their `.cragmeta` paths).
- Direction controls are wired to the spatializer graph's float parameters and to the composite overlay visualizer simultaneously.

---

## 8. Directory Layout (Proposed)

```
crag-mountain/
├── data/
│   └── hrtf/
│       ├── sadie-ii/          ← git submodule (SS2_HRTF)
│       └── cipic/             ← git submodule (cipic-hrtf-database)
├── spatializers/
│   └── hrtf/
│       ├── hrtf-sadie-ii/
│       │   ├── hrtf-sadie-ii.wasm
│       │   ├── hrtf-sadie-ii.wasm.cragmeta
│       │   └── index.html
│       ├── hrtf-cipic/
│       │   ├── hrtf-cipic.wasm
│       │   ├── hrtf-cipic.wasm.cragmeta
│       │   └── index.html
│       ├── manifest.json
│       └── test/
│           └── index.html
├── tools/
│   ├── build_hrtf_graphs.sh
│   └── postprocess_hrtf_irs/
│       └── <post-processing crag graph sources>
├── test_signals/
│   └── hrtf_reference/        ← reference IR snapshots for automated tests
└── documentation/
    └── experiments/
        └── hrtf-spatializer.md   ← this document
```

---

## 9. Milestones

1. **Submodules** — add `data/hrtf/sadie-ii` and `data/hrtf/cipic` as submodules; verify raw IR files are accessible.
2. **Post-processing graph** — build and validate the IR post-processing pipeline; produce windowed, ITD-stripped, EQ'd IR blobs for at least one subject from each data set.
3. **Core HRTF graph (nearest-neighbour)** — implement the simplest interpolation scheme end-to-end; verify impulse round-trip test passes.
4. **Inlining build tooling** — implement `tools/build_hrtf_graphs.sh`; produce `hrtf-sadie-ii.wasm` and `hrtf-cipic.wasm` with all data baked in.
5. **Additional interpolation schemes** — implement bilinear, VBAP, and SH schemes; compare output quality in the perceptual smoke test.
6. **Visualizers** — implement all four visualizer components; integrate composite overlay as the default.
7. **Test harness** — automate ITD, spectral, and continuity tests; document manual listening test procedure.
8. **Documentation visualizer HRTF routing** — extend `crag_player.js` and the graph `index.html` template to support chained HRTF playback.
