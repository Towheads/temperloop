---
title: Guard and lifecycle hooks
slug: hooks
---

## Problem

An AI coding agent has broad, fast write access to a working tree and to the
shell — broader and faster than a human operator exercising the same
permissions by hand. Left unchecked, a single session can silently step on a
concurrent session's checkout, branch off a stale base that only reveals the
divergence at push time, bypass a rate-limited API adapter with a raw query
that drains a shared budget, or leak an edit meant for a sandboxed worktree
into the real repository. None of these are hypothetical: each guard in this
repo exists because a real session hit the failure it now prevents. Without a
mechanical layer sitting between the agent's tool calls and their effects,
every one of those mistakes depends on the agent noticing its own mistake in
time — which is exactly the class of error an agent is worst at catching.

Session lifecycle also needs a durable record. A session that ends leaves
behind context (what happened, what was decided, what was read) that is
useful later but only if something captures it before the process exits —
otherwise it is lost the moment the terminal closes.

## How it works

Hooks are shell scripts registered against Claude Code tool-use events
(`PreToolUse`, `PostToolUse`, `SessionStart`, `SessionEnd`) and matched to a
tool pattern (e.g. `Bash`, or `Edit|Write|MultiEdit`). A `PreToolUse` hook
receives the proposed tool call on stdin and returns a permission decision
before the call executes; a `PostToolUse` or lifecycle hook runs after the
fact and can only observe and record, never block.

**The guard inventory** (all `PreToolUse`, all shell scripts under
`claude/hooks/`):

