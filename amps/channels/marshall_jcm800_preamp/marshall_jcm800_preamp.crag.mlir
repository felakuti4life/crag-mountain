module {
  crag.include "amps/tube/marshall_jcm800_v1_12ax7.crag.mlir" as "jcm_stage"
  crag.include "amps/tone-stacks/marshall_jtm45_jcm800_tone_stack.crag.mlir" as "jcm_tone"
  crag.graph name = "marshall_jcm800_preamp" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %s1 = crag.subgraph_ref "jcm_stage"(%in) : (!crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    %s2 = crag.subgraph_ref "jcm_tone"(%s1) : (!crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.output %s2 : !crag.audio<f32, 0, 0>
  }
}
