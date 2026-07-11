#!/usr/bin/env bash
# description: install the machine surface (links_enumerate desired state) onto this machine, recording every touched path via the install manifest
#
# install.sh — `temperloop install` (temperloop#264, ADR K164 D7 "install
# manifest" amendment — the CLI half links.sh/manifest.sh's own headers
# document as "not yet built" when they landed).
#
# Thin wiring over two landed seams — this script is their ONLY call site
# for the machine-surface install path, it adds no parallel desired-state
# logic of its own:
#   1. workflows/scripts/install/links.sh's links_enumerate() — the SOLE
#      source of desired state (what should exist, and of what kind, after
#      install). Same enumeration `make doctor` (workflows/scripts/install/
#      doctor.sh) verifies against, so apply and verify can never drift.
#   2. workflows/scripts/install/manifest.sh — the install manifest
#      library. manifest_backup_and_record() is called immediately before
#      this script writes/replaces EVERY managed path, so a future
#      `temperloop uninstall` (not built yet) has an exact, restorable
#      record of what this run did: state=created (nothing to restore
#      beyond removal) or state=preexisting (the original is backed up
#      under the manifest's backups/ root, recorded via an EXPLICIT
#      backup_path this script never re-derives).
#
# Three managed kinds, applied differently (mirrors doctor.sh's own
# classify_entry split):
#   kind=symlink   idempotent relink: already-correct is left alone;
#                  anything else is removed (having just been backed up by
#                  manifest_backup_and_record, if it existed) and
#                  re-linked.
#   kind=real      settings.json (#292) — reconciled via the existing
#                  workflows/scripts/install-settings.sh composer (preserves
#                  the machine-local `model` field; never marker-stamped —
#                  it is strict JSON, and Claude Code owns writing back into
#                  it via /model).
#   kind=claude-md the composed ~/.claude/CLAUDE.md — reconciled via the
#                  existing workflows/scripts/install-claude-md.sh composer.
#                  Only ever enumerated when BOTH claude/CLAUDE.kernel.md
#                  and claude/CLAUDE.overlay.md exist (links_enumerate's own
#                  guard) — absent on a kernel-only checkout with no overlay
#                  doc, so this branch is a no-op there.
#   kind=gh-shim   ~/.local/bin/gh — a banner-stamped real copy of
#                  workflows/scripts/gh-call-logger.sh. This script is the
#                  FIRST place that copy is actually materialized for the
#                  `temperloop` CLI (no install-gh-logger.sh composer exists
#                  in this repo); it embeds manifest_marker_line() as a
#                  second comment line (after the shebang, so the file
#                  stays executable) — the marker-stamp helper's canonical
#                  use case per manifest.sh's own header ("settings.json-
#                  like composers can't rely on -L/readlink"). doctor.sh's
#                  own OK check for this kind greps for 'call-logger', which
#                  the copied source's own header comment already carries
#                  independent of this marker — the two checks are
#                  complementary, not redundant: doctor's is the PRIMARY
#                  identity check, manifest_has_marker is the secondary,
#                  install-manifest-aware one.
#
# CONSENT — mirrors eject.sh's single --yes/interactive-confirm gate (not
# init.sh's finer per-action prompts): installing the machine surface is
# ONE atomic operation, not several independently-declinable ones. Nothing
# is written without explicit consent (--yes, or an interactive y/N) —
# --dry-run skips the consent step entirely and performs ZERO writes (no
# manifest_backup_and_record call, no composer invocation, no symlink/file
# touched).
#
# IDEMPOTENT BY CONSTRUCTION: manifest_backup_and_record() is itself
# idempotent per path (a second record is a no-op — see its own header), so
# re-running this script converges: already-correct managed paths are left
# alone, and no path is ever backed up twice.
#
# Usage:
#   install.sh [--yes] [--dry-run]
#
#   --yes                  Pre-confirm the install instead of an
#                          interactive y/N prompt. Required on a
#                          non-interactive stdin — absent both, the run
#                          aborts with NOTHING written.
#   --dry-run               Print the desired-state plan (what would be
#                          created / replaced-with-backup / left alone);
#                          zero writes, zero manifest calls.
#
# Exit codes: 0 = ran to completion (a declined confirmation, or a dry run,
# is a legible no-op, not a failure). 1 = fatal usage/environment error, OR
# one or more managed paths could not be installed (see the per-path FAILED
# lines). 2 = invalid CLI usage.
#
# Dependencies: bash (3.2+), jq (via manifest.sh). No network.
#
# shellcheck shell=bash

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate sibling kernel content — same pinned-physical-path idiom as
# init.sh / eject.sh's own header comments.
# ---------------------------------------------------------------------------
SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SUBCOMMAND_DIR/.." && pwd)"
KERNEL_ROOT="$(cd "$BIN_DIR/.." && pwd)"
LIB_DIR="$BIN_DIR/lib"
INSTALL_DIR="$KERNEL_ROOT/workflows/scripts/install"
LINKS_SH="$INSTALL_DIR/links.sh"
MANIFEST_SH="$INSTALL_DIR/manifest.sh"
SETTINGS_COMPOSER="$KERNEL_ROOT/workflows/scripts/install-settings.sh"
CLAUDE_MD_COMPOSER="$KERNEL_ROOT/workflows/scripts/install-claude-md.sh"
GH_LOGGER_SRC="$KERNEL_ROOT/workflows/scripts/gh-call-logger.sh"

# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

command -v jq >/dev/null 2>&1 || { echo "install.sh: jq not found on PATH" >&2; exit 1; }

if [ ! -f "$LINKS_SH" ]; then
  echo "install.sh: links.sh not found at $LINKS_SH (broken kernel checkout)" >&2
  exit 1
fi
if [ ! -f "$MANIFEST_SH" ]; then
  echo "install.sh: manifest.sh not found at $MANIFEST_SH (broken kernel checkout)" >&2
  exit 1
fi

# shellcheck source=../../workflows/scripts/install/links.sh
source "$LINKS_SH"
# shellcheck source=../../workflows/scripts/install/manifest.sh
source "$MANIFEST_SH"

usage() {
  cat <<'EOF'
usage: install.sh [--yes] [--dry-run]
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
    *) echo "install.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

echo "== temperloop install =="
echo

# ---------------------------------------------------------------------------
# Enumerate desired state once. Read into three parallel arrays (bash 3.2
# has no associative/nested arrays) rather than re-invoking links_enumerate
# per phase, so the plan printed to the operator and the plan actually
# applied are byte-identical.
# ---------------------------------------------------------------------------
targets=()
kinds=()
srcs=()
while IFS=$'\t' read -r t k s; do
  [ -n "$t" ] || continue
  targets+=("$t")
  kinds+=("$k")
  srcs+=("$s")
done < <(links_enumerate "$KERNEL_ROOT")

n="${#targets[@]}"

# ---------------------------------------------------------------------------
# describe_entry <target> <kind> <expected_source> — one-line plan
# description with NO side effects (used by both --dry-run and the
# pre-consent plan printout).
# ---------------------------------------------------------------------------
describe_entry() {
  local target="$1" kind="$2" src="$3"
  case "$kind" in
    symlink)
      if [ -L "$target" ] && [ "$(readlink "$target")" = "$src" ]; then
        echo "  = ${target} (already linked)"
      elif [ -e "$target" ] || [ -L "$target" ]; then
        echo "  → ${target} (would replace — original backed up)"
      else
        echo "  → ${target} (would create)"
      fi
      ;;
    real|claude-md)
      if [ -e "$target" ] && [ ! -L "$target" ]; then
        echo "  → ${target} (would reconcile — prior content backed up)"
      elif [ -e "$target" ] || [ -L "$target" ]; then
        echo "  → ${target} (would replace — original backed up)"
      else
        echo "  → ${target} (would generate)"
      fi
      ;;
    gh-shim)
      if [ -f "$target" ] && ! [ -L "$target" ] && grep -q 'call-logger' "$target" 2>/dev/null; then
        echo "  = ${target} (already installed)"
      elif [ -e "$target" ] || [ -L "$target" ]; then
        echo "  → ${target} (would replace — original backed up)"
      else
        echo "  → ${target} (would create)"
      fi
      ;;
    *)
      echo "  ? ${target} (unknown kind: ${kind})"
      ;;
  esac
}

echo "-- Desired state (${n} managed path(s)) --"
i=0
while [ "$i" -lt "$n" ]; do
  describe_entry "${targets[$i]}" "${kinds[$i]}" "${srcs[$i]}"
  i=$((i + 1))
done
echo

if [ "$dry_run" -eq 1 ]; then
  echo "-- Dry run: nothing written above (zero manifest calls, zero file/symlink writes) --"
  echo
  echo "temperloop install: done (dry run)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Consent gate — mirrors eject.sh's own _init_confirm-adjacent default:
# nothing installed without explicit consent (--yes, or an interactive
# y/N). A non-interactive run with no --yes aborts entirely, writing
# nothing.
# ---------------------------------------------------------------------------
proceed=0
if [ "$do_yes" -eq 1 ]; then
  proceed=1
  echo "install: yes (--yes)"
elif [ -t 0 ]; then
  printf 'Install the %s managed path(s) above onto this machine? [y/N] ' "$n"
  ans=""
  read -r ans || ans=""
  case "$ans" in
    y|Y|yes|YES) proceed=1; echo "install: yes (operator confirmed)" ;;
    *) echo "install: no (operator declined)" ;;
  esac
else
  echo "install: no (skipped — no explicit consent; non-interactive; pass --yes to opt in)"
fi
echo

if [ "$proceed" -ne 1 ]; then
  echo "temperloop install: aborted — nothing written"
  exit 0
fi

