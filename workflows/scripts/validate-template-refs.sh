#!/usr/bin/env bash
#
# validate-template-refs.sh — static reference-integrity + parsed-surface
# registry-completeness lint for the message-template system (temperloop#94,
# plan item `template-lints`).
#
# Three independent, purely STATIC checks (no runtime message rendering is
# inspected — a lint that claimed to check actual rendered wording would be a
# false floor, not CI-checkable, and is deliberately out of scope):
#
#   1. Reference-integrity: every by-name reference to a message template
#      (a bolded template name immediately followed by the word "template",
#      e.g. "**PR-body skeleton** template") found in claude/CLAUDE.kernel.md
#      or claude/commands/*.md must name a template actually defined (a
#      `### <Name>` heading under claude/message-schema.md's `## Templates`
#      section). A renamed/typo'd/retired template name that a doc still
#      references by name is caught here.
#
#   2. Dangling-override check: claude/message-schema.md's own § Overrides
#      section says an overlay overrides a template by "writing out the
#      entire template again under the same name" — every such overlay
#      redeclaration must match a kernel-defined template name. A bare kernel
#      checkout (this repo) ships no overlay, so this check is parameterized
#      over an overlay path (MESSAGE_SCHEMA_OVERLAY, default
#      claude/message-schema.overlay.md — the natural sibling of the
#      existing claude/live-drain-registry.overlay.md pattern) that is
#      typically ABSENT here: absent -> zero overrides to check -> trivial
#      pass, not an error. When a downstream composed checkout ships that
#      file, this check activates automatically.
#
#   3. Registry-completeness: every contract-frozen row in
#      claude/presentation-plane.md's "## Kernel table" must name a
#      RESOLVABLE owner — every backticked path-shaped token (containing a
#      "/") in its "Owning contract / parser" column must exist on disk, and
#      every single "§ <Section>" pointer (word-shaped, not "§§" or a bare
#      numeric range like "2-3", both of which name non-heading targets this
#      script does not attempt to resolve) must resolve to a heading or
#      bold-label anchor in the file it follows — the same anchor_present
#      contract validate-live-drain.sh already uses for the Live/Drain
#      registry, applied here to presentation-plane.md's registry instead.
#      This is the "live-drain-validator mold" the acceptance criteria name.
#
# Kept POSIX-bash-3.2 friendly (no mapfile/associative arrays) so it runs on
# the macOS dev shell as well as Linux CI, matching validate-live-drain.sh's
# own portability contract.
#
# Usage: workflows/scripts/validate-template-refs.sh   (resolves the repo itself)

set -euo pipefail

SCRIPTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$SCRIPTS_DIR/../.." && pwd)"

MSG_SCHEMA="$REPO/claude/message-schema.md"
KERNEL_MD="$REPO/claude/CLAUDE.kernel.md"
COMMANDS_DIR="$REPO/claude/commands"
PRES_PLANE="$REPO/claude/presentation-plane.md"
OVERLAY_MSG_SCHEMA="${MESSAGE_SCHEMA_OVERLAY:-$REPO/claude/message-schema.overlay.md}"

fail=0

for f in "$MSG_SCHEMA" "$KERNEL_MD" "$PRES_PLANE"; do
  if [ ! -f "$f" ]; then
    echo "FAIL  required kernel doc missing: $f"
    exit 1
  fi
done

# --- shared helpers -----------------------------------------------------

# anchor_present <file> <anchor> -> 0 if the anchor appears in the file as a
# markdown heading ("## Anchor...") or a bold label ("**Anchor"). Identical
# contract to validate-live-drain.sh's own anchor_present, reused here so the
# two registry validators agree on what "resolvable" means.
anchor_present() {
  local file="$1" anchor="$2"
  [ -f "$file" ] || return 1
  if grep -Eq "^#{1,6}[[:space:]]+${anchor}([[:space:](.]|\$)" "$file"; then return 0; fi
  if grep -Fq "**${anchor}" "$file"; then return 0; fi
  return 1
}

