#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/plan.sh — the build Step-1 plan
# parse/validate + dependency-level toposort and the in-band sentinel writeback
# CLI (epic #253, spike #245). Board-toolkit fixture style: throwaway plan-note
# files in a tmpdir, the _plan_vault_write REST seam OVERRIDDEN so ZERO live
# REST calls happen, structured-output assertions via jq.
#
# Covers:
#   - validate: a valid approved plan → VALID; malformed plans → INVALID +
#     non-zero exit (draft status, duplicate slug, missing acceptance, bad
#     branch, dangling depends-on/after ref, leftover acceptance placeholder,
#     non-int gh_issue, gh_issue+split_from together, prose external gate with
#     no gate_check); a depends-on ∪ after cycle → INVALID (rule 8)
#   - toposort: a 2-level DAG over the union of depends-on + after → the right
#     level partition; a cycle → CYCLE outcome + non-zero exit
#   - writeback routes EVERY vault write through _plan_vault_write (grep: no
#     direct curl outside that function); the seam is overridden, sentinel is
#     flipped, stamp sub-lines are written, WRITTEN is emitted
#   - an unreachable REST API (seam returns non-zero) → WRITE_FAILED + non-zero
#     exit + stderr; NEVER silent success
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plan.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- fixtures ----------------------------------------------------------------
# A valid, approved 2-level plan. Edges:
#   base       : (none)            → L0
#   builds-on  : depends-on base   → L1
#   follows    : after base        → L1
# So levels = [[base], [builds-on, follows]].
cat > "$TMP/valid.md" <<'EOF'
---
tags: [plan, project/foundation]
date: 2026-06-09
status: approved
---

# foundation - valid plan

## Items

- [ ] **Base change** `slug: base` — the foundation item
  - branch: `feat/base`
  - size: S
  - acceptance:
    - base works
    - tests pass

- [ ] **Builds on base** `slug: builds-on` — extends base
  - branch: `feat/builds-on`
  - size: M
  - depends-on: base
  - gh_issue: 4567
  - acceptance:
    - extension works

- [ ] **Follows base logically** `slug: follows` — sequenced after base
  - branch: `fix/follows`
  - size: S
  - after: base
  - acceptance:
    - follows correctly
EOF

# --- validate: the valid plan passes -----------------------------------------
out="$(bash "$SCRIPT" validate "$TMP/valid.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "valid plan not VALID (got: $out)"
echo "PASS: validate → VALID on a well-formed approved plan"

# --- validate: draft status is rejected (rule 1) -----------------------------
sed 's/^status: approved/status: draft/' "$TMP/valid.md" > "$TMP/draft.md"
rc=0; out="$(bash "$SCRIPT" validate "$TMP/draft.md")" || rc=$?
[ "$rc" -ne 0 ] || fail "draft plan did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "INVALID" ] || fail "draft not INVALID (got: $out)"
jq -e '.errors | map(test("rule 1")) | any' <<<"$out" >/dev/null \
  || fail "draft INVALID but rule 1 not in errors (got: $out)"
echo "PASS: validate → INVALID + non-zero on a draft (non-approved) plan (rule 1)"

# --- validate: duplicate slug is rejected (rule 3) ---------------------------
cat > "$TMP/dupe.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **First** `slug: same` — one
  - branch: `feat/same`
  - acceptance:
    - x

- [ ] **Second** `slug: same` — two
  - branch: `feat/same`
  - acceptance:
    - y
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/dupe.md")" || rc=$?
[ "$rc" -ne 0 ] || fail "duplicate-slug plan did not exit non-zero"
jq -e '.errors | map(test("duplicate slug")) | any' <<<"$out" >/dev/null \
  || fail "duplicate slug not flagged (got: $out)"
echo "PASS: validate → INVALID + non-zero on a duplicate slug (rule 3)"

# --- validate: missing acceptance / bad branch / dangling refs ---------------
cat > "$TMP/multi.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **No acceptance** `slug: no-acc` — missing block
  - branch: `feat/no-acc`

- [ ] **Bad branch** `slug: bad-branch` — wrong prefix
  - branch: `feature/bad-branch`
  - acceptance:
    - x

