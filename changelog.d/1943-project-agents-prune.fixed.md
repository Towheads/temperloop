- **`project-agents.sh` now prunes the managed links whose source file is
  gone, on every deploy** (#1943). Deleting a `claude/agents/` or
  `claude/commands/` source file used to leave its deployed symlink behind in
  the project-scoped `.claude/` tree, dangling — and invisible, because the
  installer gitignores the very directory it writes into, so `git status`
  never showed it and `doctor` looked only at `$HOME/.claude`. A dangling
  entry under `.claude/agents/` is not inert: that tree is exactly where
  Claude Code's capability probe looks, so a deleted reviewer kept reading as
  available. Every run (bulk and `--only` alike) now removes them first — no
  flag to remember, and `--dry-run` prints the plan without removing
  anything. The prune is narrow by construction: only a dangling symlink
  whose target string is one this installer itself writes, one directory
  level deep, `.md` only. A regular file, a link to anything else, a link
  that still resolves, and anything outside `.claude/{agents,commands}` are
  left untouched. `make doctor` gains a matching **advisory** section that
  reports any dangling managed link that survives; like the other advisory
  checks it touches no tally and never changes doctor's exit code.
