#!/usr/bin/env bash
# test_checkin_status_trailing_newline.sh — pins the agent-plane half of
# foundation#1308 / temperloop#853: /check-in's in-place `Status`-line
# rewrite (claude/commands/check-in.md, Part 2's shared preamble) must
# preserve or restore a pipeline surface's trailing newline, so a later
# appender can never glue a `### heading` mid-line.
#
# The store-seam half (ks_append's own fresh-line-on-append guarantee,
# `_ks_backend_plain_files_append` in workflows/scripts/lib/knowledge_store.sh)
# is already fixed and OUT OF SCOPE here — this suite deliberately exercises
# the OTHER half: what happens when the STATUS-LINE EDIT ITSELF (not the
# append) is the thing that leaves a surface unterminated.
#
# Why a hermetic script can test prose: check-in.md's fix is "run this exact
# idempotent shell check after every Status-line Edit" — a real, deterministic
# command, not a judgment call. This suite pins that command's two properties
# (restores a missing trailing newline; is a true no-op when one already
# exists) and then proves, via the concrete before/after scenario named in
# the item notes, that skipping it reproduces the corruption while running it
# prevents that corruption.
#
# A plain string-replace `Edit` only touches the bytes it matches — it can
# never add or remove anything past the match. python3's str.replace() is
# used below to reproduce that exact semantic (unlike `sed`/`perl -p`, which
# can silently normalize a missing final-line terminator).
#
# Usage: bash workflows/scripts/tests/test_checkin_status_trailing_newline.sh

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required for this test" >&2; exit 1; }

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# edit_status_line <file> <old> <new> — byte-exact substring replace, first
# (and here, only) occurrence — the same semantic the harness's real `Edit`
# tool guarantees: nothing outside the match is touched, and no newline is
# added or removed unless it was literally part of <old>/<new>.
edit_status_line() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "rb") as f:
    content = f.read()
old_b, new_b = old.encode(), new.encode()
if content.count(old_b) != 1:
    sys.exit(f"FATAL: expected exactly one match of {old!r}, found {content.count(old_b)}")
content = content.replace(old_b, new_b, 1)
with open(path, "wb") as f:
    f.write(content)
PY
}

# ends_with_newline <file> — true iff the file's last byte is '\n'.
ends_with_newline() {
  [ -z "$(tail -c1 -- "$1")" ]
}

# THE FIX — the exact command check-in.md's Part 2 preamble now requires
# after every Status-line Edit (temperloop#853). Idempotent, conditional.
trailing_newline_guard() {
  [ -z "$(tail -c1 -- "$1")" ] || printf '\n' >> "$1"
}

OLD_STATUS='### pending-example - **Status:** open'
NEW_STATUS='### pending-example - **Status:** resolved — confirmed (check-in 2026-08-02; auto-taken default was right)'

new_fixture_unterminated() { # <path> — the newest (last) entry, no trailing \n, as a fresh vault_append/ks_append entry commonly lands
  printf '# Pending decisions\n\nSome prior, already-resolved entry.\n\n%s\n- **class:** B\n- **default taken:** kept the funnel frozen' "$OLD_STATUS" > "$1"
  # Deliberately no trailing newline after the last line above.
}

# ── 1. Unguarded: the Edit alone does not fix an unterminated file ─────────
echo "1. a Status-line Edit alone does not restore a missing trailing newline"
F1="$TMP/f1.md"
new_fixture_unterminated "$F1"
if ends_with_newline "$F1"; then
  bad "fixture sanity" "fixture should start unterminated"
else
  ok "fixture starts unterminated, as a freshly-appended entry does"
fi
edit_status_line "$F1" "$OLD_STATUS" "$NEW_STATUS"
if ends_with_newline "$F1"; then
  bad "Edit alone" "expected the file to STILL lack a trailing newline after a bare substring Edit"
else
  ok "confirms the mechanism: a bare Status-line Edit leaves an unterminated file unterminated"
fi

