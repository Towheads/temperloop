# CLAUDE.md

This file is a thin pointer, not the contract itself — it exists so a
Claude Code session started in a fresh clone of this repo (a stranger's
checkout, with no personal overlay installed) self-orients immediately.

1. Read [`AGENTS.md`](AGENTS.md) first — the cross-agent operating
   instructions: what this repo is, the CLI-vs-`make` split, board-adapter
   rules and the shared GraphQL budget, quality gates, and the branch/PR/
   worktree safety rails. It applies to any AI coding agent, not just
   Claude Code.
2. Then read [`claude/CLAUDE.kernel.md`](claude/CLAUDE.kernel.md) — the
   full kernel process-contract doc: branch/PR policy, working-tree
   ownership, the task workflow, the plan-first default, the PR
   verification surface, and the rest of the process rules that govern how
   work happens in this repo (and its sibling build repos that adopt the
   same kernel).

An installed checkout composes `claude/CLAUDE.kernel.md` with a private
`claude/CLAUDE.overlay.md` into `~/.claude/CLAUDE.md` at install time (see
`claude/CLAUDE.kernel.md`'s own "Kernel vs overlay routing rule" section) —
this repo ships the kernel half only, which is why this file points at that
source doc rather than restating it.
