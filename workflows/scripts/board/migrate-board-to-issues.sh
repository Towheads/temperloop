#!/usr/bin/env bash
#
# Projects-v2 -> issues-only migration: read a board's Status/Component via
# the PROJECTS arm and write the equivalent fnd: labels via the ISSUES arm
# (see ISSUES-ONLY-BACKEND.md for the label vocabulary this writes). Dry-run
# is the default and does ZERO writes; --apply performs the writes and then
# VERIFIES every migrated item reads back identically through the issues arm.
#
# Scope (verified against the current board population, F#799-801/#808):
#   - Only Status and Component are migrated — the only two Projects fields
#     in live use. A board whose SCHEMA carries any other single-select
#     field, or a Status option outside {Backlog, Ready, In Progress, Done}
#     (the only vocabulary the issues arm has labels for — see
#     ISSUES-ONLY-BACKEND.md), refuses to run at all: "no invented mappings"
#     (acceptance #3) means unrecognized board shape is a hard stop, not a
#     best-effort partial migration.
#   - Host/Session claim stamps are deliberately NOT migrated. A live claim
#     re-mints its stamp on the issues backend the next time claim.sh runs,
#     so there is nothing worth carrying over — migrating a possibly-stale
#     stamp would just plant a confusing fossil label. Reported in the
#     mapping table so this is visible, not silent.
#   - Seq (worklist ordering) is out of scope on BOTH backends already
#     (board_set_number fails loud either way) and is untouched here.
#   - Milestones are backend-agnostic REST already (board_set_milestone /
#     board_active_milestones) and need no migration step.
#   - Scope is OPEN (non-Done) items only — board_item_list's Projects-v2
#     active-set default already excludes Done, and "Done" isn't a label on
#     the issues arm anyway (it's the issue being CLOSED, a GitHub-native
#     fact independent of which backend reads it).
#
# This script deliberately couples to BOTH arms for the SAME board number:
# board_set_status / board_set_component dispatch on the ISSUE_* item-id
# PREFIX (not on board_backend — see board.sh), so writing issues-arm labels
# for a board still configured backend=projects needs no boards.conf flip.
# It is expected to be retired once a later removal epic drops the
# Projects-v2 arm entirely — see ISSUES-ONLY-BACKEND.md.
#
# Usage:
#   migrate-board-to-issues.sh --board N [--board M ...]            # dry run (default)
#   migrate-board-to-issues.sh --board N [--board M ...] --apply    # write + verify
#
# Exit codes:
#   0  success — dry run: mapping table printed, zero writes; --apply: every
#      write succeeded and every item verified (or nothing needed writing).
#   1  a write failed, or a post-write verify mismatch was found.
#   2  usage error, board already backend=issues (nothing to read from the
#      Projects arm), a resolve failure, OR a board carries an unrecognized
#      field/option — refused BEFORE any write.
#
set -euo pipefail

export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-migrate-board-to-issues}"

# Resolve symlinks so the script finds its real lib/ even when invoked through
# a symlink (on PATH or from a consuming repo's scripts/ dir) — BASH_SOURCE
# points at the symlink, not the real file. Portable (no GNU readlink -f).
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$src")" && pwd)"
# shellcheck source=scripts/lib/board.sh
source "$SCRIPT_DIR/lib/board.sh"

# --- the known, migratable vocabulary --------------------------------------
# Deliberately the SAME sets ISSUES-ONLY-BACKEND.md documents. Anything
# outside these is "no invented mapping" territory — the run stops before
# writing rather than guessing a label. Indexed arrays (never associative —
# board.sh's own bash-3.2/macOS portability constraint applies here too), so
# a multi-word option name ("In Progress") survives intact.
_MIGRATE_KNOWN_FIELDS=("$BOARD_FIELD_STATUS" "$BOARD_FIELD_COMPONENT")
_MIGRATE_KNOWN_STATUS_OPTIONS=("$BOARD_OPT_BACKLOG" "$BOARD_OPT_READY" "$BOARD_OPT_INPROGRESS" "$BOARD_OPT_DONE")

# _migrate_in_list <needle> <hay1> [<hay2> ...] — true iff needle is one of
# the trailing args (an indexed-array expansion at the call site).
_migrate_in_list() {
  local needle="$1"; shift
  local w
  for w in "$@"; do [ "$w" = "$needle" ] && return 0; done
  return 1
}