- [ ] **Dangling depends** `slug: dangling` — points nowhere
  - branch: `feat/dangling`
  - depends-on: ghost
  - after: phantom
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/multi.md")" || rc=$?
[ "$rc" -ne 0 ] || fail "multi-error plan did not exit non-zero"
jq -e '.errors | map(test("rule 2")) | any' <<<"$out" >/dev/null || fail "missing acceptance (rule 2) not flagged (got: $out)"
jq -e '.errors | map(test("rule 4")) | any' <<<"$out" >/dev/null || fail "bad branch (rule 4) not flagged (got: $out)"
jq -e '.errors | map(test("rule 5")) | any' <<<"$out" >/dev/null || fail "dangling depends-on (rule 5) not flagged (got: $out)"
jq -e '.errors | map(test("rule 8.*phantom|after .phantom")) | any' <<<"$out" >/dev/null || fail "dangling after (rule 8) not flagged (got: $out)"
echo "PASS: validate flags missing acceptance, bad branch, dangling depends-on/after (rules 2/4/5/8)"

# --- validate: acceptance placeholder is fatal (rule 9) ----------------------
cat > "$TMP/placeholder.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Placeholder** `slug: ph` — unfinished acceptance
  - branch: `feat/ph`
  - acceptance:
    - (no acceptance criteria derivable from source — fill in during review)
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/placeholder.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 9")) | any' <<<"$out" >/dev/null \
  || fail "leftover acceptance placeholder not flagged (rule 9) (got: $out)"
echo "PASS: validate → INVALID on a leftover acceptance placeholder (rule 9)"

# --- validate: gh_issue must be a positive int (rule 7) ----------------------
cat > "$TMP/badissue.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Bad issue** `slug: bad-issue` — non-int gh_issue
  - branch: `feat/bad-issue`
  - gh_issue: abc
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/badissue.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 7")) | any' <<<"$out" >/dev/null \
  || fail "non-int gh_issue not flagged (rule 7) (got: $out)"
echo "PASS: validate → INVALID on a non-integer gh_issue (rule 7)"

# --- validate: gh_issue + split_from mutual exclusion (rule 10) --------------
cat > "$TMP/bothrefs.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Both refs** `slug: both` — gh_issue and split_from together
  - branch: `feat/both`
  - gh_issue: 100
  - split_from: #40
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/bothrefs.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 10")) | any' <<<"$out" >/dev/null \
  || fail "gh_issue+split_from not flagged (rule 10) (got: $out)"
echo "PASS: validate → INVALID when gh_issue and split_from coexist (rule 10)"

# --- validate: prose external gate without gate_check (rule 11) --------------
cat > "$TMP/gate.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Gated** `slug: gated` — waits on external work
  - branch: `feat/gated`
  - notes: External gate — do not start until #380 lands.
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" validate "$TMP/gate.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 11")) | any' <<<"$out" >/dev/null \
  || fail "prose external gate without gate_check not flagged (rule 11) (got: $out)"
# adding a gate_check clears it
cat > "$TMP/gate-ok.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **Gated** `slug: gated` — waits on external work
  - branch: `feat/gated`
  - notes: External gate — do not start until #380 lands.
  - gate_check: "configs/artists.toml lists >=40 artists"
  - acceptance:
    - x
EOF
out="$(bash "$SCRIPT" validate "$TMP/gate-ok.md")"
[ "$(jq -r .outcome <<<"$out")" = "VALID" ] || fail "external gate WITH gate_check should be VALID (got: $out)"
echo "PASS: validate flags a prose external gate missing gate_check, clears it once gate_check present (rule 11)"

# --- toposort: 2-level DAG over depends-on ∪ after ----------------------------
out="$(bash "$SCRIPT" toposort "$TMP/valid.md")"
jq -e '.levels | length == 2' <<<"$out" >/dev/null || fail "expected 2 levels (got: $out)"
jq -e '.levels[0] == ["base"]' <<<"$out" >/dev/null || fail "L0 should be [base] (got: $out)"
jq -e '.levels[1] | sort == ["builds-on","follows"]' <<<"$out" >/dev/null \
  || fail "L1 should be {builds-on, follows} (got: $out)"
echo "PASS: toposort partitions a 2-level DAG over the depends-on ∪ after union"

# --- toposort: a cycle fails loud (rule 8 / CYCLE outcome) -------------------
cat > "$TMP/cycle.md" <<'EOF'
---
status: approved
---
## Items

- [ ] **A** `slug: a` — cycles to b
  - branch: `feat/a`
  - depends-on: b
  - acceptance:
    - x

- [ ] **B** `slug: b` — cycles to a
  - branch: `feat/b`
  - after: a
  - acceptance:
    - x
