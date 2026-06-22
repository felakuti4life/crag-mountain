module {
  crag.include "amps/wdf-core/rc-adaptor.crag.mlir" as "wdf_rc"
  crag.include "amps/wdf-core/parallel-junction.crag.mlir" as "wdf_parallel"
  crag.graph name = "fender_bassman_tone_stack" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %bass   = crag.param "bass"   min = 0.0 max = 1.0 default = 0.5 : f32
    %mid    = crag.param "mid"    min = 0.0 max = 1.0 default = 0.5 : f32
    %treble = crag.param "treble" min = 0.0 max = 1.0 default = 0.5 : f32
    %cutoff = arith.constant 0.2 : f32
    %fb, %ff = crag.get_filter_coeffs %cutoff order = 2 type = "lowpass"
                 : f32, !crag.coeff_vec, !crag.coeff_vec
    %lp = crag.filter %in, %fb, %ff
          : (!crag.audio<f32, 0, 0>, !crag.coeff_vec, !crag.coeff_vec) -> !crag.audio<f32, 0, 0>
    %neg1 = arith.constant -1.0 : f32
    %lpn = crag.scale %lp, %neg1 : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %hp = crag.sum %in, %lpn : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    %b = crag.scale %lp, %bass : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %m = crag.scale %in, %mid : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %t = crag.scale %hp, %treble : !crag.audio<f32, 0, 0>, f32 -> !crag.audio<f32, 0, 0>
    %u = crag.sum %b, %m : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    %out = crag.sum %u, %t : (!crag.audio<f32, 0, 0>, !crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.output %out : !crag.audio<f32, 0, 0>
  }
}
