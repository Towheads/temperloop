#!/usr/bin/env bash
# description: move the managed clone's HEAD to a newer release tag — fetch tags (auto-converting a shallow/tagless clone first), surface the CHANGELOG delta with BREAKING sections called out, consent-gate the checkout, re-run the manifest-backed install, finish with doctor
#
# update.sh — `temperloop update` (ADR 0002 "Managed-clone state ownership",
# temperloop#429, epic #419 "beta upgrade story"). Implements the decision's
# second half: bin/bootstrap.sh (a SIBLING item, not this one) owns
# first-install only; once a clone exists, THIS subcommand is the SOLE
# sanctioned way to move that clone's HEAD forward — a bootstrap re-run
# against an existing install is expected to delegate here rather than pull
# in place.
#
# WHAT THIS TOUCHES, AND WHAT IT NEVER TOUCHES (ADR 0002: "Neither mechanism
# ever writes a repo-tracked path in any target repo"): this subcommand's
# entire write surface is (a) the managed clone's OWN git state — the HEAD
# move + the tags/objects it fetches, i.e. exactly the checkout `temperloop`
# itself is running from — and (b) the machine surface install.sh already
# owns (symlinks/real files under $HOME, recorded in the install manifest).
# It takes no --dir/--repo argument and never reaches into any OTHER repo (a
# user's own project, wherever `temperloop init` ran). Moving THIS clone's
# HEAD is not "a repo-tracked write in a target repo" in the ADR's sense —
# the managed clone is temperloop's own turf, the same way install.sh's
# writes under $HOME are; a repo-tracked change a new version needs still
# ships as a normal branch/PR through the standard flow, never as a side
# effect of a personal update.
#
# FLOW (in order — each step gates the next; nothing after a refusal runs):
#   1. Confirm the running checkout (KERNEL_ROOT, resolved the same
#      BASH_SOURCE-relative way as install.sh/uninstall.sh) is actually a
#      git repo — a `git subtree`-vendored kernel/ inside a larger overlay
#      repo, or a dev checkout with no history, is not a "managed clone"
#      this subcommand knows how to move; it refuses legibly rather than
#      guessing.
#   2. UNSHALLOW + FETCH TAGS (acceptance criterion 2): a `--depth 1` clone
#      (bin/bootstrap.sh's own shape — the entire pre-ADR-0002 install base)
#      carries no tags and can't resolve a release target. This step
#      converts it in place (`git fetch --unshallow`, then `--tags`) before
#      anything else runs; a no-op on an already-full clone.
#   3. Resolve cur_tag (HEAD's exact tag match, "" if none — e.g. still on a
#      branch tip, the shallow-clone starting state) and the target tag
#      (highest vX.Y.Z by version sort, or an explicit --to TAG).
#   4. SURFACE THE DELTA (acceptance criterion 1): every CHANGELOG.md
#      section in (cur_tag, target] — read from the TARGET tag's own
#      committed CHANGELOG.md via `git show`, never the working tree's
#      current one, so the preview is what the checkout will actually
#      contain — is printed, and any BREAKING-marked section among them is
#      called out with a banner. This ALL happens before any consent is
#      asked.
#   5. SCHEMA GATE (acceptance criterion 4): before touching HEAD, compares
#      the on-disk install manifest's recorded schema_version (if any
#      install has ever run on this machine) against the TARGET tag's own
#      manifest.sh MANIFEST_READABLE_SCHEMA_VERSIONS (read via `git show`,
#      without checking anything out) — a version this build can't read
#      halts legibly with instructions, never guesses or proceeds blind.
#   6. CONSENT GATE: --yes pre-confirms (the same explicit, deliberate,
#      scriptable-consent idiom install.sh/uninstall.sh/eject.sh already
#      use); otherwise an interactive y/N prompt; a non-interactive run with
#      no --yes REFUSES outright — no timeout-as-consent (see
#      claude/CLAUDE.kernel.md § Merge autonomy & consent, the same
#      standing principle applied to this HEAD move: a question with no
#      safe default never auto-proceeds on an absent operator).
#   7. CHECKOUT the target tag (detached HEAD).
#   8. RE-EXEC into the just-checked-out copy of THIS SAME script
#      (`--post-checkout`) rather than continuing to run the pre-checkout
#      process's already-in-memory copy — a `git checkout` mutating the
#      very file bash is mid-way through interpreting is an unspecified-
#      behavior self-modifying-script hazard. `exec` replaces the process
#      image, forcing a fresh read of update.sh off disk (now at the target
#      tag) — the standard safe self-update idiom.
#   9. (post-checkout phase) re-run `install.sh --yes` — the SAME consent
#      already given in step 6 covers this re-install; it is one atomic
#      "update" operation, not two separately-consented ones — then
#      doctor.sh, then report the tag transition.
#
# Usage:
#   update.sh [--yes] [--to TAG]
#
#   --yes       Pre-confirm the update instead of an interactive y/N
#               prompt. Required on non-interactive stdin — absent both,
#               the run refuses with HEAD left exactly where it was.
#   --to TAG    Update to a specific tag instead of the highest vX.Y.Z tag
#               found after fetching (the default: "latest release").
#
# Exit codes: 0 = already up to date, a declined/refused confirmation (HEAD
# untouched — a legible no-op, not a failure), or a completed update
# (checkout + re-install + doctor all green). 1 = a fetch/checkout/install/
# doctor failure, or a schema-gate refusal (HEAD deliberately left
# untouched). 2 = invalid CLI usage.
#
# Dependencies: bash (3.2+), git, jq (only for the schema gate — its absence
# refuses rather than skipping the safety check). No network beyond the
# managed clone's own `origin` remote.
#
# shellcheck shell=bash

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate sibling kernel content — same pinned-physical-path idiom as
# install.sh/uninstall.sh/eject.sh's own header comments. KERNEL_ROOT is the
# managed clone `temperloop update` moves: there is no --dir override, by
# design (see the header note above on "what this touches").
# ---------------------------------------------------------------------------
SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SUBCOMMAND_DIR/.." && pwd)"
KERNEL_ROOT="$(cd "$BIN_DIR/.." && pwd)"
LIB_DIR="$BIN_DIR/lib"
CHANGELOG_LIB="$KERNEL_ROOT/workflows/scripts/lib/changelog.sh"
INSTALL_SH="$SUBCOMMAND_DIR/install.sh"
DOCTOR_SH="$KERNEL_ROOT/workflows/scripts/install/doctor.sh"
MANIFEST_SH_RELPATH="workflows/scripts/install/manifest.sh"

# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

usage() {
  cat <<'EOF'
usage: update.sh [--yes] [--to TAG]
EOF
}

# ---------------------------------------------------------------------------
# schema_gate <target_tag>
#
# Acceptance criterion 4: halt legibly BEFORE moving HEAD if the on-disk
# install manifest's schema_version is one the TARGET tag's own manifest.sh
# doesn't know how to read. Reads the target's manifest.sh via `git show` —
# nothing is checked out yet. Minimal and honest for beta: no migration
# machinery exists, so an incompatible schema is a halt-with-instructions,
# never a silent break or a guess.
#
# Mirrors manifest.sh's OWN manifest_file() path convention
# (${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/install-manifest.json)
# rather than sourcing that file — sourcing would pull in whatever this
# PRE-checkout tag's manifest.sh says, which is exactly the version this
# gate must not assume matches the target's. If that path convention itself
# ever changes, this literal must move with it (an accepted, documented
# coupling for a beta-stage safety check, not an oversight).
# ---------------------------------------------------------------------------
schema_gate() {
  local target_tag="$1"
  local manifest_file="${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/install-manifest.json"

  [[ -f "$manifest_file" ]] || return 0   # nothing installed yet — nothing to migrate

  if ! command -v jq >/dev/null 2>&1; then
    echo "update: jq not found on PATH — cannot verify install-manifest schema compatibility before moving HEAD; refusing (install jq and re-run)" >&2
    return 1
  fi

  local on_disk_schema
  on_disk_schema="$(jq -r '.schema_version // "unknown"' "$manifest_file" 2>/dev/null)"
  [[ -n "$on_disk_schema" ]] || on_disk_schema="unknown"

  local target_manifest_src
  target_manifest_src="$(git -C "$KERNEL_ROOT" show "${target_tag}:${MANIFEST_SH_RELPATH}" 2>/dev/null || true)"
  if [[ -z "$target_manifest_src" ]]; then
    echo "update: could not read ${MANIFEST_SH_RELPATH} at ${target_tag} — skipping the schema-compatibility check (proceeding)" >&2
    return 0
  fi

  local readable
  readable="$(grep -m1 '^MANIFEST_READABLE_SCHEMA_VERSIONS=' <<<"$target_manifest_src" | sed -E 's/^MANIFEST_READABLE_SCHEMA_VERSIONS="?//; s/"$//')"
  if [[ -z "$readable" ]]; then
    echo "update: could not parse MANIFEST_READABLE_SCHEMA_VERSIONS out of ${target_tag}'s manifest.sh — skipping the schema-compatibility check (proceeding)" >&2
    return 0
  fi

  case " $readable " in
    *" $on_disk_schema "*)
      return 0
      ;;
    *)
      echo "" >&2
      echo "update: REFUSED — install-manifest schema mismatch, halting BEFORE moving HEAD." >&2
      echo "  On-disk install manifest (${manifest_file}) has schema_version=${on_disk_schema}." >&2
      echo "  ${target_tag}'s manifest.sh only knows how to read: ${readable}." >&2
      echo "  No automatic migration exists yet (beta) — pick one:" >&2
      echo "    - back up and remove ${manifest_file}, then re-run 'temperloop update' (loses uninstall history)" >&2
      echo "    - wait for a temperloop release that ships a migration for this schema" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# confirm_gate <do_yes>