# ---------------------------------------------------------------------------
# apply_symlink <target> <expected_source> — install-side symlink apply.
# Unlike links_apply_symlink() (links.sh), this REPLACES whatever sits at
# <target> once manifest_backup_and_record has already preserved it — the
# whole point of the manifest is to make that replacement safe. Idempotent:
# an already-correct symlink is left untouched.
# ---------------------------------------------------------------------------
apply_symlink() {
  local target="$1" src="$2"
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$src" ]; then
    echo "  = $(basename "$target") already linked"
    return 0
  fi
  mkdir -p "$(dirname "$target")" || { echo "  ! could not create parent dir for ${target}" >&2; return 1; }
  rm -rf -- "$target"
  ln -s "$src" "$target" && echo "  → linked $(basename "$target")"
}

# ---------------------------------------------------------------------------
# apply_gh_shim <target> — install-side gh call-logger shim materializer.
# The FIRST place this repo actually writes the shim (no install-gh-
# logger.sh composer exists yet) — a banner-stamped real copy of
# gh-call-logger.sh, marker-stamped via manifest_marker_line() as the
# second line (after the shebang, so the file stays executable).
# ---------------------------------------------------------------------------
apply_gh_shim() {
  local target="$1"
  if [ ! -f "$GH_LOGGER_SRC" ]; then
    echo "  ! gh-call-logger source not found: ${GH_LOGGER_SRC}" >&2
    return 1
  fi
  mkdir -p "$(dirname "$target")" || { echo "  ! could not create parent dir for ${target}" >&2; return 1; }
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/temperloop-gh-shim.XXXXXX")" || return 1
  if { head -n1 "$GH_LOGGER_SRC"; manifest_marker_line; tail -n +2 "$GH_LOGGER_SRC"; } >"$tmp" \
      && mv "$tmp" "$target" && chmod +x "$target"; then
    echo "  → installed gh call-logger shim at ${target}"
  else
    rm -f "$tmp"
    echo "  ! failed to write gh shim at ${target}" >&2
    return 1
  fi
}

echo "-- Installing --"
failures=0
i=0
while [ "$i" -lt "$n" ]; do
  target="${targets[$i]}"
  kind="${kinds[$i]}"
  src="${srcs[$i]}"

  if ! manifest_backup_and_record "$target"; then
    echo "  ! manifest recording failed for ${target} — skipping" >&2
    failures=$((failures + 1))
    i=$((i + 1))
    continue
  fi

  case "$kind" in
    symlink)
      apply_symlink "$target" "$src" || failures=$((failures + 1))
      ;;
    real)
      # Only settings.json today (links.sh § 2, the #292 exception).
      if [ -f "$SETTINGS_COMPOSER" ]; then
        if bash "$SETTINGS_COMPOSER" "$KERNEL_ROOT/claude/settings.json" "$target"; then
          echo "  → reconciled $(basename "$target")"
        else
          echo "  ! install-settings.sh failed for ${target}" >&2
          failures=$((failures + 1))
        fi
      else
        echo "  ! install-settings.sh not found at ${SETTINGS_COMPOSER} — skipping ${target}" >&2
        failures=$((failures + 1))
      fi
      ;;
    claude-md)
      if [ -f "$CLAUDE_MD_COMPOSER" ]; then
        if bash "$CLAUDE_MD_COMPOSER" "$KERNEL_ROOT/claude/CLAUDE.kernel.md" "$KERNEL_ROOT/claude/CLAUDE.overlay.md" "$target"; then
          echo "  → composed $(basename "$target")"
        else
          echo "  ! install-claude-md.sh failed for ${target}" >&2
          failures=$((failures + 1))
        fi
      else
        echo "  ! install-claude-md.sh not found at ${CLAUDE_MD_COMPOSER} — skipping ${target}" >&2
        failures=$((failures + 1))
      fi
      ;;
    gh-shim)
      apply_gh_shim "$target" || failures=$((failures + 1))
      ;;
    *)
      echo "  ! unknown kind '${kind}' for ${target} — skipping" >&2
      failures=$((failures + 1))
      ;;
  esac

  i=$((i + 1))
done
echo

# ---------------------------------------------------------------------------
# Best-effort cache-store provisioning (F#988/#1026) — not a managed path
# doctor.sh's OK/non-OK gate tracks (it is informational only, per its own
# header), so a failure here is reported but never counted against this
# script's own exit code.
# ---------------------------------------------------------------------------
echo "-- Cache-store provisioning --"
links_provision_cache_stores "$KERNEL_ROOT" || echo "  (non-fatal — see above)"
echo

echo "-- Summary --"
echo "${n} managed path(s) processed, ${failures} failure(s)"
echo "Verify with: bash ${INSTALL_DIR}/doctor.sh (or 'make doctor' from a foundation checkout)"
echo

if [ "$failures" -gt 0 ]; then
  echo "temperloop install: incomplete"
  exit 1
fi

echo "temperloop install: done"
exit 0
