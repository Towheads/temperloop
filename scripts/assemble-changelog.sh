#!/usr/bin/env bash
#
# assemble-changelog.sh — fold `changelog.d/` fragments into CHANGELOG.md's
# `## [Unreleased]` section at release-cut time (temperloop#1321, epic #1299).
#
# WHY FRAGMENTS EXIST. `VERSIONING.md` mandates a `## [Unreleased]` entry for
# every contract-surface change and `workflows/scripts/check-changelog-entry.sh`
# enforces it, so 25 of the last 25 commits touched CHANGELOG.md and any two
# concurrent PRs collided on one file. Under fragments each PR writes its own
# new file under `changelog.d/`, two concurrent PRs share no line, and the
# collision becomes structurally impossible rather than merely unlikely. This
# script is the other half: the release cut assembles those disjoint files back
# into the single Unreleased section every downstream reader still expects.
# Direction ratified by the keystone spike (temperloop#1311); see
# `Decisions/temperloop - changelog fragment direction (keystone spike verdict)`.
#
# WHY IT LIVES IN scripts/. ADR-0002's layering rule (stated in
# `workflows/scripts/lib/changelog.sh`'s own header): `bin/` is the
# pre-checkout CLI surface, `scripts/` is an in-checkout dev tool, and neither
# is the other's library. A release cut runs inside an established checkout by
# a maintainer, so per ADR-0023 it is not `bin/temperloop` surface; it is
# mechanical rather than judgment-bearing, so it is not a slash command
# either. That lands it here, beside `update-kernel.sh`, sourcing the shared
# lib in the sanctioned scripts/ -> workflows/scripts/lib/ direction.
#
# ADDITIVE, NEVER REPLACING. The assembled body MERGES into whatever
# `## [Unreleased]` already holds — existing sub-sections keep their order and
# their content, fragments append to the end of their category's section, and
# a category with no section yet gets a new one. This is deliberate and
# load-bearing: `main`'s Unreleased section is routinely substantial, and an
# assembler that assumed it was empty would silently drop everything
# accumulated since the last tag. It also makes an in-flight PR written
# against the old flow (a direct Unreleased line, no fragment) harmless
# rather than lost.
#
# SCOPE OF THIS CHANGE (temperloop#1321). Additive and non-breaking on its
# own: nothing yet REQUIRES a fragment. `check-changelog-entry.sh` is
# unchanged and the existing `## [Unreleased]` flow keeps working. The gate
# cutover, the `VERSIONING.md` § Cutting a release rewrite, and the
# legible-degradation arm for a `changelog.d/`-less consumer tree are
# temperloop#1322.
#
# Usage:
#   scripts/assemble-changelog.sh                 assemble in place, then
#                                                 delete the consumed fragments
#   scripts/assemble-changelog.sh --dry-run       print the assembled
#                                                 CHANGELOG.md to stdout;
#                                                 write nothing, delete nothing
#   scripts/assemble-changelog.sh --check         validate fragments only;
#                                                 exit 1 on any problem
#   scripts/assemble-changelog.sh --keep-fragments
#                                                 assemble in place but leave
#                                                 the fragment files on disk
#   scripts/assemble-changelog.sh --list          print fragments in assembly
#                                                 order and exit
#
#   --changelog <path>      changelog to rewrite   (default: <repo>/CHANGELOG.md)
#   --fragment-dir <path>   fragment directory     (default: <repo>/changelog.d)
#   -h | --help             this header's usage block
#
# Deliberately NO environment seams: every tunable is a flag, so this script
# adds no row to `workflows/scripts/config/setting-registry.tsv`. The test
# suite points it at a synthetic tree with --changelog/--fragment-dir rather
# than by exporting anything.
#
# Exit codes: 0 success (including "nothing to assemble"), 1 a fragment or
# changelog problem the operator must fix, 2 a usage error.
#
# Portable shell only — bash 3.2 + POSIX awk, identical on macOS and Linux CI
# (AGENTS.md § Safety rails).