#
# --yes pre-confirms. Otherwise: an interactive TTY gets a y/N prompt; a
# non-interactive stdin refuses outright — no timeout-as-consent. Interactive
# detection is forceable via UPDATE_ASSUME_TTY (test seam, mirrors
# scripts/update-kernel.sh's own KERNEL_UPDATE_ASSUME_TTY convention:
# auto|1|0).
# ---------------------------------------------------------------------------
confirm_gate() {
  local do_yes="$1"

  if [[ "$do_yes" -eq 1 ]]; then
    echo "update: yes (--yes)"
    return 0
  fi

  local interactive=0
  case "${UPDATE_ASSUME_TTY:-auto}" in
    1) interactive=1 ;;
    0) interactive=0 ;;
    *) [[ -t 0 ]] && interactive=1 ;;
  esac

  if [[ "$interactive" -eq 1 ]]; then
    printf 'Proceed with this update? [y/N] ' >&2
    local reply=""
    read -r reply || reply=""
    case "$reply" in
      y|Y|yes|YES)
        echo "update: yes (operator confirmed)"
        return 0
        ;;
      *)
        echo "update: no (operator declined)"
        return 1
        ;;
    esac
  fi

  echo "update: REFUSED — non-interactive with no --yes (no timeout-as-consent). Re-run with --yes, or interactively, to confirm." >&2
  return 1
}

