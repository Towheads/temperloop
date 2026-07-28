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

# Source the shared gitignore-safety helper (temperloop#569/#570 dedup —
# check_reviewer_coverage() below calls gitignore_ensure_entry() directly
# instead of a private, doctor-local reimplementation).
GITIGNORE_SAFETY_SH="${SCRIPT_DIR}/gitignore-safety.sh"
if [ ! -f "$GITIGNORE_SAFETY_SH" ]; then
  echo "doctor.sh: missing sibling script: $GITIGNORE_SAFETY_SH" >&2
  exit 1
fi
# shellcheck source=gitignore-safety.sh
source "$GITIGNORE_SAFETY_SH"

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
# (#762) knowledge_store split-brain guard: EVERY consumer of ks_root() must
# resolve the SAME KNOWLEDGE_STORE_ROOT regardless of which files it happens
# to source first. A mismatch means the two planes silently split the
# corpus: e.g. a script-plane consumer that sources build.config.sh writes
# into one directory while a bare-env consumer (a hook, a launchd agent —
# session-start-drain.sh is the motivating case) that sources only
# knowledge_store.sh reads/writes another.
#
# REWRITTEN (foundation#1332): the prior version of this check compared
# ks_root() against a root derived from KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE
# (workflows/scripts/lib/knowledge_store_obsidian.sh) — but that setting's
# ONLY default is itself "$(ks_root)/.obsidian/plugins/.../data.json", and
# nothing in this tree ever sets it independently. So the old check compared
# a value to itself: its MISMATCH branch was dead code that could never
# fire. Worse, its resolution subshell sourced build.config.sh FIRST, which
# directly sources the operator's rung-3 machine conf (BUILD_CONFIG_MACHINE)
# into scope before ks_root() ever ran its own `:=` — so the old check could
# only ever observe the ALREADY-correct plane, never the bare-env plane it
# was nominally guarding. This is exactly how a 218-drain, 16-consecutive-day
# split-brain outage (temperloop#1328/foundation#1328, fixed for real
# consumers by temperloop#771's _ks_machine_conf_root()) ran with this check
# reporting green the whole time.
#
# The rewrite compares TWO independently-resolved planes instead:
#
#   Plane A (script-plane) — sources build.config.sh, then knowledge_store.sh,
#     then calls ks_root(). build.config.sh directly sources the rung-3
#     machine conf into this subshell's scope, so this is the root any
#     consumer that goes through the full build/sweep stack sees — the same
#     value install-claude-md.sh renders as the vault "Store root:" line.
#
#   Plane B (bare-env) — sources ONLY knowledge_store.sh, then calls
#     ks_root(). This is exactly what a bare hook or launchd agent sees: no
#     build.config.sh in the chain, so ks_root()'s own `_ks_machine_conf_root
#     || _ks_default_root` fallback (temperloop#771) is what resolves it.
#
# A mismatch here is real and actionable: it means the rung-3 machine conf
# (or its KNOWLEDGE_STORE_MACHINE_CONF pointer) is broken or inconsistent
# with whatever build.config.sh itself sees, so the bare-env plane silently
# resolves a different root than the script-plane one.
#
# Runs fully offline: sourcing build.config.sh / knowledge_store.sh does no
# network I/O (only functions never called here would).
# ---------------------------------------------------------------------------
check_knowledge_root() {
  local build_config="${FOUNDATION}/workflows/scripts/build/build.config.sh"
  local ks_lib="${FOUNDATION}/workflows/scripts/lib/knowledge_store.sh"

  printf '\nKnowledge-store root check:\n'

  if [[ ! -f "$build_config" || ! -f "$ks_lib" ]]; then
    printf '  SKIPPED (config files not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  local plane_a plane_b
  plane_a="$(
    set -e
    # shellcheck source=/dev/null
    source "$build_config"
    # shellcheck source=/dev/null
    source "$ks_lib"
    ks_root
  )" || { printf '  FAIL — could not resolve build.config.sh / knowledge_store.sh (plane A, script-plane)\n'; return 1; }

  plane_b="$(
    set -e
    # shellcheck source=/dev/null
    source "$ks_lib"
    ks_root
  )" || { printf '  FAIL — could not resolve knowledge_store.sh (plane B, bare-env)\n'; return 1; }

  printf '  Plane A (script-plane, via build.config.sh)  = %s\n' "$plane_a"
  printf '  Plane B (bare-env, knowledge_store.sh alone) = %s\n' "$plane_b"

  if [[ "$plane_a" == "$plane_b" ]]; then
    printf '  OK — script-plane and bare-env knowledge-store root agree.\n'
    return 0
  fi

  printf '  MISMATCH — a consumer that sources build.config.sh (plane A) resolves\n'
  printf '  KNOWLEDGE_STORE_ROOT to a DIFFERENT directory than a bare consumer that\n'
  printf '  sources only knowledge_store.sh (plane B, e.g. a hook or launchd agent).\n'
  printf '  Fix the rung-3 machine conf (see docs/config-precedence.md, default path\n'
  printf '  under XDG_CONFIG_HOME or HOME/.config, temperloop/build.config.sh) or\n'
  printf '  repoint KNOWLEDGE_STORE_MACHINE_CONF at it so both planes agree.\n'
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

  # temperloop#165: the machine conf's subdir renamed foundation/ ->
  # temperloop/ in v0.15.0, and the legacy read was removed in v0.19.0 — the
  # legacy path is no longer a fallback. But this is `doctor`, whose whole
  # job is to explain why a tree isn't wired up the way its operator thinks,
  # so a legacy file that still exists is REPORTED rather than passed over in
  # silence (same disposition as board.sh's own promoted NOTE — and note this
  # fires whether or not a repo-local conf then supplies the boards, since
  # the operator's question is "why is my machine conf being ignored").
  local machine_conf="${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/boards.conf"
  local machine_conf_legacy="${XDG_CONFIG_HOME:-$HOME/.config}/foundation/boards.conf"
  local repo_conf="${FOUNDATION}/workflows/scripts/board/boards.conf"
  local conf=""
  if [[ ! -f "$machine_conf" && -f "$machine_conf_legacy" ]]; then
    printf '  NOTE: a machine boards.conf exists only at the legacy path %s — the default moved to %s in v0.15.0 and the legacy read was removed in v0.19.0, so that file is IGNORED; move it.\n' "$machine_conf_legacy" "$machine_conf"
  fi
  if [[ -f "$machine_conf" ]]; then
    conf="$machine_conf"
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
# check_reviewer_coverage — advisory, WARN-level reviewer-activation-coverage
# check (temperloop#550, ADR 0007/0008). REUSES #548's pure, non-interactive
# data path (reviewer_coverage_gaps / reviewer_coverage_check_integrity,
# sourced from reviewer-activation-coverage.sh) — NEVER #549's interactive
# reviewer-activate.sh (that script has no source-guard and would run its
# whole offer/prompt body unconditionally if sourced here).
#
# Strictly advisory: a WARN increments a local tally ONLY, never `non_ok`/
# the exit code — an inert, un-activated reviewer is the DESIGNED default
# (opt-in, ADR 0007), so a fresh checkout with zero activated reviewers must
# still exit 0. Mirrors check_cache_state()'s read-only `|| true` posture.
#
# Three outcomes per catalogued-reviewer language, computed from #548's own
# gap-set semantics:
#   - resolvable gap (catalogued in reviewer-routing.tsv, material usage at/
#     above REVIEWER_SCAN_MIN_FILES, not yet activated, not durably declined)
#     -> WARN, every run, until activated or declined. reviewer_coverage_
#     gaps() already computes exactly this set.
#   - durably declined (a decline marker under the per-repo reviewer-state
#     dir, #549's format) -> silent. reviewer_coverage_gaps() already
#     excludes these from its output, so nothing extra is needed here.
#   - uncatalogued (a reviewer-routing.tsv row whose catalog-agent-path does
#     NOT resolve to a real file on disk — reviewer_coverage_check_
#     integrity() reports it DANGLING, i.e. that "catalogued" language has no
#     actual backing rubric to activate) -> a ONE-TIME INFO, never a
#     repeating WARN. This check is catalog-wide (not dependent on this
#     checkout's own file mix), so it fires identically anywhere the tsv/
#     catalog pairing is broken. "One-time" state is a small marker file
#     under the SAME gitignored per-repo reviewer-state dir #549 owns
#     (.claude/reviewer-state/doctor-uncatalogued-notified) — this is
#     doctor.sh's FIRST write-capable check, a deliberate scoped exception to
#     its otherwise read-only posture, confined to that one gitignored path
#     and NEVER touching anything a `git add -A` would stage. If the state
#     dir/gitignore can't be confirmed safe, this degrades to read-only
#     (skips the write, so the INFO simply reprints next run) rather than
#     leaking state anywhere — and never fails the check either way.
# ---------------------------------------------------------------------------
check_reviewer_coverage() {
  local rac_sh="${FOUNDATION}/workflows/scripts/install/reviewer-activation-coverage.sh"

  printf '\nReviewer coverage check (temperloop#550):\n'

  if [[ ! -f "$rac_sh" ]]; then
    printf '  SKIPPED (reviewer-activation-coverage.sh not found under %s)\n' "$FOUNDATION"
    return 0
  fi

  # shellcheck source=/dev/null
  if ! source "$rac_sh" 2>/dev/null; then
    printf '  SKIPPED (could not source reviewer-activation-coverage.sh)\n'
    return 0
  fi

  if [[ ! -f "${REVIEWER_ROUTING_TSV:-}" ]]; then
    printf '  SKIPPED (reviewer-routing.tsv not found at %s)\n' "${REVIEWER_ROUTING_TSV:-<unset>}"
    return 0
  fi

  local project_dir="$FOUNDATION"
  local gaps=""
  gaps="$(reviewer_coverage_gaps "$project_dir" "$REVIEWER_ROUTING_TSV" 2>/dev/null)" || gaps=""

  local warn_count=0 name
  if [[ -n "$gaps" ]]; then
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      printf '  WARN  %-22s catalogued, not yet activated (repo has material usage at/above threshold) — run reviewer-activate.sh to opt in or decline\n' "$name"
      warn_count=$((warn_count + 1))
    done <<<"$gaps"
  fi

  local integrity_err=""
  integrity_err="$(reviewer_coverage_check_integrity "$REVIEWER_ROUTING_TSV" "$FOUNDATION" 2>&1 1>/dev/null)" || true

  if [[ -n "$integrity_err" ]]; then
    local state_dir="${project_dir}/.claude/reviewer-state"
    local notice_marker="${state_dir}/doctor-uncatalogued-notified"

    if [[ ! -e "$notice_marker" ]]; then
      printf '  INFO  one or more reviewer-routing.tsv entries reference a language with no backing rubric on disk (uncatalogued) — see docs/features/review-agents.md for the bring-your-own path:\n'
      printf '%s\n' "$integrity_err" | sed 's/^/        /'

      if gitignore_ensure_entry "$project_dir" ".claude/reviewer-state/" "${project_dir}/.claude/reviewer-state/.doctor-probe"; then
        # if-then-else, not `A && B || C` (SC2015): the marker write is
        # best-effort — a failed mkdir or printf must never fail the check.
        if mkdir -p "$state_dir" 2>/dev/null; then
          printf '# doctor.sh: uncatalogued-language notice already shown on %s\n' "$(date +%Y-%m-%d)" >"$notice_marker" 2>/dev/null || true
        fi
      fi
    fi
  fi

  if [[ "$warn_count" -eq 0 && -z "$integrity_err" ]]; then
    printf '  no resolvable reviewer-activation gaps\n'
  fi

  return 0
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

check_reviewer_coverage || true

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
