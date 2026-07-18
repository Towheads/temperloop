#!/usr/bin/env bash
# update-kernel.sh — pull the vendored kernel subtree (kernel/) forward to a
# named kernel release tag and record the new identity in .kernel-pin,
# atomically (tmp + mv). The ONLY sanctioned way to change kernel/ content in
# an adopter repo — hand edits inside kernel/ are forbidden (they are
# overwritten by the next subtree pull and violate the split's one-owner
# principle; see the F#804 cutover design). This tool ships FROM the kernel so
# the versioning policy (VERSIONING.md) and the machinery that enforces it live
# together; an adopter vendors it alongside the rest of kernel/.
#
# BREAKING-DELTA GATE (temperloop#89, follow-up to the versioning spike #79 /
# PR #88): BEFORE the subtree pull, this scans the version/CHANGELOG delta
# between the current .kernel-pin tag and the target KERNEL_TAG and treats it
# as an ACTIONABLE signal, per VERSIONING.md § "Signal to the machinery":
#   * pre-1.0  — a CHANGELOG section in the range (current, target] whose
#                heading is tagged `BREAKING`;
#   * post-1.0 — a major-version increment (target major > current major).
# On a breaking delta it REFUSES the unattended path and requires an explicit
# acknowledgment — `KERNEL_ALLOW_BREAKING=1` or an interactive `y` confirm —
# printing the migration notes from the marked CHANGELOG sections first. An
# additive/patch delta pulls WITHOUT prompting (preserves prior behavior).
# kernel-drift-check.sh is orthogonal (byte-identity, not semver) and untouched.
#
# Usage:
#   make update-kernel KERNEL_TAG=v0.1.2
#   KERNEL_TAG=v0.1.2 scripts/update-kernel.sh
#
# Env:
#   KERNEL_TAG            required — the release tag to pull (deliberate updates
#                         only; no floating default, so an update is always an
#                         explicit, reviewable choice).
#   KERNEL_ALLOW_BREAKING set to 1 to acknowledge a breaking delta and proceed
#                         on the unattended path (the CI/cron acknowledgment).
#   KERNEL_REMOTE         kernel repo URL (default: the canonical GitHub remote).
#
# Test seams (env overrides; see scripts/tests/test_update_kernel.sh — mirrors
# kernel-drift-check.sh's KERNEL_DRIFT_* override style):
#   KERNEL_UPDATE_ROOT       repo root (default: this script's repo)
#   KERNEL_UPDATE_PIN_FILE   pin file path (default: $ROOT/.kernel-pin)
#   KERNEL_UPDATE_CHANGELOG  CHANGELOG path (default: $ROOT/CHANGELOG.md)
#   KERNEL_UPDATE_ASSUME_TTY force interactive (1) / unattended (0) instead of
#                            auto-detecting via `[ -t 0 ]`
#   KERNEL_UPDATE_DRY_RUN    set 1 to run the gate + report the decision but
#                            SKIP the actual subtree pull / pin / commit (the
#                            test seam — the gate is exercised, no network).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${KERNEL_UPDATE_ROOT:=$REPO_ROOT}"
: "${KERNEL_UPDATE_PIN_FILE:=$KERNEL_UPDATE_ROOT/.kernel-pin}"
: "${KERNEL_UPDATE_CHANGELOG:=$KERNEL_UPDATE_ROOT/CHANGELOG.md}"
KERNEL_REMOTE="${KERNEL_REMOTE:-https://github.com/Towheads/temperloop}"  # denylist:allow — the kernel repo's own clone URL is this tool's load-bearing default (override via KERNEL_REMOTE); the repo's identity, not a personal-token leak
KERNEL_TAG="${KERNEL_TAG:?set KERNEL_TAG=vX.Y.Z (make update-kernel KERNEL_TAG=...)}"

cd "$KERNEL_UPDATE_ROOT"

# ---------------------------------------------------------------------------
# Helpers — semver_major()/breaking_sections() lifted into the shared lib
# workflows/scripts/lib/changelog.sh (temperloop#429, ADR 0002 follow-on) so
# bin/subcommands/update.sh (the managed-clone updater) can reuse the exact
# same CHANGELOG-range parsing without back-channeling into scripts/. Sourced
# SCRIPT-RELATIVE (never repo-root- or cwd-relative, and independent of
# KERNEL_UPDATE_ROOT below, which may point at a wholly different repo under
# test) so this keeps resolving correctly no matter where this script's
# caller cd'd from. changelog_semver_major()/changelog_breaking_sections()
# are the renamed (changelog_-prefixed) equivalents of this script's former
# private semver_major()/breaking_sections() — same behavior, same argument
# order, name only.
# ---------------------------------------------------------------------------
# shellcheck source=../workflows/scripts/lib/changelog.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../workflows/scripts/lib/changelog.sh"

# ---------------------------------------------------------------------------
# 1. Resolve the current pin tag (the "before" surface). A first-time vendor
#    with no pin has no prior contract surface to break, so the gate is a no-op
#    there — proceed with a note.
# ---------------------------------------------------------------------------
cur_tag=""
if [[ -f "$KERNEL_UPDATE_PIN_FILE" ]]; then
  cur_tag="$(awk '/^tag /{print $2; exit}' "$KERNEL_UPDATE_PIN_FILE" 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# 2. Classify the delta: breaking iff a major-version increment (post-1.0) OR a