# ---------------------------------------------------------------------------
# run_post_checkout <target_tag> — phase 2, run ONLY after the re-exec in
# step 8 of the header's FLOW. Re-runs install.sh (the same consent already
# covers this) and doctor.sh from the NOW-CURRENT (just-checked-out) tag's
# own copies.
# ---------------------------------------------------------------------------
run_post_checkout() {
  local target_tag="$1"

  echo "-- Re-running install (temperloop install --yes) at ${target_tag} --"
  if [[ ! -f "$INSTALL_SH" ]]; then
    echo "update: ${INSTALL_SH} not found after checkout — broken tag?" >&2
    return 1
  fi
  if ! bash "$INSTALL_SH" --yes; then
    echo "update: install.sh failed after moving to ${target_tag} — the managed clone's HEAD IS now at ${target_tag}, but the machine surface may be inconsistent; re-run 'temperloop install' by hand, or 'temperloop update' again" >&2
    return 1
  fi
  echo

  echo "-- Doctor --"
  if [[ ! -f "$DOCTOR_SH" ]]; then
    echo "update: ${DOCTOR_SH} not found after checkout — broken tag?" >&2
    return 1
  fi
  if ! bash "$DOCTOR_SH" "$KERNEL_ROOT"; then
    echo "update: doctor reported drift after updating to ${target_tag} — see above" >&2
    return 1
  fi
  echo

  echo "temperloop update: done — now at ${target_tag}"
  return 0
}

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
do_yes=0
to_tag=""
post_checkout_tag=""

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) do_yes=1; shift ;;
    --to)
      [ $# -ge 2 ] || { echo "update.sh: --to requires a tag argument" >&2; exit 2; }
      to_tag="$2"; shift 2
      ;;
    --post-checkout)
      # Internal — never documented as public usage. Set only by this
      # script's own re-exec in step 8 (see header FLOW); a caller passing
      # this by hand is asserting "HEAD is already at this tag", which is
      # exactly what the re-exec's own invocation guarantees.
      [ $# -ge 2 ] || { echo "update.sh: --post-checkout requires a tag argument" >&2; exit 2; }
      post_checkout_tag="$2"; shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "update.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Post-checkout phase (step 9) — dispatch immediately, before any of the
# pre-checkout machinery below runs.
# ---------------------------------------------------------------------------
if [[ -n "$post_checkout_tag" ]]; then
  run_post_checkout "$post_checkout_tag"
  exit $?
fi

# ---------------------------------------------------------------------------
# Pre-checkout phase (steps 1-8).
# ---------------------------------------------------------------------------
echo "== temperloop update =="
echo

if ! git -C "$KERNEL_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "update: ${KERNEL_ROOT} is not a git checkout — not a managed clone; nothing to update" >&2
  exit 1
fi

if [[ ! -f "$CHANGELOG_LIB" ]]; then
  echo "update: ${CHANGELOG_LIB} not found (broken kernel checkout)" >&2
  exit 1
fi
# shellcheck source=../../workflows/scripts/lib/changelog.sh
source "$CHANGELOG_LIB"

# --- Step 2: unshallow + fetch tags -----------------------------------------
if [[ "$(git -C "$KERNEL_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
  echo "-- Converting shallow clone to full history (git fetch --unshallow) --"
  if ! git -C "$KERNEL_ROOT" fetch --unshallow origin; then
    echo "update: 'git fetch --unshallow' failed — check your network/remote and re-run" >&2
    exit 1
  fi
  echo
fi

echo "-- Fetching tags --"
if ! git -C "$KERNEL_ROOT" fetch --tags origin; then
  echo "update: 'git fetch --tags' failed — check your network/remote and re-run" >&2
  exit 1
fi
echo

# --- Step 3: resolve cur/target tags ----------------------------------------
cur_tag="$(git -C "$KERNEL_ROOT" describe --tags --exact-match HEAD 2>/dev/null || true)"

if [[ -n "$to_tag" ]]; then
  target_tag="$to_tag"
  if ! git -C "$KERNEL_ROOT" rev-parse -q --verify "refs/tags/${target_tag}" >/dev/null; then
    echo "update: tag '${target_tag}' (--to) not found after fetching — check the name and re-run" >&2
    exit 1
  fi
else
  target_tag="$(git -C "$KERNEL_ROOT" tag -l 'v*' --sort=-v:refname | head -n1)"
  if [[ -z "$target_tag" ]]; then
    echo "update: no release tags (v*) found on origin — nothing to update to" >&2
    exit 1
  fi
fi

echo "Current: ${cur_tag:-<none — not on a release tag>}"
echo "Target:  ${target_tag}"
echo

if [[ -n "$cur_tag" && "$cur_tag" == "$target_tag" ]]; then
  echo "temperloop update: already at ${target_tag} — nothing to do"
  exit 0
fi

# --- Step 4: surface the delta (BEFORE any consent gate) -------------------
echo "-- CHANGELOG delta (${cur_tag:-<start>} -> ${target_tag}] --"
changelog_tmp="$(mktemp "${TMPDIR:-/tmp}/temperloop-update-changelog.XXXXXX")"
breaking=""
if git -C "$KERNEL_ROOT" show "${target_tag}:CHANGELOG.md" >"$changelog_tmp" 2>/dev/null; then
  sections="$(changelog_sections_in_range "$cur_tag" "$target_tag" "$changelog_tmp")"
  if [[ -n "$sections" ]]; then
    printf '%s\n' "$sections"
  else
    echo "(no CHANGELOG section found in range — nothing to show)"
  fi
  breaking="$(changelog_breaking_sections "$cur_tag" "$target_tag" "$changelog_tmp")"
else
  echo "(could not read CHANGELOG.md at ${target_tag} — proceeding without a delta preview)"
fi
rm -f "$changelog_tmp"
echo

if [[ -n "$breaking" ]]; then
  echo "-- WARNING: BREAKING section(s) detected in this range --" >&2
  echo "  A change in this range requires you to adapt before/after pulling — read the" >&2
  echo "  section(s) marked BREAKING above before confirming." >&2
  echo >&2
fi

# --- Step 5: schema gate (BEFORE moving HEAD) -------------------------------
if ! schema_gate "$target_tag"; then
  exit 1
fi

# --- Step 6: consent gate ---------------------------------------------------
if ! confirm_gate "$do_yes"; then
  echo "temperloop update: aborted — HEAD not moved, nothing written"
  exit 0
fi
echo

# --- Step 7: checkout --------------------------------------------------------
echo "-- Checking out ${target_tag} --"
if ! git -C "$KERNEL_ROOT" checkout --detach "$target_tag"; then
  echo "update: checkout of ${target_tag} failed — HEAD left at ${cur_tag:-its prior position}" >&2
  exit 1
fi
echo

# --- Step 8: re-exec into the freshly-checked-out copy for phase 2 ---------
exec bash "$SUBCOMMAND_DIR/update.sh" --post-checkout "$target_tag"
