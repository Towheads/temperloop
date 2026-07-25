#!/usr/bin/env bash
#
# validate-prose-budget.sh — two-tier CI prose-budget gate (temperloop#719,
# item prose-budget-gate / #725; ADR 0015).
#
# TIER-1: fails when the composed KERNEL-AUTHORED render (claude/
#         CLAUDE.kernel.md rendered through install-claude-md.sh's
#         INSTALL_CLAUDE_MD_KERNEL_ONLY seam — never the kernel+overlay
#         total) exceeds PROSE_BUDGET_TIER1_CAP lines.
# TIER-2: fails when ANY tracked claude/**/*.md file (agent charters
#         included) exceeds PROSE_BUDGET_TIER2_FILE_CAP lines — ONE uniform
#         per-file cap, never a per-file table (a per-file value would just
#         be a relocated exemption mechanism; this gate has none).
#
# Both counts come from workflows/scripts/count-prose.sh's own stdout report
# — this script re-implements NEITHER the compose-seam invocation nor the
# per-file `wc` walk (ADR 0015, "one compose seam"). It only PARSES that
# report and compares the two numbers it already carries against the two cap
# knobs. This is also why this gate is exactly as host-deterministic as
# count-prose.sh itself (see that script's own header) — nothing here adds a
# second, independently-driftable counting path.
#
# Ratchet: PROSE_BUDGET_TIER1_CAP / PROSE_BUDGET_TIER2_FILE_CAP (defaulted in
# workflows/scripts/build/build.config.sh, registered in
# workflows/scripts/config/knob-registry.tsv) are seeded at the measured
# baseline, so this gate is green on the unmodified tree by construction and
# blocks no unrelated PR. A cap is lowered again only by a later config PR
# (after a subtraction pass actually shrinks the prose) or raised by a config
# PR when new prose is deliberately added — never dodged by editing THIS
# script.
#
# Failure message contract (epic #719 Contract, Produces #4): every
# violation names the FILE, its COUNT, its CAP, and both remediation paths
# (trim the prose, or open a config PR raising the cap — build.config.sh's
# knob default AND its knob-registry.tsv row, in the SAME PR, per
# check-knob-registry.sh's equality lint). A TIER-1 failure additionally
# prints the full TIER-2 per-file breakdown alongside the composed total, so
# a seam-only regression (composed count grows, every per-file count stays
# flat) is attributable on sight, with no second investigation step.
#
# CITATION-MARKER presence check (temperloop#719, item citation-markers /
# #724): alongside the two size caps, this gate reconciles the tree's
# same-line `<!-- cite: <row-id> <class>:<ref> -->` markers 1:1 against
# workflows/scripts/config/citation-registry.tsv — the registry IS the
# mechanical definition of "a standing kernel rule needing a marker" (see
# claude/citation-schema.md for the grammar, classes, and placement rules).
# Enforced both directions over the SAME tracked file set the TIER-2 table
# already carries (no second file-walk): a registry row whose marker is
# missing or duplicated in its file is red; a marker found in any tracked
# claude/**/*.md file with no registry row for that file is red; any
# `<!-- cite:` occurrence outside a fenced code block that does not parse
# to the grammar is red. Markers are zero-line-growth by construction
# (same-line HTML comments), so this check never fights the size caps.
#
# Usage:
#   workflows/scripts/validate-prose-budget.sh
#
# Env overrides (fixture-driven tests):
#   CITATION_REGISTRY_FILE path to the citation registry TSV (default: the
#                          tracked workflows/scripts/config/
#                          citation-registry.tsv). knob:exempt — fixture
#                          seam, same rationale as COUNT_PROSE_BIN.
#   COUNT_PROSE_ROOT       forwarded verbatim to count-prose.sh (its own
#                          test/fixture root override — see that script's
#                          header). A fixture pointing this at a scratch git
#                          checkout with a MODIFIED install-claude-md.sh (a
#                          compose-seam change) but byte-identical
#                          claude/**/*.md files demonstrates the tier-1-only
#                          breach case: composed count grows, every per-file
#                          count stays exactly the baseline value.
#   COUNT_PROSE_BIN        path to the count-prose.sh script itself (default:
#                          the sibling count-prose.sh next to this script).
#                          knob:exempt — test-double seam, not an
#                          operator-facing config-precedence default (mirrors
#                          count-prose.sh's own COUNT_PROSE_ROOT rationale).
#   PROSE_BUDGET_TIER1_CAP, PROSE_BUDGET_TIER2_FILE_CAP   override the
#                          build.config.sh knob defaults directly — the
#                          fixture red/green demonstrations use this to
#                          exercise a deliberate overage without editing
#                          build.config.sh (rung 2, env, always outranks
#                          rung 5's tracked default per the six-rung ladder).
#
# Kept bash-3.2-portable (no associative arrays, no mapfile) so it runs on
# the macOS dev shell as well as Linux CI, matching every other
# workflows/scripts/*.sh checker in this family.

