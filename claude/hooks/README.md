# claude/hooks — hook inventory and eval profile contract

## Hook inventory

| File | Event | Matcher | Side-channel owned | EVAL_RUN suppressed? |
|---|---|---|---|---|
| `session-start-drain.sh` | SessionStart | — | Vault drain (`Sessions/_inbox/`), vault snapshot | Yes (drain/snapshot skipped; session-id still emitted) |
| `mcp-health-preflight.sh` | SessionStart | — | Injects banner into model context | Yes (no banner injected under eval) |
| `session-start-deploy-mini.sh` | SessionStart | — | Board toolkit deploy (mini-only) | No (mini-gate handles it; eval runs are not mini) |
| `board-adapter-guard.sh` | PreToolUse | Bash | None (prod: *ask* decision) | Behavior changes: prod→ask, eval→record-and-deny |
| `git-stale-branch-guard.sh` | PreToolUse | Bash | None (prod: *ask* decision) | Yes (exits 0 silently under EVAL_RUN) |
| `build-worktree-guard.sh` | PreToolUse | Edit\|Write\|MultiEdit | None (deny decision) | No (write jail is always active) |
| `mcp-failure-tripwire.sh` | PostToolUse | mcp__obsidian.* | None (block decision) | No (eval sessions don't use vault; hook is a no-op if MCP not called) |
| `log-askuserquestion.sh` | PostToolUse | AskUserQuestion | `meta/data/raw/askuserquestion-events.jsonl` | Yes |
| `session-end-log.sh` | SessionEnd | — | `<cwd>/.mind/<stub>.md` | Yes |
| `session-end-seq-cleanup.sh` | SessionEnd | — | Vault `Sequencing/<id8>.md` | Yes |

## Shared helper

**`eval-guard.sh`** — sourced by every hook that owns a production write channel.  Provides a single function:

```bash
# shellcheck source=eval-guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/eval-guard.sh"
eval_guard_exit_if_eval   # exits 0 immediately when EVAL_RUN is non-empty
```

The check is a `[ -n "${EVAL_RUN:-}" ]` test — cheap, uniform, zero-overhead on production runs.

---

## Eval profile contract

The eval runner must set the following to launch a headless `claude -p` session in eval mode such that all side-channel hooks self-suppress and the board-adapter guard record-and-denies.

### Required environment

| Variable | Value | Purpose |
|---|---|---|
| `EVAL_RUN` | `1` (any non-empty string) | Activates all hook suppressions and guard downgrade |
| `CLAUDE_CONFIG_DIR` | Path to an isolated config directory (see below) | Prevents reading/writing the production `~/.claude/` profile |

### Isolated config directory

Create a minimal config dir that omits or stubs production hooks as needed.  A typical setup copies or links the hook scripts (which self-suppress via `EVAL_RUN`) but points to a scratch working directory:

```sh
EVAL_CONFIG="$HOME/.claude-eval"
mkdir -p "$EVAL_CONFIG/hooks"
# Link (not copy) hooks — they self-suppress via EVAL_RUN
for h in session-end-log session-start-drain log-askuserquestion \
          session-end-seq-cleanup mcp-health-preflight board-adapter-guard \
          eval-guard; do
  ln -sf "$HOME/dev/foundation/claude/hooks/${h}.sh" "$EVAL_CONFIG/hooks/"
done
# Provide a minimal settings.json referencing the eval hook paths
```

### Eval denial log

When `board-adapter-guard.sh` fires under `EVAL_RUN`, it appends a structured line to:

```
${EVAL_DENIAL_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/foundation/eval-board-adapter-denials.log}
```

Each line has the format:

```
[<ISO-8601 UTC>] BOARD-ADAPTER-BYPASS DENIED cmd=<full command string>
```

The eval harness should read this log after each eval session to detect and score adapter bypasses as mechanical findings.  Override `EVAL_DENIAL_LOG` to redirect to a per-run scratch file.

### What is suppressed vs what still fires

| Hook behaviour | Production (EVAL_RUN unset) | Eval (EVAL_RUN=1) |
|---|---|---|
| SessionEnd transcript stub in `.mind/` | Written | **Suppressed** |
| Vault drain (`Sessions/_inbox/`) | Runs | **Suppressed** |
| Vault snapshot | Runs | **Suppressed** |
| MCP health preflight banner | Injected if degraded | **Suppressed** |
| AskUserQuestion telemetry to JSONL | Appended | **Suppressed** |
| Sequencing record cleanup | Runs | **Suppressed** |
| Board-adapter guard on direct `gh project` | `ask` decision | `deny` decision + log line |
| Git stale-branch guard on `checkout -b`/`switch -c` off stale main | `ask` decision | **Suppressed** (exit 0) |
| Session-id `additionalContext` | Emitted | **Emitted** (eval traceability) |
| Write-jail guard (build-worktree-guard) | Active when armed | Active when armed |

### Launching a headless eval session

```sh
EVAL_RUN=1 CLAUDE_CONFIG_DIR=/path/to/eval-config \
  claude -p "$(cat prompt.txt)" --output-format json > result.json
```

After the session, check for adapter bypasses:

```sh
grep "BOARD-ADAPTER-BYPASS" "${EVAL_DENIAL_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/foundation/eval-board-adapter-denials.log}"
```

Zero matches = no bypass (adapter-compliant). One or more matches = adapter bypass detected, scored as a finding.
