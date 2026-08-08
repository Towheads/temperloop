#!/usr/bin/env bash
# changelog.sh — shared CHANGELOG.md parsing helpers: semver comparison and
# BREAKING-section extraction (temperloop#429, ADR 0002 follow-on "lift
# breaking_sections() out of scripts/update-kernel.sh into a shared lib").
#
# LIFTED VERBATIM from scripts/update-kernel.sh's own breaking-delta gate
# (temperloop#89), which defined `semver_major()` / `breaking_sections()` as
# private functions of that one script. Both `scripts/update-kernel.sh` (the
# adopter-repo kernel-subtree updater) and `bin/subcommands/update.sh` (the
# managed-clone updater, ADR 0002) need the exact same CHANGELOG-range
# parsing — sourcing this file from BOTH is the alternative to bin/
# back-channeling into scripts/ (or vice versa), which this repo's own
# working-tree/layer conventions forbid (bin/ is the pre-checkout CLI
# surface; scripts/ is an in-checkout dev tool; neither is the other's
# library). Function names are prefixed `changelog_` (this repo's sourced-
# library convention — see workflows/scripts/install/manifest.sh's
# `manifest_` prefix, workflows/scripts/board/lib/board.sh's `board_`
# prefix) since update-kernel.sh's own prior names (`semver_major`,
# `breaking_sections`) were unprefixed private functions, not a documented
# external contract this file needs to preserve byte-for-byte.
#
# Usage (sourced, not executed):
#
#   source "$(dirname "$0")/../workflows/scripts/lib/changelog.sh"   # or
#   source "$SCRIPT_DIR/../workflows/scripts/lib/changelog.sh"       # script-relative
#   changelog_breaking_sections v0.1.0 v0.3.0 CHANGELOG.md
#
# Public functions:
#   changelog_semver_major <vX.Y.Z>
#     Echoes the numeric major field (leading v stripped), 0 when
#     absent/non-numeric so a malformed tag never trips arithmetic.
#
#   changelog_sections_in_range <cur-tag> <target-tag> <changelog-file>
#     Prints the FULL text (heading + body) of every CHANGELOG section whose
#     version is in the range (cur, target] — the whole delta, breaking or
#     not. <cur-tag> may be the empty string ("" — no prior tag / not yet on
#     a release), in which case every section up to and including <target-
#     tag> is printed (semver_num("") == 0, so the whole history qualifies).
#     Empty output means no section in range (e.g. cur == target).
#
#   changelog_breaking_sections <cur-tag> <target-tag> <changelog-file>
#     Same range as changelog_sections_in_range, but prints ONLY the
#     sections whose heading (or body) carries a `BREAKING` marker — the
#     pre-1.0 migration-note subset (VERSIONING.md's bump-rules table).
#     Empty output means no BREAKING-marked section in range.
#
#   changelog_unreleased_body <changelog-file>
#     Prints the BODY of the `## [Unreleased]` section — every line AFTER the
#     heading, up to (not including) the next `## [` heading. The heading line
#     itself is never printed, so a heading suffix (`## [Unreleased] —
#     BREAKING`) can't register as body content. Empty output means the
#     section is absent or carries nothing.
#
#   changelog_version_headings <changelog-file>
#     Prints one bare version token per line for every version-shaped
#     `## [x.y.z]` heading, in file order. `[Unreleased]` is not version-
#     shaped, so it is never printed.
#
# The last two were added for the CHANGELOG-entry merge gate
# (workflows/scripts/check-changelog-entry.sh, temperloop#960). That gate asks
# the COMPLETENESS question about the same file the range helpers above read
# for the BREAKING acknowledgment question: it diffs the Unreleased body
# across a PR's merge-base and head to answer "did this PR add an entry?",
# and compares the version-heading sets to recognize a RELEASE CUT (a PR that
# moves the Unreleased body down into a brand-new version section, leaving
# Unreleased legitimately empty) rather than mistake it for an omission.
#
# Dependencies: bash (3.2+), awk, POSIX-portable (no GNU-only awk/sed
# extensions — runs identically on macOS/BSD and Linux CI, per AGENTS.md §
# Safety rails "Portable shell only").
#
# shellcheck shell=bash

# Guard against double-sourcing (same idiom as manifest.sh / links.sh).
if [[ "${_TEMPERLOOP_CHANGELOG_SH_LOADED:-}" == "1" ]]; then
  return 0
fi
_TEMPERLOOP_CHANGELOG_SH_LOADED=1