EOF
rc=0; out="$(bash "$SCRIPT" toposort "$TMP/cycle.md")" || rc=$?
[ "$rc" -ne 0 ] || fail "cyclic toposort did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "CYCLE" ] || fail "cycle not reported as CYCLE (got: $out)"
echo "PASS: toposort → CYCLE + non-zero exit on a depends-on ∪ after cycle"
# validate catches the same cycle as rule 8
rc=0; out="$(bash "$SCRIPT" validate "$TMP/cycle.md")" || rc=$?
[ "$rc" -ne 0 ] && jq -e '.errors | map(test("rule 8")) | any' <<<"$out" >/dev/null \
  || fail "validate did not flag the cycle as rule 8 (got: $out)"
echo "PASS: validate → INVALID (rule 8) on the same cycle"

# --- writeback: ALL writes route through _plan_vault_write (source grep) ------
# The only curl in the script must live inside the _plan_vault_write function.
curl_lines="$(grep -nE '\bcurl\b' "$SCRIPT" || true)"
[ -n "$curl_lines" ] || fail "expected a curl call inside _plan_vault_write"
# Extract the body of _plan_vault_write and assert the curl line(s) fall inside it.
awk '/^_plan_vault_write\(\)/{f=1} f{print NR": "$0} f&&/^}/{f=0}' "$SCRIPT" > "$TMP/seam.txt"
while IFS= read -r cl; do
  ln="${cl%%:*}"
  grep -q "^${ln}: " "$TMP/seam.txt" || fail "a curl call (line $ln) lives OUTSIDE _plan_vault_write — not the sole write path"
done <<<"$curl_lines"
echo "PASS: every curl in plan.sh lives inside _plan_vault_write (sole sentinel-write path)"

# --- writeback: seam overridden → no live REST; sentinel flipped + stamped ----
# Source the script's functions, override the seam to capture instead of PUT.
# shellcheck disable=SC1090
( set +e
  # Run plan.sh with the seam stubbed via an injected wrapper. We can't source
  # the dispatch tail, so we exercise writeback as a subprocess with a stub
  # _plan_vault_write installed by pointing the REST helper at a fake: override
  # by exporting a function is not inherited by a bash subprocess, so instead we
  # drive the seam through a writable fake key-file + a curl shim on PATH.
  true
)
# Stub strategy mirroring pr.sh's gh-shim: put a fake `curl` on PATH that
# records the PUT target + body and returns HTTP 200, and a fake key-file so the
# seam's preconditions pass. This proves the write goes THROUGH _plan_vault_write
# (it is the only curl) and that a 200 → WRITTEN.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
# record args + body, emit 200 as the -w '%{http_code}' value
printf '%s\n' "\$@" > "$TMP/curl-args"
for a in "\$@"; do case "\$a" in @*) cp "\${a#@}" "$TMP/put-body" ;; esac; done
printf '200'
EOF
chmod +x "$TMP/bin/curl"
mkdir -p "$TMP/keydir"
echo '{"apiKey":"test-key"}' > "$TMP/keydir/data.json"

cp "$TMP/valid.md" "$TMP/wb.md"
out="$(PATH="$TMP/bin:$PATH" PLAN_API_KEY_FILE="$TMP/keydir/data.json" \
  bash "$SCRIPT" writeback "$TMP/wb.md" --slug builds-on --sentinel '[~]' \
  --pr 142 --pushed-sha abc123 --run-status "worker active")"
[ "$(jq -r .outcome <<<"$out")" = "WRITTEN" ] || fail "writeback not WRITTEN (got: $out)"
[ "$(jq -r .sentinel <<<"$out")" = "[~]" ] || fail "writeback sentinel not echoed (got: $out)"
# the PUT body must carry the flipped sentinel on the builds-on item + the stamps
grep -q '^- \[~\] \*\*Builds on base\*\* `slug: builds-on`' "$TMP/put-body" \
  || fail "PUT body did not flip the builds-on sentinel to [~]"
grep -q '^  - pr: 142' "$TMP/put-body" || fail "PUT body missing stamped pr: 142"
grep -q '^  - pushed_sha: abc123' "$TMP/put-body" || fail "PUT body missing stamped pushed_sha"
grep -q '^  - Run-status: worker active' "$TMP/put-body" || fail "PUT body missing Run-status stamp"
# the OTHER items must be untouched (base still [ ])
grep -q '^- \[ \] \*\*Base change\*\* `slug: base`' "$TMP/put-body" \
  || fail "writeback disturbed an unrelated item's sentinel"
