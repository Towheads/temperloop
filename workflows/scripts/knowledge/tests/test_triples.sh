#!/usr/bin/env bash
#
# test_triples.sh — tests for workflows/scripts/knowledge/triples.sh
# (epic Towheads/temperloop#1910, item "triples-extractor").
#
# A throwaway fixture tree (TRIPLES_REPO_ROOT) carries a minimal citation
# registry + marked-up rule file, a two-ADR supersession chain, and a
# synthetic issue-touches/claims lake (TRIPLES_RAW_DIR / ISSUE_TOUCHES_RAW_DIR
# / CLAIMS_RAW_DIR) — the real workflows/scripts/config/{ontology-registry,
# join-keys-lib,join-keys}.tsv/.sh are copied in verbatim (static, tracked,
# offline reads — no network, no live external system) so the ontology
# predicate check and the join-key normalization run against the SAME
# source of truth production does, without touching this checkout's own
# live repo tree. Zero network; every path stays under the test's own
# mktemp dir.
#
# COVERS (mapped to the item's acceptance bullets):
#   1. `build` reads the citation registry + markers, the issue-touches /
#      claims lake streams (session ids resolved through join-keys-lib.sh),
#      and appends {s,p,o,provenance:{file,record}} triples to
#      triples-<YYYY-MM>.jsonl.
#   2. `query cites` / `query touched_by` / `query supersedes` golden
#      fixtures.
#   3. Predicates are drawn from the ontology registry's edge alphabet: an
#      unlisted predicate is a hard, loud error (RED without the edge row,
#      GREEN with it restored — the discrimination proof).
#   4. A citation marker whose (row-id, file) pair is NOT the registered
#      pair is never turned into a triple (mirrors the citation-registry
#      validator's own reconciliation).
#   5. A touch/claim record with an absent or non-UUID session id is
#      skipped, never coerced into a triple.
#   6. `build` run twice never doubles the lake (idempotent re-derivation).

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNOWLEDGE_DIR="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$KNOWLEDGE_DIR/../../.." && pwd)"
TRIPLES="$KNOWLEDGE_DIR/triples.sh"