# migrate_validate_schema <board> — validate <board>'s CURRENT schema
# (BOARD_FIELDS_JSON, already resolved via the Projects arm by the caller)
# against the known, migratable vocabulary above. Reports every unrecognized
# single-select field or Status option to stderr; returns 1 if anything was
# unrecognized, 0 (silent) when clean. Schema-level, not item-level: a
# legacy/unused option still declared on the field is caught here even if no
# CURRENT item happens to carry it, because a later item could still pick it
# up with no label to land on ("no invented mappings" — acceptance #3).
migrate_validate_schema() {
  local board="$1" bad=0 name opt

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! _migrate_in_list "$name" "${_MIGRATE_KNOWN_FIELDS[@]}"; then
      echo "  UNRECOGNIZED FIELD: '$name' is a single-select field on board $board's schema; this script only knows how to migrate '$BOARD_FIELD_STATUS' and '$BOARD_FIELD_COMPONENT' — no label mapping exists for it." >&2
      bad=1
    fi
  done < <(printf '%s' "$BOARD_FIELDS_JSON" | jq -r '.fields[] | select(.type=="ProjectV2SingleSelectField") | .name')

  while IFS= read -r opt; do
    [ -n "$opt" ] || continue
    if ! _migrate_in_list "$opt" "${_MIGRATE_KNOWN_STATUS_OPTIONS[@]}"; then
      echo "  UNRECOGNIZED STATUS OPTION: '$opt' is a declared option on board $board's $BOARD_FIELD_STATUS field, but the issues-only backend (ISSUES-ONLY-BACKEND.md) only has label vocabulary for: ${_MIGRATE_KNOWN_STATUS_OPTIONS[*]}." >&2
      bad=1
    fi
  done < <(printf '%s' "$BOARD_FIELDS_JSON" | jq -r --arg f "$BOARD_FIELD_STATUS" '.fields[] | select(.name==$f) | .options[]?.name')

  return "$bad"
}