- **write-lane-guard.sh** — matches `Bash|Edit|Write|MultiEdit|NotebookEdit`.
  A session's "lane" is its own launch directory plus any git worktree linked
  to it. A state-mutating call whose target resolves to the *main* working
  tree of a different repository (not the session's own lane) returns an
  `ask` — the sanctioned way to touch another repository is a dedicated,
  isolated worktree, which this guard leaves silent. It exists because two
  concurrent sessions sharing one filesystem can otherwise move each other's
  branch pointer out from under one another.
- **git-stale-branch-guard.sh** — matches `Bash`. On a branch-creation command
  (`git checkout -b`/`-B`, `git switch -c`/`-C`/`--create`) whose base is the
  *local* default branch, fetches the default branch from origin and, if the
  local copy is behind, returns an `ask` naming how many commits behind and
  the fix. Branching off `origin/<default>`, a SHA, or a non-default ref is
  left silent — those bases are already correct. It exists because branching
  from a stale local base and discovering the divergence only at push time
  was the single most common and most expensive friction pattern observed.
- **board-adapter-guard.sh** — matches `Bash`. Fires an `ask` on a direct
  `gh project` invocation or a raw `gh api graphql` call touching a
  Projects-v2 board, prompting the caller to go through the shared board
  adapter library instead. The adapter caches state across processes and
  keeps single-item operations off an expensive full-board page load; an
  ad-hoc raw query bypasses both protections and has drained a shared,
  metered GraphQL budget in a real incident.
- **build-worktree-guard.sh** — matches `Edit|Write|MultiEdit`. Enforces that
  an automated build worker only ever writes inside its own pre-created
  worktree. It is inert by default and arms only when a per-worktree marker
  file is present *and* the worktree sits under the expected
  `<repo>.wt/<name>/` convention — so an ordinary interactive session, which
  has neither, is never affected. It exists because a bare absolute path can
  resolve against the parent checkout even when the worker's shell is `cd`'d
  into its worktree, silently leaking an uncommitted write into the
  orchestrator's own tree.
- **subtree-edit-guard.sh** — matches `Edit|Write|MultiEdit`. In a repository
  that vendors this kernel via a pinned subtree, an edit through the vendored
  path (or a compatibility symlink into it) returns an `ask` — the only
  sanctioned way to change vendored content is to land the change upstream in
  the kernel repository first, then pull it down. A build worker operating
  inside an already-supervised, marker-armed worktree is exempted from the
  interactive prompt (nothing to ask — no live operator is present, and a
  downstream mechanical check still catches an unwaived change).

**The fail-open philosophy.** Every guard above shares the same posture:
`ask`, never `deny`, and any internal error — missing `jq`, unparseable
input, not a git repository, a network failure — exits `0` immediately and
lets the command through unmodified. A guard's job is to make a risky action
a *conscious* choice, not to hard-block legitimate work; a guard bug must
never be able to wedge a session that is doing something correct. This is a
deliberate trade-off: a guard can be bypassed by a determined or confused
caller, but it can never be the reason a legitimate write fails.

**`EVAL_RUN` self-suppression.** An unattended, headless evaluation run has
no live operator to answer an interactive `ask` prompt — an unanswered
`ask` would simply hang the run forever. Every hook that owns a
production side effect sources a shared helper, `eval-guard.sh`, which
exposes one function:

```bash
. "$(dirname "${BASH_SOURCE[0]}")/eval-guard.sh"
eval_guard_exit_if_eval   # exits 0 immediately when EVAL_RUN is non-empty
```

The check is a single `[ -n "${EVAL_RUN:-}" ]` test. Setting `EVAL_RUN` to
any non-empty value during a headless evaluation session suppresses every
side-channel write (vault drain, session-stub logging, telemetry appends)
and downgrades the interactive guards from `ask` to a silent pass-through —
except `board-adapter-guard.sh`, which downgrades from `ask` to `deny` under
`EVAL_RUN` and logs the attempt to a durable eval-denial log, because a board
bypass by the workflow under evaluation is itself a scored finding rather
than something to wave through.

**Session lifecycle hooks.** Beyond the five guards, a set of `SessionStart`
and `SessionEnd` hooks handle non-blocking bookkeeping: writing a transcript
stub when a session ends, draining accumulated stubs into durable storage
when a new session starts, and a health-preflight check that injects a
banner into the model's context if a dependency looks degraded. These never
return a permission decision — they observe and record, and every one of
them is itself `EVAL_RUN`-suppressed so an evaluation run's transcripts and
telemetry never mix with production data.

## Integration

Hooks are declared in the Claude Code settings file (matcher + event +
script path) and installed alongside the rest of the CLI configuration. They
run as ordinary subprocesses invoked by the harness around each tool call —
no separate service, daemon, or long-running process. A repository that
vendors this kernel gets the guard inventory for free once the hooks are
installed; a hook's behavior is entirely local to the checkout(s) it can see
on disk plus whatever it reads from environment variables (`EVAL_RUN`,
`XDG_STATE_HOME`, and a small number of per-hook overrides for pointing a
test harness at a scratch location instead of the real one).

## Resource impact

Each guard is a short shell script invoked synchronously before or after a
single tool call; the added latency is dominated by process-spawn overhead
(a `jq` parse of a small JSON payload, an occasional `git` or `gh` call) —
low milliseconds per invocation, not a measurable drag on a session. The
stale-branch guard is the one guard that does network I/O (a `git fetch`
against origin) when it fires, which is also a deliberate side benefit: the
fetch cures the stale remote-tracking ref the warning is about. Lifecycle
hooks write small text files (a transcript stub, a denial-log line) to local
disk; none of them hold a lock or block the session on I/O beyond a normal
file write.

## Telemetry

`board-adapter-guard.sh` under `EVAL_RUN` appends one line per bypass attempt
to a durable eval-denial log (default under
`${XDG_STATE_HOME:-$HOME/.local/state}/foundation/eval-board-adapter-denials.log`,
overridable), giving an evaluation harness a mechanical, grep-able signal of
whether the workflow under test bypassed the adapter. Outside of that one
stream, the guards do not emit their own metrics — a fired `ask` is visible
in-session as the prompt itself, and a silent pass-through leaves no trace by
design (this is the fail-open contract, not a gap). Absence of a fired guard
is not itself observable; if a guard needs to be proven inert or active in a
given run, add a scoped assertion around that scenario rather than relying
on an existing stream.
