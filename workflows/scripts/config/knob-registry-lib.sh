#!/usr/bin/env bash
#
# knob-registry-lib.sh — parse helper for the kernel knob registry
# (temperloop#164/#169, design decision D2: a kernel TSV registry + "keep the
# shell literals, lint them for equality" — the equality lint itself is a
# LATER item, registry-config-lints; this file only reads the registry).
#
# Reads workflows/scripts/config/knob-registry.tsv (the kernel table, ALWAYS
# present) and UNIONS in an optional overlay extension TSV when one is
# present — the same union shape as validate-live-drain.sh's kernel-table +
# overlay-extension-table pairing (see that script's header for the
# precedent this mirrors): a standalone kernel checkout reads the kernel
# table alone; a composed/overlay checkout (one that vendors this kernel via
# git subtree and adds its own org-specific knobs) additionally unions in its
# overlay extension.
#
# ── Row shape (kernel table) ────────────────────────────────────────────────
#   name<TAB>default<TAB>type<TAB>layer<TAB>owning-script<TAB>doc   (6 fields)
# See knob-registry.tsv's own header for the full column contract (type/layer
# closed sets, inclusion rule).
#
# ── Overlay extension TSV ───────────────────────────────────────────────────
# Same 6 fields PLUS a 7th trailing `op` field, op in {add, redefault}:
#   name<TAB>default<TAB>type<TAB>layer<TAB>owning-script<TAB>doc<TAB>op
#   - op=add        a NEW knob, not present in the kernel table at all. It is
#                    an error (malformed) for an `add` row's name to already
#                    exist in the kernel table — that is a collision, almost
#                    certainly a copy-paste mistake, and should be `redefault`
#                    instead.
#   - op=redefault   OVERRIDES an existing kernel row's default/type/layer/
#                    owning-script/doc for the union view (e.g. an overlay
#                    that ships a different default for a knob the kernel
#                    also defines). It is an error for a `redefault` row's
#                    name to be absent from the kernel table — nothing to
#                    redefine.
# Discovery path: a sibling file next to the kernel TSV,
# workflows/scripts/config/knob-registry.overlay.tsv — present only in a
# composed/overlay checkout, mirroring claude/live-drain-registry.overlay.md.
# Overridable via KNOB_REGISTRY_OVERLAY_FILE (a test seam / explicit path
# override), per this repo's config-precedence discovery conventions
# (docs/config-precedence.md; see e.g. BOARDS_CONF_REPO_LOCAL). The kernel
# file path itself is overridable via KNOB_REGISTRY_FILE.
#
# Parsed with grep/cut only — NEVER sourced or eval'd, so a registry file
# (kernel or overlay) cannot execute code, same discipline as boards.conf.
#
# Kept bash-3.2-portable (no associative arrays, no mapfile) so it runs on
# the macOS dev shell as well as Linux CI, matching board.sh / cache.sh.
#
# This file is SOURCED, never executed directly — it has no CLI of its own.

_KNOB_REGISTRY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The closed `type` vocabulary (knob-registry.tsv's own header is the
# canonical documentation of these; kept here too so validation doesn't need
# to re-parse the header comment).
KNOB_REGISTRY_TYPES="int seconds pct bool string enum path url label marker"

# The closed `layer` vocabulary — the six-rung ladder's own tokens
# (docs/config-precedence.md), naming WHERE a row's recorded default lives.
# Every row in THIS registry records a rung-5 or rung-6 default (a config
# ladder's rungs 1-4 are call-site/environment, never a registry row); both
# tokens are kept in one vocabulary so a validator can still recognize e.g. a
# future rung-3/4 row without a schema change.
KNOB_REGISTRY_LAYERS="cli env machine-conf repo-local tracked-repo kernel"

# knob_registry_kernel_file -> the kernel TSV path (default: sibling
# knob-registry.tsv next to this lib; override via KNOB_REGISTRY_FILE).
knob_registry_kernel_file() {
  printf '%s' "${KNOB_REGISTRY_FILE:-$_KNOB_REGISTRY_LIB_DIR/knob-registry.tsv}"
}

# knob_registry_overlay_file -> the overlay extension TSV path (default: a
# sibling knob-registry.overlay.tsv; override via KNOB_REGISTRY_OVERLAY_FILE).
# Does NOT check existence — callers test `-f` themselves (mirrors
# validate-live-drain.sh's DRAIN_OVERLAY_EXT handling).
knob_registry_overlay_file() {
  printf '%s' "${KNOB_REGISTRY_OVERLAY_FILE:-$_KNOB_REGISTRY_LIB_DIR/knob-registry.overlay.tsv}"
}

# _knob_registry_data_rows <file> -> non-blank, non-comment lines of <file>,
# one per line. A comment is a line whose first non-space character is `#`.
_knob_registry_data_rows() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$file" || true
}