# ---------------------------------------------------------------------------
# changelog_semver_major <vX.Y.Z> — echo the numeric major field (leading v
# stripped), 0 when absent/non-numeric so a malformed tag never trips the
# arithmetic.
# ---------------------------------------------------------------------------
changelog_semver_major() {
  local v="${1#v}"
  v="${v%%.*}"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s\n' "$v" || printf '0\n'
}

# ---------------------------------------------------------------------------
# changelog_sections_in_range <cur> <tgt> <changelog>
#
# Prints the full text of every CHANGELOG section whose version is in the
# range (cur, tgt] — the whole delta, unconditional on any BREAKING marker.
# ---------------------------------------------------------------------------
changelog_sections_in_range() {
  local cur="$1" tgt="$2" changelog="$3"
  [[ -f "$changelog" ]] || return 0
  awk -v cur="$cur" -v tgt="$tgt" '
    function semver_num(v,   a, n) {
      sub(/^v/, "", v)
      n = split(v, a, ".")
      return (a[1] + 0) * 1000000 + (a[2] + 0) * 1000 + (a[3] + 0)
    }
    function flush() {
      if (in_range) printf "%s", buf
      buf = ""; in_range = 0
    }
    BEGIN { cur_n = semver_num(cur); tgt_n = semver_num(tgt) }
    /^## \[/ {
      flush()
      ver = $0; sub(/^## \[/, "", ver); sub(/\].*/, "", ver)
      if (ver ~ /^v?[0-9]/) {
        sn = semver_num(ver)
        if (sn > cur_n && sn <= tgt_n) in_range = 1
      }
      buf = $0 "\n"
      next
    }
    { buf = buf $0 "\n" }
    END { flush() }
  ' "$changelog"
}

# ---------------------------------------------------------------------------
# changelog_breaking_sections <cur> <tgt> <changelog>
#
# Prints the full text of every CHANGELOG section whose version is in the
# range (cur, tgt] AND whose heading (or body) carries a `BREAKING` marker —
# the pre-1.0 migration notes. Empty output ⇒ no breaking-marked section in
# range. (Verbatim behavior of scripts/update-kernel.sh's former private
# breaking_sections() — only the name changed.)
# ---------------------------------------------------------------------------
changelog_breaking_sections() {
  local cur="$1" tgt="$2" changelog="$3"
  [[ -f "$changelog" ]] || return 0
  awk -v cur="$cur" -v tgt="$tgt" '
    function semver_num(v,   a, n) {
      sub(/^v/, "", v)
      n = split(v, a, ".")
      return (a[1] + 0) * 1000000 + (a[2] + 0) * 1000 + (a[3] + 0)
    }
    function flush() {
      if (in_range && brk) printf "%s", buf
      buf = ""; in_range = 0; brk = 0
    }
    BEGIN { cur_n = semver_num(cur); tgt_n = semver_num(tgt) }
    /^## \[/ {
      flush()
      ver = $0; sub(/^## \[/, "", ver); sub(/\].*/, "", ver)
      if (ver ~ /^v?[0-9]/) {
        sn = semver_num(ver)
        if (sn > cur_n && sn <= tgt_n) in_range = 1
      }
      buf = $0 "\n"
      if ($0 ~ /BREAKING/) brk = 1
      next
    }
    { buf = buf $0 "\n" }
    /^#+ .*BREAKING/ { brk = 1 }
    END { flush() }
  ' "$changelog"
}

# ---------------------------------------------------------------------------
# changelog_unreleased_body <changelog>
#
# Prints the body of the `## [Unreleased]` section — every line after the
# heading up to (not including) the next `## [` heading. The heading itself is
# excluded on purpose: a release marks breakingness by SUFFIXING that heading
# (`## [Unreleased] — BREAKING`), and a suffix edit is not an entry.
# ---------------------------------------------------------------------------
changelog_unreleased_body() {
  local changelog="$1"
  [[ -f "$changelog" ]] || return 0
  awk '
    /^## \[/ {
      # Any `## [` heading ends the Unreleased body; the Unreleased heading
      # itself starts it (and is not part of the body).
      in_unrel = ($0 ~ /^## \[Unreleased\]/) ? 1 : 0
      next
    }
    in_unrel { print }
  ' "$changelog"
}

