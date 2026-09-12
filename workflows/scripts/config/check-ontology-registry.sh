#!/usr/bin/env bash
#
# check-ontology-registry.sh — the CI checker behind ontology-registry.tsv,
# the single source of truth for the pipeline's tracker and plan vocabularies
# (ADR 0032, docs/adr/0032-ontology-registry-is-source-of-truth-for-tracker-
# and-plan-vocabularies.md; epic temperloop#1910 L0-b).
#
# Same live-check-then-fixture-tests mold as check-reviewer-routing.sh,
# check-gate-paths.sh and validate-exec-bit-registry.sh ("a registry that is
# not mechanically reconciled against the tree is a registry that drifts").
# The live gate exercises the GREEN arm against this repo; every RED arm is
# proven in tests/test_check_ontology_registry.sh.
#
# SIX CHECKS:
#
#   1. WELL-FORMED   every registry row is TAB-separated with four fields,
#      a known AXIS, and a unique (AXIS, TOKEN) pair; every REQUIRED axis has
#      at least one row. An absent/unreadable registry or allowlist is
#      CANNOT EVALUATE (exit 2, never a silent OK — epic #1409's rule); a
#      registry with zero rows is EMPTY-REGISTRY (exit 1).
#   2. ROUTE-EQUAL   the `state:route` alphabet is set-EQUAL to the
#      `"route": "a|b|..."` block in issue-state.sh's usage text — the one
#      place the resolver publishes its own enum. Neither side may drift alone.
#   3. TREE SCAN     every git-tracked file is scanned for the TWO token
#      grammars a vocabulary item is written in (nothing fuzzier — a scan of
#      every `[.]` would trip on regex classes and array indexes):
#        * a `fnd:` label: `fnd:<field>[:<value>...]`, concrete slugs only.
#          Placeholders (`fnd:<field>:*`, `fnd:status:*`) reduce to the bare
#          field mention. The field must be a `label-field` row; a `closed`
#          field's full token must be a `state:issue-status` row; an `open`
#          field (a claim stamp, a component slug) accepts any value. Any
#          segment starting with the `personal-prefix` token is EXEMPT.
#        * a plan sentinel: a markdown list checkbox at line start (`- [m] `)
#          or a backtick-quoted one. It must be a `state:plan-sentinel` row.
#      Every token that fails is UNLISTED-LABEL / UNLISTED-SENTINEL, named
#      with its path:line — unless the grandfather allowlist carries it.
#   4. GRANDFATHER   a listed token that the tree no longer contains, or that
#      the registry now lists, is GRANDFATHER-STALE (pay debt down by
#      deleting the line in the same PR).
#   5. RATCHET       the allowlist may only SHRINK: a token present now but
#      absent at the ratchet base ref is ALLOWLIST-GREW. Same mechanics as
#      validate-exec-bit-registry.sh's §ratchet (bootstrap-exempt; explicit
#      unresolvable ref = CANNOT EVALUATE; no origin remote = reported SKIP).
#   6. CONTRACT DOCS each of the four contract docs must cite the registry
#      by filename (DOC-CITATION-MISSING) and must not restate a vocabulary
#      table: a markdown table row whose first cell is a backtick-quoted
#      registry token, or a `- [<c>] <title>` sentinel-grammar example line,
#      is DOC-RESTATES (the check-reviewer-routing.sh set-membership shape).
#
# Usage:
#   check-ontology-registry.sh
#
# Env overrides (the fixture seams — tests/test_check_ontology_registry.sh):
#   ONTOLOGY_REGISTRY_FILE       registry to validate (default: sibling
#                                ontology-registry.tsv)
#   ONTOLOGY_ALLOWLIST_FILE      grandfather allowlist (default: sibling
#                                ontology-grandfather-allowlist.tsv)
#   ONTOLOGY_ROOT                repo root to scan (default: this repo)
#   ONTOLOGY_TRACKED_FILE        file of ROOT-relative paths (one per line)
#                                to scan instead of `git ls-files`
#   ONTOLOGY_ISSUE_STATE_SH      the resolver whose route block is compared
#                                (default: ROOT/workflows/scripts/build/
#                                issue-state.sh)
#   ONTOLOGY_CONTRACT_DOCS       space-separated ROOT-relative docs for check
#                                6 (default: the four ADR 0032 docs; set to
#                                the empty string to skip the check)
#   ONTOLOGY_ALLOWLIST_BASE_REF  explicit ratchet base ref (default: empty —
#                                auto-resolved from origin/HEAD, origin/main)
#
# Kept bash-3.2-portable (macOS default shell): no associative arrays, no
# mapfile. Membership tests are `grep -Fxq` over newline-delimited lists.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

