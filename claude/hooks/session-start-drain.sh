#!/usr/bin/env bash
# SessionStart hook — drains .mind/ session stubs from all dev roots into the
# knowledge store at Sessions/_inbox/<original-filename>.md via the
# knowledge_store interface's `plain-files` backend — a direct local file
# copy (foundation #952, Epic "Obsidian → knowledge_store parallel-run
# migration" #951, Phase 2 #948; previously a REST PUT against the Obsidian
# Local REST API — the store is a local folder, so REST added nothing).
# Deletes each local stub on successful copy.
#
# Stubs that land in Sessions/_inbox/ are reviewed and processed by the
# /drain-mind slash command (extracts learnings, generates tasks, moves to
# Sessions/<filename>.md).
#
# Failures are logged to the XDG state dir (foundation #773):
# ${XDG_STATE_HOME:-$HOME/.local/state}/foundation/session-start-drain.log —
# and stubs are left in place for the next run. Never blocks session start.
#
# EVAL_RUN suppression: when EVAL_RUN is set (non-empty), the vault drain is
# skipped entirely.  The session-id additionalContext is still emitted so eval
# runs can trace their own session; no vault writes occur.

set -uo pipefail

# Store-root / config resolution routes through the knowledge_store seam
# (foundation #777, Epic A #762 "kernel split"). This hook previously issued
# a raw curl PUT against the Obsidian Local REST API directly (predating
# F#952); it now goes through `ks_write` (the interface's write op) with the
# backend hard-pinned to `plain-files` below — a direct, atomic local file
# copy into the store, per the migration plan's explicit design ("it's a
# local folder; REST adds nothing"). Zero REST/network dependency: this hook
# keeps working after the Local REST API plugin is uninstalled (the
# migration's Phase-3/L5 stack retirement). The old raw-curl path is one
# `git revert` away.
#
# ROOT-RESOLUTION ARCH FINDING (F#952): this hook runs in a bare hook
# environment that does NOT source workflows/scripts/build/build.config.sh
# (the script that seeds `KNOWLEDGE_STORE_ROOT=$HOME/dev/mind` for every
# script-plane caller in a normal foundation invocation) — so
# knowledge_store.sh's own bare default (`${XDG_DATA_HOME:-$HOME/.local/share}/foundation/knowledge`)
# would apply here unless this hook seeds the root itself. Both knobs are
# therefore pinned UNCONDITIONALLY (plain assignment, not `:=`/`:-`
# defaulting) after sourcing the seam: the hook's env cannot be trusted to
# have sourced build.config.sh, and an *inherited* bogus
# KNOWLEDGE_STORE_ROOT (or a leaked KNOWLEDGE_STORE_BACKEND) must NOT win —
# a session stub silently landing in an XDG data dir or an arbitrary
# inherited path is exactly the failure mode this pin exists to prevent.
# The pinned root mirrors build.config.sh's own foundation-specific value.
#
# Absolute path (not BASH_SOURCE-relative): this hook is symlinked to
# ~/.claude/hooks/, so a relative "../.." climb from BASH_SOURCE[0] would climb
# out of ~/.claude, not out of the foundation checkout (same reasoning as the
# pre-existing $HOME/dev/foundation/.../mind_snapshot.sh reference below).
KS_LIB_DIR="${KS_LIB_DIR:-$HOME/dev/foundation/workflows/scripts/lib}"
if [ -f "$KS_LIB_DIR/knowledge_store.sh" ]; then
  # shellcheck source=/dev/null
  . "$KS_LIB_DIR/knowledge_store.sh"
fi

# See ROOT-RESOLUTION ARCH FINDING above: both knobs pinned unconditionally,
# regardless of what ambient env this hook inherits.
KNOWLEDGE_STORE_ROOT="$HOME/dev/mind"
KNOWLEDGE_STORE_BACKEND="plain-files"
export KNOWLEDGE_STORE_ROOT KNOWLEDGE_STORE_BACKEND

