#!/usr/bin/env bash
# make doctor — verify managed install links and report drift.
#
# Sources workflows/scripts/install/links.sh for the canonical link enumeration,
# then classifies each managed path and prints a status table.
#
# Status codes (printed per-entry and in the summary):
#
#   OK        symlink present and points at expected source
#             OR managed real file / shim is present
#   MISSING   target path does not exist (and is not a broken symlink)
#   DRIFT     symlink present but points at a DIFFERENT source
#   SHADOWED  a real file/directory exists where a symlink is expected
#   DANGLING  symlink present but its target path does not exist on disk
#
# Exit codes:
#   0   all entries are OK
#   1   one or more entries are non-OK
#
# Usage: bash workflows/scripts/install/doctor.sh [<foundation-root>]
#        (foundation-root defaults to the repo root detected from this script's path)
#
# shellcheck shell=bash
set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve FOUNDATION (repo root) from this script's location or an argument.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUNDATION="${1:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"
export FOUNDATION

# Source the shared enumeration helper.
# shellcheck source=links.sh
source "${SCRIPT_DIR}/links.sh"

# ---------------------------------------------------------------------------
# classify_entry <target> <expected_source> <kind>
#
# Prints the status string for a single managed path.
# ---------------------------------------------------------------------------
classify_entry() {
  local target="$1"
  local expected_src="$2"
  local kind="$3"

  if [[ "$kind" == "real" || "$kind" == "claude-md" ]]; then
    # settings.json (real) / composed CLAUDE.md (claude-md) — both are
    # expected to be a real (non-symlink) regular file; same classification.
    if [ -f "$target" ] && ! [ -L "$target" ]; then
      echo "OK"
    elif [ -e "$target" ] || [ -L "$target" ]; then
      echo "DRIFT"   # exists but not a plain file (e.g. is a symlink or directory)
    else
      echo "MISSING"
    fi
    return
  fi

  if [[ "$kind" == "gh-shim" ]]; then
    # gh logger shim — managed real copy, recognised by 'call-logger' marker.
    if [ -f "$target" ] && ! [ -L "$target" ] && grep -q 'call-logger' "$target" 2>/dev/null; then
      echo "OK"
    elif [ -f "$target" ] && ! [ -L "$target" ]; then
      echo "DRIFT"   # real file but not our shim
    elif [ -L "$target" ]; then
      echo "DRIFT"   # should be a real file, not a symlink
    elif [ -e "$target" ]; then
      echo "DRIFT"   # something else (directory?)
    else
      echo "MISSING"
    fi
    return
  fi

  # kind == "symlink"
  if [ -L "$target" ]; then
    local actual_src
    actual_src="$(readlink "$target")"
    if [[ "$actual_src" == "$expected_src" ]]; then
      if [ -e "$target" ]; then
        echo "OK"
      else
        echo "DANGLING"
      fi
    else
      echo "DRIFT"
    fi
  elif [ -e "$target" ]; then
    echo "SHADOWED"
  else
    echo "MISSING"
  fi
}

