#!/usr/bin/env bash
#
# test_scan_stub.sh — CI tests for scan_stub.py.
#
# Tests:
#   1. Basic scan report shape: required top-level keys present.
#   2. Lexicon matches: tells in real user turns produce matches.
#   3. Self-match guard: command-expansion turns with embedded tell phrases
#      produce ZERO lexicon matches (the false-positive trap).
#   4. Tool events: AskUserQuestion, is_error, interrupt, capture.sh parsed.
#   5. Determinism: two runs of the same input produce identical output.
#   6. Fail/pass toggle: removing the self-match guard lets the test stub
#      produce matches; guard restored → zero again.
#
# Usage: bash workflows/scripts/drain/tests/test_scan_stub.sh
# Exit 0 = all pass, exit 1 = one or more failures.

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/drain/scan_stub.py"
FIXTURES="$REPO/workflows/scripts/drain/tests/fixtures"
SAMPLE_STUB="$FIXTURES/sample_stub.md"
CMD_STUB="$FIXTURES/command_expansion_stub.md"
SAMPLE_JSONL="$FIXTURES/sample_transcript.jsonl"

pass=0
fail=0

# ── helpers ─────────────────────────────────────────────────────────────────

ok() {
  local name="$1"
  echo "  ok    $name"
  pass=$((pass + 1))
}

fail_test() {
  local name="$1" reason="$2"
  echo "  FAIL  $name: $reason"
  fail=$((fail + 1))
}

# Run scanner and parse JSON output.
scan() {
  python3 "$SCRIPT" "$@" 2>/dev/null
}

# ── Test 1: required top-level keys ──────────────────────────────────────────

echo "--- test 1: required top-level keys ---"

report=$(scan "$SAMPLE_STUB" --jsonl "$SAMPLE_JSONL") || {
  fail_test "schema_keys" "scanner exited non-zero"
}

if [ -n "${report:-}" ]; then
  for key in schema_version stub lexicon_matches user_turns tool_events; do
    val=$(printf '%s' "$report" | python3 -c "import json,sys; d=json.load(sys.stdin); print('ok' if '$key' in d else 'missing')" 2>/dev/null)
    if [ "${val:-missing}" = "ok" ]; then
      ok "top-level key '$key' present"
    else
      fail_test "top-level key '$key'" "missing from report"
    fi
  done

  # Verify schema_version = "1"
  sv=$(printf '%s' "$report" | python3 -c "import json,sys; print(json.load(sys.stdin).get('schema_version',''))" 2>/dev/null)
  if [ "$sv" = "1" ]; then
    ok "schema_version == '1'"
  else
    fail_test "schema_version" "expected '1', got '$sv'"
  fi
fi

# ── Test 2: lexicon matches in real user turns ────────────────────────────────

echo "--- test 2: lexicon matches in real user turns ---"

report=$(scan "$SAMPLE_STUB" --jsonl "$SAMPLE_JSONL") || true

if [ -n "${report:-}" ]; then
  match_count=$(printf '%s' "$report" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('lexicon_matches',[])))" 2>/dev/null)
  if [ "${match_count:-0}" -gt 0 ]; then
    ok "lexicon_matches non-empty ($match_count matches found)"
  else
    fail_test "lexicon_matches" "expected >0 matches, got $match_count — real tells not matched"
  fi

  # Verify we find specific known tells from the fixture.
  # sample_stub.md user turns contain: "Lesson:", "wrong layer", "are you sure",
  # "version mismatch", "latent defect", "Park to Backlog", "stopping point"
  for tell in "Lesson:" "the wrong layer" "are you sure" "Park to Backlog" "stopping point"; do
    found=$(printf '%s' "$report" | python3 -c "
import json, sys
d = json.load(sys.stdin)
tells = [m['tell'] for m in d.get('lexicon_matches', [])]
print('yes' if '$tell' in tells else 'no')
" 2>/dev/null)
    if [ "${found:-no}" = "yes" ]; then
      ok "tell '$tell' matched"
    else
      fail_test "tell '$tell'" "not found in lexicon_matches"
    fi
  done

  # Verify user_turns digest has entries.
  ut_count=$(printf '%s' "$report" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('user_turns',[])))" 2>/dev/null)
  if [ "${ut_count:-0}" -gt 0 ]; then
    ok "user_turns digest non-empty ($ut_count turns)"
  else
    fail_test "user_turns" "expected >0 entries"
  fi
fi

# ── Test 3: self-match guard — command-expansion turns must produce ZERO matches

echo "--- test 3: self-match guard (command-expansion turns → ZERO matches) ---"

report_cmd=$(scan "$CMD_STUB") || true

