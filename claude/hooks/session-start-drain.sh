#!/usr/bin/env bash
# SessionStart hook — drains .mind/ session stubs from all dev roots into the
# Obsidian vault at Sessions/_inbox/<original-filename>.md via the Obsidian
# Local REST API. Deletes each local stub on successful upload.
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

# Vault-root / config resolution routes through the knowledge_store seam
# (foundation #777, Epic A #762 "kernel split") rather than a hardcoded vault
# path. This hook is permanently Obsidian-specific (it drains straight into
# Sessions/_inbox via the vault's REST API — the interface's `ks_root` is
# documented as MEANINGLESS for the obsidian backend, see
# knowledge_store_obsidian.sh, so it is deliberately NOT used here), so the
# config it borrows is the obsidian backend's own knobs
# (KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE / _API_BASE) — their defaults already
# resolve to today's vault path/URL in that ONE file, not duplicated here. The
# transport itself (raw curl PUT, not ks_write) is unchanged — see the header
# comment below on why a whole-file PUT stays outside the interface's own
# write op for this hook.
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
if [ -f "$KS_LIB_DIR/knowledge_store_obsidian.sh" ]; then
  # shellcheck source=/dev/null
  . "$KS_LIB_DIR/knowledge_store_obsidian.sh"
fi

# If the seam couldn't be sourced (e.g. a stripped-down checkout with no
# workflows/scripts/lib/), these stay empty — the existing "API key file
# missing" check further below (an empty path fails `[ -f "" ]`) already fails
# open onto "skipping drain" with no separate early exit needed, and the
# session-id emission below (which must fire regardless) is unaffected.
API_KEY_FILE="${KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE:-}"
API_BASE="${KNOWLEDGE_STORE_OBSIDIAN_API_BASE:-https://127.0.0.1:27124}"
# The vault's filesystem root, derived from the API key file's fixed Obsidian
# plugin-data suffix (never a hardcoded vault path) — needed below only to
# EXCLUDE the vault dir from the stub search, not for any vault content I/O.
VAULT="${API_KEY_FILE%/.obsidian/plugins/obsidian-local-rest-api/data.json}"
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

# Read API key.
if [ ! -f "$API_KEY_FILE" ]; then
  log "API key file missing: $API_KEY_FILE — skipping drain"
  exit 0
fi

API_KEY=$(jq -r '.apiKey // empty' "$API_KEY_FILE" 2>/dev/null)
if [ -z "$API_KEY" ]; then
  log "Could not read apiKey from $API_KEY_FILE — skipping drain"
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

  # PUT is idempotent — overwrites if a prior run partially completed.
  # Whole-file PUT only: this hook issues NO PATCH, so the Obsidian Local REST
  # API 4.0.0 change that made `targetScope` required on PATCH does not apply
  # here (verified, foundation #6). If you ever add a PATCH call to this hook,
  # it MUST carry a `Target-Type`/`targetScope` (and `createTargetIfMissing`
  # where relevant) or it 400s on REST API >= 4.0.
  http_code=$(curl -s -k -o /tmp/drain_response.$$ -w '%{http_code}' \
    -X PUT "$API_BASE/vault/$vault_path" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: text/markdown" \
    --data-binary "@$stub" 2>/dev/null)

  if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
    rm -f "$stub"
    moved=$((moved + 1))
    log "drained: $stub -> $vault_path"
  else
    failed=$((failed + 1))
    response=$(cat /tmp/drain_response.$$ 2>/dev/null | head -c 200)
    log "FAILED [$http_code]: $stub -> $vault_path | response: $response"
  fi
  rm -f /tmp/drain_response.$$
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
