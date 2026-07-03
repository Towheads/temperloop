#!/usr/bin/env bash
#
# lint-pr-body.sh — assert a PR body's issue-linkage is what the author intended.
#
# GitHub's closing-keyword parser is purely LEXICAL: it matches the token
# sequence `(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved) #N`
# (case-insensitive) anywhere in a PR body — or in any commit message merged to
# the default branch — and closes #N on merge. Two failure modes follow from how
# blunt that parser is, both seen in real prose:
#
#   1. BACKTICKS / CODE SPANS SUPPRESS the match. A backticked `Closes #5` does
#      NOT close anything — silently ignored. So when you MEANT to close, a
#      backticked keyword is a trap: the issue stays open after merge.
#
#   2. NEGATION DOES NOT SUPPRESS the match. `does not close #5`, `won't fix #5`
#      etc. STILL close #5 — the parser doesn't understand "not". So when you did
#      NOT mean to close, a negated (or stray, or opportunistic) bare keyword is a
#      trap: it closes an issue you only mentioned in passing.
#
# This lint mechanizes the bidirectional post-merge linkage check so we can TRUST
# the parser instead of hand-verifying every PR. It has two modes:
#
#   --expect N  (known intent — used by tests and any caller that knows the
#               issue the PR is meant to close):
#     (a) assert the intended `Closes #N` is present AND BARE (not backticked,
#         not inside a fenced code block) — fail if backticked or absent (the
#         silent-non-close trap);
#     (b) flag any OTHER honored closing keyword for M != N (stray/opportunistic
#         close GitHub will act on);
#     (c) flag any NEGATED honored keyword (even for N — a negated phrase reads
#         as "won't close" to a human but DOES close to GitHub; surfacing it lets
#         the author rephrase).
#
#   (no --expect)  (intent unknown — the realistic CI gate that runs on EVERY
#               PR, where we cannot know which close was intended):
#     flag every NEGATED honored closing keyword (always a real, usually-
#     unintended close trigger). Bare positive closes are left alone (a normal
#     PR legitimately closes its issue); the backtick-trap needs known intent
#     and so is exercised via --expect (tests).
#
# A keyword "GitHub would honor" = appears outside any inline code span or fenced
# code block. Negation is irrelevant to whether GitHub honors it, so a negated
# bare keyword IS honored (and thus flagged).
#
# Usage:
#   lint-pr-body.sh [--expect N] [FILE]
#   lint-pr-body.sh [--expect N] < body.md
#
# Exits 0 if clean, 1 on any violation (clear message on stderr), 2 on usage
# error.
#
# Dependency-free: bash + awk only. shellcheck-clean (-e SC1091).

set -euo pipefail

usage() {
	cat >&2 <<'EOF'
Usage: lint-pr-body.sh [--expect N] [FILE]
       lint-pr-body.sh [--expect N] < body.md

  --expect N   Assert the intended `Closes #N` is present and BARE (not
               backticked / not in a fenced code block). Fails if backticked or
               absent. Also flags any OTHER honored close (M != N).
  FILE         Read the PR body from FILE (default: stdin).

With or without --expect, any NEGATED honored closing keyword is flagged:
GitHub ignores the negation, so `does not close #N` still closes #N on merge.
EOF
}

expect=""
file=""

while [ $# -gt 0 ]; do
	case "$1" in
		--expect)
			[ $# -ge 2 ] || { echo "lint-pr-body: --expect needs an argument" >&2; usage; exit 2; }
			expect="$2"
			shift 2
			;;
		--expect=*)
			expect="${1#--expect=}"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		--)
			shift
			[ $# -gt 0 ] && file="$1"
			break
			;;
		-*)
			echo "lint-pr-body: unknown option: $1" >&2
			usage
			exit 2
			;;
		*)
			file="$1"
			shift
			;;
	esac
done

if [ -n "$expect" ] && ! printf '%s' "$expect" | grep -qE '^[0-9]+$'; then
	echo "lint-pr-body: --expect must be a number, got: $expect" >&2
	exit 2
fi

# Read the body (file arg or stdin) into a variable.
if [ -n "$file" ]; then
	[ -f "$file" ] || { echo "lint-pr-body: file not found: $file" >&2; exit 2; }
	body="$(cat -- "$file")"
else
	body="$(cat)"
fi