: "${ONTOLOGY_REGISTRY_FILE:=$SCRIPT_DIR/ontology-registry.tsv}"
: "${ONTOLOGY_ALLOWLIST_FILE:=$SCRIPT_DIR/ontology-grandfather-allowlist.tsv}"
: "${ONTOLOGY_ROOT:=$REPO_ROOT_DEFAULT}"
: "${ONTOLOGY_TRACKED_FILE:=}"
: "${ONTOLOGY_ISSUE_STATE_SH:=$ONTOLOGY_ROOT/workflows/scripts/build/issue-state.sh}"
: "${ONTOLOGY_ALLOWLIST_BASE_REF:=}"
# `+x`, not `:=` — an EMPTY value is a deliberate "skip check 6", never a
# request for the default.
if [ -z "${ONTOLOGY_CONTRACT_DOCS+x}" ]; then
  ONTOLOGY_CONTRACT_DOCS="workflows/scripts/board/ISSUES-ONLY-BACKEND.md claude/plan-schema.md claude/decision-queue-contract.md claude/work-class-policy.md"
fi

RC_CANNOT_EVALUATE=2

KNOWN_AXES="node
edge
label-field
personal-prefix
state:issue-status
state:plan-sentinel
state:pr-merge
state:decision-baton
state:route
work-class
source"
# Every axis the ADR names must be populated — an empty alphabet is a
# registry that pretends to cover a vocabulary it does not.
REQUIRED_AXES="$KNOWN_AXES"

_or_cannot_evaluate() {
  printf 'check-ontology-registry: CANNOT EVALUATE — %s\n' "$1" >&2
  exit "$RC_CANNOT_EVALUATE"
}

failures=""
n_fail=0
_or_fail() {
  failures="$failures$1
"
  n_fail=$((n_fail + 1))
}

_or_ere_escape() {
  # `]` first, `[` last-before-close — the bracket-expression ordering BSD
  # sed needs (same helper shape as check-reviewer-routing.sh).
  printf '%s' "$1" | sed -E 's/[]\.^$*+?(){}|[]/\\&/g'
}

# --- inputs: fail closed on anything unreadable ------------------------------
for f in "$ONTOLOGY_REGISTRY_FILE" "$ONTOLOGY_ALLOWLIST_FILE"; do
  [ -e "$f" ] || _or_cannot_evaluate "file not found: $f"
  [ -r "$f" ] || _or_cannot_evaluate "file exists but is not readable: $f"
done
[ -d "$ONTOLOGY_ROOT" ] || _or_cannot_evaluate "root is not a directory: $ONTOLOGY_ROOT"
[ -r "$ONTOLOGY_ISSUE_STATE_SH" ] || _or_cannot_evaluate "issue-state.sh not readable at $ONTOLOGY_ISSUE_STATE_SH (the route alphabet has nothing to be compared against)"