# The store's filesystem root — needed below both as ks_write's target root
# and to EXCLUDE the store dir from the stub search (a stub must never be
# re-drained out of the store itself).
VAULT="$KNOWLEDGE_STORE_ROOT"
INBOX_DIR="Sessions/_inbox"
XDG_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/foundation"
mkdir -p "$XDG_STATE_DIR" 2>/dev/null || true
LOG="$XDG_STATE_DIR/session-start-drain.log"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# Capture stdin (Claude Code sends session_id, transcript_path, cwd, etc. here).
INPUT=$(cat 2>/dev/null || true)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
SHORT_ID=$(printf '%s' "$SESSION_ID" | cut -c1-8)

# Surface session ID to the model so live decision-capture can stamp `source_session`.
# See vault note [[Decisions/foundation - Vault provenance schema (note-level)]].
# Emitted early so it fires even when no stubs exist (drain section below has early exits).
if [ -n "$SHORT_ID" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<session-id>%s</session-id>"}}\n' "$SHORT_ID"
fi

# EVAL_RUN suppression: skip all vault writes (drain + snapshot).
# Session-id was already emitted above so eval runs can trace their session.
# shellcheck source=eval-guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/eval-guard.sh"
eval_guard_exit_if_eval

# Fail open (logged, exit 0 — never blocks session start) when the drain
# cannot run at all: the seam wasn't sourceable (stripped-down checkout with
# no workflows/scripts/lib/), or the store root doesn't exist on this machine
# (a fresh install with no ~/dev/mind — the hook must NOT conjure a store
# root into existence as a side effect of session start; per-file parent-dir
# creation inside an existing root is ks_write's job, root creation is not).
if ! declare -F ks_write >/dev/null 2>&1; then
  log "knowledge_store.sh not sourceable from $KS_LIB_DIR — skipping drain"
  exit 0
fi
if [ ! -d "$KNOWLEDGE_STORE_ROOT" ]; then
  log "knowledge store root missing: $KNOWLEDGE_STORE_ROOT — skipping drain"
  exit 0
fi

# Find stubs across dev roots, excluding the vault itself.
STUBS=$(find "$HOME/dev" "$HOME/Cursor" -path "$VAULT" -prune -o -type f -path '*/.mind/*.md' -print 2>/dev/null)

if [ -z "$STUBS" ]; then
  exit 0  # nothing to drain, silent
fi

moved=0
failed=0

while IFS= read -r stub; do
  [ -z "$stub" ] && continue
  [ ! -f "$stub" ] && continue

  filename=$(basename "$stub")
  vault_path="$INBOX_DIR/$filename"

  # ks_write is a whole-file replace, idempotent on retry (same semantics as
  # the raw REST PUT it replaces) — overwrites if a prior run partially
  # completed. Content travels on stdin per the knowledge_store interface
  # contract; the plain-files backend stages to a sibling temp file and
  # renames into place (atomic — a reader never sees a half-written stub)
  # and creates the Sessions/_inbox/ parent dirs as needed — see
  # knowledge_store.sh's _ks_backend_plain_files_write.
  if ks_err=$(ks_write "$vault_path" < "$stub" 2>&1); then
    rm -f "$stub"
    moved=$((moved + 1))
    log "drained: $stub -> $vault_path"
  else
    failed=$((failed + 1))
    log "FAILED: $stub -> $vault_path | error: ${ks_err:0:200}"
  fi
done <<< "$STUBS"

if [ "$moved" -gt 0 ] || [ "$failed" -gt 0 ]; then
  log "summary: $moved moved, $failed failed"
fi

# Snapshot the vault if it has been more than 20h since the last snapshot.
# Fails open: snapshot errors must never block session start.
SNAPSHOT_SCRIPT="$HOME/dev/foundation/workflows/scripts/mind_snapshot.sh"
if [ -x "$SNAPSHOT_SCRIPT" ]; then
  if ! snap_out=$("$SNAPSHOT_SCRIPT" --if-stale 20 2>&1); then
    log "snapshot FAILED: $snap_out"
  elif [ -n "$snap_out" ]; then
    log "snapshot: $snap_out"
  fi
fi

exit 0