if [ -n "${report_cmd:-}" ]; then
  cmd_match_count=$(printf '%s' "$report_cmd" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('lexicon_matches',[])))" 2>/dev/null)
  if [ "${cmd_match_count:-1}" -eq 0 ]; then
    ok "self-match guard: command-expansion stub → 0 lexicon matches"
  else
    fail_test "self-match guard" "expected 0 matches, got $cmd_match_count — guard not working"
    # Show which tells leaked through.
    printf '%s' "$report_cmd" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for m in d.get('lexicon_matches', []):
    print(f'  LEAKED: tell={m[\"tell\"]} location={m[\"location\"]}')
" 2>/dev/null
  fi

  # Verify the only non-excluded user turn ('ok done with commands') is in digest.
  ut_count=$(printf '%s' "$report_cmd" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('user_turns',[])))" 2>/dev/null)
  if [ "${ut_count:-0}" -eq 1 ]; then
    ok "self-match guard: only the real user turn appears in digest (1 entry)"
  else
    fail_test "self-match guard digest" "expected 1 real user turn in digest, got $ut_count"
  fi
fi

# ── Test 3b: fail/pass toggle — removing exclusion produces matches, guard restores zero

echo "--- test 3b: fail/pass toggle (exclusion removal → matches; guard → zero) ---"

# Build a temporary lexicon with just one tell that appears in the command-expansion fixture.
TMPDIR_TEST=$(mktemp -d)
TMP_LEXICON="$TMPDIR_TEST/test_lexicon.tsv"
TMP_STUB="$TMPDIR_TEST/no_guard_stub.md"

printf 'Lesson:\tself-critique\tliteral\n' > "$TMP_LEXICON"

# Create a stub whose command-expansion turn is NOT wrapped in command tags —
# simulating what happens if the guard were absent (plain text containing the tell).
cat > "$TMP_STUB" << 'STUBEOF'
---
date: 2026-06-01
time: "1600"
project: testproject
cwd: /tmp
session_id: aabbccdd-test-toggle-00000001
transcript: /nonexistent
tags:
  - session
---

## Transcript

### User

Lesson: this turn has no command wrapper so it should match when guard is absent.

STUBEOF

# This stub's user turn has no command tags → should match.
report_toggle=$(scan "$TMP_STUB" --lexicon "$TMP_LEXICON") || true
toggle_count=$(printf '%s' "$report_toggle" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('lexicon_matches',[])))" 2>/dev/null)
if [ "${toggle_count:-0}" -gt 0 ]; then
  ok "toggle: non-wrapped user turn with tell → $toggle_count match(es) (guard would block this if wrapped)"
else
  fail_test "toggle" "expected ≥1 match for non-wrapped tell turn, got $toggle_count"
fi

# Now wrap it in a command tag → guard should block to 0.
cat > "$TMP_STUB" << 'STUBEOF'
---
date: 2026-06-01
time: "1600"
project: testproject
cwd: /tmp
session_id: aabbccdd-test-toggle-00000002
transcript: /nonexistent
tags:
  - session
---

## Transcript

### User

<local-command-stdout>Lesson: this turn is wrapped in command tags so guard must block it.</local-command-stdout>

STUBEOF

report_toggle2=$(scan "$TMP_STUB" --lexicon "$TMP_LEXICON") || true
toggle_count2=$(printf '%s' "$report_toggle2" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('lexicon_matches',[])))" 2>/dev/null)
if [ "${toggle_count2:-1}" -eq 0 ]; then
  ok "toggle: wrapped command-expansion turn → 0 matches (guard working)"
else
  fail_test "toggle" "expected 0 matches after wrapping in command tag, got $toggle_count2"
fi

rm -rf "$TMPDIR_TEST"

# ── Test 4: tool events from .jsonl ────────────────────────────────────────

echo "--- test 4: tool events from .jsonl ---"

report_tools=$(scan "$SAMPLE_STUB" --jsonl "$SAMPLE_JSONL") || true

if [ -n "${report_tools:-}" ]; then
  # AskUserQuestion: expect 1 entry with a non-null answer.
  auq_count=$(printf '%s' "$report_tools" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('ask_user_questions', [])))
" 2>/dev/null)
  if [ "${auq_count:-0}" -eq 1 ]; then
    ok "tool_events.ask_user_questions: 1 entry found"
  else
    fail_test "tool_events.ask_user_questions" "expected 1, got $auq_count"
  fi

  auq_answered=$(printf '%s' "$report_tools" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
auq = te.get('ask_user_questions', [])
print('yes' if auq and auq[0].get('answer') else 'no')
" 2>/dev/null)
  if [ "${auq_answered:-no}" = "yes" ]; then
    ok "tool_events.ask_user_questions: answer populated"
  else
    fail_test "tool_events.ask_user_questions" "answer not populated"
  fi

  # is_error: expect 1 error entry.
  err_count=$(printf '%s' "$report_tools" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('errors', [])))
