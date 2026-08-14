- **The "cannot evaluate" idiom now fails CLOSED instead of open when a
  caller forgets to branch on it** (#1475). Five independently reinvented
  `*_cannot_evaluate()` functions across
  `workflows/scripts/model-comparison/{batch,judge,score,replay}.sh` — four
  byte-identical modulo a script-name prefix — every one of them returning 0
  (a bare `jq`+`printf` body with no explicit `return`, so the function's
  own exit status was whatever `printf` happened to return). A caller that
  forgot to branch on the result fell straight through to the OK path — the
  exact defect shape epic #1409 targets, reinvented inside the idiom meant
  to prevent it. All five now delegate to one shared helper,
  `cannot_evaluate_emit` in the new `workflows/scripts/lib/cannot-evaluate.sh`,
  which returns the reserved `RC_CANNOT_EVALUATE` (2) as its OWN status —
  converging on the same value three sibling standalone conventions already
  used (`KERNEL_LIB_RC_CANNOT_EVALUATE`, `PA_RC_CANNOT_EVALUATE`,
  `FD_RC_CANNOT_EVALUATE`) rather than minting a fourth. `replay.sh`'s
  `preflight` — the one instance that previously printed the machine JSON
  verdict but no human-readable stderr diagnostic — now prints one, matching
  its four siblings. Every existing call site already followed the old
  helper with its own explicit `return 1`, so no observed exit behavior
  changes; the fix is forward-looking, for the next caller that doesn't.
  The reserved code and the two output shapes are registered as a
  machine-parsed surface in `claude/presentation-plane.md`.
