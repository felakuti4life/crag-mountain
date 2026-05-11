module {
  crag.graph name = "fender_deluxe_5e3_preamp_12ax7" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %drive = crag.param "drive" min = 0.0 max = 1.0 default = 0.65 : f32
    %d = arith.addf %drive, %drive : f32
    %b = crag.scale %in, %d : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %x2 = crag.audio_mul %b, %b : !crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0> -> !crag.audio<f32, 0, 0>
    %x3 = crag.audio_mul %x2, %b : !crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0> -> !crag.audio<f32, 0, 0>
    %a1 = arith.constant 1.6 : f32
    %a2 = arith.constant -0.6 : f32
    %a3 = arith.constant 0.9 : f32
    %t1 = crag.scale %b, %a1 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %t2 = crag.scale %x2, %a2 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %t3 = crag.scale %x3, %a3 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %u = crag.sum %t1, %t2 : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    %out = crag.sum %u, %t3 : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
