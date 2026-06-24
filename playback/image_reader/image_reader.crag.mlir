// Image Reader
//
// A convenience wrapper around a crag.texture_sampler that reads a bound image
// asset and emits it through crag.texture_output each process tick, making the
// decoded texture available to the patchbay texture-routing layer.
//
// The reader holds a single texture sampler named "texture" whose asset is
// bound at runtime via crag_bind_texture_by_index(0, ...).  The decoded image
// is forwarded unchanged through the visualizer's viz_output; no processing is
// applied in v1.  A silent audio block is produced as a placeholder output —
// the image_reader is purely a texture source and does not contribute to the
// audio mix.
//
// Parameters: none (a future `gain` / `tint` parameter is out of scope here)
// Events:     none
//
// Sampler:
//   "texture" — bind a PNG / JPEG / TGA / BMP / EXR image asset via
//   crag_bind_texture_by_index(0, ptr, len)
//
// Output: !crag.texture<256, 256> via crag.texture_output
//         (256 × 256 is the v1 fixed size; follow-up passes can promote
//          dimensions once the cache exposes per-binding metadata)
//
// Usage (after crag.include):
//   crag.include "standard-graphs/playback/image_reader.crag.mlir" as "image_reader"
//   ...
//   // Instantiate through crag_engine_add_instance with a textureSlotNames /
//   // textureFilePaths binding, or drop a texture file from the Resource Browser
//   // onto the graph-designer canvas.

module {
  crag.graph name = "image_reader" sample_rate = 0 channels = 1
             default_visualizer = "image_reader_viz" {

    // -------------------------------------------------------------------------
    // Silent audio output (required by the graph ABI; the real output is the
    // texture routed through viz_output).
    // -------------------------------------------------------------------------
    %noise   = crag.white_noise : !crag.audio<f32, 0, 0>
    %c0f     = arith.constant 0.0 : f32
    %silence = crag.scale %noise, %c0f
                   : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>

    crag.visualizer_ref "image_reader_viz"(%silence)
        : (!crag.audio<f32, 0, 0>)

    crag.output %silence : !crag.audio<f32, 0, 0>
  }

  // ---------------------------------------------------------------------------
  // Visualizer: read the bound texture sampler and forward the decoded image.
  // ---------------------------------------------------------------------------
  crag.visualizer name = "image_reader_viz" width = 256 height = 256 {
    %audio = crag.audio_input "audio" : !crag.audio<f32, 0, 0>
    %ts  = crag.texture_sampler "texture"
               : !crag.texture_sampler<"texture">
    %tex = crag.read_texture %ts
               : !crag.texture_sampler<"texture"> -> !crag.texture<256, 256>
    crag.texture_output %tex : !crag.texture<256, 256>
  }
}