# ── 2. THE REGRESSION: an unguarded subsequent append glues mid-line ───────
echo "2. without the guard, the next appender glues its heading mid-line (the corruption)"
NEW_ENTRY='### fresh-entry - **Status:** open
- **class:** C
'
printf '%s' "$NEW_ENTRY" >> "$F1"   # models vault_append's raw append (no fresh-line guard) — the corruptor named in the item notes
if grep -qxF '### fresh-entry - **Status:** open' "$F1"; then
  bad "regression repro" "expected the new heading to be glued mid-line, but it landed on its own line — repro is not exercising the bug"
else
  ok "reproduces the named corruption: the new '### fresh-entry' heading is glued onto the prior line, not its own"
fi
LINE_COUNT_BEFORE_ANCHOR=$(grep -c '^### fresh-entry' "$F1")
if [ "$LINE_COUNT_BEFORE_ANCHOR" -eq 0 ]; then
  ok "a line-start '^### ' scan (the real consumer pattern) misses the corrupted entry entirely"
else
  bad "regression repro" "expected '^### fresh-entry' to NOT match at line-start in the corrupted file"
fi

# ── 3. THE FIX: guard after the Edit restores the missing newline ──────────
echo "3. the trailing-newline guard restores a missing terminator"
F3="$TMP/f3.md"
new_fixture_unterminated "$F3"
edit_status_line "$F3" "$OLD_STATUS" "$NEW_STATUS"
trailing_newline_guard "$F3"
if ends_with_newline "$F3"; then
  ok "guard restores the trailing newline after the Status-line Edit"
else
  bad "guard" "file still lacks a trailing newline after the guard ran"
fi
# Exactly ONE trailing newline was added — not zero, not two.
TAIL2="$(tail -c2 -- "$F3" | od -An -c | tr -d ' ')"
case "$TAIL2" in
  *'\n\n'*) bad "guard exactness" "guard introduced a stray blank line (two trailing newlines)" ;;
  *) ok "guard adds exactly one trailing newline, no stray blank line" ;;
esac

# ── 4. THE FIX composed with an append: the next heading lands clean ───────
echo "4. with the guard, the next appender's heading lands on its own line"
printf '%s' "$NEW_ENTRY" >> "$F3"
if grep -qxF '### fresh-entry - **Status:** open' "$F3"; then
  ok "the new heading lands on its own full line"
else
  bad "fix verification" "the new heading is still glued mid-line even after the guard ran"
fi
LINE_COUNT_AFTER_ANCHOR=$(grep -c '^### fresh-entry' "$F3")
if [ "$LINE_COUNT_AFTER_ANCHOR" -eq 1 ]; then
  ok "a line-start '^### ' scan now finds the new entry — a subsequent append can never land mid-line"
else
  bad "fix verification" "expected exactly one line-start match for '^### fresh-entry', got $LINE_COUNT_AFTER_ANCHOR"
fi

# ── 5. Idempotent / no-op on an already-terminated file ────────────────────
echo "5. the guard is a true no-op on an already-terminated file (no stray blank line)"
F5="$TMP/f5.md"
printf '# Pending decisions\n\n%s\n- **class:** B\n' "$NEW_STATUS" > "$F5"   # already newline-terminated
BEFORE_HASH="$(shasum -a 256 "$F5" | awk '{print $1}')"
trailing_newline_guard "$F5"
AFTER_HASH="$(shasum -a 256 "$F5" | awk '{print $1}')"
if [ "$BEFORE_HASH" = "$AFTER_HASH" ]; then
  ok "guard is byte-identical no-op on an already-terminated file"
else
  bad "no-op guarantee" "guard changed a file that was already correctly terminated"
fi

# ── 6. Running the guard twice never double-appends a newline ──────────────
echo "6. running the guard twice is idempotent"
trailing_newline_guard "$F3"   # F3 is already terminated from step 3 — run again
TAIL2_AFTER_TWICE="$(tail -c2 -- "$F3" | od -An -c | tr -d ' ')"
case "$TAIL2_AFTER_TWICE" in
  *'\n\n'*) bad "double-run idempotency" "a second guard run introduced a stray blank line" ;;
  *) ok "a second guard run adds nothing further (idempotent)" ;;
esac

echo
echo "test_checkin_status_trailing_newline: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
