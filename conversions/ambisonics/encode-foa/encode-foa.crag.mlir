// First-Order Ambisonics Encoder (Mono → FOA)
//
// Encodes a mono audio source into First-Order Ambisonics (FOA) using the
// ACN channel ordering and SN3D normalisation, which together form the
// AmbiX format (the current industry standard).
//
// Output channel layout (ACN/SN3D):
//   Channel 0  W  (l=0, m=0)  : omnidirectional  — gain = 1
//   Channel 1  Y  (l=1, m=-1) : left/right        — gain = sin(az)*cos(el)
//   Channel 2  Z  (l=1, m=0)  : up/down           — gain = sin(el)
//   Channel 3  X  (l=1, m=1)  : front/back        — gain = cos(az)*cos(el)
//
// Parameters:
//   azimuth   – horizontal angle in radians (0 = front, π/2 = left,
//               -π/2 = right, ±π = back).
//   elevation – vertical angle in radians (0 = horizontal, π/2 = up,
//               -π/2 = down).
//
// Channel count: 1 → 4 (subtype="ambisonics")
//
// References:
//   Daniel, J. (2001). Représentation de champs acoustiques. PhD thesis,
//     Université Paris VI. (Defines ACN/SN3D normalisation.)
//   IEM Plugin Suite documentation, https://plugins.iem.at/
//   Malham, D. (2003). Space in Music. PhD thesis, University of York.
//     (Practical AmbiX conventions.)

module {
  crag.graph name = "encode_foa" sample_rate = 0 channels = 4 default_visualizer = "oscilloscope" {
  ^bb0(%src: !crag.audio<f32, 0, 1>):

    // Virtual source direction parameters.
    %az = crag.param "azimuth"
              min = -3.14159274 max = 3.14159274 default = 0.0
              unit = "rad" : f32
    %el = crag.param "elevation"
              min = -1.57079637 max = 1.57079637 default = 0.0
              unit = "rad" : f32

    // Encoding gains computed from direction.
    %cos_az = math.cos %az : f32
    %sin_az = math.sin %az : f32
    %cos_el = math.cos %el : f32
    %sin_el = math.sin %el : f32

    // W  = src * 1  (omnidirectional; no azimuth/elevation dependency)
    %one = arith.constant 1.0 : f32
    %W = crag.scale %src, %one
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // Y  = src * sin(az) * cos(el)
    %gain_Y = arith.mulf %sin_az, %cos_el : f32
    %Y = crag.scale %src, %gain_Y
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // Z  = src * sin(el)
    %Z = crag.scale %src, %sin_el
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // X  = src * cos(az) * cos(el)
    %gain_X = arith.mulf %cos_az, %cos_el : f32
    %X = crag.scale %src, %gain_X
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // Assemble FOA stream in ACN order: W, Y, Z, X.
    // Inputs are all plain mono — output is tagged as ambisonics.
    %foa = crag.channel_join %W, %Y, %Z, %X
               : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                  !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                 -> !crag.audio<f32, 0, 4, subtype="ambisonics">

    crag.output %foa : !crag.audio<f32, 0, 4, subtype="ambisonics">
  }
}
