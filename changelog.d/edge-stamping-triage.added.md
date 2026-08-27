- **`/triage` now stamps durable logical order between an Operational
  group's members as native `blocked_by` edges** (docs/adr/0031). At Step 4
  materialization, a genuine meaning-level precedence pair (never a
  merge-safety one) is written via the board adapter's `board_blocked_by_add`
  behind a script-backed cycle check (`workflows/scripts/board/cycle-check.sh`)
  that refuses any edge that would close a loop; each stamped edge carries a
  one-line rationale comment, and the epic receives an `edges-considered`
  marker once the sub-step completes (stamped, or legitimately none). The
  formerly-unqualified "edges never live on the board" invariant is narrowed
  accordingly — merge-safety edges and levels stay plan-resident and are
  still never stored — with the amended invariant stated once
  (`claude/commands/triage.md` § Operating principles) and pointed to from
  `/assess`'s recomputed-fresh line. `/triage`'s Step 3 requirements-auditor
  pass also now flags a group whose members carry mixed `Operational`/
  `Foundational` work-class labels at birth, before any stamping is
  attempted.
