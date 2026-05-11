module {
  crag.include "amps/clippers/tubescreamer_ts808_clip.crag.mlir" as "ts_clip"
  crag.include "amps/tone-stacks/baxandall_tone_control.crag.mlir" as "ts_tone"
  crag.graph name = "tubescreamer_full" sample_rate = 48000 channels = 1 {
  ^bb0(%in: !crag.audio<f32, 0, 0>):
    %s1 = crag.subgraph_ref "ts_clip"(%in) : (!crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    %s2 = crag.subgraph_ref "ts_tone"(%s1) : (!crag.audio<f32, 0, 0>) -> !crag.audio<f32, 0, 0>
    crag.output %s2 : !crag.audio<f32, 0, 0>
  }
}