# ---------------------------------------------------------------------------
# changelog_version_headings <changelog>
#
# Prints the bare version token of every version-shaped `## [x.y.z]` heading,
# one per line, in file order. `## [Unreleased]` is not version-shaped and is
# never printed.
# ---------------------------------------------------------------------------
changelog_version_headings() {
  local changelog="$1"
  [[ -f "$changelog" ]] || return 0
  awk '
    /^## \[/ {
      ver = $0; sub(/^## \[/, "", ver); sub(/\].*/, "", ver)
      if (ver ~ /^v?[0-9]/) print ver
    }
  ' "$changelog"
}

# ===========================================================================
# Fragment support (temperloop#1321, epic #1299) — `changelog.d/` per-entry
# fragment files, and the release-time assembly of those fragments into
# `## [Unreleased]`.
#
# WHY THIS LIVES HERE, not in a new lib under scripts/: ADR-0002's layering
# rule, stated in this file's own header above — `bin/` is the pre-checkout
# CLI surface, `scripts/` is an in-checkout dev tool, and neither is the
# other's library. `workflows/scripts/check-changelog-entry.sh` already
# sources THIS file, and it is the gate that must parse fragments once
# temperloop#1322 cuts the gate over. A fragment parser placed in `scripts/`
# and sourced from `workflows/scripts/` is the FORBIDDEN direction; the
# `scripts/` -> `workflows/scripts/lib/` direction (which
# `scripts/assemble-changelog.sh` uses) is the sanctioned one.
#
# THE FORMAT IS INDEX-FREE — deliberately, and this is a ratified constraint
# (`Decisions/temperloop - changelog fragment direction (keystone spike
# verdict)`), not a style call. There is NO ordering file and NO manifest
# inside `changelog.d/`: category, breakingness and sort key all derive from
# a fragment's own FILENAME. Any shared index would recreate, one directory
# over, the exact single-file merge hotspot fragments exist to remove (25 of
# the last 25 commits touched CHANGELOG.md; any two concurrent PRs collided
# structurally).
#
#   changelog.d/<slug>.<category>[.breaking].md
#
#     <slug>      [A-Za-z0-9][A-Za-z0-9_-]*  — no dots (`.` is the field
#                 delimiter). Convention: `<issue#>-<branch-slug>`, e.g.
#                 `1321-changelog-fragment-format`. Uniqueness per PR is what
#                 makes two concurrent PRs write DISJOINT files sharing no
#                 line, so the collision is structurally impossible rather
#                 than merely unlikely.
#     <category>  one of added|changed|deprecated|removed|fixed|security
#                 (Keep a Changelog's six, lowercased).
#     .breaking   optional marker. Present => the assembled sub-heading gets
#                 the ` — BREAKING` suffix `changelog_breaking_sections()`
#                 keys on (that function reads HEADINGS only — body prose
#                 never sets its flag, VERSIONING.md § Cutting a release).
#
# ASSEMBLY ORDER is total and derives from the filename alone: canonical
# category order first (Added, Changed, Deprecated, Removed, Fixed,
# Security), then LC_ALL=C lexicographic by filename within a category.
#
# `README.md` and dotfiles (`.gitkeep`) in the fragment directory are
# placeholders/docs, never fragments, and are skipped everywhere below.
# ===========================================================================

# Canonical Keep-a-Changelog category order. `_`-prefixed: private lib state,
# not an operator setting (see workflows/scripts/config/check-setting-registry.sh).
# ---------------------------------------------------------------------------
# changelog_fragment_category_order — print the six canonical categories, one
# per line, in assembly order. This function IS the single definition of that
# order; every loop below iterates it rather than re-listing the categories.
#
# It emits literals rather than word-splitting a space-separated string
# (`for c in $LIST`) on purpose: this file is SOURCED, and zsh does not
# word-split an unquoted parameter, so that idiom silently collapses to one
# six-word "category" under the shell half this repo already lints for
# (scripts/lint-zsh-param-tie.sh, temperloop#40). Literals split identically
# under bash and zsh.
# ---------------------------------------------------------------------------
changelog_fragment_category_order() {
  printf '%s\n' added changed deprecated removed fixed security
}

# ---------------------------------------------------------------------------
# changelog_fragment_title <category> — echo the Title-Cased heading word for
# a lowercase category token. Returns non-zero on an unknown category, which
# is what makes it double as the category validator.
# ---------------------------------------------------------------------------
changelog_fragment_title() {
  case "$1" in
    added)      printf 'Added\n' ;;
    changed)    printf 'Changed\n' ;;
    deprecated) printf 'Deprecated\n' ;;
    removed)    printf 'Removed\n' ;;
    fixed)      printf 'Fixed\n' ;;
    security)   printf 'Security\n' ;;
    *)          return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# changelog_fragment_parse <filename> — parse a fragment FILENAME (a bare