[ -f "$TRIPLES" ] || { echo "FATAL: triples.sh not found at $TRIPLES" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-triples.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
check_eq() { # <desc> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi
}
check() { # <desc> <cmd...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d" "command failed: $*"; fi
}
check_not() {
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$d" "command unexpectedly succeeded: $*"; else ok "$d"; fi
}

# ── fixture tree ────────────────────────────────────────────────────────
FX="$WORK/fx"
mkdir -p "$FX/workflows/scripts/config" "$FX/docs/adr" "$FX/rule-files" "$FX/lake"

cp "$REPO/workflows/scripts/config/ontology-registry.tsv" "$FX/workflows/scripts/config/ontology-registry.tsv"
cp "$REPO/workflows/scripts/config/join-keys-lib.sh" "$FX/workflows/scripts/config/join-keys-lib.sh"
cp "$REPO/workflows/scripts/config/join-keys.tsv" "$FX/workflows/scripts/config/join-keys.tsv"

cat >"$FX/workflows/scripts/config/citation-registry.tsv" <<'EOF'
# fixture citation registry
FX.1	rule-files/registered.md
EOF

cat >"$FX/rule-files/registered.md" <<'EOF'
A standing rule with its own marker. <!-- cite: FX.1 incident:F#1050 -->
EOF

# A SECOND file carries the SAME row id but is NOT the registered pair for
# it — this marker must never become a triple (acceptance bullet 4 above).
cat >"$FX/rule-files/unregistered.md" <<'EOF'
A different file, same row id, wrong pairing. <!-- cite: FX.1 guard:some/other/path.sh -->
EOF

cat >"$FX/docs/adr/0000-first.md" <<'EOF'
---
title: "0000: first"
---

## Status

Superseded by ADR-0001

## Context

old decision
EOF

cat >"$FX/docs/adr/0001-second.md" <<'EOF'
---
title: "0001: second"
---

## Status

Accepted

## Context

new decision
EOF

cat >"$FX/lake/issue-touches-2026-01.jsonl" <<'EOF'
{"schema_version":"1","ts":"2026-01-05T00:00:00Z","repo":"acme/widgets","issue":42,"session_id":"4d8b1d3e-1234-4a5b-9c3d-0a1b2c3d4e5f","host":"mini","kind":"pr-open"}
{"schema_version":"1","ts":"2026-01-06T00:00:00Z","repo":"acme/widgets","issue":43,"session_id":"","host":"mini","kind":"capture"}
{"schema_version":"1","ts":"2026-01-07T00:00:00Z","repo":"acme/widgets","issue":44,"session_id":"not-a-uuid","host":"mini","kind":"merge"}
EOF

cat >"$FX/lake/claims-2026-01.jsonl" <<'EOF'
{"ts":"2026-01-05T00:00:00Z","host":"mini","session_id":"4d8b1d3e-1234-4a5b-9c3d-0a1b2c3d4e5f","board":7,"issue":42,"item_id":"IT_1"}
EOF

run_build() { # -> BUILD_OUT / BUILD_RC
  BUILD_OUT="$(TRIPLES_REPO_ROOT="$FX" TRIPLES_RAW_DIR="$FX/out" \
    ISSUE_TOUCHES_RAW_DIR="$FX/lake" CLAIMS_RAW_DIR="$FX/lake" \
    bash "$TRIPLES" build 2>"$WORK/err.txt")"
  BUILD_RC=$?
}
run_query() { # <verb> <arg> -> QUERY_OUT / QUERY_RC
  QUERY_OUT="$(TRIPLES_REPO_ROOT="$FX" TRIPLES_RAW_DIR="$FX/out" \
    bash "$TRIPLES" query "$1" "$2" 2>"$WORK/err.txt")"
  QUERY_RC=$?
}
lake_lines() { cat "$FX/out"/triples-*.jsonl 2>/dev/null | wc -l | tr -d ' '; }

echo "── 1. build derives one triple per source, with schema_version + provenance ──"
run_build
check_eq "build exits 0" "0" "$BUILD_RC"
check_eq "cites count == 1" "1" "$(jq -r '.predicates.cites' <<<"$BUILD_OUT")"
check_eq "touched_by count == 1 (the two bad-session records are skipped)" "1" "$(jq -r '.predicates.touched_by' <<<"$BUILD_OUT")"
check_eq "claimed_by count == 1" "1" "$(jq -r '.predicates.claimed_by' <<<"$BUILD_OUT")"
check_eq "supersedes count == 1" "1" "$(jq -r '.predicates.supersedes' <<<"$BUILD_OUT")"
check_eq "4 lines land in the lake" "4" "$(lake_lines)"

cites_row="$(cat "$FX/out"/triples-*.jsonl | jq -c 'select(.p == "cites")')"
check_eq "cites: s is the row id" "FX.1" "$(jq -r '.s' <<<"$cites_row")"
check_eq "cites: o is class:ref verbatim from the marker" "incident:F#1050" "$(jq -r '.o' <<<"$cites_row")"
check_eq "cites: schema_version present" "1" "$(jq -r '.schema_version' <<<"$cites_row")"
check_eq "cites: provenance.file is the registered rule file" "rule-files/registered.md" "$(jq -r '.provenance.file' <<<"$cites_row")"
check_eq "cites: provenance.record names the marker's line" "L1" "$(jq -r '.provenance.record' <<<"$cites_row")"

echo "── 2. a marker sharing a row id but NOT the registered (row-id, file) pair is never a triple ──"
check_not "the unregistered.md marker produced no cites row" \
  bash -c "cat '$FX/out'/triples-*.jsonl | jq -e 'select(.p == \"cites\" and .provenance.file == \"rule-files/unregistered.md\")' | grep . >/dev/null"

echo "── 3. touched_by / claimed_by resolve session ids through join-keys-lib.sh into host:sess8 ──"
touch_row="$(cat "$FX/out"/triples-*.jsonl | jq -c 'select(.p == "touched_by")')"
check_eq "touched_by: s is <repo>#<issue>" "acme/widgets#42" "$(jq -r '.s' <<<"$touch_row")"
check_eq "touched_by: o is the host:sess8 stamp (join-keys-normalized)" "mini:4d8b1d3e" "$(jq -r '.o' <<<"$touch_row")"
claim_row="$(cat "$FX/out"/triples-*.jsonl | jq -c 'select(.p == "claimed_by")')"
check_eq "claimed_by: s is board:<board>#<issue> (claims carries no repo)" "board:7#42" "$(jq -r '.s' <<<"$claim_row")"
check_eq "claimed_by: o is the same host:sess8 stamp shape" "mini:4d8b1d3e" "$(jq -r '.o' <<<"$claim_row")"

echo "── 4. an absent or non-UUID session id is skipped, never coerced into a triple ──"
check_not "issue 43 (blank session_id) produced no touched_by row" \
  bash -c "cat '$FX/out'/triples-*.jsonl | jq -e 'select(.p == \"touched_by\" and (.s | endswith(\"#43\")))' | grep . >/dev/null"
check_not "issue 44 (not-a-uuid session_id) produced no touched_by row" \
  bash -c "cat '$FX/out'/triples-*.jsonl | jq -e 'select(.p == \"touched_by\" and (.s | endswith(\"#44\")))' | grep . >/dev/null"

echo "── 5. supersedes reads docs/adr/*.md's own Status section ──"
super_row="$(cat "$FX/out"/triples-*.jsonl | jq -c 'select(.p == "supersedes")')"
check_eq "supersedes: s is the superseding ADR" "ADR-0001" "$(jq -r '.s' <<<"$super_row")"
check_eq "supersedes: o is the superseded ADR" "ADR-0000" "$(jq -r '.o' <<<"$super_row")"
check_eq "supersedes: provenance.file is the OLD (superseded) ADR file" "docs/adr/0000-first.md" "$(jq -r '.provenance.file' <<<"$super_row")"

echo "── 6. build is idempotent per month: a second run appends nothing new ──"
run_build
check_eq "second build exits 0" "0" "$BUILD_RC"
check_eq "second build appends 0" "0" "$(jq -r '.appended' <<<"$BUILD_OUT")"
check_eq "second build reports 4 skipped duplicates" "4" "$(jq -r '.skipped_duplicate' <<<"$BUILD_OUT")"
check_eq "lake still has exactly 4 lines (no doubling)" "4" "$(lake_lines)"

echo "── 7. query cites <rule-id> — golden fixture ──"
run_query cites FX.1
check_eq "query exits 0" "0" "$QUERY_RC"
check_eq "exactly one row" "1" "$(printf '%s\n' "$QUERY_OUT" | grep -c .)"
check_eq "the row is the FX.1 cites triple" "incident:F#1050" "$(jq -r '.o' <<<"$QUERY_OUT")"
run_query cites NO.SUCH.ROW
check_eq "an unknown rule id returns no rows (empty is a valid answer)" "0" "$(printf '%s' "$QUERY_OUT" | grep -c .)"

echo "── 8. query touched_by <issue> — golden fixture, bare and qualified forms ──"
run_query touched_by 42
check_eq "bare issue number matches" "acme/widgets#42" "$(jq -r '.s' <<<"$QUERY_OUT")"
run_query touched_by acme/widgets#42
check_eq "fully-qualified owner/repo#N matches the same row" "acme/widgets#42" "$(jq -r '.s' <<<"$QUERY_OUT")"
run_query touched_by other/repo#42
check_eq "a qualified ref for a DIFFERENT repo does not match" "0" "$(printf '%s' "$QUERY_OUT" | grep -c .)"

echo "── 9. query supersedes <adr-ref> — golden fixture, every normalization form ──"
run_query supersedes 1
check_eq "bare number (new side) normalizes to ADR-0001" "ADR-0000" "$(jq -r '.o' <<<"$QUERY_OUT")"
run_query supersedes ADR-0000
check_eq "ADR-000N form (old side) matches the same edge" "ADR-0001" "$(jq -r '.s' <<<"$QUERY_OUT")"
run_query supersedes 99
check_eq "querying an ADR with no supersession edge at all returns no rows" "0" "$(printf '%s' "$QUERY_OUT" | grep -c .)"

echo "── 10. predicates are drawn from the ontology registry's edge alphabet (discrimination) ──"
NO_CITES_FX="$WORK/fx-no-cites-edge"
mkdir -p "$NO_CITES_FX/workflows/scripts/config" "$NO_CITES_FX/rule-files"
grep -v $'^edge\tcites\t' "$FX/workflows/scripts/config/ontology-registry.tsv" >"$NO_CITES_FX/workflows/scripts/config/ontology-registry.tsv"
cp "$FX/workflows/scripts/config/join-keys-lib.sh" "$NO_CITES_FX/workflows/scripts/config/join-keys-lib.sh"
cp "$FX/workflows/scripts/config/join-keys.tsv" "$NO_CITES_FX/workflows/scripts/config/join-keys.tsv"
cp "$FX/workflows/scripts/config/citation-registry.tsv" "$NO_CITES_FX/workflows/scripts/config/citation-registry.tsv"
cp "$FX/rule-files/registered.md" "$NO_CITES_FX/rule-files/registered.md"
RED_OUT="$(TRIPLES_REPO_ROOT="$NO_CITES_FX" TRIPLES_RAW_DIR="$NO_CITES_FX/out" bash "$TRIPLES" build 2>&1)"
RED_RC=$?
check_eq "build FAILS LOUDLY when the ontology registry drops the cites edge row" "1" "$RED_RC"
check "the failure names the unlisted predicate" \
  bash -c "printf '%s' '$RED_OUT' | grep -i 'cites.*not a registered ontology edge' >/dev/null"
check "no lake file is left behind on the red run" \
  bash -c "! ls '$NO_CITES_FX/out'/triples-*.jsonl >/dev/null 2>&1"
# ...and restoring the edge row goes back to GREEN, proving this is a real
# discrimination (not a check that can only ever fail).
run_build
check_eq "restoring the edge row: build goes green again" "0" "$BUILD_RC"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_triples: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_triples: OK — all %d checks passed\n' "$pass"