# trim <string> -> leading/trailing whitespace stripped.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# ==========================================================================
# 1. Canonical template names — the source-of-truth extraction.
# ==========================================================================

canonical_names="$(awk '
  /^## Templates/  { insec = 1; next }
  insec && /^## /  { insec = 0 }
  insec && /^### / { sub(/^### /, ""); print }
' "$MSG_SCHEMA")"

if [ -z "$canonical_names" ]; then
  echo "FAIL: no '### <Template>' headings found under '## Templates' in $MSG_SCHEMA"
  exit 1
fi

echo "canonical templates ($MSG_SCHEMA):"
printf '%s\n' "$canonical_names" | sed 's/^/  - /'

# name_is_canonical <name> -> 0 if <name> matches a canonical template name
# (case-insensitive, trimmed).
name_is_canonical() {
  local want lc_want lc_have
  want="$(trim "$1")"
  lc_want="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r have; do
    [ -n "$have" ] || continue
    lc_have="$(printf '%s' "$(trim "$have")" | tr '[:upper:]' '[:lower:]')"
    [ "$lc_want" = "$lc_have" ] && return 0
  done <<EOF
$canonical_names
EOF
  return 1
}

# ==========================================================================
# 2. Reference-integrity: by-name template refs in CLAUDE.kernel.md +
#    claude/commands/*.md must resolve to a canonical template.
# ==========================================================================

echo
echo "--- reference-integrity (by-name template refs) ---"

ref_targets="$KERNEL_MD"
if [ -d "$COMMANDS_DIR" ]; then
  for f in "$COMMANDS_DIR"/*.md; do
    [ -e "$f" ] || continue
    ref_targets="$ref_targets
$f"
  done
fi

nrefs=0
while IFS= read -r target; do
  [ -n "$target" ] || continue
  # Extract every "**<name>** template" occurrence (case-insensitive on the
  # word "template" only — the captured name's case is preserved verbatim
  # for the message, matched case-insensitively against the canonical set).
  matches="$(grep -oE '\*\*[^*]+\*\*[[:space:]]+[Tt]emplate' "$target" || true)"
  [ -n "$matches" ] || continue
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    nrefs=$((nrefs + 1))
    # Strip the leading "**", the trailing "** template"/"** Template".
    name="$(printf '%s' "$m" | sed -E 's/^\*\*//; s/\*\*[[:space:]]+[Tt]emplate$//')"
    if name_is_canonical "$name"; then
      echo "ok    \"$name\" ($target)"
    else
      echo "FAIL  \"$name\" ($target) does not match any template defined in $MSG_SCHEMA § Templates"
      fail=$((fail + 1))
    fi
  done <<EOF
$matches
EOF
done <<EOF
$ref_targets
EOF

echo "checked $nrefs by-name reference(s)"

# ==========================================================================
# 3. Dangling-override check: an overlay's redeclared template names (if the
#    overlay file is present at all) must match a canonical template name.
# ==========================================================================

echo
echo "--- dangling-override check ---"

if [ -f "$OVERLAY_MSG_SCHEMA" ]; then
  overlay_names="$(grep -oE '^### .+' "$OVERLAY_MSG_SCHEMA" | sed 's/^### //' || true)"
  if [ -z "$overlay_names" ]; then
    echo "skip  $OVERLAY_MSG_SCHEMA present but declares no '### <Template>' overrides"
  else
    while IFS= read -r oname; do
      [ -n "$oname" ] || continue
      if name_is_canonical "$oname"; then
        echo "ok    overlay override \"$oname\" matches a kernel template"
      else
        echo "FAIL  overlay override \"$oname\" ($OVERLAY_MSG_SCHEMA) does not match any kernel-defined template in $MSG_SCHEMA § Templates"
        fail=$((fail + 1))
      fi
    done <<EOF
$overlay_names
EOF
  fi
else
  echo "skip  no overlay message-schema present at $OVERLAY_MSG_SCHEMA (bare kernel checkout) — 0 overrides to check"
fi