" 2>/dev/null)
  if [ "${err_count:-0}" -eq 1 ]; then
    ok "tool_events.errors: 1 is_error entry found"
  else
    fail_test "tool_events.errors" "expected 1, got $err_count"
  fi

  # interrupt: expect 1.
  int_count=$(printf '%s' "$report_tools" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('interrupts', [])))
" 2>/dev/null)
  if [ "${int_count:-0}" -eq 1 ]; then
    ok "tool_events.interrupts: 1 interrupt found"
  else
    fail_test "tool_events.interrupts" "expected 1, got $int_count"
  fi

  # capture_calls: expect 1.
  cap_count=$(printf '%s' "$report_tools" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('capture_calls', [])))
" 2>/dev/null)
  if [ "${cap_count:-0}" -eq 1 ]; then
    ok "tool_events.capture_calls: 1 capture call found"
  else
    fail_test "tool_events.capture_calls" "expected 1, got $cap_count"
  fi
fi

# ── Test 5: determinism ──────────────────────────────────────────────────────

echo "--- test 5: determinism ---"

out1=$(scan "$SAMPLE_STUB" --jsonl "$SAMPLE_JSONL")
out2=$(scan "$SAMPLE_STUB" --jsonl "$SAMPLE_JSONL")

if [ "$out1" = "$out2" ]; then
  ok "determinism: two runs produce identical output"
else
  fail_test "determinism" "two runs produced different output"
fi

# ── Test 6: missing stub → non-zero exit ─────────────────────────────────────

echo "--- test 6: missing stub → non-zero exit ---"

scan "/nonexistent/stub.md" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  ok "missing stub exits non-zero (rc=$rc)"
else
  fail_test "missing stub" "expected non-zero exit, got 0"
fi

# ── Test 7: absent .jsonl → empty tool_events (graceful) ─────────────────────

echo "--- test 7: absent .jsonl → graceful empty tool_events ---"

