module {
  crag.include "amps/tube/fender_bassman_5f6a_input_12ay7.crag.mlir" as "bassman_stage"
  crag.include "amps/tone-stacks/fender_bassman_tone_stack.crag.mlir" as "bassman_tone"
  crag.graph name = "fender_bassman_preamp" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %s1 = crag.subgraph_ref "bassman_stage"(%in) : (!crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    %s2 = crag.subgraph_ref "bassman_tone"(%s1) : (!crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.output %s2 : !crag.audio<f32, 0, 0>
  }
}
