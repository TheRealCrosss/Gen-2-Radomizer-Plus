# Trainer Rematch 2 — Gold v1.0.0

The Gold interaction path exposes defeated trainer NPCs with flattened
`trainerClass` / `trainerParty` fields. v8.6.0 was primarily checking for the
normalized `npc.def.trainer` table, so the talk wrapper could miss the trainer.

v1.0.0 recognizes both shapes.

It also:
- uses Gold's authoritative `trainerDefeated()` check,
- includes a save-state fallback for packaged builds,
- adds a `world.interact` fallback for Gold interaction paths that bypass the
  compatibility `talkTo` façade,
- temporarily normalizes trainer metadata only while starting the existing
  working native rematch script.

Expected behavior:
1. Talk to an already-defeated trainer.
2. **Want a rematch?**
3. YES -> rematch.
4. NO -> normal post-defeat line.