report_nojsonl=$(scan "$SAMPLE_STUB") || true
if [ -n "${report_nojsonl:-}" ]; then
  empty_te=$(printf '%s' "$report_nojsonl" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
all_empty = all(len(v) == 0 for v in te.values())
print('yes' if all_empty else 'no')
" 2>/dev/null)
  if [ "${empty_te:-no}" = "yes" ]; then
    ok "absent .jsonl → all tool_events sub-arrays empty"
  else
    fail_test "absent .jsonl" "expected all tool_events empty, got non-empty"
  fi
fi

# ── Test 8: assistant-turn tell scan (self-worked-around-defect, #444) ───────
#
# The blind spot of foundation #444: a defect the *assistant* narrates working
# around (e.g. "this is broken, let me route around it") and never files. The
# main lexicon skips assistant turns; lexicon-assistant.tsv is scanned against
# them. Assert such an assistant turn produces a role:"assistant" match with
# category "worked-around-defect" — and that a benign assistant turn does NOT.

echo "--- test 8: assistant-turn self-worked-around-defect tell scan ---"

TMPDIR8=$(mktemp -d)
TMP_STUB8="$TMPDIR8/assistant_workaround_stub.md"
cat > "$TMP_STUB8" << 'STUBEOF'
---
date: 2026-06-01
time: "1700"
project: testproject
cwd: /tmp
session_id: aabbccdd-test-assistant-0000001
transcript: /nonexistent
tags:
  - session
---

## Transcript

### User

run the board adapter

### Assistant

The BOARD_ITEMS_JSON path is broken — jq chokes on a control char. Let me work
around it by falling back to worklist.sh per-item for now.

### Assistant

All set, listed the items fine.
STUBEOF

report8=$(scan "$TMP_STUB8") || true
asst_matches=$(printf '%s' "$report8" | python3 -c "
import json, sys
d = json.load(sys.stdin)
m = [x for x in d.get('lexicon_matches', []) if x.get('role') == 'assistant' and x.get('category') == 'worked-around-defect']
print(len(m))
" 2>/dev/null)
if [ "${asst_matches:-0}" -gt 0 ]; then
  ok "assistant tell: self-worked-around-defect turn → $asst_matches assistant match(es)"
else
  fail_test "assistant tell" "expected ≥1 assistant worked-around-defect match, got ${asst_matches:-0}"
fi

# The location string must name the assistant role (not hardcoded "user").
asst_loc=$(printf '%s' "$report8" | python3 -c "
import json, sys
d = json.load(sys.stdin)
m = [x for x in d.get('lexicon_matches', []) if x.get('role') == 'assistant']
print('yes' if m and '(assistant)' in m[0]['location'] else 'no')
" 2>/dev/null)
if [ "${asst_loc:-no}" = "yes" ]; then
  ok "assistant tell: location string names the assistant role"
else
  fail_test "assistant tell location" "expected '(assistant)' in location string"
fi

# Benign assistant turn (no defect language) → no assistant match.
TMP_STUB8B="$TMPDIR8/benign_assistant_stub.md"
cat > "$TMP_STUB8B" << 'STUBEOF'
---
date: 2026-06-01
time: "1700"
project: testproject
cwd: /tmp
session_id: aabbccdd-test-assistant-0000002
transcript: /nonexistent
tags:
  - session
---

## Transcript

### User

list the items

### Assistant

Done — here are the three open items. Let me know what to pull next.
STUBEOF

report8b=$(scan "$TMP_STUB8B") || true
benign_matches=$(printf '%s' "$report8b" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(len([x for x in d.get('lexicon_matches', []) if x.get('role') == 'assistant']))
" 2>/dev/null)
if [ "${benign_matches:-1}" -eq 0 ]; then
  ok "assistant tell: benign assistant turn → 0 assistant matches (precision)"
else
  fail_test "assistant tell precision" "expected 0 assistant matches on benign turn, got $benign_matches"
fi

# Stale-local-main realization is assistant-narrated → must surface as an
# assistant-role state-collision match (the gap that left this recurring rework
# invisible to /tidy: user-only lexicon + user-only model-skim digest).
TMP_STUB8C="$TMPDIR8/assistant_stale_main_stub.md"
cat > "$TMP_STUB8C" << 'STUBEOF'
---
date: 2026-06-01
time: "1700"
project: testproject
cwd: /tmp
session_id: aabbccdd-test-assistant-0000003
transcript: /nonexistent
tags:
  - session
---

## Transcript

### User

open the PR for the board fix

### Assistant

The PR came back DIRTY — local main was 100 commits behind origin, so I branched
off a stale local main and created conflicts. Recovering with reset --hard
origin/main, then re-branching.
STUBEOF

report8c=$(scan "$TMP_STUB8C") || true
stale_matches=$(printf '%s' "$report8c" | python3 -c "
import json, sys
d = json.load(sys.stdin)
m = [x for x in d.get('lexicon_matches', []) if x.get('role') == 'assistant' and x.get('category') == 'state-collision']
print(len(m))
" 2>/dev/null)
if [ "${stale_matches:-0}" -gt 0 ]; then
  ok "assistant tell: stale-local-main narration → $stale_matches assistant state-collision match(es)"
else
  fail_test "assistant state-collision" "expected ≥1 assistant state-collision match, got ${stale_matches:-0}"
fi

# Self-correction realization is assistant-narrated → must surface as an
# assistant-role self-correction match (foundation #501). The "I'm thinking about
# this wrong / that didn't go right" mid-session reversal the user-only lexicon
# never saw.
TMP_STUB8D="$TMPDIR8/assistant_self_correction_stub.md"
cat > "$TMP_STUB8D" << 'STUBEOF'
---
date: 2026-06-01
time: "1700"
project: testproject
cwd: /tmp
session_id: aabbccdd-test-assistant-0000004
transcript: /nonexistent
tags:
  - session
---

## Transcript

### User

wire the principle into the gate

### Assistant

Wait — I'm thinking about this wrong. I had this backwards: the gate reads the
principle, not the other way round. Let me reconsider the approach before editing.
STUBEOF

report8d=$(scan "$TMP_STUB8D") || true
sc_matches=$(printf '%s' "$report8d" | python3 -c "
import json, sys
d = json.load(sys.stdin)
m = [x for x in d.get('lexicon_matches', []) if x.get('role') == 'assistant' and x.get('category') == 'self-correction']
print(len(m))
" 2>/dev/null)
if [ "${sc_matches:-0}" -gt 0 ]; then
  ok "assistant tell: self-correction narration → $sc_matches assistant self-correction match(es)"
else
  fail_test "assistant self-correction" "expected ≥1 assistant self-correction match, got ${sc_matches:-0}"
fi

# Benign assistant turn with routine "let me check" narration → no self-correction
# match (precision; only a real reasoning reversal qualifies).
TMP_STUB8E="$TMPDIR8/benign_no_correction_stub.md"
cat > "$TMP_STUB8E" << 'STUBEOF'
---
date: 2026-06-01
time: "1700"
project: testproject
cwd: /tmp
session_id: aabbccdd-test-assistant-0000005
transcript: /nonexistent
tags:
  - session
---

## Transcript

### User

add the rule

### Assistant

Let me check the file and add the rule. Done — the gate now reads the principle.
STUBEOF

report8e=$(scan "$TMP_STUB8E") || true
sc_benign=$(printf '%s' "$report8e" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(len([x for x in d.get('lexicon_matches', []) if x.get('category') == 'self-correction']))
" 2>/dev/null)
if [ "${sc_benign:-1}" -eq 0 ]; then
  ok "assistant self-correction precision: routine 'let me check' narration → 0 self-correction matches"
else
  fail_test "assistant self-correction precision" "expected 0 self-correction matches, got $sc_benign"
fi

rm -rf "$TMPDIR8"

# ── Test 9: soft-failure tool result (is_error false, error signature, #444) ──
#
# The other half of #444: a tool result that FAILED but is not flagged
# is_error: true — e.g. a Bash command that emitted a downstream `jq: error` to
# stdout yet exited 0. The is_error-only pass misses it; the signature pass
# catches it as kind:"soft".

echo "--- test 9: soft-failure tool result (is_error false + error signature) ---"

TMPDIR9=$(mktemp -d)
TMP_JSONL9="$TMPDIR9/soft_error.jsonl"
# A tool_use (Bash) followed by a tool_result that is NOT is_error but whose
# content carries a jq parse-error signature (the BOARD_ITEMS_JSON #443 class).
cat > "$TMP_JSONL9" << 'JSONLEOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_soft1","name":"Bash","input":{"command":"board_resolve 3"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_soft1","content":[{"type":"text","text":"jq: error (at <stdin>:0): Invalid numeric literal at line 1, column 9"}]}]}}
JSONLEOF

report9=$(scan "$SAMPLE_STUB" --jsonl "$TMP_JSONL9") || true
soft_count=$(printf '%s' "$report9" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len([e for e in te.get('errors', []) if e.get('kind') == 'soft']))
" 2>/dev/null)
if [ "${soft_count:-0}" -eq 1 ]; then
  ok "soft failure: jq error on a non-is_error result → 1 soft error captured"
else
  fail_test "soft failure" "expected 1 soft error, got ${soft_count:-0}"
fi

# The soft error must carry tool_name (matched back to the tool_use) and kind.
soft_kind=$(printf '%s' "$report9" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
e = [x for x in te.get('errors', []) if x.get('kind') == 'soft']
print('yes' if e and e[0].get('tool_name') == 'Bash' else 'no')
" 2>/dev/null)
if [ "${soft_kind:-no}" = "yes" ]; then
  ok "soft failure: tool_name matched back to tool_use (Bash)"
else
  fail_test "soft failure tool_name" "expected tool_name 'Bash' on the soft error"
fi

# A benign (non-error) tool result → no soft error (precision).
TMP_JSONL9B="$TMPDIR9/clean.jsonl"
cat > "$TMP_JSONL9B" << 'JSONLEOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_clean1","name":"Bash","input":{"command":"echo hi"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_clean1","content":[{"type":"text","text":"hi\nthree items listed successfully"}]}]}}
JSONLEOF

report9b=$(scan "$SAMPLE_STUB" --jsonl "$TMP_JSONL9B") || true
clean_count=$(printf '%s' "$report9b" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('errors', [])))
" 2>/dev/null)
if [ "${clean_count:-1}" -eq 0 ]; then
  ok "soft failure precision: clean tool result → 0 errors"
else
  fail_test "soft failure precision" "expected 0 errors on clean result, got $clean_count"
fi

# Prose that merely mentions a signature word must NOT match (PR #446 review:
# tightened `fatal:` to line-initial and `parse error` to require location).
TMP_JSONL9C="$TMPDIR9/prose.jsonl"
cat > "$TMP_JSONL9C" << 'JSONLEOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_prose1","name":"Bash","input":{"command":"echo note"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_prose1","content":[{"type":"text","text":"this is not fatal: just a warning; we handle parse error gracefully"}]}]}}
JSONLEOF

report9c=$(scan "$SAMPLE_STUB" --jsonl "$TMP_JSONL9C") || true
prose_count=$(printf '%s' "$report9c" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('errors', [])))
" 2>/dev/null)
if [ "${prose_count:-1}" -eq 0 ]; then
  ok "soft failure precision: benign 'not fatal:'/'parse error gracefully' prose → 0 errors"
else
  fail_test "soft failure prose precision" "expected 0 errors on benign signature-word prose, got $prose_count"
fi

rm -rf "$TMPDIR9"

# ── Test 10: promoted soft-failure signatures (foundation #662) ──────────────
#
# Two candidate-tells promoted into _ERROR_SIGNATURES: the MCP wrong-parameter
# error (`Key "<ident>" does not exist`) and the headless sandbox path violation
# (`may only concatenate files from the allowed working directories`). Both are
# emitted on tool_results that are NOT is_error, so only the signature pass
# catches them.

echo "--- test 10: promoted soft-failure signatures (MCP wrong-param + sandbox path) ---"

TMPDIR10=$(mktemp -d)
TMP_JSONL10="$TMPDIR10/promoted.jsonl"
cat > "$TMP_JSONL10" << 'JSONLEOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_mcp1","name":"mcp__obsidian-builtin__vault_patch","input":{"target":"Scratch::Hubs"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_mcp1","content":[{"type":"text","text":"Error: Key \"Scratch::Hubs\" does not exist"}]}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_sbx1","name":"Bash","input":{"command":"cat a b"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_sbx1","content":[{"type":"text","text":"Error: may only concatenate files from the allowed working directories"}]}]}}
JSONLEOF

report10=$(scan "$SAMPLE_STUB" --jsonl "$TMP_JSONL10") || true
promoted_count=$(printf '%s' "$report10" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len([e for e in te.get('errors', []) if e.get('kind') == 'soft']))
" 2>/dev/null)
if [ "${promoted_count:-0}" -eq 2 ]; then
  ok "promoted signatures: MCP wrong-param + sandbox path → 2 soft errors captured"
else
  fail_test "promoted signatures" "expected 2 soft errors, got ${promoted_count:-0}"
fi

# Precision: benign prose that merely says "the key does not exist" (no quoted
# key literal) and mentions concatenation must NOT match either new signature.
TMP_JSONL10B="$TMPDIR10/benign.jsonl"
cat > "$TMP_JSONL10B" << 'JSONLEOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_bn1","name":"Bash","input":{"command":"echo note"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_bn1","content":[{"type":"text","text":"the key does not exist in that mental model, but concatenating the files worked"}]}]}}
JSONLEOF

report10b=$(scan "$SAMPLE_STUB" --jsonl "$TMP_JSONL10B") || true
benign10=$(printf '%s' "$report10b" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('errors', [])))
" 2>/dev/null)
if [ "${benign10:-1}" -eq 0 ]; then
  ok "promoted signatures precision: benign prose → 0 errors"
else
  fail_test "promoted signatures precision" "expected 0 errors on benign prose, got $benign10"
fi

rm -rf "$TMPDIR10"

# ── Test 11: AUQ answer-field scan (#421 detector 1) ─────────────────────────
#
# The AskUserQuestion ANSWER is structurally unreachable by the turn-scanning
# lexicon (it lives in the tool_result, not a ### User turn). Two signals:
#   (1a) a confusion answer ("I do not understand this…") — top feedback moment
#   (1b) an answer that is itself a question / counter-proposal — the option set
#        omitted the right answer.

echo "--- test 11: AUQ answer-field scan (confusion + omitted-option) ---"

TMPDIR11=$(mktemp -d)
TMP_JSONL11="$TMPDIR11/auq.jsonl"
cat > "$TMP_JSONL11" << 'JSONLEOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"q_conf","name":"AskUserQuestion","input":{"questions":[{"question":"Fix the test or the implementation?"}]}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"q_conf","content":"Your questions have been answered: \"Fix the test or the implementation?\"=\"I do not understand this. I need more context.\""}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"q_omit","name":"AskUserQuestion","input":{"questions":[{"question":"Which path?"}]}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"q_omit","content":"Your questions have been answered: \"Which path?\"=\"Why not use the existing adapter?\""}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"q_ok","name":"AskUserQuestion","input":{"questions":[{"question":"Which path?"}]}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"q_ok","content":"Your questions have been answered: \"Which path?\"=\"Fix the implementation\""}]}}
JSONLEOF

report11=$(scan "$SAMPLE_STUB" --jsonl "$TMP_JSONL11") || true

conf_count=$(printf '%s' "$report11" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len([f for f in te.get('auq_answer_flags', []) if f.get('signal') == 'confusion']))
" 2>/dev/null)
if [ "${conf_count:-0}" -eq 1 ]; then
  ok "AUQ scan: confusion answer → 1 confusion flag"
else
  fail_test "AUQ confusion" "expected 1 confusion flag, got ${conf_count:-0}"
fi

omit_count=$(printf '%s' "$report11" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len([f for f in te.get('auq_answer_flags', []) if f.get('signal') == 'omitted-option']))
" 2>/dev/null)
if [ "${omit_count:-0}" -eq 1 ]; then
  ok "AUQ scan: question-shaped answer → 1 omitted-option flag"
else
  fail_test "AUQ omitted-option" "expected 1 omitted-option flag, got ${omit_count:-0}"
fi

# Precision: a normal selected answer produces no flag.
total11=$(printf '%s' "$report11" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('auq_answer_flags', [])))
" 2>/dev/null)
if [ "${total11:-99}" -eq 2 ]; then
  ok "AUQ scan precision: normal 'Fix the implementation' answer → no flag (2 flags total)"
else
  fail_test "AUQ precision" "expected 2 flags total, got ${total11:-99}"
fi

rm -rf "$TMPDIR11"

# ── Test 12: repeated inline env-var workaround (#421 detector 2) ─────────────
#
# A leading `export VAR=value` re-typed verbatim ahead of 3+ separate Bash
# calls in one session (config patched at call site vs. fixing the default).

echo "--- test 12: repeated inline env-var workaround (export prefix ×3) ---"

TMPDIR12=$(mktemp -d)
TMP_JSONL12="$TMPDIR12/env.jsonl"
cat > "$TMP_JSONL12" << 'JSONLEOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"e1","name":"Bash","input":{"command":"export DISPLAY_TZ=America/Los_Angeles && python3 render.py a"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"e2","name":"Bash","input":{"command":"export DISPLAY_TZ=America/Los_Angeles && python3 render.py b"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"e3","name":"Bash","input":{"command":"export DISPLAY_TZ=America/Los_Angeles && python3 render.py c"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"e4","name":"Bash","input":{"command":"export OTHER=1 && echo once"}}]}}
JSONLEOF

report12=$(scan "$SAMPLE_STUB" --jsonl "$TMP_JSONL12") || true

rep_count=$(printf '%s' "$report12" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('repeated_env_prefixes', [])))
" 2>/dev/null)
if [ "${rep_count:-0}" -eq 1 ]; then
  ok "env workaround: repeated export prefix → 1 flagged prefix"
else
  fail_test "env workaround" "expected 1 flagged prefix, got ${rep_count:-0}"
fi

rep_n=$(printf '%s' "$report12" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
p = te.get('repeated_env_prefixes', [])
print(p[0]['count'] if p else 0)
" 2>/dev/null)
if [ "${rep_n:-0}" -eq 3 ]; then
  ok "env workaround: count == 3 (the DISPLAY_TZ prefix), the OTHER=1 single call not flagged"
else
  fail_test "env workaround count" "expected count 3, got ${rep_n:-0}"
fi

# Precision: the same prefix used only twice must NOT flag (< 3).
TMP_JSONL12B="$TMPDIR12/env_twice.jsonl"
cat > "$TMP_JSONL12B" << 'JSONLEOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"export FOO=bar && echo a"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"export FOO=bar && echo b"}}]}}
JSONLEOF
report12b=$(scan "$SAMPLE_STUB" --jsonl "$TMP_JSONL12B") || true
rep_twice=$(printf '%s' "$report12b" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('repeated_env_prefixes', [])))
" 2>/dev/null)
if [ "${rep_twice:-1}" -eq 0 ]; then
  ok "env workaround precision: prefix used only twice → not flagged (< 3)"
else
  fail_test "env workaround precision" "expected 0 flagged prefixes for a 2× prefix, got $rep_twice"
fi

rm -rf "$TMPDIR12"

# ── Test 13: MCP -32602 Invalid arguments bucket (#421 detector 3) ────────────

echo "--- test 13: MCP -32602 Invalid arguments its own bucket ---"

TMPDIR13=$(mktemp -d)
TMP_JSONL13="$TMPDIR13/mcp.jsonl"
cat > "$TMP_JSONL13" << 'JSONLEOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"mc1","name":"mcp__obsidian-builtin__vault_patch","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"mc1","is_error":true,"content":[{"type":"text","text":"MCP error -32602: Invalid arguments for tool vault_patch: target is required"}]}]}}
JSONLEOF
report13=$(scan "$SAMPLE_STUB" --jsonl "$TMP_JSONL13") || true
mcp_count=$(printf '%s' "$report13" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('mcp_invalid_args', [])))
" 2>/dev/null)
if [ "${mcp_count:-0}" -eq 1 ]; then
  ok "MCP -32602: dedicated bucket → 1 entry"
else
  fail_test "MCP -32602" "expected 1 mcp_invalid_args entry, got ${mcp_count:-0}"
fi

mcp_tool=$(printf '%s' "$report13" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
b = te.get('mcp_invalid_args', [])
print(b[0].get('tool_name','') if b else '')
" 2>/dev/null)
if [ "$mcp_tool" = "mcp__obsidian-builtin__vault_patch" ]; then
  ok "MCP -32602: bucket entry carries tool_name"
else
  fail_test "MCP -32602 tool_name" "expected vault_patch tool_name, got '$mcp_tool'"
fi

# Precision: a different MCP error code must NOT land in this bucket.
TMP_JSONL13B="$TMPDIR13/mcp_other.jsonl"
cat > "$TMP_JSONL13B" << 'JSONLEOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"mo1","name":"mcp__x__y","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"mo1","is_error":true,"content":[{"type":"text","text":"MCP error -32000: Server error, please retry"}]}]}}
JSONLEOF
report13b=$(scan "$SAMPLE_STUB" --jsonl "$TMP_JSONL13B") || true
mcp_other=$(printf '%s' "$report13b" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('mcp_invalid_args', [])))
" 2>/dev/null)
if [ "${mcp_other:-1}" -eq 0 ]; then
  ok "MCP -32602 precision: a -32000 error → 0 entries (only -32602 counted)"
else
  fail_test "MCP -32602 precision" "expected 0 for -32000 error, got $mcp_other"
fi

rm -rf "$TMPDIR13"

# ── Test 14: mutating-MCP timeout bucket (#421 detector 4) ────────────────────
#
# A vault_write/vault_move/vault_delete result matching /timed out/i leaves the
# store in UNKNOWN state — materially unlike a read timeout. Distinct bucket.

echo "--- test 14: mutating-MCP timeout distinct bucket ---"

TMPDIR14=$(mktemp -d)
TMP_JSONL14="$TMPDIR14/timeout.jsonl"
cat > "$TMP_JSONL14" << 'JSONLEOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"mv1","name":"mcp__obsidian-builtin__vault_move","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"mv1","is_error":true,"content":[{"type":"text","text":"The operation timed out."}]}]}}
JSONLEOF
report14=$(scan "$SAMPLE_STUB" --jsonl "$TMP_JSONL14") || true
mut_count=$(printf '%s' "$report14" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('mutating_mcp_timeouts', [])))
" 2>/dev/null)
if [ "${mut_count:-0}" -eq 1 ]; then
  ok "mutating-MCP timeout: vault_move timeout → 1 distinct-bucket entry"
else
  fail_test "mutating-MCP timeout" "expected 1 entry, got ${mut_count:-0}"
fi

# Precision: a READ-tool (vault_read) timeout must NOT land in the mutating
# bucket (a read timeout leaves no UNKNOWN store state).
TMP_JSONL14B="$TMPDIR14/read_timeout.jsonl"
cat > "$TMP_JSONL14B" << 'JSONLEOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"rd1","name":"mcp__obsidian-builtin__vault_read","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"rd1","is_error":true,"content":[{"type":"text","text":"The operation timed out."}]}]}}
JSONLEOF
report14b=$(scan "$SAMPLE_STUB" --jsonl "$TMP_JSONL14B") || true
read_to=$(printf '%s' "$report14b" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('mutating_mcp_timeouts', [])))
" 2>/dev/null)
if [ "${read_to:-1}" -eq 0 ]; then
  ok "mutating-MCP timeout precision: vault_read timeout → 0 entries (read ≠ mutating)"