# basename or a path; only the basename is read). On success prints one
# space-separated line `<category> <breaking:0|1> <slug>` and returns 0. On
# any malformation returns 1 and prints nothing — so a caller can use it as
# the conformance predicate.
# ---------------------------------------------------------------------------
changelog_fragment_parse() {
  local name="${1##*/}"
  local breaking=0 stem cat slug
  case "$name" in
    *.md) stem="${name%.md}" ;;
    *)    return 1 ;;
  esac
  case "$stem" in
    *.breaking) breaking=1; stem="${stem%.breaking}" ;;
  esac
  case "$stem" in
    *.*) cat="${stem##*.}"; slug="${stem%.*}" ;;
    *)   return 1 ;;
  esac
  changelog_fragment_title "$cat" >/dev/null 2>&1 || return 1
  case "$slug" in
    *.*) return 1 ;;
  esac
  if [[ ! "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    return 1
  fi
  printf '%s %s %s\n' "$cat" "$breaking" "$slug"
}

# ---------------------------------------------------------------------------
# changelog_fragment_category <filename> — echo the lowercase category of a
# conforming fragment filename; non-zero if it does not conform.
# ---------------------------------------------------------------------------
changelog_fragment_category() {
  local parsed
  parsed="$(changelog_fragment_parse "$1")" || return 1
  printf '%s\n' "${parsed%% *}"
}

# ---------------------------------------------------------------------------
# changelog_fragment_is_breaking <filename> — exit 0 iff the filename carries
# the `.breaking` marker (and conforms).
# ---------------------------------------------------------------------------
changelog_fragment_is_breaking() {
  local parsed rest
  parsed="$(changelog_fragment_parse "$1")" || return 1
  rest="${parsed#* }"
  [[ "${rest%% *}" == "1" ]]
}

# ---------------------------------------------------------------------------
# _changelog_fragment_ls_all <dir> — basenames of EVERY entry directly in
# <dir>, regular or not, LC_ALL=C sorted. Dotfiles are excluded by the glob (a
# `.gitkeep` placeholder is never a fragment and is never reported as one).
#
# A dangling symlink fails `-e` but passes `-L`, so both tests are needed: the
# unmatched-glob literal (`<dir>/*` when the directory is empty) must be
# dropped, but a broken symlink must NOT be — silently dropping it is exactly
# the invisibility `changelog_fragment_nonregular` exists to end.
# ---------------------------------------------------------------------------
_changelog_fragment_ls_all() {
  local dir="$1" f
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*; do
    if [[ -e "$f" || -L "$f" ]]; then
      printf '%s\n' "${f##*/}"
    fi
  done | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# _changelog_fragment_ls <dir> — basenames of every regular file directly in
# <dir>, LC_ALL=C sorted. This is the ASSEMBLY-side listing: only a regular
# file can be read as a fragment body. Everything it drops is reported by
# `changelog_fragment_nonregular` below, so nothing filtered here is invisible.
# ---------------------------------------------------------------------------
_changelog_fragment_ls() {
  local dir="$1" name
  _changelog_fragment_ls_all "$dir" | while IFS= read -r name; do
    if [[ -f "$dir/$name" ]]; then
      printf '%s\n' "$name"
    fi
  done
}

# ---------------------------------------------------------------------------
# changelog_fragment_nonregular <dir> — basenames of entries directly in <dir>
# that are NOT regular files: a subdirectory, a dangling symlink, a fifo.
#
# WHY THIS IS REPORTED RATHER THAN FILTERED. `_changelog_fragment_ls` keeps
# only regular files, so without this listing a fragment placed one level down
# (`changelog.d/subdir/1-nested.added.md`) is INVISIBLE end to end: `--check`
# reports "all well-formed", the fragment never assembles, and it survives the
# deletion loop — sitting on disk looking pending while the release ships
# without it. A dangling symlink whose NAME conforms is the same failure with
# no filename tell at all. Kernel principle 5: a lost entry must fail loudly.
# ---------------------------------------------------------------------------
changelog_fragment_nonregular() {
  local dir="$1" name
  _changelog_fragment_ls_all "$dir" | while IFS= read -r name; do
    if [[ ! -f "$dir/$name" ]]; then
      printf '%s\n' "$name"
    fi
  done
}

# ---------------------------------------------------------------------------
# _changelog_fragment_names_in <dir> <category> — conforming fragment
# basenames of one category, LC_ALL=C sorted.
# ---------------------------------------------------------------------------
_changelog_fragment_names_in() {
  local dir="$1" want="$2" name got
  _changelog_fragment_ls "$dir" | while IFS= read -r name; do
    got="$(changelog_fragment_category "$name" 2>/dev/null)" || continue
    if [[ "$got" == "$want" ]]; then
      printf '%s\n' "$name"
    fi
  done
}

# ---------------------------------------------------------------------------
# changelog_fragment_names <dir> — every conforming fragment basename in
# ASSEMBLY ORDER (canonical category order, then LC_ALL=C by filename).
# Empty output means the directory is absent, empty, or holds only
# placeholders.
# ---------------------------------------------------------------------------
changelog_fragment_names() {
  local dir="$1" c
  [[ -d "$dir" ]] || return 0
  while IFS= read -r c; do
    _changelog_fragment_names_in "$dir" "$c"
  done < <(changelog_fragment_category_order)
}

# ---------------------------------------------------------------------------
# changelog_fragment_invalid <dir> — basenames in <dir> that are NOT
# conforming fragments and are not the sanctioned placeholders (`README.md`,
# dotfiles). A release cut must fail loudly on these rather than silently
# drop somebody's entry, so this is a listing, not a filter.
#
# NON-REGULAR ENTRIES COUNT AS INVALID, whatever their name. A subdirectory or
# a dangling symlink cannot be read as a fragment body, so leaving it out of
# this listing would make it invisible to `--check` (see
# `changelog_fragment_nonregular` above). The name test is only reached for
# entries that are actually readable files — a broken symlink NAMED
# `1-nested.added.md` parses fine and would otherwise pass.
# ---------------------------------------------------------------------------
changelog_fragment_invalid() {
  local dir="$1" name
  _changelog_fragment_ls_all "$dir" | while IFS= read -r name; do
    if [[ ! -f "$dir/$name" ]]; then
      printf '%s\n' "$name"
      continue
    fi
    case "$name" in
      README.md) continue ;;
    esac
    if ! changelog_fragment_parse "$name" >/dev/null 2>&1; then
      printf '%s\n' "$name"
    fi
  done
}

# ---------------------------------------------------------------------------
# changelog_fragment_body <file> — the fragment's body with leading and
# trailing blank lines trimmed. Interior blank lines are preserved (a
# multi-paragraph entry is normal). Empty output means an empty fragment.
# ---------------------------------------------------------------------------
changelog_fragment_body() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    { l[NR] = $0 }
    END {
      first = 0; last = 0
      for (i = 1; i <= NR; i++) {
        if (l[i] ~ /[^ \t\r]/) { if (first == 0) first = i; last = i }
      }
      if (first == 0) exit
      for (i = first; i <= last; i++) print l[i]
    }
  ' "$file"
}