# _knob_registry_field_count <line> -> number of TAB-separated fields.
_knob_registry_field_count() {
  awk -F'\t' '{print NF}' <<<"$1"
}

# _knob_registry_in_list <needle> <space-separated list> -> rc 0 if present.
_knob_registry_in_list() {
  local needle="$1" list="$2" item
  for item in $list; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# knob_registry_validate [--kernel-only] -> validates the kernel table (and,
# unless --kernel-only, the overlay extension when present). Prints one
# "MALFORMED: <reason>: <line>" line per bad row to stderr and returns
# non-zero if any row is malformed; otherwise prints nothing and returns 0.
# Malformed conditions:
#   - kernel row: field count != 6, OR `type` not in KNOB_REGISTRY_TYPES, OR
#     `layer` not in KNOB_REGISTRY_LAYERS, OR a duplicate (name,
#     owning-script) PAIR within the kernel table itself. A repeated `name`
#     alone is NOT an error — a knob whose default genuinely differs between
#     two owning scripts (a real rung-5-vs-rung-6 divergence, see
#     knob-registry.tsv's own header) legitimately gets two rows, one per
#     owning-script/layer; only an exact (name, owning-script) repeat is a
#     copy-paste mistake.
#   - overlay row: field count != 7, OR `type`/`layer` invalid (as above), OR
#     `op` not in {add, redefault}, OR an `add` row whose name already
#     exists in the kernel table (collision), OR a `redefault` row whose name
#     does NOT exist in the kernel table (nothing to redefine).
knob_registry_validate() {
  local kernel_only="${1:-}"
  local kfile ofile rows row name type layer op fc bad=0
  kfile="$(knob_registry_kernel_file)"

  if [ ! -f "$kfile" ]; then
    echo "MALFORMED: kernel registry file not found: $kfile" >&2
    return 1
  fi

  local kernel_names="" kernel_name_script_pairs="" owning_script pair
  rows="$(_knob_registry_data_rows "$kfile")"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    fc="$(_knob_registry_field_count "$row")"
    if [ "$fc" != "6" ]; then
      echo "MALFORMED: kernel row has $fc fields (want 6): $row" >&2
      bad=1
      continue
    fi
    name="$(cut -f1 <<<"$row")"
    type="$(cut -f3 <<<"$row")"
    layer="$(cut -f4 <<<"$row")"
    owning_script="$(cut -f5 <<<"$row")"
    # Uniqueness key is (name, owning-script), not name alone — a knob
    # legitimately gets two rows when its default genuinely differs between
    # two owning scripts (see this function's header comment).
    pair="${name}|${owning_script}"
    if _knob_registry_in_list "$pair" "$kernel_name_script_pairs"; then
      echo "MALFORMED: duplicate kernel knob (name, owning-script): $pair" >&2
      bad=1
    fi
    kernel_name_script_pairs="$kernel_name_script_pairs $pair"
    kernel_names="$kernel_names $name"
    if ! _knob_registry_in_list "$type" "$KNOB_REGISTRY_TYPES"; then
      echo "MALFORMED: kernel row '$name' has unknown type '$type': $row" >&2
      bad=1
    fi
    if ! _knob_registry_in_list "$layer" "$KNOB_REGISTRY_LAYERS"; then
      echo "MALFORMED: kernel row '$name' has unknown layer '$layer': $row" >&2
      bad=1
    fi
  done <<EOF
$rows
EOF

  if [ "$kernel_only" != "--kernel-only" ]; then
    ofile="$(knob_registry_overlay_file)"
    if [ -f "$ofile" ]; then
      rows="$(_knob_registry_data_rows "$ofile")"
      while IFS= read -r row; do
        [ -n "$row" ] || continue
        fc="$(_knob_registry_field_count "$row")"
        if [ "$fc" != "7" ]; then
          echo "MALFORMED: overlay row has $fc fields (want 7): $row" >&2
          bad=1
          continue
        fi
        name="$(cut -f1 <<<"$row")"
        type="$(cut -f3 <<<"$row")"
        layer="$(cut -f4 <<<"$row")"
        op="$(cut -f7 <<<"$row")"
        if ! _knob_registry_in_list "$type" "$KNOB_REGISTRY_TYPES"; then
          echo "MALFORMED: overlay row '$name' has unknown type '$type': $row" >&2
          bad=1
        fi
        if ! _knob_registry_in_list "$layer" "$KNOB_REGISTRY_LAYERS"; then
          echo "MALFORMED: overlay row '$name' has unknown layer '$layer': $row" >&2
          bad=1
        fi
        case "$op" in
          add)
            if _knob_registry_in_list "$name" "$kernel_names"; then
              echo "MALFORMED: overlay 'add' row '$name' collides with an existing kernel knob (use op=redefault): $row" >&2
              bad=1
            fi
            ;;
          redefault)
            if ! _knob_registry_in_list "$name" "$kernel_names"; then
              echo "MALFORMED: overlay 'redefault' row '$name' has no matching kernel knob to redefine: $row" >&2
              bad=1
            fi
            ;;
          *)
            echo "MALFORMED: overlay row '$name' has unknown op '$op' (want add|redefault): $row" >&2
            bad=1
            ;;
        esac
      done <<EOF