set -uo pipefail

# This script lives at workflows/scripts/validate-prose-budget.sh — the
# same directory as count-prose.sh — so REPO_ROOT is TWO levels up from
# SCRIPT_DIR, matching that script's own resolution exactly.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

: "${COUNT_PROSE_ROOT:=$REPO_ROOT}"  # knob:exempt — forwarded verbatim to count-prose.sh, whose own identical seam carries this same marker (test/fixture root override, not an operator-facing config-precedence default)
: "${COUNT_PROSE_BIN:=$SCRIPT_DIR/count-prose.sh}"  # knob:exempt — test-double seam (fixture: a modified compose seam under a scratch COUNT_PROSE_ROOT tree)
: "${CITATION_REGISTRY_FILE:=$REPO_ROOT/workflows/scripts/config/citation-registry.tsv}"  # knob:exempt — fixture seam (a scratch registry against a scratch COUNT_PROSE_ROOT tree), not an operator-facing config-precedence default

[ -f "$COUNT_PROSE_BIN" ] || { echo "validate-prose-budget: counting script not found: $COUNT_PROSE_BIN" >&2; exit 1; }

# Cap knobs: sourced from build.config.sh (tracked-repo rung 5) unless a
# caller already exported them (rung 2 — an env override — wins per the
# normal six-rung precedence ladder; this is exactly the seam the fixture
# red/green demonstrations below use).
if [ -f "$REPO_ROOT/workflows/scripts/build/build.config.sh" ]; then
  # shellcheck source=workflows/scripts/build/build.config.sh
  source "$REPO_ROOT/workflows/scripts/build/build.config.sh"
fi
: "${PROSE_BUDGET_TIER1_CAP:?PROSE_BUDGET_TIER1_CAP is unset — build.config.sh missing, or the knob was removed}"
: "${PROSE_BUDGET_TIER2_FILE_CAP:?PROSE_BUDGET_TIER2_FILE_CAP is unset — build.config.sh missing, or the knob was removed}"
case "$PROSE_BUDGET_TIER1_CAP" in ''|*[!0-9]*) echo "validate-prose-budget: PROSE_BUDGET_TIER1_CAP is not a positive integer: '$PROSE_BUDGET_TIER1_CAP'" >&2; exit 1 ;; esac
case "$PROSE_BUDGET_TIER2_FILE_CAP" in ''|*[!0-9]*) echo "validate-prose-budget: PROSE_BUDGET_TIER2_FILE_CAP is not a positive integer: '$PROSE_BUDGET_TIER2_FILE_CAP'" >&2; exit 1 ;; esac

# ---------------------------------------------------------------------------
# Run count-prose.sh and parse its report. Never re-derive either number.
#
# stdout and stderr are captured SEPARATELY (never merged via 2>&1) — a
# merged stream makes line POSITION meaningless: any benign stderr line
# (a git-advice notice, a warning count-prose.sh itself emits) landing
# before the real TIER-1 line would either shift it out of "line 1" (a
# spurious "parser drift" red) or, worse, itself be a stray digit-only line
# mistaken for the count. stderr is captured to a scratch file and surfaced
# only in the failure path below, never fed to the parser.
# ---------------------------------------------------------------------------
tmp_err="$(mktemp "${TMPDIR:-/tmp}/validate-prose-budget.stderr.XXXXXX")"
trap 'rm -f "$tmp_err"' EXIT

report="$(COUNT_PROSE_ROOT="$COUNT_PROSE_ROOT" bash "$COUNT_PROSE_BIN" 2>"$tmp_err")"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "validate-prose-budget: count-prose.sh failed (exit $rc) — cannot evaluate the budget:" >&2
  printf '%s\n' "$report" >&2
  [ -s "$tmp_err" ] && cat "$tmp_err" >&2
  exit 1