# ---------------------------------------------------------------------------
# changelog_fragment_empty <dir> — basenames of conforming fragments whose
# body is blank. An empty fragment is a lost entry, so the cut fails on it.
# ---------------------------------------------------------------------------
changelog_fragment_empty() {
  local dir="$1" name body
  changelog_fragment_names "$dir" | while IFS= read -r name; do
    body="$(changelog_fragment_body "$dir/$name")"
    if [[ -z "$body" ]]; then
      printf '%s\n' "$name"
    fi
  done
}

# ---------------------------------------------------------------------------
# changelog_fragment_body_offenders <dir> — `<name>:<line>: <text>` for every
# fragment body line that is an h1/h2/h3 heading, or that impersonates one of
# the assembler's own control tokens. The assembler OWNS the `### <Category>`
# heading; a heading inside a body would silently restructure the assembled
# section (and, with `BREAKING` in it, could forge a breaking signal
# `changelog_breaking_sections()` reads). h4+ inside an entry is fine.
#
# THE CONTROL-TOKEN ARM IS DEFENCE IN DEPTH, not the primary guard. The
# assembler's metadata now travels OUT OF BAND (see
# `_changelog_fragment_additions`: a control-only manifest, one body file per
# category), so a body line can no longer be parsed as control however it is
# spelled — that is the structural fix. This arm additionally rejects the two
# tokens LOUDLY so (a) a future refactor back toward an in-band stream cannot
# silently reopen the forgery path, and (b) a line like `##CATEGORY## security
# 1` — which is not a valid ATX heading, so `/^## /` never matched it — does
# not land in a shipped changelog as confusing literal text.
#
# Deliberately NOT fence-aware: a fenced ``` ### Foo — BREAKING ``` inside a
# fragment body would still be copied verbatim into `## [Unreleased]`, and
# `changelog_breaking_sections()` reads `/^#+ .*BREAKING/` with no fence
# tracking of its own. Flagging it is the safe direction.
# ---------------------------------------------------------------------------
changelog_fragment_body_offenders() {
  local dir="$1" name
  changelog_fragment_names "$dir" | while IFS= read -r name; do
    awk -v f="$name" '
      /^# / || /^## / || /^### / ||
      /^##BEGIN##$/ || /^##CATEGORY##([ \t]|$)/ {
        printf "%s:%d: %s\n", f, FNR, $0
      }
    ' "$dir/$name"
  done
}