# --- 1. well-formed registry ---------------------------------------------------
# REG_ROWS: one `axis<TAB>token<TAB>qualifier` line per row (detail dropped —
# it is documentation, never read by a check).
REG_ROWS=""
REG_KEYS=""
n_rows=0
while IFS=$'\t' read -r axis token qual detail || [ -n "${axis:-}" ]; do
  [ -z "${axis:-}" ] && continue
  case "$axis" in \#*) continue ;; esac
  if [ -z "${token:-}" ] || [ -z "${qual:-}" ] || [ -z "${detail:-}" ]; then
    _or_fail "MALFORMED  registry row needs 4 tab-separated fields (axis, token, qualifier, detail): $axis${token:+	$token}"
    continue
  fi
  if ! grep -Fxq -- "$axis" <<<"$KNOWN_AXES"; then
    _or_fail "MALFORMED  unknown axis '$axis' on row for token '$token' (known: $(tr '\n' ' ' <<<"$KNOWN_AXES"))"
    continue
  fi
  if grep -Fxq -- "$axis	$token" <<<"$REG_KEYS"; then
    _or_fail "DUPLICATE  ($axis, $token) appears on more than one registry row"
    continue
  fi
  REG_KEYS="$REG_KEYS$axis	$token
"
  REG_ROWS="$REG_ROWS$axis	$token	$qual
"
  n_rows=$((n_rows + 1))
done <"$ONTOLOGY_REGISTRY_FILE"

if [ "$n_rows" -eq 0 ]; then
  printf 'EMPTY-REGISTRY  zero vocabulary rows parsed from %s — an empty registry would pass every token vacuously\n' "$ONTOLOGY_REGISTRY_FILE" >&2
  exit 1
fi

# _or_tokens <axis> -> the tokens registered on that axis, one per line
_or_tokens() {
  awk -F'\t' -v a="$1" '$1 == a { print $2 }' <<<"$REG_ROWS"
}
# _or_qual <axis> <token> -> that row's qualifier
_or_qual() {
  awk -F'\t' -v a="$1" -v t="$2" '$1 == a && $2 == t { print $3; exit }' <<<"$REG_ROWS"
}

while IFS= read -r axis; do
  [ -n "$axis" ] || continue
  if [ -z "$(_or_tokens "$axis")" ]; then
    _or_fail "MISSING-AXIS  registry carries no row on required axis '$axis'"
  fi
done <<<"$REQUIRED_AXES"

LABEL_FIELDS="$(_or_tokens label-field)"
ISSUE_STATUS="$(_or_tokens state:issue-status)"
SENTINELS="$(_or_tokens state:plan-sentinel)"
PERSONAL_PREFIXES="$(_or_tokens personal-prefix)"
ROUTES="$(_or_tokens state:route)"