# ---------------------------------------------------------------------------
# check_knowledge_root — foundation Epic B "layered CLAUDE.md" / the Epic A
# (#762) knowledge_store split-brain guard: the agent-plane Obsidian MCP
# vault (what a live Claude session actually reads/writes via mcp__obsidian*)
# must be the SAME directory as KNOWLEDGE_STORE_ROOT (the script-plane
# document-I/O seam, workflows/scripts/build/build.config.sh). A mismatch
# means the two planes silently split the corpus: the agent writes decisions
# into one vault while hooks/scripts read/write knowledge_store documents in
# another.
#
# The Obsidian MCP vault root is not itself exposed as a config value — it is
# derived MECHANICALLY from KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE
# (workflows/scripts/lib/knowledge_store_obsidian.sh), whose default is
# always "<vault>/.obsidian/plugins/obsidian-local-rest-api/data.json" (the
# Local REST API plugin's fixed on-disk layout) — stripping that fixed
# suffix recovers <vault> with no hardcoded path literal in this script.
#
# Runs fully offline: sourcing build.config.sh / knowledge_store_obsidian.sh
# does no network I/O (only their functions, never called here, would).
# ---------------------------------------------------------------------------
check_knowledge_root() {
  local build_config="${FOUNDATION}/workflows/scripts/build/build.config.sh"
  local ks_lib="${FOUNDATION}/workflows/scripts/lib/knowledge_store.sh"
  local ks_obsidian="${FOUNDATION}/workflows/scripts/lib/knowledge_store_obsidian.sh"
  local suffix="/.obsidian/plugins/obsidian-local-rest-api/data.json"

  printf '\nKnowledge-store root check:\n'

  if [[ ! -f "$build_config" || ! -f "$ks_lib" || ! -f "$ks_obsidian" ]]; then
    printf '  SKIPPED (config files not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  local resolved store_root api_key_file obsidian_root
  resolved="$(
    set -e
    # shellcheck source=/dev/null
    source "$build_config"
    # knowledge_store_obsidian.sh's own API-key-file default is DERIVED from
    # ks_root (knowledge_store.sh) — source it first, per that file's own
    # documented "source AFTER knowledge_store.sh" requirement.
    # shellcheck source=/dev/null
    source "$ks_lib"
    # shellcheck source=/dev/null
    source "$ks_obsidian"
    printf '%s\n%s\n' "$(ks_root)" "$KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE"
  )" || { printf '  FAIL — could not resolve build.config.sh / knowledge_store.sh / knowledge_store_obsidian.sh\n'; return 1; }
  store_root="$(sed -n '1p' <<<"$resolved")"
  api_key_file="$(sed -n '2p' <<<"$resolved")"

  case "$api_key_file" in
    *"$suffix")
      obsidian_root="${api_key_file%"$suffix"}"
      ;;
    *)
      printf '  FAIL — could not derive the Obsidian vault root from KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE=%s\n' "$api_key_file"
      printf '        (expected it to end in %s)\n' "$suffix"
      return 1
      ;;
  esac

  printf '  KNOWLEDGE_STORE_ROOT              = %s\n' "$store_root"
  printf '  Obsidian MCP vault root (derived) = %s\n' "$obsidian_root"

  if [[ "$store_root" == "$obsidian_root" ]]; then
    printf '  OK — knowledge store and Obsidian MCP vault agree.\n'
    return 0
  fi

  printf '  MISMATCH — the agent-plane Obsidian MCP vault and the script-plane\n'
  printf '  KNOWLEDGE_STORE_ROOT point at DIFFERENT directories. Fix by setting\n'
  printf '  KNOWLEDGE_STORE_ROOT (env, or workflows/scripts/build/build.config.local.sh)\n'
  printf '  to match the vault root, or vice versa.\n'
  return 1
}

