- **New `claude-p-spawn-guard.sh` PreToolUse hook — a bare `claude -p` in a
  Bash command now raises an `ask`** (#1836). A headless `claude -p`/`--print`
  spawn does not inherit the launching session's model; it resolves the
  *machine's* saved default, so a fan-out composed mid-run silently routes
  every worker to whatever tier that host was last set to.
  `validate-model-usage-emit.sh` §6e already covered committed `*.sh`; this
  covers spawn text composed at run time. It scans the **whole** command
  string, heredoc bodies included, so it fires on the heredoc that *authors* a
  `/tmp` fan-out script — before any spawn runs — rather than only on the
  leading command word. Command position is recognised after a separator, an
  assignment, a bare modifier, `sh -c`, and a short *named* set of
  argument-taking launchers (`timeout`, `gtimeout`, `xargs`, `parallel`).
  Quoting is tracked as one shell-accurate state, so a `;`, `&` or `&&` inside
  a quoted prompt is prompt text rather than a command break and the compliant
  `claude -p '…; …' --model …` form stays silent. That quote state gates flag
  recognition too — a flag-shaped word inside a quoted prompt is prompt text,
  so `claude -p "explain the --model flag"` still asks (it passes no `--model`)
  while `--append-system-prompt "always use -p mode"` stays silent (it passes
  no `-p`). The attached spellings `-p"hi"` / `--print'hi'` are recognised.
  `ask`, never `deny`; fails
  open; silent under `EVAL_RUN`. Its residual blind spots — a bare spawn inside
  an already-committed script invoked by path, one behind an unlisted launcher
  prefix, or anything launched outside the harness — are stated in the hook
  header and `claude/hooks/README.md`, and the two that can be pinned
  mechanically are asserted as silence tests rather than left implied.
- **New `test_hook_exec_bits.sh` hook check — every invoked hook must be
  committed executable** (#1836). `~/.claude/hooks` is a symlink into the
  tracked checkout and `settings.json` registers each hook as a bare absolute
  path, so a hook committed `100644` exits 126 on every matching tool call and
  silently never fires. No behavioural suite can catch that: they all drive
  their hook as `bash "$HOOK"`, which ignores the exec bit. This asserts the
  git index mode instead, deriving the sourced-helper exemption mechanically
  rather than from a hand-maintained list.