fi

# tier-1: locate the "TIER-1 kernel-authored composed render: NNN lines"
# line ANYWHERE in the (stdout-only) report by its full, anchored content —
# never by its POSITION (e.g. `sed -n '1p'`), which a stray leading line
# (from either stream) would silently defeat — and never by a bare
# digit-run search, which would match the literal "1" in "TIER-1" itself
# before ever reaching the real count (see test_count_prose.sh's own
# extract_tier1 for the same fix, applied here identically). `head -1`
# guards against a hypothetical duplicate match rather than trusting
# uniqueness.
tier1_count="$(printf '%s\n' "$report" | sed -n -E 's/^TIER-1 kernel-authored composed render: ([0-9]+) lines$/\1/p' | head -1)"
case "$tier1_count" in
  ''|*[!0-9]*)
    echo "validate-prose-budget: could not parse a TIER-1 line count from count-prose.sh's report — parser drift against that script's output format?" >&2
    printf '%s\n' "$report" >&2
    exit 1
    ;;
esac

# tier-2: the per-file table between the "TIER-2 per-file line counts"
# header and the blank line before "TIER-2 total: ...". Each row is
# `printf '%8d  %s\n'` in count-prose.sh — right-justified count, two
# spaces, path.
tier2_files=()
tier2_counts=()
in_table=0
while IFS= read -r line; do
  case "$line" in
    "TIER-2 per-file line counts"*)
      in_table=1
      continue
      ;;
  esac
  if [ "$in_table" -eq 1 ]; then
    if [ -z "$line" ]; then
      in_table=0
      continue
    fi
    cnt="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+.*$/\1/')"
    fpath="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//')"
    case "$cnt" in
      ''|*[!0-9]*) continue ;;  # not a data row (shouldn't happen; defensive)
    esac
    tier2_files+=("$fpath")
    tier2_counts+=("$cnt")
  fi
done <<REPORT_EOF
$report
REPORT_EOF