# ---------------------------------------------------------------------------
# changelog_fragment_has_breaking <dir> — exit 0 iff ANY conforming fragment
# in <dir> carries the `.breaking` marker.
# ---------------------------------------------------------------------------
changelog_fragment_has_breaking() {
  local dir="$1" name
  while IFS= read -r name; do
    if changelog_fragment_is_breaking "$name"; then
      return 0
    fi
  done < <(changelog_fragment_names "$dir")
  return 1
}

# ---------------------------------------------------------------------------
# _changelog_fragment_additions <dir> <workdir> — the assembler's intermediate
# form. Writes ONE BODY FILE PER CATEGORY into <workdir> and prints a
# control-only MANIFEST on stdout:
#
#   ##BEGIN##
#   <category> <breaking:0|1> <path to that category's body file>
#
# METADATA TRAVELS OUT OF BAND — this is a correctness property, not a
# refactor. The former shape multiplexed control lines and fragment bodies
# onto ONE stream using in-band `##CATEGORY## <cat> <brk>` sentinels, which
# made a body line indistinguishable from a control line: a fragment whose
# body contained `##CATEGORY## security 1` passed validation and assembled to
# `### Security — BREAKING`, forging the exact heading
# `changelog_breaking_sections()` keys on — the signal `scripts/update-kernel.sh`
# and `bin/subcommands/update.sh` read to gate a downstream pull for EVERY
# vendoring overlay. A `##BEGIN##` body line was silently deleted outright.
#
# With bodies in their own files, no fragment content is ever parsed as
# control, whatever it says. Kernel principle 5 — counter the failure mode
# STRUCTURALLY rather than with a matching rule someone must keep in sync.
# (`changelog_fragment_body_offenders` still rejects the tokens as defence in
# depth; that arm is now a second line, not the only one.)
#
# The manifest's every field is generated here — a fixed category token, a
# 0|1, and an mktemp'd path — so its leading `##BEGIN##` sentinel is
# unforgeable. It exists only to guarantee the first file of the assembler's
# two-file awk pass is never empty, which is what makes `NR==FNR` a sound
# input separator (an empty first file makes NR==FNR true for the SECOND
# file's lines too).
# ---------------------------------------------------------------------------
_changelog_fragment_additions() {
  local dir="$1" workdir="$2" c name brk count first bodyfile
  printf '##BEGIN##\n'
  while IFS= read -r c; do
    brk=0
    count=0
    while IFS= read -r name; do
      count=$((count + 1))
      if changelog_fragment_is_breaking "$name"; then
        brk=1
      fi
    done < <(_changelog_fragment_names_in "$dir" "$c")
    if [[ "$count" -eq 0 ]]; then
      continue
    fi
    bodyfile="$workdir/body.$c"
    first=1
    while IFS= read -r name; do
      if [[ "$first" -eq 0 ]]; then
        printf '\n'
      fi
      first=0
      changelog_fragment_body "$dir/$name"
    done < <(_changelog_fragment_names_in "$dir" "$c") >"$bodyfile" || return 1
    printf '%s %s %s\n' "$c" "$brk" "$bodyfile"
  done < <(changelog_fragment_category_order)
}

