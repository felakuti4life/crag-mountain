module {
  crag.include "amps/tube/vox_ac30_topboost_ecc83.crag.mlir" as "ac30_stage"
  crag.include "amps/tone-stacks/vox_ac30_topboost_tone_stack.crag.mlir" as "ac30_tone"
  crag.graph name = "vox_ac30_topboost_preamp" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %s1 = crag.subgraph_ref "ac30_stage"(%in) : (!crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    %s2 = crag.subgraph_ref "ac30_tone"(%s1) : (!crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.output %s2 : !crag.audio<f32, 0, 0>
  }
}