if [ "${#tier2_files[@]}" -eq 0 ]; then
  echo "validate-prose-budget: parsed zero TIER-2 files from count-prose.sh's report — parser drift against that script's output format?" >&2
  printf '%s\n' "$report" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Evaluate both tiers. Collect ALL violations before failing (same
# collect-then-exit-nonzero shape as scripts/quality-gates.sh itself), so one
# run surfaces every offending file instead of one per re-run.
# ---------------------------------------------------------------------------
fail=0
violations=0
tier2_max=0

i=0
while [ "$i" -lt "${#tier2_files[@]}" ]; do
  f="${tier2_files[$i]}"
  c="${tier2_counts[$i]}"
  if [ "$c" -gt "$tier2_max" ]; then
    tier2_max="$c"
  fi
  if [ "$c" -gt "$PROSE_BUDGET_TIER2_FILE_CAP" ]; then
    fail=1
    violations=$((violations + 1))
    echo "PROSE-BUDGET TIER-2: $f: $c lines exceeds the per-file cap of $PROSE_BUDGET_TIER2_FILE_CAP lines (PROSE_BUDGET_TIER2_FILE_CAP)"
    echo "  Remediation: trim $f back under the cap, OR open a config PR raising PROSE_BUDGET_TIER2_FILE_CAP in workflows/scripts/build/build.config.sh (+ its workflows/scripts/config/knob-registry.tsv row, in the SAME PR)"
  fi
  i=$((i + 1))
done

if [ "$tier1_count" -gt "$PROSE_BUDGET_TIER1_CAP" ]; then
  fail=1
  violations=$((violations + 1))
  [ "$violations" -gt 1 ] && echo
  echo "PROSE-BUDGET TIER-1: composed kernel-authored render is $tier1_count lines, exceeding the cap of $PROSE_BUDGET_TIER1_CAP lines (PROSE_BUDGET_TIER1_CAP)"
  echo "  Remediation: trim claude/CLAUDE.kernel.md (or whatever compose-seam change inflated the render) back under the cap, OR open a config PR raising PROSE_BUDGET_TIER1_CAP in workflows/scripts/build/build.config.sh (+ its workflows/scripts/config/knob-registry.tsv row, in the SAME PR)"
  echo
  echo "  Full TIER-2 per-file breakdown, for seam-attribution — every count here matching a prior green run means this IS a compose-seam-only regression (zero per-file prose change), not a per-file overage:"
  printf '%s\n' "$report" | sed -n '/^TIER-2 per-file line counts/,$p' | sed 's/^/  /'
fi

# ---------------------------------------------------------------------------
# Citation-marker presence check (item citation-markers / #724).
#
# The registry (row-id <TAB> file) is the single mechanical definition of the
# rule set; the tree's markers must reconcile 1:1 against it, both
# directions, over exactly the TIER-2 tracked file set parsed above. Fence-
# aware: a marker inside a fenced code block is ignored (that is how
# claude/citation-schema.md displays the grammar without registering it).
# Bash-3.2 portable: pair sets go through temp files + sort/comm/uniq, never
# associative arrays.
# ---------------------------------------------------------------------------
marker_grammar='<!-- cite: [A-Z]+\.[0-9]+ (incident|guard|class|keep):[^[:space:]]+ -->'

reg_pairs="$(mktemp "${TMPDIR:-/tmp}/validate-prose-budget.reg.XXXXXX")"
found_pairs="$(mktemp "${TMPDIR:-/tmp}/validate-prose-budget.found.XXXXXX")"
trap 'rm -f "$tmp_err" "$reg_pairs" "$found_pairs"' EXIT

if [ ! -f "$CITATION_REGISTRY_FILE" ]; then
  echo "validate-prose-budget: citation registry not found: $CITATION_REGISTRY_FILE (CITATION_REGISTRY_FILE)" >&2
  exit 1
fi

# parse the registry: `<row-id><TAB><file>`, #-comments and blank lines
# ignored; a malformed data row is a violation (never silently skipped).
reg_lineno=0
while IFS= read -r rline || [ -n "$rline" ]; do
  reg_lineno=$((reg_lineno + 1))
  case "$rline" in ''|\#*) continue ;; esac
  rid="${rline%%	*}"
  rfile="${rline#*	}"
  if [ "$rid" = "$rline" ] || [ -z "$rfile" ] || ! printf '%s' "$rid" | grep -qE '^[A-Z]+\.[0-9]+$'; then
    fail=1
    violations=$((violations + 1))
    echo "CITATION-MARKERS: $CITATION_REGISTRY_FILE:$reg_lineno: malformed registry row (expected '<ROW-ID><TAB><file>'): $rline"
    continue
  fi
  printf '%s\t%s\n' "$rid" "$rfile" >>"$reg_pairs"
done <"$CITATION_REGISTRY_FILE"

# duplicate registry rows are themselves a defect (the 1:1 contract needs a
# set, not a bag).
while IFS= read -r dup; do
  [ -z "$dup" ] && continue
  fail=1
  violations=$((violations + 1))
  echo "CITATION-MARKERS: duplicate registry row: ${dup}"
done <<REG_DUP_EOF
$(LC_ALL=C sort "$reg_pairs" | uniq -d)
REG_DUP_EOF

# every registry file must be in the tracked TIER-2 set (a row pointing at an
# untracked/renamed file would otherwise surface as a misleading "missing
# marker").
tier2_list="$(printf '%s\n' "${tier2_files[@]}")"
while IFS= read -r rfile; do
  [ -z "$rfile" ] && continue
  if ! printf '%s\n' "$tier2_list" | grep -qxF "$rfile"; then
    fail=1
    violations=$((violations + 1))
    echo "CITATION-MARKERS: registry names a file not in the tracked claude/**/*.md set: $rfile"
    echo "  Remediation: fix the citation-registry.tsv row (renamed/deleted file?), or track the file"
  fi
done <<REG_FILES_EOF
$(cut -f2 "$reg_pairs" | LC_ALL=C sort -u)
REG_FILES_EOF

# scan every tracked file for markers, fence-aware; collect (row-id, file)
# pairs and flag any `<!-- cite:` occurrence that does not parse.
for f in "${tier2_files[@]}"; do
  fpath="$COUNT_PROSE_ROOT/$f"
  [ -f "$fpath" ] || continue  # defensive; count-prose just listed it
  while IFS= read -r cand; do
    [ -z "$cand" ] && continue
    lineno="${cand%%	*}"
    # strip backtick code spans first (same rationale as check-knob-prose.sh):
    # a `<!-- cite:` shown in code font is a quotation, never a live marker.
    # The quoting is a literal sed program, not a missed expansion.
    # shellcheck disable=SC2016
    ltext="$(printf '%s' "${cand#*	}" | sed -E 's/`[^`]*`//g')"
    raw_n="$(printf '%s' "$ltext" | grep -o '<!-- cite:' | wc -l | tr -d '[:space:]')"
    parsed="$(printf '%s' "$ltext" | grep -oE "$marker_grammar" || true)"
    parsed_n=0
    if [ -n "$parsed" ]; then
      parsed_n="$(printf '%s\n' "$parsed" | grep -c . | tr -d '[:space:]')"
      while IFS= read -r m; do
        rid="$(printf '%s' "$m" | sed -E 's/^<!-- cite: ([A-Z]+\.[0-9]+) .*$/\1/')"
        printf '%s\t%s\n' "$rid" "$f" >>"$found_pairs"
      done <<PARSED_EOF
$parsed
PARSED_EOF
    fi
    if [ "$raw_n" -ne "$parsed_n" ]; then
      fail=1
      violations=$((violations + 1))
      echo "CITATION-MARKERS: $f:$lineno: malformed citation marker (does not parse as '<!-- cite: <ROW-ID> <incident|guard|class|keep>:<ref> -->'):"
      echo "    $ltext"
      echo "  Remediation: fix the marker to the grammar in claude/citation-schema.md"
    fi
  done <<CAND_EOF
$(awk '/^[[:space:]]*```/ { fence = !fence; next } !fence && index($0, "<!-- cite:") { printf "%d\t%s\n", FNR, $0 }' "$fpath")
CAND_EOF
done

sorted_reg="$(LC_ALL=C sort -u "$reg_pairs")"
sorted_found_u="$(LC_ALL=C sort -u "$found_pairs")"

# registry rows with no marker in their file.
while IFS= read -r miss; do
  [ -z "$miss" ] && continue
  rid="${miss%%	*}"
  rfile="${miss#*	}"
  fail=1
  violations=$((violations + 1))
  echo "CITATION-MARKERS: missing marker: registered rule $rid has no '<!-- cite: $rid ...' marker in $rfile"
  echo "  Remediation: add the rule's same-line marker (claude/citation-schema.md), or remove the citation-registry.tsv row if the rule was deliberately deleted"
done <<MISS_EOF
$(LC_ALL=C comm -23 <(printf '%s\n' "$sorted_reg") <(printf '%s\n' "$sorted_found_u"))
MISS_EOF

# markers with no registry row.
while IFS= read -r extra; do
  [ -z "$extra" ] && continue
  rid="${extra%%	*}"
  rfile="${extra#*	}"
  fail=1
  violations=$((violations + 1))
  echo "CITATION-MARKERS: unregistered marker: $rfile carries '<!-- cite: $rid ...' but citation-registry.tsv has no ($rid, $rfile) row"
  echo "  Remediation: add the registry row in the same change, or remove the stray marker"
done <<EXTRA_EOF
$(LC_ALL=C comm -13 <(printf '%s\n' "$sorted_reg") <(printf '%s\n' "$sorted_found_u"))
EXTRA_EOF

# duplicated markers (a registered pair appearing more than once in the tree).
while IFS= read -r dup; do
  [ -z "$dup" ] && continue
  rid="${dup%%	*}"
  rfile="${dup#*	}"
  fail=1
  violations=$((violations + 1))
  echo "CITATION-MARKERS: duplicate marker: '<!-- cite: $rid ...' appears more than once in $rfile (the registry contract is exactly once per row)"
done <<DUP_EOF
$(LC_ALL=C sort "$found_pairs" | uniq -d)
DUP_EOF

reg_count="$(printf '%s\n' "$sorted_reg" | grep -c . | tr -d '[:space:]')"

echo
if [ "$fail" -ne 0 ]; then
  echo "FAIL: $violations prose-budget violation(s)" >&2
  exit 1
fi
echo "OK — prose budget clean: tier-1 $tier1_count/$PROSE_BUDGET_TIER1_CAP lines; tier-2 ${#tier2_files[@]} file(s) checked against a $PROSE_BUDGET_TIER2_FILE_CAP-line uniform cap (largest: $tier2_max lines); citation markers: $reg_count registry row(s) reconciled 1:1"