# `-e` IS LOAD-BEARING, not boilerplate. This script REWRITES CHANGELOG.md and
# then DELETES the fragments — the only other copy of those entries — so an
# unchecked failure mid-run destroys data. Without `-e`, a failing
# `changelog_assemble_unreleased_body` left an empty body file, the rewrite
# swallowed the whole pre-existing `## [Unreleased]` section, and the script
# still exited 0 announcing success. It matches the sibling MUTATING scripts
# beside it (`update-kernel.sh`, `prune-merged-branches.sh`); the `set -uo`
# form used by `scripts/lint-*.sh` is for violation COUNTERS that must survive
# a failing check, which this is not.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../workflows/scripts/lib/changelog.sh
source "$REPO_ROOT/workflows/scripts/lib/changelog.sh"

CHANGELOG="$REPO_ROOT/CHANGELOG.md"
FRAGMENT_DIR="$REPO_ROOT/changelog.d"
MODE="apply"
KEEP_FRAGMENTS=0

usage() {
  sed -n '2,/^# Portable shell only/p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//'
}

die() {
  printf 'assemble-changelog: %s\n' "$1" >&2
  exit "${2:-1}"
}

say() { printf 'assemble-changelog: %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        MODE="dry-run" ;;
    --check)          MODE="check" ;;
    --list)           MODE="list" ;;
    --keep-fragments) KEEP_FRAGMENTS=1 ;;
    --changelog)      shift; [[ $# -gt 0 ]] || die "--changelog needs a path" 2; CHANGELOG="$1" ;;
    --fragment-dir)   shift; [[ $# -gt 0 ]] || die "--fragment-dir needs a path" 2; FRAGMENT_DIR="$1" ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown argument: $1 (try --help)" 2 ;;
  esac
  shift
done

# --- fragment validation ----------------------------------------------------
# Fail loudly on anything that would otherwise SILENTLY drop somebody's entry:
# a filename the format doesn't recognise, an empty fragment, or a body that
# smuggles in its own h1/h2/h3 heading (the assembler owns the `### <Category>`
# heading, and a body heading carrying `BREAKING` could forge the very signal
# `changelog_breaking_sections()` reads). Kernel principle 5 — counter AI
# failure modes structurally; a typo'd category must not vanish quietly.
problems=0

invalid="$(changelog_fragment_invalid "$FRAGMENT_DIR")"
if [[ -n "$invalid" ]]; then
  printf 'assemble-changelog: UNRECOGNISED or unreadable entr(ies) in %s:\n' "$FRAGMENT_DIR" >&2
  printf '%s\n' "$invalid" | sed 's/^/  - /' >&2
  printf '  expected <slug>.<category>[.breaking].md with category in: %s\n' \
    "$(changelog_fragment_category_order | tr '\n' ' ')" >&2
  printf '  a subdirectory or dangling symlink is never assembled — flatten or remove it\n' >&2
  problems=1
fi

empty="$(changelog_fragment_empty "$FRAGMENT_DIR")"
if [[ -n "$empty" ]]; then
  printf 'assemble-changelog: EMPTY fragment(s) — an empty fragment is a lost entry:\n' >&2
  printf '%s\n' "$empty" | sed 's/^/  - /' >&2
  problems=1
fi

offenders="$(changelog_fragment_body_offenders "$FRAGMENT_DIR")"
if [[ -n "$offenders" ]]; then
  printf 'assemble-changelog: fragment body carries its own h1/h2/h3 heading or an assembler control token (the assembler owns the category sub-heading):\n' >&2
  printf '%s\n' "$offenders" | sed 's/^/  - /' >&2
  problems=1
fi

names="$(changelog_fragment_names "$FRAGMENT_DIR")"
count=0
if [[ -n "$names" ]]; then
  count="$(printf '%s\n' "$names" | wc -l | tr -d ' ')"
fi

if [[ "$MODE" == "list" ]]; then
  if [[ -n "$names" ]]; then
    printf '%s\n' "$names"
  fi
  exit 0
fi

if [[ "$MODE" == "check" ]]; then
  if [[ "$problems" -ne 0 ]]; then
    die "fragment validation FAILED — fix the entries above before cutting"
  fi
  say "ok — $count fragment(s) in $FRAGMENT_DIR, all well-formed"
  exit 0
fi

if [[ "$problems" -ne 0 ]]; then
  die "fragment validation FAILED — refusing to assemble (nothing was written)"
fi

if [[ ! -f "$CHANGELOG" ]]; then
  die "no changelog at $CHANGELOG"
fi

# `grep -q` over a fixed anchor; a changelog with no Unreleased section is an
# operator error, not something to paper over by inventing one.
if ! grep -q '^## \[Unreleased\]' "$CHANGELOG"; then
  die "no '## [Unreleased]' heading in $CHANGELOG — add one before assembling"
fi

# --- nothing to do ----------------------------------------------------------
# The no-fragment case short-circuits BEFORE any rewrite, so a cut with an
# empty changelog.d/ leaves CHANGELOG.md byte-identical rather than passing it
# through the (structurally faithful, but not byte-guaranteed) reassembly.
if [[ "$count" -eq 0 ]]; then
  say "no fragments in $FRAGMENT_DIR — $CHANGELOG left untouched"
  exit 0
fi

mark_breaking=0
if changelog_fragment_has_breaking "$FRAGMENT_DIR"; then
  mark_breaking=1
fi

# TRAP FIRST, mktemp second. Installed after the temps were made, a failure of
# the SECOND mktemp leaks the first. The cleanup reads its targets at trap
# time, so an unset-or-empty variable is simply skipped, and it always returns
# 0 so it can never itself trip `set -e` on the way out.
work_dir=""
body_tmp=""
out_tmp=""
new_tmp=""
# shellcheck disable=SC2329  # invoked indirectly by the EXIT trap below
cleanup() {
  # `if` rather than `[[ ]] && rm`: under `set -e` an AND-list whose left side
  # is false fails as a whole, which would abort the trap part-way and skip
  # the remaining removals.
  if [[ -n "$body_tmp" ]]; then rm -f "$body_tmp"; fi
  if [[ -n "$out_tmp" ]]; then rm -f "$out_tmp"; fi
  if [[ -n "$new_tmp" ]]; then rm -f "$new_tmp"; fi
  if [[ -n "$work_dir" ]]; then rm -rf "$work_dir"; fi
  return 0
}
trap cleanup EXIT

work_dir="$(mktemp -d)" || die "mktemp -d failed"
body_tmp="$(mktemp)" || die "mktemp failed"
out_tmp="$(mktemp)" || die "mktemp failed"

# HOW MUCH BODY EXISTED BEFORE we touch anything. This is the reference for
# the additive-over-non-empty guarantee: every non-blank line of the current
# Unreleased body is re-emitted by the assembly (headings are rewritten in
# place, never dropped; unrecognised sub-sections are kept), and each fragment
# adds at least one more. So the assembled body can never hold FEWER non-blank
# lines than the body it merged into — and if it does, something failed and we
# must not write.
prior_nonblank="$(changelog_unreleased_body "$CHANGELOG" | awk 'NF { c++ } END { print c + 0 }')"

# The `|| die` is the first of two guards, and the one that catches a hard
# failure (`mktemp` failure inside the lib, a crashed awk). `set -e` does NOT
# cover this on its own: the exit status of a command whose stdout is
# redirected is still checked, but the previous shape discarded it entirely.
changelog_assemble_unreleased_body "$FRAGMENT_DIR" "$CHANGELOG" "$work_dir" >"$body_tmp" \
  || die "assembly failed — nothing written to $CHANGELOG, fragments kept"

# The second guard catches a SILENT failure — an assembly that exits 0 but
# returns an empty (or shrunken) body. Checking the rewritten changelog
# instead, as this once did, cannot see it: the rest of the file is still
# there, so the output is non-empty and the guard passes while the entire
# `## [Unreleased]` section has just been swallowed.
assembled_nonblank="$(awk 'NF { c++ } END { print c + 0 }' "$body_tmp")"
if [[ "$assembled_nonblank" -eq 0 || "$assembled_nonblank" -lt "$prior_nonblank" ]]; then
  die "assembly returned $assembled_nonblank non-blank line(s) where [Unreleased] already had $prior_nonblank — refusing to write (nothing changed, fragments kept)"
fi

# Replace ONLY the first `## [Unreleased]` section's body. The `done` flag
# matters: `## [Unreleased] — BREAKING` also occurs inside historical release
# prose further down the file (VERSIONING.md § Cutting a release warns about
# exactly this), and rewriting one of those would corrupt shipped history.
awk -v bodyfile="$body_tmp" -v mark_breaking="$mark_breaking" '
  BEGIN { SUFFIX = " \342\200\224 BREAKING" }
  !done && /^## \[Unreleased\]/ {
    h = $0
    if (mark_breaking == "1" && h !~ /BREAKING/) h = h SUFFIX
    print h
    while ((getline line < bodyfile) > 0) print line
    close(bodyfile)
    done = 1
    inbody = 1
    next
  }
  inbody && /^## \[/ { inbody = 0 }
  inbody { next }
  { print }
' "$CHANGELOG" >"$out_tmp"

if [[ ! -s "$out_tmp" ]]; then
  die "assembly produced an empty changelog — refusing to write"
fi

if [[ "$MODE" == "dry-run" ]]; then
  cat "$out_tmp"
  exit 0
fi

# ATOMIC REPLACE, then delete. `cat "$out_tmp" >"$CHANGELOG"` truncated the
# real file in place and left its status unchecked, so a write that failed
# part-way (ENOSPC, a read-only mount, an interrupt) corrupted CHANGELOG.md
# AND the deletion loop below then removed the fragments — the only other copy
# of those entries. Staging beside the target and renaming means the file is
# either wholly old or wholly new, and the fragments are only ever deleted
# after a replace that actually succeeded.
#
# The temp is created in the SAME DIRECTORY as the changelog on purpose:
# `mv` is only atomic within one filesystem, and $TMPDIR is routinely a
# different one. `cp -p` first so the rename preserves the changelog's
# existing mode rather than stamping mktemp's 0600 onto it.
changelog_dir="$(dirname "$CHANGELOG")"
new_tmp="$(mktemp "$changelog_dir/.assemble-changelog.XXXXXX")" \
  || die "cannot stage a replacement in $changelog_dir — $CHANGELOG untouched, fragments kept"
cp -p "$CHANGELOG" "$new_tmp" \
  || die "cannot copy $CHANGELOG's mode onto the staged replacement — $CHANGELOG untouched, fragments kept"
cat "$out_tmp" >"$new_tmp" \
  || die "write to the staged replacement failed — $CHANGELOG untouched, fragments kept"
mv -f "$new_tmp" "$CHANGELOG" \
  || die "atomic replace of $CHANGELOG failed — fragments kept"
new_tmp=""   # ownership handed to $CHANGELOG; the trap must not remove it

say "assembled $count fragment(s) into $CHANGELOG"
if [[ "$mark_breaking" -eq 1 ]]; then
  say "at least one fragment is BREAKING — the Unreleased heading and its sub-heading(s) carry the marker"
fi

if [[ "$KEEP_FRAGMENTS" -eq 1 ]]; then
  say "--keep-fragments — $FRAGMENT_DIR left as-is"
  exit 0
fi

# Reached ONLY after the atomic replace above succeeded — every `die` on that
# path leaves the fragments on disk, so the entries always survive somewhere.
printf '%s\n' "$names" | while IFS= read -r name; do
  if [[ -n "$name" ]]; then
    rm -f "$FRAGMENT_DIR/$name"
  fi
done
say "removed $count consumed fragment(s) from $FRAGMENT_DIR"
exit 0
