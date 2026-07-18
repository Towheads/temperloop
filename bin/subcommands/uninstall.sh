#!/usr/bin/env bash
# description: manifest-scoped, reversible removal of everything a future `temperloop install` recorded — restores preexisting files from backup, removes created paths, never touches an unrecorded path
#
# uninstall.sh — `temperloop uninstall`: the manifest-scoped, reversible
# counterpart to a future `temperloop install` (temperloop#265, ADR K164 D7
# "install manifest" amendment).
#
# THIS SUBCOMMAND READS ONLY workflows/scripts/install/manifest.sh's own
# machine-surface manifest
# (${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/install-manifest.json —
# never a namespace grep, never an inferred path. For every path recorded
# there it calls manifest_restore_from_record(path): a "created" entry is
# removed; a "preexisting" entry is restored from its recorded backup. A
# path with NO manifest entry is invisible and is NEVER touched, no matter
# how plausible it looks (e.g. a machine conf under
# $XDG_CONFIG_HOME/temperloop/ a human hand-edited after install — see
# bin/README.md's Uninstall section for the worked example).
#
# FOUR SEPARATE REMOVAL SCOPES (bin/README.md § Uninstall has the full
# table; eject.sh's print_uninstall_bullet prints the same delineation) —
# this subcommand is exactly the SECOND one:
#   (a) the bootstrap footprint (~/.local/bin/temperloop + the `foundation`
#       compat shim + ~/.local/share/temperloop) — written by
#       bin/bootstrap.sh BEFORE any manifest existed, so this manifest
#       cannot record or remove it. Manual removal stays documented
#       (print_bootstrap_footprint_bullet below). This is a deliberate
#       stance, not an oversight: inferring "temperloop lives under
#       ~/.local, remove it too" would be exactly the namespace-grep
#       behavior manifest.sh's own read discipline forbids (see that
#       file's header, "a path with NO entry here is INVISIBLE to every
#       reader").
#   (b) THIS SCRIPT — the machine-surface manifest a `temperloop install`
#       records (settings/config/symlinks under $HOME the CLI itself wrote).
#   (c) `temperloop eject` — a target REPO's `.temperloop/config` side
#       effects (labels, required checks, boards, proposal PRs; a
#       pre-v0.14.0 init recorded them in `.foundation/config`). A wholly
#       separate manifest, a wholly separate script — see eject.sh's own
#       header for why the two are never merged. This script prints a
#       reminder to run it (print_eject_reminder below) since a machine-
#       scoped manifest has no way to know which repos `init` ever touched.
#   (d) the issue-cache store root
#       (${CACHE_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/temperloop},
#       links.sh's links_provision_cache_stores) — created by `temperloop
#       install` but DELIBERATELY left out of this manifest (see
#       print_cache_store_bullet below for why) rather than folded into
#       scope (b).
#
# Usage:
#   uninstall.sh [--yes] [--dry-run]
#
#   --yes       Pre-confirm the uninstall instead of an interactive y/N
#               prompt. Required on non-interactive stdin — absent both,
#               the whole run aborts with NOTHING touched (the same
#               "nothing lands without explicit consent" default
#               eject.sh/init.sh use, mirrored for this also-mutating
#               direction).
#   --dry-run   Print what would be restored/removed; zero writes — the
#               manifest and every recorded path are left exactly as they
#               are.
#
# Exit codes: 0 = ran to completion (a declined confirmation, an empty
# manifest, or a dry run are legible no-ops, not failures). 1 = fatal
# usage/environment error (including an unreadable manifest — see
# manifest_load's read-compat refusal in workflows/scripts/install/
# manifest.sh), OR a partial uninstall (some recorded paths could not be
# restored — manifest.sh's own contract leaves those entries recorded so a
# re-run retries only them; see manifest_restore_from_record). 2 = invalid
# CLI usage.
#
# Dependencies: bash (3.2+), jq. No network — this subcommand never calls
# `gh` or `claude` itself, and (temperloop#412, per-subcommand prereq
# scoping) declares no `# prereqs: ...` header, so `bin/temperloop`'s
# dispatcher gate (bin/lib/common.sh: foundation_check_prereqs) runs zero
# claude/gh checks before dispatching it — `temperloop uninstall` works
# with neither tool on PATH, matching what this script actually needs
# (nothing). A test that wants to exercise only this script's own logic
# still invokes it directly (bash bin/subcommands/uninstall.sh ...),
# bypassing the dispatcher entirely — the same idiom
# bin/subcommands/tests/test_eject.sh already uses.
#
# shellcheck shell=bash

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate sibling kernel content — same pinned-physical-path idiom as
# init.sh / eject.sh's own header comments.
# ---------------------------------------------------------------------------
SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SUBCOMMAND_DIR/.." && pwd)"
LIB_DIR="$BIN_DIR/lib"
REPO_ROOT="$(cd "$BIN_DIR/.." && pwd)"
INSTALL_LIB_DIR="$REPO_ROOT/workflows/scripts/install"

# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=../../workflows/scripts/install/manifest.sh
source "$INSTALL_LIB_DIR/manifest.sh"

command -v jq >/dev/null 2>&1 || { echo "uninstall.sh: jq not found on PATH" >&2; exit 1; }

usage() {
  cat <<'EOF'
usage: uninstall.sh [--yes] [--dry-run]
EOF
}

print_bootstrap_footprint_bullet() {
  cat <<EOF
Bootstrap footprint (predates this manifest — 'temperloop uninstall' has no
  record of it and cannot remove it; scope (a) of bin/README.md's Uninstall
  section — manual removal):
  rm -f "$FOUNDATION_CLI_BIN_DEFAULT" "${FOUNDATION_CLI_BIN_DEFAULT%/*}/foundation"
  rm -rf "$FOUNDATION_CLI_HOME_DEFAULT"
EOF
}

# print_cache_store_bullet — scope (d): the issue-cache store root
# (links.sh's links_provision_cache_stores, run by `temperloop install`).
# Deliberately NOT folded into this manifest: unlike every other managed
# path (a single file/symlink install writes once and this script restores/
# removes verbatim), the store root is a directory that keeps growing after
# install — every board cache read/refresh across every repo this checkout
# has touched writes into it — so "remove it" and "restore its original
# content" are the wrong verbs for it. It is content-addressed regenerable
# cache, not install state; documented here as a deliberately-unmanaged
# scope rather than silently left unexplained.
print_cache_store_bullet() {
  # Same precedence links.sh (links_provision_cache_stores) and
  # board/lib/cache.sh resolve the store root with: an explicit
  # CACHE_STORE_ROOT override wins outright, THEN the XDG_CACHE_HOME/
  # $HOME/.cache fallback. Printing anything else here would hand an
  # operator who has CACHE_STORE_ROOT set a wrong rm -rf path.
  local cache_root="${CACHE_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/temperloop}"
  cat <<EOF
Issue-cache store root (deliberately unmanaged — not tracked by this
  manifest, never touched by 'temperloop uninstall'; scope (d) of
  bin/README.md's Uninstall section):
  $cache_root
  Created by 'temperloop install' and grown by ongoing board cache reads —
  everything in it is regenerable, so removing it is safe but optional:
  rm -rf "$cache_root"
EOF
}

# print_eject_reminder — scope (c): `temperloop init` side effects live in
# a target REPO's .foundation/config, a wholly separate manifest this
# machine-scoped script never reads (see header). There is no machine-level
# record of which repos init ever touched, so — mirroring the bootstrap-
# footprint bullet's own always-print posture — this is a fixed reminder,
# not a personalized one.
print_eject_reminder() {
  cat <<EOF
Ran 'temperloop init' in one or more target repos? Their side effects
  (labels, required checks, boards, proposal PRs, recorded in that repo's
  .temperloop/config — or .foundation/config from a pre-v0.14.0 init) are
  scope (c) — a separate manifest this script never touches. Run
  'temperloop eject' inside each such repo if you want those reverted too.
EOF
}

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
do_yes=0
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) do_yes=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "uninstall.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

echo "== temperloop uninstall =="
echo

# ---------------------------------------------------------------------------
# Step 0 — load the manifest. A refusal here (bad JSON, unknown/future
# schema_version) is a HARD stop before anything else runs: no partial
# deletion is ever attempted against a manifest this build can't trust
# itself to have parsed correctly. manifest_load already prints the exact
# version found + what this build can read to stderr (see manifest.sh's
# read-compatibility stance).
# ---------------------------------------------------------------------------
manifest_json="$(manifest_load)" || {
  echo >&2
  echo "uninstall.sh: refusing to proceed — nothing was touched." >&2
  exit 1
}