# --- 2. route alphabet == issue-state.sh's published enum ---------------------
# The usage block spells the enum as `"route": "a|b|...|z"`, wrapped across
# lines; flatten, take the first such block, split on `|`, trim.
resolver_routes="$(tr '\n' ' ' <"$ONTOLOGY_ISSUE_STATE_SH" | grep -oE '"route": "[^"]*"' | head -1 \
  | sed -E 's/^"route": "//; s/"$//' | tr '|' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' || true)"
if [ -z "$resolver_routes" ]; then
  _or_fail "ROUTE-DRIFT  no \"route\": \"a|b|...\" block found in $ONTOLOGY_ISSUE_STATE_SH — the resolver's enum moved or was reworded"
else
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    grep -Fxq -- "$r" <<<"$ROUTES" || _or_fail "ROUTE-DRIFT  issue-state.sh emits route '$r' but the registry's state:route axis does not list it"
  done <<<"$resolver_routes"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    grep -Fxq -- "$r" <<<"$resolver_routes" || _or_fail "ROUTE-DRIFT  registry lists route '$r' but issue-state.sh's enum does not emit it"
  done <<<"$ROUTES"
fi

# --- grandfather allowlist ------------------------------------------------------
ALLOW_TOKENS=""
while IFS=$'\t' read -r a_tok a_reason || [ -n "${a_tok:-}" ]; do
  [ -z "${a_tok:-}" ] && continue
  case "$a_tok" in \#*) continue ;; esac
  if [ -z "${a_reason:-}" ]; then
    _or_fail "MALFORMED  allowlist row needs a non-empty REASON: $a_tok"
    continue
  fi
  if grep -Fxq -- "$a_tok" <<<"$ALLOW_TOKENS"; then
    _or_fail "DUPLICATE  allowlist token appears twice: $a_tok"
    continue
  fi
  ALLOW_TOKENS="$ALLOW_TOKENS$a_tok
"
done <"$ONTOLOGY_ALLOWLIST_FILE"

# --- 3. tree scan -----------------------------------------------------------------
if [ -n "$ONTOLOGY_TRACKED_FILE" ]; then
  [ -r "$ONTOLOGY_TRACKED_FILE" ] || _or_cannot_evaluate "tracked-path list not readable: $ONTOLOGY_TRACKED_FILE"
  TRACKED="$(grep -v '^[[:space:]]*$' "$ONTOLOGY_TRACKED_FILE" || true)"
else
  TRACKED="$(git -C "$ONTOLOGY_ROOT" ls-files 2>/dev/null)" \
    || _or_cannot_evaluate "git ls-files failed under $ONTOLOGY_ROOT (not a git checkout? set ONTOLOGY_TRACKED_FILE)"
fi
if [ -z "$TRACKED" ]; then
  _or_cannot_evaluate "zero tracked paths to scan under $ONTOLOGY_ROOT"
fi

LABEL_RE='fnd:[a-z0-9][a-z0-9/-]*(:[A-Za-z0-9][A-Za-z0-9-]*)*'
SENT_LINE_RE='^[[:space:]]*[-*] \[[^]]\] '
# shellcheck disable=SC2016  # the backticks are literal pattern characters
SENT_TICK_RE='`\[[^]]\]`'

# One grep pass over the tracked set: `-H` forces the filename even when a
# batch holds a single file, `-I` skips binaries, `-o` yields one hit per
# line as `path:line:match`.
HITS="$(cd "$ONTOLOGY_ROOT" && printf '%s\n' "$TRACKED" | while IFS= read -r p; do
    [ -f "$p" ] && printf '%s\0' "$p"
  done | xargs -0 grep -nHIoE -e "$LABEL_RE" -e "$SENT_LINE_RE" -e "$SENT_TICK_RE" 2>/dev/null || true)"

SEEN_TOKENS=""
n_hits=0
n_exempt=0
n_grandfathered=0
_or_note_seen() {
  grep -Fxq -- "$1" <<<"$SEEN_TOKENS" || SEEN_TOKENS="$SEEN_TOKENS$1
"
}
# _or_personal <token> -> rc 0 iff any segment after `fnd:` starts with a
# registered personal prefix.
_or_personal() {
  local body="${1#fnd:}" seg rest pfx
  rest="$body"
  while :; do
    seg="${rest%%:*}"
    while IFS= read -r pfx; do
      [ -n "$pfx" ] || continue
      case "$seg" in "$pfx"*) return 0 ;; esac
    done <<<"$PERSONAL_PREFIXES"
    [ "$rest" = "$seg" ] && break
    rest="${rest#*:}"
  done
  return 1
}