# ---------------------------------------------------------------------------
# changelog_assemble_unreleased_body <fragment-dir> <changelog-file> [workdir]
#
# <workdir> is optional scratch space the CALLER owns and cleans up — pass it
# when the caller already has an EXIT trap, so a signal during the awk pass
# cannot leak temps. Omitted, this function makes and removes its own.
#
# RETURNS NON-ZERO on any failure, and callers MUST check it: a silent empty
# body here is what let `scripts/assemble-changelog.sh` print "assembled N
# fragment(s)" while deleting the entire pre-existing `[Unreleased]` section.
#
# Print the `## [Unreleased]` BODY that results from folding <fragment-dir>'s
# fragments into the changelog's CURRENT Unreleased body. The output has the
# same shape `changelog_unreleased_body()` reads today: a leading blank line,
# `### <Category>` sub-headings each followed by a blank line, a trailing
# blank line.
#
# ADDITIVE OVER A NON-EMPTY BODY — this is the load-bearing property, not an
# edge case. `main`'s `## [Unreleased]` is routinely substantial, and an
# assembler that assumed an empty section and REPLACED it would silently drop
# everything accumulated since the last tag. So:
#
#   * existing sub-sections are kept, in their existing order, with their
#     content byte-preserved (only leading/trailing blank lines normalise);
#   * a fragment's body is APPENDED to the end of its category's existing
#     sub-section when one exists;
#   * a category with no existing sub-section gets a new one, INSERTED at its
#     canonical Keep-a-Changelog position among the sub-sections already
#     there (which are never reordered — insertion only);
#   * an existing sub-heading gains the ` — BREAKING` suffix when a fragment
#     merged into it is breaking and the heading does not already say so.
#
# A consequence worth stating: an in-flight PR written against the OLD flow
# (a direct `## [Unreleased]` line, no fragment) is harmless rather than
# lost — its line is existing body content and is simply kept.
# ---------------------------------------------------------------------------
changelog_assemble_unreleased_body() {
  local dir="$1" changelog="$2" workdir="${3:-}"
  local owned=0 rc=0 manifest body

  # TEMP OWNERSHIP. The caller MAY pass its own <workdir>, in which case the
  # caller's own EXIT trap owns cleanup — that is the signal-safe path, and
  # `scripts/assemble-changelog.sh` uses it. When no workdir is passed this
  # function makes one and removes it on EVERY return path below, including
  # the early failures (the previous shape's bare `rm -f` at the end was
  # skipped by an early `return 1`, leaking two temps per failure).
  if [[ -z "$workdir" ]]; then
    workdir="$(mktemp -d)" || return 1
    owned=1
  fi
  [[ -d "$workdir" ]] || { [[ "$owned" -eq 1 ]] && rm -rf "$workdir"; return 1; }

  manifest="$workdir/manifest"
  body="$workdir/unreleased-body"

  if ! _changelog_fragment_additions "$dir" "$workdir" >"$manifest"; then
    rc=1
  fi
  if [[ "$rc" -eq 0 ]] && ! changelog_unreleased_body "$changelog" >"$body"; then
    rc=1
  fi
  if [[ "$rc" -eq 0 ]]; then
    _changelog_assemble_awk "$manifest" "$body" || rc=1
  fi

  if [[ "$owned" -eq 1 ]]; then
    rm -rf "$workdir"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# _changelog_assemble_awk <manifest> <body> — the two-file awk pass behind
# `changelog_assemble_unreleased_body`. Split out so that function stays
# readable as the temp-ownership + error-propagation wrapper it now is.
#
# <manifest> is the control-only stream `_changelog_fragment_additions`
# printed; <body> is the changelog's current Unreleased body. Each manifest
# line names a category, its breakingness, and a FILE holding that category's
# concatenated fragment bodies, which this pass slurps with `getline`.
# ---------------------------------------------------------------------------
_changelog_assemble_awk() {
  awk '
    BEGIN {
      ncat = split("added changed deprecated removed fixed security", CATS, " ")
      T["added"] = "Added"; T["changed"] = "Changed"
      T["deprecated"] = "Deprecated"; T["removed"] = "Removed"
      T["fixed"] = "Fixed"; T["security"] = "Security"
      SUFFIX = " \342\200\224 BREAKING"
    }
    function catof(h,   t, i, c) {
      t = h
      sub(/^###[ \t]+/, "", t)
      t = tolower(t)
      for (i = 1; i <= ncat; i++) {
        c = CATS[i]
        if (t == c || substr(t, 1, length(c) + 1) == (c " ")) return c
      }
      return ""
    }
    function emit(s) { OUT[++on] = s }
    function emit_block(str,   m, k, arr) {
      m = split(str, arr, "\n")
      for (k = 1; k <= m; k++) {
        if (k == m && arr[k] == "") break
        emit(arr[k])
      }
    }
    # Emit any BRAND-NEW category section (one the body has no sub-heading
    # for) whose canonical rank sorts before `limit`, so a new section lands
    # at its Keep-a-Changelog position instead of being dumped at the end.
    # EXISTS[] gates it: a category that DOES have a sub-heading further down
    # is merged there, never duplicated here.
    function flush_new(limit,   j, c, h) {
      for (j = 1; j <= ncat; j++) {
        c = CATS[j]
        if (RANK[c] < limit && HAVE[c] && !EXISTS[c] && !NEWDONE[c]) {
          h = "### " T[c]
          if (BR[c] == 1) h = h SUFFIX
          emit("")
          emit(h)
          emit("")
          emit_block(ADD[c])
          NEWDONE[c] = 1
        }
      }
    }
    # FILE 1 — the control-only manifest. Every field here was generated by
    # `_changelog_fragment_additions`, never by a fragment body, so no
    # fragment text can reach this branch however it is spelled. The body
    # itself is slurped from the named FILE, out of band.
    NR == FNR {
      if ($0 == "##BEGIN##") next
      if (NF < 3) next
      c = $1
      BR[c] = $2
      HAVE[c] = 1
      # The path is everything after the second field — a workdir under
      # $TMPDIR may legitimately contain spaces, so $3 alone is not enough.
      p = $0
      sub(/^[^ ]+ [^ ]+ /, "", p)
      r = (getline line < p)
      while (r > 0) { ADD[c] = ADD[c] line "\n"; r = (getline line < p) }
      close(p)
      if (r < 0) {
        printf "changelog_assemble_unreleased_body: cannot read body stream for category %s (%s)\n", c, p > "/dev/stderr"
        exit 1
      }
      next
    }
    { L[++n] = $0 }
    END {
      # FENCE-AWARE heading scan. An UNINDENTED ``` fence in the Unreleased
      # body may legitimately contain a line like `### Added` as sample text;
      # treating that as a real sub-heading would split the section at it,
      # inject a blank line INSIDE the fence (mutating existing content), and
      # append fragments into a pseudo-section. Toggling on a line-initial
      # fence keeps fenced content opaque to the scan. (An INDENTED fence
      # never matched /^### / in the first place, so it needs no handling.)
      nh = 0
      infence = 0
      for (i = 1; i <= n; i++) {
        if (L[i] ~ /^```/) { infence = !infence; continue }
        if (!infence && L[i] ~ /^### /) { nh++; H[nh] = i; HC[nh] = catof(L[i]) }
      }
      for (j = 1; j <= ncat; j++) RANK[CATS[j]] = j
      for (k = 1; k <= nh; k++) if (HC[k] != "" && !EXISTS[HC[k]]) EXISTS[HC[k]] = k
      # An UNRECOGNISED `### Foo` heading inherits the running rank, so it
      # stays glued to the sub-section it currently follows.
      prev = 0
      for (k = 1; k <= nh; k++) { ER[k] = (HC[k] != "") ? RANK[HC[k]] : prev; prev = ER[k] }
      end0 = (nh > 0) ? H[1] - 1 : n
      ps = 1; pe = end0
      while (ps <= pe && L[ps] ~ /^[ \t]*$/) ps++
      while (pe >= ps && L[pe] ~ /^[ \t]*$/) pe--
      if (pe >= ps) {
        emit("")
        for (i = ps; i <= pe; i++) emit(L[i])
      }
      for (k = 1; k <= nh; k++) {
        flush_new(ER[k])
        head = L[H[k]]
        c = HC[k]
        takes = (c != "" && HAVE[c] && !DONE[c]) ? 1 : 0
        if (takes && BR[c] == 1 && head !~ /BREAKING/) head = "### " T[c] SUFFIX
        emit("")
        emit(head)
        emit("")
        bs = H[k] + 1
        be = (k < nh) ? H[k + 1] - 1 : n
        while (bs <= be && L[bs] ~ /^[ \t]*$/) bs++
        while (be >= bs && L[be] ~ /^[ \t]*$/) be--
        for (i = bs; i <= be; i++) emit(L[i])
        if (takes) {
          if (be >= bs) emit("")
          emit_block(ADD[c])
          DONE[c] = 1
        }
      }
      flush_new(ncat + 1)
      emit("")
      for (i = 1; i <= on; i++) print OUT[i]
    }
  ' "$1" "$2"
}