# ---------------------------------------------------------------------------
# check_cache_state — report the canonical-layer issue-cache store's state
# per board (F#988/#1026): whether a board has opted in (`board.<N>.cache=on`
# in boards.conf) and whether its on-disk store is present/stale/absent.
#
# READ-ONLY and never fails the overall `make doctor` gate — an absent store
# or absent boards.conf is a normal, expected state (cache is opt-in), not a
# drift condition the way a broken managed symlink is. This mirrors
# check_knowledge_root's SKIPPED-is-fine posture for a tree that simply
# doesn't have the pieces wired up yet.
#
# Board discovery is boards.conf-only (the same file board.sh's own
# `_board_conf_file()` would resolve — machine-level, then repo-local),
# never the built-in org-specific case map in board.sh: a stranger's fresh
# clone has no boards.conf and this prints one informational line and
# returns, exactly like links_provision_cache_stores's own discovery.
# ---------------------------------------------------------------------------
check_cache_state() {
  local board_lib="${FOUNDATION}/workflows/scripts/board/lib/board.sh"
  local cache_lib="${FOUNDATION}/workflows/scripts/board/lib/cache.sh"

  printf '\nCache-store state (F#988/#1026):\n'

  if [[ ! -f "$board_lib" || ! -f "$cache_lib" ]]; then
    printf '  SKIPPED (board.sh / cache.sh not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  # temperloop#165 rename window: temperloop/ machine conf preferred, an
  # existing legacy foundation/ one read as fallback (removed in v0.17.0).
  local machine_conf="${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/boards.conf"
  local machine_conf_legacy="${XDG_CONFIG_HOME:-$HOME/.config}/foundation/boards.conf"
  local repo_conf="${FOUNDATION}/workflows/scripts/board/boards.conf"
  local conf=""
  if [[ -f "$machine_conf" ]]; then
    conf="$machine_conf"
  elif [[ -f "$machine_conf_legacy" ]]; then
    conf="$machine_conf_legacy"
    printf '  NOTE: machine boards.conf found at the legacy path %s — the default moved to %s in v0.15.0 (legacy read removed in v0.17.0); move the file.\n' "$machine_conf_legacy" "$machine_conf"
  elif [[ -f "$repo_conf" ]]; then
    conf="$repo_conf"
  fi

  if [[ -z "$conf" ]]; then
    printf '  (no boards.conf found — nothing configured; cache is OFF everywhere by default)\n'
    return 0
  fi

  local boards
  boards="$(grep -oE '^board\.[0-9]+\.repo=' "$conf" 2>/dev/null | cut -d. -f2 | sort -un)"
  if [[ -z "$boards" ]]; then
    printf '  (%s declares no board with a repo= axis — nothing to report)\n' "$conf"
    return 0
  fi

  local n enabled state
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue

    if grep -q "^board\.${n}\.cache=on$" "$conf" 2>/dev/null; then
      enabled="on"
    else
      enabled="off"
    fi

    state="$(
      # shellcheck source=/dev/null
      source "$board_lib" 2>/dev/null
      # shellcheck source=/dev/null
      source "$cache_lib" 2>/dev/null
      repo="$(board_repo "$n" 2>/dev/null)" || { printf 'n/a (no repo axis)'; exit 0; }
      meta="$(cache_meta_file "$repo" 2>/dev/null)"
      if [[ -z "$meta" || ! -f "$meta" ]]; then
        printf 'absent'
      elif cache_stale "$repo" 2>/dev/null; then
        printf 'stale'
      else
        printf 'present'
      fi
    )"

    printf '  board.%-3s  cache=%-3s  store=%s\n' "$n" "$enabled" "$state"
  done <<<"$boards"
}

# ---------------------------------------------------------------------------
# Main — enumerate and classify every managed entry.
# ---------------------------------------------------------------------------
ok=0
non_ok=0
non_ok_entries=()

printf '\nmake doctor — managed link status (%s)\n\n' "$FOUNDATION"
printf '  %-10s  %s\n' "STATUS" "TARGET"
printf '  %-10s  %s\n' "----------" "------"

while IFS=$'\t' read -r target kind expected_src; do
  status="$(classify_entry "$target" "$expected_src" "$kind")"
  printf '  %-10s  %s\n' "$status" "$target"
  if [[ "$status" == "OK" ]]; then
    (( ok++ )) || true
  else
    (( non_ok++ )) || true
    non_ok_entries+=("${status}  ${target}")
  fi
done < <(links_enumerate "$FOUNDATION")

echo
printf 'OK: %d   Non-OK: %d\n' "$ok" "$non_ok"

knowledge_root_status=0
check_knowledge_root || knowledge_root_status=$?

check_cache_state || true

if (( non_ok > 0 )); then
  echo
  echo "Non-OK entries:"
  printf '  %s\n' "${non_ok_entries[@]}"
fi

if (( non_ok > 0 || knowledge_root_status != 0 )); then
  echo
  exit 1
fi

echo