# Lexical analysis in awk: walk the body line by line, tracking fenced-code-block
# state (``` / ~~~) and masking inline code spans (backtick runs) per line, then
# scan the UNMASKED text for closing keywords. This is exactly the surface
# GitHub's parser sees. For each closing keyword found we also decide whether it
# is NEGATED — a negation cue (no/not/n't/never/without/cannot/can't) appearing
# shortly before the keyword on the same line.
#
# awk emits one record per occurrence:
#   H <issue> <neg>   honored (bare) closing keyword; neg=1 if negated, else 0
#   M <issue> <neg>   masked (backticked/fenced) closing keyword
#
# Portability: we do NOT rely on awk IGNORECASE (gawk-only — absent in the BWK
# awk on macOS). Instead every comparison is done on a tolower() copy. Offsets
# are preserved by tolower (same length), so numbers extracted from the lowered
# copy match the original. Alternatives are ordered longest-first so awks that
# are not leftmost-longest still match the full keyword (e.g. `closes`, not the
# `close` prefix).
analysis="$(printf '%s\n' "$body" | awk '
	BEGIN { infence = 0 }
	{
		line = $0
		stripped = line
		sub(/^[ \t]*/, "", stripped)
		if (stripped ~ /^(```|~~~)/) { infence = (infence ? 0 : 1); next }
		if (infence) { scan(line, 0); next }

		# Mask inline code spans: split the line into a "bare" buffer (text
		# outside backticks) and a "masked" buffer (text inside backticks),
		# replacing the other side with spaces so token adjacency is preserved
		# and offsets stay aligned for negation lookback.
		bare = ""; masked = ""; incode = 0; n = length(line); i = 1
		while (i <= n) {
			c = substr(line, i, 1)
			if (c == "`") { incode = (incode ? 0 : 1); bare = bare " "; masked = masked " "; i++; continue }
			if (incode) { masked = masked c; bare = bare " " }
			else        { bare = bare c;     masked = masked " " }
			i++
		}
		scan(bare, 1)
		scan(masked, 0)
	}

	function scan(text, honored,   lc, t, kw, num, pre, neg, consumed) {
		lc = tolower(text)
		t = lc
		consumed = 0
		while (match(t, /(closes|closed|close|fixes|fixed|fix|resolves|resolved|resolve)[ \t]*:?[ \t]*#[0-9]+/)) {
			kw = substr(t, RSTART, RLENGTH)
			# Text preceding this keyword on the line (lowercased; for negation
			# lookback). Window the last ~40 chars so an early "not" elsewhere on
			# the line does not spuriously negate a later keyword.
			pre = substr(lc, 1, consumed + RSTART - 1)
			if (length(pre) > 40) pre = substr(pre, length(pre) - 39)
			neg = 0
			# Whole-word cues (no, not, never, without, cannot) require a
			# non-alnum boundary on both sides. The contraction cue n([apostrophe])t
			# (won'\''t, don'\''t, doesn'\''t, can'\''t) is a WORD SUFFIX, so it only
			# needs a trailing boundary — match it separately.
			if (pre ~ /(^|[^[:alnum:]])(no|not|never|without|cannot)([^[:alnum:]]|$)/) neg = 1
			if (pre ~ /n.t([^[:alnum:]]|$)/) neg = 1
			if (match(kw, /#[0-9]+/)) {
				num = substr(kw, RSTART + 1, RLENGTH - 1)
				print (honored ? "H " : "M ") num " " neg
			}
			consumed = consumed + RSTART + RLENGTH - 1
			t = substr(t, RSTART + RLENGTH)
		}
	}
')"

# Parse the analysis into space-delimited collections.
honored_nums=""        # all bare/honored issue numbers
masked_nums=""         # all masked issue numbers
negated_nums=""        # honored AND negated issue numbers
while IFS=' ' read -r kind num neg; do
	[ -z "${kind:-}" ] && continue
	case "$kind" in
		H)
			honored_nums="$honored_nums $num"
			[ "${neg:-0}" = "1" ] && negated_nums="$negated_nums $num"
			;;
		M) masked_nums="$masked_nums $num" ;;
	esac
done <<EOF
$analysis
EOF

contains() {
	case " $2 " in
		*" $1 "*) return 0 ;;
		*) return 1 ;;
	esac
}

violations=0

# (1) --expect bare-presence assertion.
if [ -n "$expect" ]; then
	if contains "$expect" "$honored_nums"; then
		: # intended Closes present and bare — good
	elif contains "$expect" "$masked_nums"; then
		echo "lint-pr-body: FAIL — intended 'Closes #$expect' is backticked / inside a code span; GitHub will SILENTLY IGNORE it and the issue will NOT close on merge. Make it bare text on its own line." >&2
		violations=$((violations + 1))
	else
		echo "lint-pr-body: FAIL — intended 'Closes #$expect' is ABSENT from the PR body; the issue will not auto-close on merge. Add a bare 'Closes #$expect' line." >&2
		violations=$((violations + 1))
	fi
fi

# (2) With known intent: flag every OTHER honored (bare) closing keyword.
if [ -n "$expect" ]; then
	seen=""
	for num in $honored_nums; do
		[ "$num" = "$expect" ] && continue
		contains "$num" "$seen" && continue
		seen="$seen $num"
		echo "lint-pr-body: FAIL — body contains a closing keyword for #$num that GitHub WILL honor on merge, but the intended close is #$expect. If you did NOT mean to close #$num, rephrase to break the keyword-then-#number adjacency (e.g. 'issue #$num') or backtick it." >&2
		violations=$((violations + 1))
	done
fi

# (3) Always (both modes): flag every NEGATED honored closing keyword. GitHub
# ignores the negation, so the keyword still closes the issue despite prose that
# reads as "won't close". In --expect mode the intended issue's negated form is
# still surfaced (so the author can rephrase to non-negated bare text); the
# stray-other check above already covered non-negated others, so dedupe.
seen_neg=""
for num in $negated_nums; do
	contains "$num" "$seen_neg" && continue
	seen_neg="$seen_neg $num"
	# Avoid double-counting a non-expect issue already flagged as stray in (2):
	# that message and this one both fire, but each is a distinct, true problem
	# (stray AND negated). Keep both for clarity? Suppress the duplicate: if it
	# was flagged in (2) it is already counted. Only the intended issue (==expect)
	# or the no-expect case reaches here without a prior (2) flag.
	if [ -n "$expect" ] && [ "$num" != "$expect" ]; then
		# already reported as a stray "other" close in (2); skip to avoid a
		# duplicate violation count for the same occurrence.
		continue
	fi
	echo "lint-pr-body: FAIL — body contains a NEGATED closing keyword for #$num (e.g. 'does not close #$num'). GitHub's parser IGNORES the negation and WILL close #$num on merge. Remove the keyword-then-#number adjacency (e.g. 'issue #$num') or backtick it if you only mean to reference it." >&2
	violations=$((violations + 1))
done

if [ "$violations" -gt 0 ]; then
	echo "lint-pr-body: $violations issue-linkage violation(s) found." >&2
	exit 1
fi

echo "lint-pr-body: OK — issue linkage is clean."
exit 0