else
  fail_test "mutating-MCP timeout precision" "expected 0 for a read timeout, got $read_to"
fi

# Precision: a mutating tool that did NOT time out (some other error) → 0.
TMP_JSONL14C="$TMPDIR14/mut_other.jsonl"
cat > "$TMP_JSONL14C" << 'JSONLEOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"mw1","name":"mcp__obsidian-builtin__vault_write","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"mw1","is_error":true,"content":[{"type":"text","text":"File not found: some/path.md"}]}]}}
JSONLEOF
report14c=$(scan "$SAMPLE_STUB" --jsonl "$TMP_JSONL14C") || true
mut_other=$(printf '%s' "$report14c" | python3 -c "
import json, sys
te = json.load(sys.stdin).get('tool_events', {})
print(len(te.get('mutating_mcp_timeouts', [])))
" 2>/dev/null)
if [ "${mut_other:-1}" -eq 0 ]; then
  ok "mutating-MCP timeout precision: vault_write non-timeout error → 0 entries"
else
  fail_test "mutating-MCP timeout precision" "expected 0 for a non-timeout mutating error, got $mut_other"
fi

rm -rf "$TMPDIR14"

# ── Summary ──────────────────────────────────────────────────────────────────

echo "---"
echo "test_scan_stub: pass=$pass fail=$fail"
if [ "$fail" -ne 0 ]; then
  echo "test_scan_stub: FAIL"
  exit 1
fi
echo "test_scan_stub: OK"