# migrate_mapping_report <board> — print the field->label mapping table from
# <board>'s already-resolved Projects-arm BOARD_ITEMS_JSON. Read-only — safe
# in dry-run, and used as the preface to --apply too (acceptance #1).
migrate_mapping_report() {
  local board="$1" repo total
  repo="$(board_repo "$board")" || return 1
  total="$(printf '%s' "$BOARD_ITEMS_JSON" | jq '.items | length')"
  echo "Board $board ($repo) — Projects → issues label mapping ($total open item(s))"

  echo "  $BOARD_FIELD_STATUS -> fnd:status:*"
  printf '%s' "$BOARD_ITEMS_JSON" | jq -r '
    [.items[] | .status // "(none)"] | group_by(.) | map({k:.[0], n:length}) | sort_by(.k)[] | "\(.n)\t\(.k)"
  ' | while IFS=$'\t' read -r count opt; do
    [ -n "$count" ] || continue
    if [ "$opt" = "(none)" ]; then
      printf '    %-16s     %s item(s) — no Status set; left unlabeled on the issues arm\n' "(none)" "$count"
    else
      printf '    %-16s -> fnd:status:%-16s (%s item(s))\n' "$opt" "$(_board_issues_slug "$opt")" "$count"
    fi
  done

  echo "  $BOARD_FIELD_COMPONENT -> fnd:component:*"
  printf '%s' "$BOARD_ITEMS_JSON" | jq -r '
    [.items[] | .component // "(none)"] | group_by(.) | map({k:.[0], n:length}) | sort_by(.k)[] | "\(.n)\t\(.k)"
  ' | while IFS=$'\t' read -r count opt; do
    [ -n "$count" ] || continue
    if [ "$opt" = "(none)" ]; then
      printf '    %-16s     %s item(s) — no Component set; left unlabeled\n' "(none)" "$count"
    else
      printf '    %-16s -> fnd:component:%-16s (%s item(s))\n' "$opt" "$(_board_issues_slug "$opt")" "$count"
    fi
  done

  echo "  NOT migrated: $BOARD_FIELD_HOSTSESSION (a live claim re-mints its stamp on the issues backend on next claim.sh run — nothing to carry over), Seq (worklist ordering, out of scope on both backends already)"
}

# _migrate_diff_tsv <src-items-json> <cur-items-json> — one TSV row per item
# in <src-items-json>: "<issue#>\t<target-status>\t<target-component>\t
# <current-status>\t<current-component>\t<same|diff>". <cur-items-json> is an
# issues-arm item-list ({"items":[...]}); a src item absent from it reads as
# current status/component "".
#
# An empty status/component is emitted as the literal "(none)" sentinel,
# NEVER a bare empty field — @tsv's delimiter is a real tab, but bash `read`
# treats tab as "IFS whitespace" (collapsed like a space/newline) even when
# IFS is set to ONLY a tab, so a genuinely empty field silently swallows the
# delimiter and shifts every column after it (the exact footgun
# reconcile.sh's own `$stout` comment documents and works around the same
# way). _migrate_denone (below) is the inverse, applied right after every
# `read` of this TSV.
_migrate_diff_tsv() {
  jq -n -r --argjson src "$1" --argjson cur "$2" '
    def nz: if (. == "" or . == null) then "(none)" else . end;
    ($cur.items | map({(.content.number|tostring): {status:(.status//""), component:(.component//"")}}) | add // {}) as $curmap
    | $src.items[]
    | (.content.number|tostring) as $num
    | (.status // "") as $tstatus
    | (.component // "") as $tcomp
    | ($curmap[$num] // {status:"", component:""}) as $c
    | [$num, ($tstatus|nz), ($tcomp|nz), ($c.status|nz), ($c.component|nz),
       (if ($tstatus == $c.status and $tcomp == $c.component) then "same" else "diff" end)] | @tsv
  '
}

# _migrate_denone <value> — the shell-side inverse of _migrate_diff_tsv's
# "(none)" sentinel: prints "" for the sentinel, the value unchanged
# otherwise. Call on every field read out of a _migrate_diff_tsv row before
# using it as a real status/component value.
_migrate_denone() {
  [ "$1" = "(none)" ] && printf '' || printf '%s' "$1"
}

# migrate_apply <board> — write <board>'s Status/Component onto the issues
# arm (fnd: labels via board_set_status/board_set_component, which reuse
# _board_issues_set_field unchanged — acceptance #2), then VERIFY every item
# reads back identically through the issues arm. An item whose issues-arm
# value already matches the target is skipped entirely (not written), so a
# second run against unchanged Projects data reports zero changes
# (acceptance #4). Prints a per-repo report (acceptance #2). Returns 0 iff
# every write succeeded and every item verified; 1 otherwise.
migrate_apply() {
  local board="$1" repo src_json cur_json diff_tsv
  repo="$(board_repo "$board")" || return 1
  src_json="$BOARD_ITEMS_JSON"   # the Projects-arm read — captured before BOARD_ITEMS_JSON is reused below

  echo "Board $board ($repo) — applying…"
  cur_json="$(_board_issues_item_list "$board")" || { echo "  could not read the issues arm — aborting" >&2; return 1; }
  diff_tsv="$(_migrate_diff_tsv "$src_json" "$cur_json")"

  local num tstatus tcomp cstatus ccomp cls
  local n_same=0 n_diff=0 n_write_fail=0 ok
  while IFS=$'\t' read -r num tstatus tcomp cstatus ccomp cls; do
    [ -n "$num" ] || continue
    tstatus="$(_migrate_denone "$tstatus")"; tcomp="$(_migrate_denone "$tcomp")"
    cstatus="$(_migrate_denone "$cstatus")"; ccomp="$(_migrate_denone "$ccomp")"
    if [ "$cls" = "same" ]; then
      n_same=$((n_same + 1))
      continue
    fi
    n_diff=$((n_diff + 1))
    ok=1
    if [ -n "$tstatus" ] && [ "$tstatus" != "$cstatus" ]; then
      if board_set_status "ISSUE_$num" "$tstatus" "$BOARD_FIELD_STATUS"; then
        echo "  #$num  $BOARD_FIELD_STATUS -> $tstatus  (fnd:status:$(_board_issues_slug "$tstatus"))"
      else
        echo "  #$num  FAILED writing $BOARD_FIELD_STATUS -> $tstatus" >&2
        ok=0
      fi
    fi
    if [ -n "$tcomp" ] && [ "$tcomp" != "$ccomp" ]; then
      if board_set_component "ISSUE_$num" "$tcomp"; then
        echo "  #$num  $BOARD_FIELD_COMPONENT -> $tcomp  (fnd:component:$(_board_issues_slug "$tcomp"))"
      else
        echo "  #$num  FAILED writing $BOARD_FIELD_COMPONENT -> $tcomp" >&2
        ok=0
      fi
    fi
    [ "$ok" -eq 1 ] || n_write_fail=$((n_write_fail + 1))
  done <<<"$diff_tsv"

  echo "  $n_same already-correct item(s), $n_diff item(s) needed a write ($n_write_fail failed)"

  # --- verify: re-read the issues arm fresh and compare EVERY item ---------
  local verify_json verify_tsv n_ok=0 n_mismatch=0
  verify_json="$(_board_issues_item_list "$board")" || { echo "  could not re-read the issues arm to verify — aborting" >&2; return 1; }
  verify_tsv="$(_migrate_diff_tsv "$src_json" "$verify_json")"
  while IFS=$'\t' read -r num tstatus tcomp cstatus ccomp cls; do
    [ -n "$num" ] || continue
    tstatus="$(_migrate_denone "$tstatus")"; tcomp="$(_migrate_denone "$tcomp")"
    cstatus="$(_migrate_denone "$cstatus")"; ccomp="$(_migrate_denone "$ccomp")"
    if [ "$cls" = "same" ]; then
      n_ok=$((n_ok + 1))
    else
      n_mismatch=$((n_mismatch + 1))
      echo "  MISMATCH #$num — Projects says $BOARD_FIELD_STATUS='$tstatus' $BOARD_FIELD_COMPONENT='$tcomp' but the issues arm reads $BOARD_FIELD_STATUS='$cstatus' $BOARD_FIELD_COMPONENT='$ccomp'" >&2
    fi
  done <<<"$verify_tsv"

  echo "  verify (reading back through backend=issues): $n_ok/$((n_ok + n_mismatch)) item(s) match"

  if [ "$n_write_fail" -gt 0 ] || [ "$n_mismatch" -gt 0 ]; then
    return 1
  fi
  return 0
}

# migrate_board <board> <apply 0|1> — full pipeline for ONE board: resolve
# (Projects arm) -> validate schema -> mapping report -> (apply=1) apply +
# verify. Returns 0 on success; 1 on any write/verify failure; 2 on a resolve
# failure, an already-issues-only board, or an unrecognized field/option
# (validation always runs, and is always reported, BEFORE any write).
migrate_board() {
  local board="$1" apply="${2:-0}"

  if _board_is_issues_only "$board"; then
    echo "board $board is already configured backend=issues — nothing to read from the Projects arm" >&2
    return 2
  fi
  board_resolve "$board" || { echo "board $board: could not resolve (Projects arm) — rate limit or auth?" >&2; return 2; }

  if ! migrate_validate_schema "$board"; then
    echo "Board $board — refusing to migrate: unrecognized field/option reported above (no invented mappings). Fix the board's schema and re-run." >&2
    return 2
  fi

  migrate_mapping_report "$board"

  if [ "$apply" -eq 0 ]; then
    echo "  0 writes (dry run — pass --apply to write)"
    return 0
  fi

  migrate_apply "$board"
}

# Execute-guard: parse argv and run only when this file is RUN, not SOURCED —
# a test sources it (its own execute-guard suppresses the auto-run) and calls
# migrate_validate_schema / migrate_mapping_report / migrate_apply /
# migrate_board directly against a fake _board_gh, mirroring reconcile.sh /
# test_issues_backend.sh's own sourcing convention.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  APPLY=0
  BOARDS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --board)
        b="$(board_resolve_name "${2:?--board needs a value}")" || exit 2
        BOARDS+=("$b")
        shift 2 ;;
      --apply) APPLY=1; shift ;;
      *) echo "usage: migrate-board-to-issues.sh --board N [--board M ...] [--apply]" >&2; exit 2 ;;
    esac
  done
  [ "${#BOARDS[@]}" -gt 0 ] || { echo "usage: migrate-board-to-issues.sh --board N [--board M ...] [--apply]" >&2; exit 2; }

  rc=0
  for b in "${BOARDS[@]}"; do
    migrate_board "$b" "$APPLY" || rc=$?
    [ "$rc" -eq 0 ] || break
  done
  exit "$rc"
fi