echo "PASS: writeback flips the target sentinel, stamps pr/pushed_sha/Run-status, leaves others untouched (→ WRITTEN)"

# --- writeback: plan filename with spaces → URL-encoded PUT path (#364) --------
# Every real plan filename has spaces ('Plans/<date> <project> - <title>.md'), so
# the PUT URL MUST percent-encode the path segments — a raw space makes curl
# reject the URL (exit 3, http_code 000) and writeback breaks for all plans.
# Re-install the recording curl shim (the 000 shim above replaced it).
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/curl-args"
for a in "\$@"; do case "\$a" in @*) cp "\${a#@}" "$TMP/put-body" ;; esac; done
printf '200'
EOF
chmod +x "$TMP/bin/curl"
mkdir -p "$TMP/Plans"
cp "$TMP/valid.md" "$TMP/Plans/2026-06-11 stagefind - spaces in name.md"
out="$(PATH="$TMP/bin:$PATH" PLAN_API_KEY_FILE="$TMP/keydir/data.json" \
  bash "$SCRIPT" writeback "$TMP/Plans/2026-06-11 stagefind - spaces in name.md" \
  --slug base --sentinel '[x]')"
[ "$(jq -r .outcome <<<"$out")" = "WRITTEN" ] || fail "spaced-filename writeback not WRITTEN (got: $out)"
# The PUT-target URL line in curl-args must carry the percent-encoded path …
grep -q 'vault/Plans/2026-06-11%20stagefind%20-%20spaces%20in%20name\.md' "$TMP/curl-args" \
  || fail "PUT URL not percent-encoded (got: $(grep vault/ "$TMP/curl-args"))"
# … and must NOT contain a raw space in the vault path (the exit-3 trigger).
grep -E '^https?://[^ ]*/vault/.* ' "$TMP/curl-args" \
  && fail "PUT URL still contains a raw space in the path (curl would reject it)"
echo "PASS: writeback URL-encodes a spaced plan filename before the PUT (→ no curl exit-3) (#364)"

# --- writeback: unreachable REST → WRITE_FAILED + non-zero + stderr -----------
# A curl shim that emits HTTP 000 (no response) must make the seam fail loud.
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
printf '000'
EOF
chmod +x "$TMP/bin/curl"
rc=0
out="$(PATH="$TMP/bin:$PATH" PLAN_API_KEY_FILE="$TMP/keydir/data.json" \
  bash "$SCRIPT" writeback "$TMP/wb.md" --slug builds-on --sentinel '[m]' 2>"$TMP/err")" || rc=$?
[ "$rc" -ne 0 ] || fail "unreachable REST writeback did NOT exit non-zero (silent success — the forbidden failure)"
[ "$(jq -r .outcome <<<"$out")" = "WRITE_FAILED" ] || fail "unreachable REST not WRITE_FAILED (got: $out)"
grep -qi 'unreachable' "$TMP/err" || fail "no fail-loud stderr message on unreachable REST (got: $(cat "$TMP/err"))"
echo "PASS: unreachable REST → WRITE_FAILED + non-zero exit + stderr (never silent success)"

# --- writeback: missing key-file also fails loud -----------------------------
rc=0
out="$(PLAN_API_KEY_FILE="$TMP/nonexistent.json" \
  bash "$SCRIPT" writeback "$TMP/wb.md" --slug base --sentinel '[x]' 2>"$TMP/err2")" || rc=$?
[ "$rc" -ne 0 ] || fail "missing key-file writeback did not exit non-zero"
grep -qi 'key file missing' "$TMP/err2" || fail "no fail-loud stderr on missing key file (got: $(cat "$TMP/err2"))"
echo "PASS: missing REST key-file → fail loud (non-zero + stderr)"

# --- error: bad args → structured ERROR + non-zero ----------------------------
rc=0; out="$(bash "$SCRIPT" validate "$TMP/nonexistent.md" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "validate on missing file not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" writeback "$TMP/wb.md" --slug base 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "writeback without --sentinel not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" writeback "$TMP/wb.md" --slug ghost --sentinel '[x]' 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "writeback on unknown slug not structured ERROR (got: $out)"
echo "PASS: bad args (missing file, no --sentinel, unknown slug) → structured ERROR + non-zero"