while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  path="${hit%%:*}"
  rest="${hit#*:}"
  lineno="${rest%%:*}"
  match="${rest#*:}"
  n_hits=$((n_hits + 1))
  case "$match" in
    fnd:*)
      token="$match"
      if _or_personal "$token"; then
        n_exempt=$((n_exempt + 1))
        continue
      fi
      _or_note_seen "$token"
      body="${token#fnd:}"
      field="${body%%:*}"
      field_tok="fnd:$field"
      if ! grep -Fxq -- "$field_tok" <<<"$LABEL_FIELDS"; then
        if grep -Fxq -- "$token" <<<"$ALLOW_TOKENS"; then n_grandfathered=$((n_grandfathered + 1)); continue; fi
        _or_fail "UNLISTED-LABEL  $token at $path:$lineno — field '$field_tok' is not a label-field row in the registry"
        continue
      fi
      [ "$body" = "$field" ] && continue # bare field mention (a placeholder like fnd:status:*)
      case "$(_or_qual label-field "$field_tok")" in
        open) continue ;;
      esac
      if ! grep -Fxq -- "$token" <<<"$ISSUE_STATUS"; then
        if grep -Fxq -- "$token" <<<"$ALLOW_TOKENS"; then n_grandfathered=$((n_grandfathered + 1)); continue; fi
        _or_fail "UNLISTED-LABEL  $token at $path:$lineno — '$field_tok' is a closed field and this value is not a state:issue-status row"
      fi
      ;;
    *)
      # Either sentinel form: the token is the `[c]` inside the match.
      tmp="${match%%]*}"
      c="${tmp##*[}"
      token="[$c]"
      _or_note_seen "$token"
      if ! grep -Fxq -- "$token" <<<"$SENTINELS"; then
        if grep -Fxq -- "$token" <<<"$ALLOW_TOKENS"; then n_grandfathered=$((n_grandfathered + 1)); continue; fi
        _or_fail "UNLISTED-SENTINEL  $token at $path:$lineno — not a state:plan-sentinel row in the registry"
      fi
      ;;
  esac
done <<<"$HITS"

# --- 4. grandfather rows must still be live debt -----------------------------
while IFS= read -r a_tok; do
  [ -n "$a_tok" ] || continue
  if ! grep -Fxq -- "$a_tok" <<<"$SEEN_TOKENS"; then
    _or_fail "GRANDFATHER-STALE  $a_tok is allowlisted but no longer appears in the tracked tree; delete its line in this PR"
  elif grep -Fxq -- "$a_tok" <<<"$ISSUE_STATUS" || grep -Fxq -- "$a_tok" <<<"$SENTINELS"; then
    _or_fail "GRANDFATHER-STALE  $a_tok is allowlisted AND registered; the debt is paid — delete its allowlist line"
  fi
done <<<"$ALLOW_TOKENS"

# --- 5. ratchet: the allowlist may only shrink ---------------------------------
ratchet_line=""
base_ref=""
explicit=0
skip_reason=""
if [ -n "$ONTOLOGY_ALLOWLIST_BASE_REF" ]; then
  base_ref="$ONTOLOGY_ALLOWLIST_BASE_REF"
  explicit=1
