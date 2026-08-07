#!/usr/bin/env bash
#
# Subset-lint: issue-state.sh's `resolve` label-constant set MUST be a
# subset of pipeline-tick.sh's label set (temperloop #635 spike verdict § (a)
# — "shared label/state VOCABULARY with thin adapters, NOT a shared
# classifier lib. A subset-lint test asserts resolve's label-constant set
# is subset-of pipeline-tick's (no parallel taxonomy).").
#
# MECHANICAL, not hand-inspection: greps issue-state.sh's own
# `ISSUE_STATE_LABEL_*` constant block (see that file's header comment
# above the block — "the subset-lint greps THIS block mechanically") for
# every literal label string / PIPELINE_*_LABEL setting name it declares, then
# checks each one is a literal pipeline-tick.sh already reads: either a bare
# string pipeline-tick.sh grep-matches directly (`needs-clarification`,
# `spike`, `decision`), or a `${PIPELINE_..._LABEL` setting reference
# pipeline-tick.sh sources/reads under the same name
# (`PIPELINE_ESCALATED_LABEL`, `PIPELINE_MERGE_PENDING_LABEL`).
#
# This is a LABEL-set subset check only (the acceptance bar's own scope,
# per the spike verdict: "resolve's route: names are its own surface —
# they are not required to be a subset — only the LABEL set is").

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE_STATE="$HERE/../issue-state.sh"
PIPELINE_TICK="$HERE/../pipeline-tick.sh"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

[ -f "$ISSUE_STATE" ] || { echo "test_issue_state_label_subset: missing $ISSUE_STATE" >&2; exit 1; }
[ -f "$PIPELINE_TICK" ] || { echo "test_issue_state_label_subset: missing $PIPELINE_TICK" >&2; exit 1; }

# Extract every ISSUE_STATE_LABEL_* constant's RHS from issue-state.sh —
# either a quoted literal (ISSUE_STATE_LABEL_X="literal") or a setting
# reference (ISSUE_STATE_LABEL_X="$SOME_SETTING").
# bash 3.2 (macOS /bin/bash) has no `mapfile`/`readarray` — read into the
# array with a portable while-loop over process substitution instead.
constants=()
while IFS= read -r _line; do
  [ -n "$_line" ] && constants+=("$_line")
done < <(
  grep -oE '^ISSUE_STATE_LABEL_[A-Z_]+="[^"]*"' "$ISSUE_STATE" \
    | sed -E 's/^ISSUE_STATE_LABEL_[A-Z_]+="([^"]*)"$/\1/'
)

if [ "${#constants[@]}" -eq 0 ]; then
  bad "extraction" "found zero ISSUE_STATE_LABEL_* constants in $ISSUE_STATE — extraction regex may be stale"
fi

for c in "${constants[@]}"; do
  case "$c" in
    '$'*)
      # A setting reference, e.g. $PIPELINE_ESCALATED_LABEL — strip the sigil and
      # confirm pipeline-tick.sh reads (sources or defaults) that SAME setting name.
      setting="${c#\$}"
      if grep -qE "\\\$\\{?${setting}\\b" "$PIPELINE_TICK"; then
        ok "setting $setting is read by pipeline-tick.sh (subset holds)"
      else
        bad "setting-subset" "$setting is not referenced anywhere in pipeline-tick.sh"
      fi
      ;;
    *)
      # A bare literal label string — confirm pipeline-tick.sh contains that
      # exact literal somewhere (its own label-matching jq/grep calls).
      if grep -qF "$c" "$PIPELINE_TICK"; then
        ok "literal '$c' appears in pipeline-tick.sh (subset holds)"
      else
        bad "literal-subset" "'$c' does not appear anywhere in pipeline-tick.sh"
      fi
      ;;
  esac
done

echo
echo "issue-state label subset-lint: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