#    BREAKING-marked CHANGELOG section in range (pre-1.0). Both rules apply;
#    their union is the breaking signal VERSIONING.md promises.
# ---------------------------------------------------------------------------
is_breaking=0
migration=""

if [[ -n "$cur_tag" ]]; then
  cur_major="$(changelog_semver_major "$cur_tag")"
  tgt_major="$(changelog_semver_major "$KERNEL_TAG")"
  if (( tgt_major > cur_major )); then
    is_breaking=1
  fi
  migration="$(changelog_breaking_sections "$cur_tag" "$KERNEL_TAG" "$KERNEL_UPDATE_CHANGELOG")"
  if [[ -n "$migration" ]]; then
    is_breaking=1
  fi
else
  echo "update-kernel: no current pin tag in $KERNEL_UPDATE_PIN_FILE — treating as a first-time vendor (no prior surface to break); proceeding without the breaking gate."
fi

# ---------------------------------------------------------------------------
# 3. The gate. On a breaking delta: print migration notes, then require an
#    acknowledgment — KERNEL_ALLOW_BREAKING=1 (the unattended ack) or an
#    interactive `y`. Refuse the unattended path outright.
# ---------------------------------------------------------------------------
if (( is_breaking )); then
  echo "update-kernel: BREAKING delta detected pulling ${cur_tag:-<none>} -> $KERNEL_TAG." >&2
  echo "  VERSIONING.md § 'Signal to the machinery': an overlay/config must adapt before this pull." >&2
  if [[ -n "$migration" ]]; then
    echo "" >&2
    echo "  --- migration notes (from the BREAKING-marked CHANGELOG section(s)) ---" >&2
    while IFS= read -r line; do echo "  $line" >&2; done <<<"$migration"
    echo "  --- end migration notes ---" >&2
    echo "" >&2
  else
    echo "  (post-1.0 major-version increment; see CHANGELOG for the migration.)" >&2
  fi

  if [[ "${KERNEL_ALLOW_BREAKING:-0}" == "1" ]]; then
    echo "update-kernel: KERNEL_ALLOW_BREAKING=1 — breaking delta acknowledged, proceeding."
  else
    # Interactive iff a real TTY (or forced via the test seam).
    interactive=0
    case "${KERNEL_UPDATE_ASSUME_TTY:-auto}" in
      1) interactive=1 ;;
      0) interactive=0 ;;
      *) [[ -t 0 ]] && interactive=1 ;;
    esac
    if (( interactive )); then
      printf 'Proceed with this BREAKING kernel update? [y/N] ' >&2
      read -r reply
      if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "update-kernel: REFUSED — breaking delta not confirmed. Aborting." >&2
        exit 1
      fi
      echo "update-kernel: breaking delta confirmed interactively, proceeding."
    else
      echo "update-kernel: REFUSED — breaking delta on the unattended path without acknowledgment." >&2
      echo "  Re-run with KERNEL_ALLOW_BREAKING=1 (after adapting your overlay/config per the migration notes above)," >&2
      echo "  or run interactively to confirm. Aborting." >&2
      exit 1
    fi
  fi
else
  echo "update-kernel: additive/patch delta ${cur_tag:-<none>} -> $KERNEL_TAG — pulling without prompting."
fi

# ---------------------------------------------------------------------------
# 4. Perform the pull (unless dry-run). Everything below is all-or-nothing from
#    the caller's view — see the header. Guarded by the dry-run seam so the test
#    exercises the gate without a real subtree/network operation.
# ---------------------------------------------------------------------------
if [[ "${KERNEL_UPDATE_DRY_RUN:-0}" == "1" ]]; then
  echo "update-kernel: DRY-RUN — gate passed; would pull kernel/ to $KERNEL_TAG (subtree pull skipped)."
  exit 0
fi

git subtree pull --prefix=kernel "$KERNEL_REMOTE" "$KERNEL_TAG" --squash \
  -m "chore(kernel): subtree pull $KERNEL_TAG"

# FETCH_HEAD was set by the subtree pull's fetch of the tag; peel to the
# commit (annotated tags resolve through ^{commit}).
sha="$(git rev-parse 'FETCH_HEAD^{commit}')"

tmp="$(mktemp "$KERNEL_UPDATE_ROOT/.kernel-pin.XXXXXX")"
{
  printf '# .kernel-pin — identity carrier for the vendored kernel subtree (kernel/).\n'
  printf '# Written atomically (tmp + mv) by scripts/update-kernel.sh (make update-kernel).\n'
  printf '# One file, tag + resolved commit sha, so a drift check needs one comparison.\n'
  printf '#\n'
  printf '# tag — the kernel release tag the subtree was last pulled at.\n'
  printf '# sha — the kernel-repo commit that tag resolved to at pull time.\n'
  printf 'tag %s\n' "$KERNEL_TAG"
  printf 'sha %s\n' "$sha"
} > "$tmp"
mv "$tmp" "$KERNEL_UPDATE_PIN_FILE"

git add "$KERNEL_UPDATE_PIN_FILE"
if git diff --cached --quiet -- "$KERNEL_UPDATE_PIN_FILE"; then
  # Idempotent re-run at the current tag: subtree already at this content and
  # the pin already records it — nothing to commit.
  echo "update-kernel: kernel/ already at $KERNEL_TAG ($sha); .kernel-pin unchanged."
else
  git commit -m "chore(kernel): pin $KERNEL_TAG ($sha)"
  echo "update-kernel: kernel/ at $KERNEL_TAG ($sha); .kernel-pin updated + committed."
fi