$rows
EOF
    fi
  fi

  [ "$bad" = "0" ]
}

# knob_registry_rows -> prints the UNIONED 6-field rows (kernel table with
# any overlay 'redefault' rows applied in place, plus overlay 'add' rows
# appended), one per line, name|default|type|layer|owning-script|doc
# (TAB-separated). Does NOT validate — call knob_registry_validate first if
# you want malformed rows rejected rather than silently best-effort unioned
# (an unrecognized op is treated as a no-op skip here, not an error).
knob_registry_rows() {
  local kfile ofile row name ofile_rows orow oname oop kernel_rows out=""
  kfile="$(knob_registry_kernel_file)"
  kernel_rows="$(_knob_registry_data_rows "$kfile")"

  ofile="$(knob_registry_overlay_file)"
  ofile_rows=""
  [ -f "$ofile" ] && ofile_rows="$(_knob_registry_data_rows "$ofile")"

  # Emit kernel rows, substituting a matching redefault row's 6 fields when
  # one exists.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    name="$(cut -f1 <<<"$row")"
    local replaced=""
    if [ -n "$ofile_rows" ]; then
      while IFS= read -r orow; do
        [ -n "$orow" ] || continue
        oname="$(cut -f1 <<<"$orow")"
        oop="$(cut -f7 <<<"$orow")"
        if [ "$oname" = "$name" ] && [ "$oop" = "redefault" ]; then
          replaced="$(cut -f1-6 <<<"$orow")"
          break
        fi
      done <<EOF
$ofile_rows
EOF
    fi
    if [ -n "$replaced" ]; then
      out="$out$replaced"$'\n'
    else
      out="$out$row"$'\n'
    fi
  done <<EOF
$kernel_rows
EOF

  # Append overlay-only additions.
  if [ -n "$ofile_rows" ]; then
    while IFS= read -r orow; do
      [ -n "$orow" ] || continue
      oop="$(cut -f7 <<<"$orow")"
      [ "$oop" = "add" ] || continue
      out="$out$(cut -f1-6 <<<"$orow")"$'\n'
    done <<EOF
$ofile_rows
EOF
  fi

  printf '%s' "$out"
}

# knob_registry_get <name> -> prints the unioned row's `default` field for
# <name>, rc 1 on no match.
knob_registry_get() {
  local name="$1" row rname
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    rname="$(cut -f1 <<<"$row")"
    if [ "$rname" = "$name" ]; then
      cut -f2 <<<"$row"
      return 0
    fi
  done <<EOF
$(knob_registry_rows)
EOF
  return 1
}
