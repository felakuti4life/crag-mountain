module {
  crag.include "amps/clippers/big_muff_clip_stages.crag.mlir" as "muff_clip"
  crag.include "amps/tone-stacks/baxandall_tone_control.crag.mlir" as "muff_tone"
  crag.graph name = "big_muff_full" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %s1 = crag.subgraph_ref "muff_clip"(%in) : (!crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    %s2 = crag.subgraph_ref "muff_tone"(%s1) : (!crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.output %s2 : !crag.audio<f32, 0, 0>
  }
}
