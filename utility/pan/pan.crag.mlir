// Pan (mono → stereo)
//
// Places a mono audio input in the stereo field using a constant-power
// (sin/cos) pan law.  At centre both channels receive -3 dB, so perceived
// loudness stays flat as the source sweeps from hard left to hard right.
//
//   θ   = (pan + 1) · π/4          pan ∈ [-1, 1] → θ ∈ [0, π/2]
//   L   = in · cos(θ)
//   R   = in · sin(θ)
//
// Parameters:
//   pan  [-1, 1] – -1 = hard left, 0 = centre, +1 = hard right (default 0.0)
//
// Conversion: channels 1 → 2.  The pan gains are computed once per block,
// so a fast automated sweep steps at block boundaries; smooth the control
// upstream if that is audible.
//
// Usage (after crag.include):
//   %stereo = crag.subgraph_ref "pan"(%mono)
//                 : (!crag.audio<f32, 0, 1>) -> !crag.audio<f32, 0, 2>

module {
  crag.graph name = "pan" sample_rate = 0 channels = 2 default_visualizer = "oscilloscope" {
  ^bb0(%in: !crag.audio<f32, 0, 1>):

    %pan = crag.param "pan" min = -1.0 max = 1.0 default = 0.0 : f32

    // θ = (pan + 1) · π/4
    %one     = arith.constant 1.0 : f32
    %quarter = arith.constant 0.785398163397448 : f32  // π/4
    %shifted = arith.addf %pan, %one : f32
    %theta   = arith.mulf %shifted, %quarter : f32

    %gain_l = math.cos %theta : f32
    %gain_r = math.sin %theta : f32

    %left  = crag.scale %in, %gain_l : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>
    %right = crag.scale %in, %gain_r : !crag.audio<f32, 0, 1>, f32 -> !crag.audio<f32, 0, 1>

    %stereo = crag.channel_join %left, %right
                  : (!crag.audio<f32, 0, 1>, !crag.audio<f32, 0, 1>)
                    -> !crag.audio<f32, 0, 2>

    crag.output %stereo : !crag.audio<f32, 0, 2>
  }
}
