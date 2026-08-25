- **Every headless `claude -p` spawn must now pass an explicit `--model`, and a
  gate enforces it for the spawn sites that live in the repo** (#1829). A bare
  `claude -p` does not inherit the launching session's model — it resolves
  whatever default model the *machine* has saved — so a fan-out script composed
  mid-run silently routed its workers to an unintended tier, discarding the
  cost-tier choice `CLAUDE.kernel.md` § Subagent usage exists to make explicit.
  `validate-model-usage-emit.sh` gains section **6e**, the direct sibling of the
  existing generic emit net: any `*.sh` directly under
  `workflows/scripts/build/` whose comment-stripped body spawns a headless
  claude (a `claude -p` / `--print` invocation, or a `--output-format json`
  capture) must also carry a `--model`, or the `checks` gate goes red — caught
  by literal signature, never by having been enumerated in advance. The tier's
  value comes from a named `build.config.sh` setting, never a hard-coded model
  id.

  **Scope, stated honestly:** a repo-scanning net can only see spawn sites that
  live in the repo. The incident behind this change was an ad-hoc script written
  into `/tmp` and run once, which no validator would ever have seen; that case is
  carried by the prose halves alone (`CLAUDE.kernel.md` § Subagent usage
  cost-tier routing, `AGENTS.md` § Safety rails). A machine-level control — a
  `claude` wrapper refusing a bare `-p` — is deliberately out of scope. All seven
  files the issue flagged as invoking `claude -p` with no `--model` turned out to
  be comment/echo-string mentions rather than spawn sites, so the gate lands
  green; the disposition is recorded in section 6e's own header. Adopters:
  an overlay carrying a genuinely bare `claude -p` spawn under
  `workflows/scripts/build/` will go red until it passes the flag.