recorded_paths=()
while IFS= read -r p; do
  [ -n "$p" ] && recorded_paths+=("$p")
done < <(jq -r '.paths | keys_unsorted[]' <<<"$manifest_json")

n_paths="${#recorded_paths[@]}"

echo "-- Install manifest --"
echo "$n_paths recorded path(s):"
if [ "$n_paths" -gt 0 ]; then
  jq -r '.paths | to_entries[] | "  - " + .value.state + ": " + .key' <<<"$manifest_json"
fi
echo

# ---------------------------------------------------------------------------
# Step 1 — nothing recorded. Idempotency end-state: a fully successful
# uninstall converges here on a re-run (every entry removed by the loop
# below).
# ---------------------------------------------------------------------------
if [ "$n_paths" -eq 0 ]; then
  echo "nothing recorded — nothing to uninstall"
  echo
  print_bootstrap_footprint_bullet
  echo
  print_cache_store_bullet
  echo
  print_eject_reminder
  echo
  echo "temperloop uninstall: done (no-op)"
  exit 0
fi

if [ "$dry_run" -eq 1 ]; then
  echo "-- Dry run: would restore/remove the $n_paths path(s) above. Nothing"
  echo "   done (zero writes, manifest untouched) --"
  echo
  echo "temperloop uninstall: done (dry run)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Consent gate — mirrors eject.sh's own default: nothing touched without
# explicit consent (--yes, or an interactive y/N).
# ---------------------------------------------------------------------------
proceed=0
if [ "$do_yes" -eq 1 ]; then
  proceed=1
  echo "uninstall: yes (--yes)"
elif [ -t 0 ]; then
  printf 'Restore/remove the %s recorded path(s) above? [y/N] ' "$n_paths"
  ans=""
  read -r ans || ans=""
  case "$ans" in
    y|Y|yes|YES) proceed=1; echo "uninstall: yes (operator confirmed)" ;;
    *) echo "uninstall: no (operator declined)" ;;
  esac
else
  echo "uninstall: no (skipped — no explicit consent; non-interactive; pass --yes to opt in)"
fi
echo

if [ "$proceed" -ne 1 ]; then
  echo "temperloop uninstall: aborted — nothing touched, manifest left intact"
  exit 0
fi

# ---------------------------------------------------------------------------
# Restore/remove step. recorded_paths was captured BEFORE any mutation, so
# this loop iterates a stable snapshot even though
# manifest_restore_from_record rewrites the manifest file on every
# successful call. A failed restore (e.g. a missing backup file) is left
# recorded by manifest.sh's own contract — never removed on failure — so a
# re-run retries exactly the unresolved subset with no extra bookkeeping
# needed here.
# ---------------------------------------------------------------------------
echo "-- Restoring/removing recorded paths --"
n_failed=0
for p in "${recorded_paths[@]:-}"; do
  [ -n "$p" ] || continue
  if ! manifest_restore_from_record "$p"; then
    n_failed=$((n_failed + 1))
  fi
done
echo

# ---------------------------------------------------------------------------
# Post-removal tidy: rmdir ~/.claude iff it's now EMPTY. Every path installed
# under it is a SEPARATE manifest entry (one per file/symlink — links.sh's
# links_enumerate never records the directory itself), so a fully successful
# uninstall can leave a now-empty ~/.claude behind with nothing to clean it
# up. `rmdir` (never `rm -rf`): if anything install didn't touch still lives
# there, rmdir fails harmlessly on a non-empty directory and it is left
# alone — exactly like every other unrecorded path this script leaves
# untouched.
# ---------------------------------------------------------------------------
claude_dir="${HOME:-$(eval echo ~)}/.claude"
if [ -d "$claude_dir" ] && rmdir "$claude_dir" 2>/dev/null; then
  echo "  → ${claude_dir} removed (was left empty)"
  echo
fi

echo "-- Summary --"
if [ "$n_failed" -eq 0 ]; then
  echo "all $n_paths recorded path(s) uninstalled"
  echo
  print_bootstrap_footprint_bullet
  echo
  print_cache_store_bullet
  echo
  print_eject_reminder
  echo
  echo "temperloop uninstall: done"
  exit 0
else
  echo "$n_failed of $n_paths path(s) could not be restored — left recorded for a retry."
  echo "Re-run 'temperloop uninstall' once resolved."
  echo
  echo "temperloop uninstall: incomplete"
  exit 1
fi
