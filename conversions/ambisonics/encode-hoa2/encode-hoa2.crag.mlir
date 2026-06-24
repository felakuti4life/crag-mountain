// Second-Order Ambisonics Encoder (Mono → HOA2)
//
// Encodes a mono audio source into Second-Order Ambisonics (HOA, order 2)
// using the ACN channel ordering and SN3D normalisation (AmbiX format).
//
// A second-order B-format signal has (N+1)² = 9 channels:
//
//   ACN  0  W    (l=0,m=0)   : 1
//   ACN  1  Y    (l=1,m=-1)  : sin(az)*cos(el)
//   ACN  2  Z    (l=1,m=0)   : sin(el)
//   ACN  3  X    (l=1,m=1)   : cos(az)*cos(el)
//   ACN  4  V    (l=2,m=-2)  : sqrt(3/4)*sin(2az)*cos²(el)
//   ACN  5  T    (l=2,m=-1)  : sqrt(3)*sin(az)*sin(el)*cos(el)
//   ACN  6  R    (l=2,m=0)   : (3sin²(el)−1)/2
//   ACN  7  S    (l=2,m=1)   : sqrt(3)*cos(az)*sin(el)*cos(el)
//   ACN  8  U    (l=2,m=2)   : sqrt(3/4)*cos(2az)*cos²(el)
//
// Parameters:
//   azimuth   – horizontal angle in radians (0 = front, π/2 = left)
//   elevation – vertical angle in radians (0 = horizontal, π/2 = up)
//
// Channel count: 1 → 9 (subtype="ambisonics")
//
// References:
//   Daniel, J. (2001). Représentation de champs acoustiques. PhD thesis,
//     Université Paris VI.
//   Zotter, F. & Frank, M. (2019). Ambisonics. Springer.
//   IEM Plugin Suite documentation, https://plugins.iem.at/

module {
  crag.graph name = "encode_hoa2" sample_rate = 0 channels = 9 default_visualizer = "oscilloscope" {
  ^bb0(%src: !crag.audio<f32, 0, 1>):

    // Virtual source direction parameters.
    %az = crag.param "azimuth"
              min = -3.14159274 max = 3.14159274 default = 0.0
              unit = "rad" : f32
    %el = crag.param "elevation"
              min = -1.57079637 max = 1.57079637 default = 0.0
              unit = "rad" : f32

    // First-order trigonometry.
    %cos_az = math.cos %az : f32
    %sin_az = math.sin %az : f32
    %cos_el = math.cos %el : f32
    %sin_el = math.sin %el : f32

    // Second-order helpers.
    %two     = arith.constant 2.0 : f32
    %half    = arith.constant 5.0e-01 : f32
    %three   = arith.constant 3.0 : f32
    %one     = arith.constant 1.0 : f32
    %neg_one = arith.constant -1.0 : f32

    // sin(2az) = 2*sin(az)*cos(az)
    %sin2az   = arith.mulf %two, %sin_az : f32
    %sin2az_f = arith.mulf %sin2az, %cos_az : f32

    // cos(2az) = cos²(az) − sin²(az)
    %cos2_az = arith.mulf %cos_az, %cos_az : f32
    %sin2_az = arith.mulf %sin_az, %sin_az : f32
    %cos2az  = arith.subf %cos2_az, %sin2_az : f32

    // cos²(el)
    %cos2_el = arith.mulf %cos_el, %cos_el : f32
    // sin²(el)
    %sin2_el = arith.mulf %sin_el, %sin_el : f32
    // sin(el)*cos(el)
    %sin_el_cos_el = arith.mulf %sin_el, %cos_el : f32

    // sqrt(3/4) ≈ 0.8660 (= sqrt(3)/2)
    %sqrt3_4 = arith.constant 8.66025404e-01 : f32
    // sqrt(3) ≈ 1.7321
    %sqrt3   = arith.constant 1.73205081e+00 : f32

    // -----------------------------------------------------------------------
    // ACN 0  W = 1
    %one_f = arith.constant 1.0 : f32
    %W = crag.scale %src, %one_f
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // ACN 1  Y = sin(az)*cos(el)
    %gain_Y = arith.mulf %sin_az, %cos_el : f32
    %Y = crag.scale %src, %gain_Y
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // ACN 2  Z = sin(el)
    %Z = crag.scale %src, %sin_el
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // ACN 3  X = cos(az)*cos(el)
    %gain_X = arith.mulf %cos_az, %cos_el : f32
    %X = crag.scale %src, %gain_X
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // ACN 4  V = sqrt(3/4)*sin(2az)*cos²(el)
    %gain_V0 = arith.mulf %sqrt3_4, %sin2az_f : f32
    %gain_V  = arith.mulf %gain_V0, %cos2_el  : f32
    %V = crag.scale %src, %gain_V
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // ACN 5  T = sqrt(3)*sin(az)*sin(el)*cos(el)
    %gain_T0 = arith.mulf %sqrt3, %sin_az : f32
    %gain_T  = arith.mulf %gain_T0, %sin_el_cos_el : f32
    %T = crag.scale %src, %gain_T
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // ACN 6  R = (3*sin²(el) − 1) / 2
    %three_sin2_el = arith.mulf %three, %sin2_el : f32
    %three_s2_m1   = arith.subf %three_sin2_el, %one : f32
    %gain_R        = arith.mulf %three_s2_m1, %half  : f32
    %R = crag.scale %src, %gain_R
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // ACN 7  S = sqrt(3)*cos(az)*sin(el)*cos(el)
    %gain_S0 = arith.mulf %sqrt3, %cos_az : f32
    %gain_S  = arith.mulf %gain_S0, %sin_el_cos_el : f32
    %S = crag.scale %src, %gain_S
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // ACN 8  U = sqrt(3/4)*cos(2az)*cos²(el)
    %gain_U0 = arith.mulf %sqrt3_4, %cos2az  : f32
    %gain_U  = arith.mulf %gain_U0, %cos2_el : f32
    %U = crag.scale %src, %gain_U
             : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    // Assemble 9-channel HOA2 stream in ACN order.
    %hoa2 = crag.channel_join %W, %Y, %Z, %X, %V, %T, %R, %S, %U
                : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                   !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                   !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                   !crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>,
                   !crag.audio<f32, 0, 1>)
                  -> !crag.audio<f32, 0, 9, subtype="ambisonics">

    crag.output %hoa2 : !crag.audio<f32, 0, 9, subtype="ambisonics">
  }
}
