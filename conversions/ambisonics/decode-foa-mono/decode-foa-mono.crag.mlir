// First-Order Ambisonics Decoder — FOA → Mono
//
// Decodes a First-Order Ambisonics (FOA) stream to a mono output by
// extracting the W (omnidirectional) channel.
//
// The W channel captures the sum of all directions equally (like an
// omnidirectional microphone), so it provides a natural mono down-mix
// of an ambisonics scene with equal contribution from all directions.
//
// Input channel ordering (ACN/SN3D, AmbiX convention):
//   Channel 0  W  (omnidirectional — extracted here)
//   Channel 1  Y  (left/right — discarded)
//   Channel 2  Z  (up/down  — discarded)
//   Channel 3  X  (front/back — discarded)
//
// Channel count: 4 (subtype="ambisonics") → 1 (plain mono)
//
// References:
//   Malham, D. (2003). Space in Music. PhD thesis, University of York.
//   IEM Plugin Suite documentation, https://plugins.iem.at/

module {
  crag.graph name = "decode_foa_mono" sample_rate = 0 channels = 1 default_visualizer = "oscilloscope" {
  ^bb0(%foa: !crag.audio<f32, 0, 4, subtype="ambisonics">):

    // Extract W (ACN channel 0) as plain mono.
    %W = crag.channel_slice %foa, 0
             : !crag.audio<f32, 0, 4, subtype="ambisonics"> -> !crag.audio<f32, 0, 1>

    crag.output %W : !crag.audio<f32, 0, 1>
  }
}