elif git -C "$ONTOLOGY_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  base_ref="$(git -C "$ONTOLOGY_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -z "$base_ref" ] && git -C "$ONTOLOGY_ROOT" show-ref --verify --quiet refs/remotes/origin/main; then
    base_ref="origin/main"
  fi
  [ -n "$base_ref" ] || skip_reason="no origin remote resolvable in $ONTOLOGY_ROOT"
else
  skip_reason="$ONTOLOGY_ROOT is not a git working tree"
fi
if [ -n "$base_ref" ] && ! git -C "$ONTOLOGY_ROOT" rev-parse --verify -q "${base_ref}^{commit}" >/dev/null 2>&1; then
  if [ "$explicit" -eq 1 ]; then
    _or_cannot_evaluate "the ratchet base ref ($base_ref) does not resolve in $ONTOLOGY_ROOT — cannot determine whether the allowlist regressed"
  fi
  skip_reason="the auto-resolved ratchet base ref ($base_ref) does not resolve to a commit"
  base_ref=""
fi
if [ -z "$skip_reason" ]; then
  git_top="$(git -C "$ONTOLOGY_ROOT" rev-parse --show-toplevel 2>/dev/null)"
  allow_abs="$(cd "$(dirname "$ONTOLOGY_ALLOWLIST_FILE")" && pwd -P)/$(basename "$ONTOLOGY_ALLOWLIST_FILE")"
  allow_rel="${allow_abs#"$git_top"/}"
  if [ "$allow_rel" = "$allow_abs" ]; then
    ratchet_line="allowlist ratchet: SKIPPED ($ONTOLOGY_ALLOWLIST_FILE is not under $git_top)"
  elif ! git -C "$ONTOLOGY_ROOT" cat-file -e "${base_ref}:${allow_rel}" 2>/dev/null; then
    # Bootstrap: the allowlist does not exist at the base ref (the PR that
    # introduces it — committed OR still untracked), nothing to compare.
    ratchet_line="allowlist ratchet: SKIPPED (bootstrap — $allow_rel is absent at $base_ref, nothing to compare against)"
  else
    prev_tokens="$(git -C "$ONTOLOGY_ROOT" show "${base_ref}:${allow_rel}" 2>/dev/null | awk -F'\t' '!/^#/ && NF >= 1 && $1 != "" { print $1 }' || true)"
    while IFS= read -r cur; do
      [ -n "$cur" ] || continue
      grep -Fxq -- "$cur" <<<"$prev_tokens" \
        || _or_fail "ALLOWLIST-GREW  $cur is on $ONTOLOGY_ALLOWLIST_FILE now but not at $base_ref; the allowlist is a shrink-only ratchet — a new token goes in the registry, never here"
    done <<<"$ALLOW_TOKENS"
    ratchet_line="allowlist ratchet: checked against $base_ref:$allow_rel"
  fi
else
  ratchet_line="allowlist ratchet: SKIPPED ($skip_reason)"
fi

# --- 6. contract docs: pointer present, table not restated ---------------------
DOC_TOKENS="$(awk -F'\t' '$1 ~ /^(label-field|state:|work-class)/ { print $2 }' <<<"$REG_ROWS")"
n_docs=0
for doc in $ONTOLOGY_CONTRACT_DOCS; do
  n_docs=$((n_docs + 1))
  doc_path="$ONTOLOGY_ROOT/$doc"
  if [ ! -r "$doc_path" ]; then
    _or_fail "DOC-MISSING  contract doc not readable: $doc"
    continue
  fi
  grep -q 'ontology-registry\.tsv' "$doc_path" \
    || _or_fail "DOC-CITATION-MISSING  $doc does not point at ontology-registry.tsv"
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    esc="$(_or_ere_escape "$tok")"
    ln="$(grep -nE "^\|[[:space:]]*\`${esc}\`[[:space:]]*\|" "$doc_path" | head -1 | cut -d: -f1 || true)"
    [ -z "$ln" ] || _or_fail "DOC-RESTATES  $doc:$ln restates registry token '$tok' as a vocabulary-table row — the registry is the only place it may be tabled"
  done <<<"$DOC_TOKENS"
  ln="$(grep -nE '^[[:space:]]*- \[[^]]\] <title>' "$doc_path" | head -1 | cut -d: -f1 || true)"
  [ -z "$ln" ] || _or_fail "DOC-RESTATES  $doc:$ln restates the sentinel grammar as an example block — point at the registry instead"
done

# --- verdict ----------------------------------------------------------------------
printf '  %s\n' "$ratchet_line"
if [ "$n_fail" -gt 0 ]; then
  printf '%s' "$failures" >&2
  printf '\ncheck-ontology-registry: FAILED — %d issue(s). Registry: %s (%d rows). Fix by adding the vocabulary row to the registry (never to the allowlist), removing a stale allowlist line, or restoring a contract doc'"'"'s pointer.\n' \
    "$n_fail" "$ONTOLOGY_REGISTRY_FILE" "$n_rows" >&2
  exit 1
fi
printf '  [ok] %d registry row(s); %d token hit(s) across the tracked tree, %d personal-prefix exempt, %d grandfathered; route alphabet equals issue-state.sh; %d contract doc(s) point at the registry\n' \
  "$n_rows" "$n_hits" "$n_exempt" "$n_grandfathered" "$n_docs"
exit 0