# ==========================================================================
# 4. Registry-completeness: every presentation-plane.md kernel-table row
#    names a resolvable owner (file exists; a single "§ <Section>" pointer
#    resolves to a heading/bold-label anchor in that file).
# ==========================================================================

echo
echo "--- registry-completeness (presentation-plane.md kernel table) ---"

kernel_table_rows="$(awk '
  /^## Kernel table/         { insec = 1; next }
  insec && /^## /            { insec = 0 }
  insec && /^\|/             { print }
' "$PRES_PLANE" | grep -vE '^\|[[:space:]]*Surface|^\|[[:space:]]*-')"

if [ -z "$kernel_table_rows" ]; then
  echo "FAIL: no data rows found under '## Kernel table' in $PRES_PLANE"
  exit 1
fi

nrows=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  nrows=$((nrows + 1))

  # Column 4 (1-indexed on the leading empty field from the row's opening
  # "|") is "Owning contract / parser".
  owner_cell="$(printf '%s' "$row" | awk -F'|' '{print $4}')"
  surface_cell="$(printf '%s' "$row" | awk -F'|' '{print $2}' | sed 's/^ *//; s/ *$//')"

  row_ok=1
  row_notes=""

  # Split the cell on " + " — the table's own convention for combining
  # multiple owner pointers in one row (see e.g. the Closes-line row).
  segments="$(printf '%s' "$owner_cell" | awk -F' \\+ ' '{ for (i=1;i<=NF;i++) print $i }')"

  while IFS= read -r seg; do
    [ -n "$seg" ] || continue

    # Path-shaped backticked tokens (contain a "/") are file references —
    # verify each exists. Bare backticked basenames/function names (no "/",
    # e.g. `open`, `writeback`) are not independently file-checkable and are
    # skipped, per this script's header.
    # SC2016: the backticks in the regex are literal (match `...` spans), not
    # a command substitution — single quotes are intentional (same rationale
    # as validate-live-drain.sh's tokens() helper).
    # shellcheck disable=SC2016
    seg_files="$(printf '%s' "$seg" | grep -oE '`[^`]*/[^`]*`' | tr -d '`' || true)"
    last_file=""
    if [ -n "$seg_files" ]; then
      while IFS= read -r relpath; do
        [ -n "$relpath" ] || continue
        last_file="$relpath"
        if [ ! -e "$REPO/$relpath" ]; then
          row_ok=0
          row_notes="$row_notes missing-file:$relpath"
        fi
      done <<EOF
$seg_files
EOF
    fi

    # A single "§ <Section>" pointer (not "§§", which names a compound/
    # quoted or numeric target this script doesn't attempt to resolve) —
    # extract the section name up to the first "(" or end of segment, and
    # check it resolves in the last path-shaped file seen in this segment.
    if printf '%s' "$seg" | grep -qE '(^|[^§])§([^§]|$)'; then
      secname="$(printf '%s' "$seg" | sed -E 's/^.*[^§]§[[:space:]]*//; s/\(.*$//' | sed 's/[[:space:]]*$//')"
      # Skip bare numeric/range targets (e.g. "2-3", "0a") — not headings.
      if printf '%s' "$secname" | grep -qE '^[0-9]'; then
        : # not a headed section; nothing to resolve
      elif [ -n "$secname" ] && [ -n "$last_file" ]; then
        if [ -f "$REPO/$last_file" ] && anchor_present "$REPO/$last_file" "$secname"; then
          : # resolves
        else
          row_ok=0
          row_notes="$row_notes missing-section:'$secname' in $last_file"
        fi
      fi
    fi
  done <<EOF
$segments
EOF

  if [ "$row_ok" = "1" ]; then
    echo "ok    $surface_cell"
  else
    echo "FAIL  $surface_cell ($row_notes )"
    fail=$((fail + 1))
  fi
done <<EOF
$kernel_table_rows
EOF

echo "checked $nrows kernel-table row(s)"

echo
if [ "$fail" -ne 0 ]; then
  echo "validate-template-refs: FAIL ($fail violation(s))"
  exit 1
fi
echo "validate-template-refs: OK"
