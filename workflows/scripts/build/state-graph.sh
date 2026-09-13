#!/usr/bin/env bash
#
# state-graph.sh — the derived state graph's CORE builder (temperloop#1910,
# epic "graph of record"; ADR 0033, docs/adr/0033-the-derived-state-graph-
# composes-one-way-and-one-independent-cross-check-survives.md).
#
# `build --board N` derives ONE typed nodes+edges snapshot per repo from
# exactly four sources — the board, its native sub-issue/blocked-by edges,
# open PRs, and linked git worktrees — and writes it through the namespaced
# board cache library (workflows/scripts/board/lib/cache.sh, kind=state-graph,
# temperloop#1929): that library's repo-keyed directory, its meta.json, its
# temp-then-rename write discipline, and its `cache_dirty`/`cache_clear`
# invalidation are INHERITED here, never reimplemented (this file's own
# `_sg_persist_snapshot` writes through cache.sh's own path accessors —
# cache_repo_dir / cache_snapshot_file / cache_meta_file — rather than a
# hand-rolled store).
#
# Every source carries a typed status — `ok`, `absent`, `error`, or `stale` —
# never collapsed into an untyped empty result (ADR 0033's whole reason to
# exist). `build` itself only ever produces `ok`/`absent`/`error`: a source
# it just live-fetched is never stale AT THE MOMENT it writes. `stale` is a
# READ-time transform — `_sg_read_snapshot` (this file's read helper, used
# internally and by the later `state-graph.sh query` item) overrides every
# source's status to `stale` when the on-disk snapshot's age is at or past
# the named setting `STATE_GRAPH_MAX_AGE_S`, so a consumer never silently
# acts on data this run has already outgrown.
#
# THE READER TABLE IS EXTENSIBLE (acceptance criterion 1): this file first
# shipped four sources — board / board_edges / pr_list / worktrees — as four
# independent `_sg_read_*` functions plus one line each in `_SG_SOURCES`
# below. `state-graph-build-local` (temperloop#1918) appended three more
# HOST-LOCAL sources the same way — plan_notes (knowledge-store `Plans/`
# notes), journal (the Workflow runtime's `agent-<id>.jsonl` transcripts),
# and tmux (the per-window `@claimed_issue` claim marker) — without touching
# the original four or the assembly loop that calls them. temperloop#1980
# round 3 appended an eighth the same way — transcripts (Claude Code's own
# per-session `~/.claude/projects/*/<sess>*.jsonl` mtime) — as `stale-
# claims`'s liveness oracle; see that query's own header comment below.
# "Host-local" means exactly that: unlike the four `gh`-backed/git sources
# above, these four describe the state of the MACHINE running `build`, not
# the repo/board, so a snapshot built on two different hosts can legitimately
# disagree on them.
#
#   state-graph.sh build --board <N>            build + persist + print
#   state-graph.sh clean --board <N>             remove ONE repo's snapshot
#   state-graph.sh bench --scale <N> --board <N>  synthetic N-scale timing run
#   state-graph.sh query <name> --board <N>      read a query over the snapshot
#   state-graph.sh soak --board <N>              build + PER-CLASS query vs.
#                                                 reconcile.sh --status, append
#                                                 one dated per-class diff record
#   state-graph.sh soak --count --board <N>      print distinct days recorded
#   state-graph.sh soak --audit --board <N> --items <file>
#                                                 record a hand-audited item set
#                                                 against today
#
# SOAK (temperloop#1910; PER-CLASS scope rewrite temperloop#1978): the
# fourteen-day cross-check ADR 0033's independence claim rests on — "one
# derivation (`build`) plus one INDEPENDENT read (`reconcile.sh --status`,
# which never touches this file's own snapshot store) should keep agreeing"
# — made MECHANICAL rather than a human diffing two command outputs by eye
# every day.
#
# PER-CLASS, never one flat set diff (temperloop#1978): status-drift and
# reconcile.sh --status have different SCOPE — status-drift only ever
# computes the board source's own in-progress/claimed_by disagreement, while
# reconcile.sh --status prints EIGHT distinct drift classes in one report
# (status labels, claim liveness, AND cross-host/lookup-failure signals all
# mixed together). Comparing status-drift's one narrow query against
# reconcile's WHOLE report manufactured false disagreement whenever
# reconcile flagged something status-drift was never designed to compute
# (a dead-session claim stamp) — a SCOPE ARTIFACT, not a real cross-check
# failure. `soak` instead runs ONE comparison per state-graph query that has
# a reconcile.sh counterpart:
#
#   status-drift  <-> reconcile's STATUS-LABEL classes: `terminal-but-not-
#                 Done`, `residual status labels on closed issues` (the
#                 closed-issue board-source read below's own residue —
#                 acceptance criterion 2), and `orphaned In-Progress` (the
#                 exact same "in-progress, no owner stamp" computation
#                 status-drift's own board source already makes).
#   stale-claims  <-> reconcile's `stale claims (In Progress...)` class ALONE
#                 (In Progress, stamped to a dead same-host session — this
#                 item's day-1 #1225/#1111/#1048/#1047). `stranded claim
#                 stamps on closed issues` is DELIBERATELY excluded
#                 (temperloop#1980 round 3 MEDIUM): the board source's
#                 closed-issue residue read (`_sg_read_board`) never attaches
#                 a `claimed_by` edge to a closed Issue node — its edge loop
#                 walks the OPEN issue set only — so that reconcile class can
#                 only ever land in `only_in_reconcile`, never `agree`. A
#                 class that can structurally never agree is not a
#                 cross-check, it is a standing false disagreement, so it is
#                 mapped to no class at all, the same way foreign/foreign-
#                 stale/unresolved already are (below).
#   unlinked-prs / orphan-worktrees  <-> reconcile.sh has NO matching class
#                 for either (it never examines PRs or worktrees) — their
#                 `reconcile_set`/`diff` read the literal string
#                 "not-covered", never an empty set standing in for a domain
#                 reconcile.sh structurally never reports on (that would be
#                 exactly the false-agreement/disagreement this rewrite
#                 exists to stop manufacturing).
#
# reconcile's `foreign`/`foreign-stale` claims (another host — unverifiable
# from here), `unresolved` (a state LOOKUP failure, not a status/claim
# verdict), and `stranded claim stamps on closed issues` (see stale-claims
# above) map to NEITHER class and are never diffed — folding any of them into
# either set would manufacture a comparison this file cannot actually back.
#
# One `soak --board N` run: fresh `build`; the four queries above off that
# SAME snapshot (no second live build); ONE `reconcile.sh --status` call
# through the overridable `_sg_reconcile` seam (mirrors `_sg_git`/`_sg_tmux`
# — reconcile.sh is a SEPARATE script, not sourced, so it gets its own seam;
# ONE call, its report reused for every mapped class, never one call per
# class), parsed into per-class issue-number sets anchored on the SAME
# line-leading `  #N` shape reconcile.sh's own marker parse uses
# (reconcile.sh:468) — a `#N` embedded mid-line in a flagged item's TITLE is
# never mistaken for a ref. Appends one `{day, type:"run", schema:2,
# classes:{<name>: {drift_query_set, reconcile_set, diff}, ...}}` record —
# `classes` covers exactly the four names above; `diff` is EITHER
# `{only_in_drift_query, only_in_reconcile, agree}` (`agree` is now PER
# CLASS — there is no single flat top-level `agree` any more, state this
# plainly since it is this item's own acceptance semantics), the literal
# string "unknown" (either side's own source is `error`/`stale`, or the
# `_sg_reconcile` invocation itself failed — never a false empty-set
# agreement computed over a side that couldn't actually be read), or the
# literal string "not-covered" (unlinked-prs / orphan-worktrees: nothing on
# reconcile's side to diff against, ever). `day` is UTC (`_sg_soak_day`,
# overridable) per the stored/parsed-timestamps-stay-UTC convention.
#
# SCHEMA VERSIONING (acceptance criterion 4): a run record now carries
# `type:"run"` and `schema:2` — both absent from every pre-temperloop#1978
# record already on disk (the OLD flat shape: `{day, drift_query_set,
# reconcile_set, diff}`, no `type` field at all). Rather than rewrite a live
# production soak log this checkout cannot even see, `schema:2` marks the
# boundary instead: `--count` counts a `day` only from a record that is
# unambiguously CURRENT-schema-comparable — `type:"audit"` / `type:"bench"`
# (unaffected by this rewrite, counted exactly as before) or `type:"run"`
# WITH `schema:2` — so a pre-existing flat-schema run record silently drops
# out of the count instead of being misread as a per-class one. (The PR body
# for this change states this choice and why explicitly, per that
# criterion.)
#
# Practically: every day whose only record predates this rewrite drops out
# of `--count`, so the fourteen-day independence check restarts from zero
# and needs fourteen new `schema:2` days before it is trustworthy again. An
# operator watching `--count` fall after this deploys should read that as
# this expected reset, not a regression.
#
# `--count` prints the number of distinct `day` values recorded (any
# comparable record type, per the schema rule above). `--audit --items
# <file>` appends a `{day, type:"audit", audited_items}` record — a hand-
# reviewed item set (one issue number per line, `#N`/`Issue:N`/bare digits
# all accepted) logged against today, for a human to compare against the
# same day's mechanical diff. `bench --scale N` also appends one `{day,
# type:"bench", ...}` record per invocation timing each of the five named
# queries against its synthetic snapshot, so running it at scale 1, then 10,
# then 100 (the doc convention used throughout this file for "one of these
# values", see the `query` name enum above) leaves a trail a soak reviewer
# scans for the first scale whose `query_ms` first exceeds
# `STATE_GRAPH_QUERY_SLOW_MS`.
#
# QUERY (temperloop#1910 L6, this item): five named, PURE functions of a
# snapshot JSON blob — `_sg_query_*` — reused verbatim by `cmd_query` (reads
# the persisted snapshot via `_sg_read_snapshot`, building AND persisting a
# fresh one only when none is persisted yet, so a second `query` call pays
# no second live build) and by test_state_graph_queries.sh (feeds a
# synthetic snapshot literal directly — no board/gh/git mocking needed for
# these tests, unlike the seven readers above). Every query answers the
# LITERAL STRING `"unknown"` for a part that depends on a source currently
# `error` or `stale` — never a bare empty array standing in for "nothing
# found" when the truth is "couldn't tell" (ADR 0033's own status typing,
# extended from per-source to per-query-part). `absent` is NOT degraded —
# it is source.sh's own "legitimately nothing here" signal, so a query
# answers its ordinary empty-but-real result for it.
#
#   status-drift       Issue nodes whose `fnd:status:*` and `claimed_by`
#                       edge disagree (board source only) — PLUS (temperloop
#                       #1978) a CLOSED issue node still wearing an
#                       `fnd:status:*` label (the `closed_with_status_label`
#                       finding kind; Done here is "closed + no status
#                       label", workflows/scripts/board/ISSUES-ONLY-
#                       BACKEND.md — the board source's own closed-issue
#                       residue read, see `_sg_read_board`).
#   stale-claims        `claimed_by` edges, GATED TO THIS HOST, naming an
#                       Issue with no currently-live transcript (board +
#                       transcripts). transcripts — Claude Code's own
#                       per-session `~/.claude/projects/*/<sess>*.jsonl`
#                       mtime, source 8 below — is this query's LIVENESS
#                       ORACLE (temperloop#1980 round 3): the SAME evidence
#                       reconcile.sh's own `_reconcile_session_live` checks
#                       (newest matching transcript's mtime within
#                       `RECONCILE_STALE_AFTER_SECS` of "now" — reconcile's
#                       own setting, reused verbatim rather than a second
#                       literal), so the two independent derivations can
#                       actually agree. Neither round 1's journal (step-
#                       outcome ledger — records WORK DONE, not a SESSION
#                       EXISTING) nor round 2's tmux `@claimed_issue` markers
#                       (a per-ISSUE proxy the comparison target never
#                       invokes) is this oracle, and neither is consulted by
#                       this query any more — both produced their own false
#                       disagreement against the actual comparison target,
#                       `reconcile.sh --status`, which `_sg_soak_run` calls
#                       (`status_reconcile_main` -> `_reconcile_session_live`
#                       for its `stale claims (In Progress...)` class; it
#                       never touches tmux at all — that lens lives only in
#                       `reconcile_main`'s separate `markers` mode, whose own
#                       `board-without-marker` class is report-only and is
#                       never diffed by the soak either).
#                       GATED ON HOST (temperloop#1980 round 3 HIGH 2): a
#                       claim's `.to` carries `Session:<host>:<sess8-or-
#                       manual>` (`_sg_normalize_claimed_by`). reconcile's
#                       own claim-liveness lens gates on host FIRST
#                       (`reconcile.sh`'s `[ "$shost" = "$HOST" ]`) and maps
#                       a foreign host's claim to no class at all (`foreign`/
#                       `foreign-stale`, never diffed — see the soak header
#                       comment above); this query does the same before
#                       computing liveness — a claim stamped to another host
#                       is excluded from `findings` entirely, never
#                       confidently reported stale from evidence (this HOST's
#                       own transcript directory) that cannot speak to a
#                       foreign host's liveness at all. `host` is resolved
#                       once at `build` time (`board_host_label`) and carried
#                       on the snapshot's own top-level `.host` field, so this
#                       query stays a pure function of the snapshot.
#                       ALSO GATED ON STATUS (temperloop#1980 round 4 HIGH):
#                       `$claims` only ever considers a `claimed_by` edge
#                       whose Issue is currently `fnd:status:in-progress` —
#                       reconcile.sh's own producer emits its "stale claims
#                       (In Progress...)" class the same way (reconcile.sh:
#                       876-879), so a claim stamp left behind on an issue
#                       moved off In Progress (an ordinary "Park, don't
#                       abandon" residue — `board_set_status` never clears
#                       the stamp, only `release.sh` does) is excluded here
#                       exactly as it is on reconcile's side, never a
#                       standing false disagreement.
#                       Unlike every other consumer of `_sg_degraded`/absent-
#                       as-empty, an `absent` transcripts source (no
#                       `~/.claude/projects`-shaped directory at all —
#                       "nothing found" for every OTHER query) is treated
#                       here as "liveness cannot be determined" and answers
#                       `unknown`, never a set computed against zero known-
#                       live sessions (which would flag every live claim as
#                       stale). This carve-out is local to this one query —
#                       `_sg_degraded` itself, and status-drift's use of it,
#                       are unchanged.
#   unlinked-prs        open PR nodes with no `closes` edge (pr_list only).
#   orphan-worktrees     Worktree nodes with no live (`[~]`/`[m]`/`[>]`)
#                       PlanItem of the same slug (worktrees + plan_notes).
#   resume              per-PlanItem resume verdict — see below.
#
# RESUME implements Step 0.5's authority ordering (claude/commands/build.md
# § Step 0.5 item 4) as a RANKED MERGE, highest tier first, each decisive
# tier short-circuiting every lower one:
#
#   1 plan     the PlanItem's own sentinel + `pr:`/`pushed_sha:` sub-fields
#              (the plan-note store itself — the authority table's own tier
#              1 groups these together). A TERMINAL sentinel (`[x]`/`[-]`/
#              `[v]`) decides `already-done` and can NEVER be reversed by a
#              lower tier — the authority table's own load-bearing
#              invariant. A non-terminal sentinel carrying `pr:` decides
#              `adopt` (there is a recorded PR to reattach to); one carrying
#              `pushed_sha:` but no `pr:` yet decides `fresh` (pushed, not
#              yet PR'd — still a tier-1 fact, decided before tier 2 is
#              ever consulted).
#   2 journal  a Session step-outcome tagged with this item's `slug` (an
#              optional passthrough field on the journal source's step
#              records — see `_sg_read_journal`) decides `adopt`
#              (`PR_OPENED`) or `fresh` (`PUSHED`, no PR yet).
#   3 git      a linked Worktree whose path's slug matches decides `fresh`
#              (work is in flight, no PR/journal evidence yet).
#   4 board    the fallback default `fresh` — gated, not positive: this
#              tier has no PlanItem->Issue join key in the current schema,
#              so it contributes no per-item fact, only a GATE on the
#              tier-4 default (see below).
#
# A tier's source being `error`/`stale` at the point it would be consulted
# answers that item's route `probe-failed` (the route alphabet's own "a
# read failed for a non-404 reason" token — the alphabet-compliant stand-in
# for "unknown" here, since resume's routes are drawn from
# workflows/scripts/config/ontology-registry.tsv's `state:route` axis, the
# SAME alphabet issue-state.sh's `resolve` emits — never a bare "unknown"
# string that would break that contract). `absent` at a tier that was never
# actually needed to decide (e.g. board is absent but tier 1 already
# decided) never taints the item.
#
# Two overridable command seams, mirroring board.sh's own `_board_gh`
# (sourced below and reused as-is for the board/board_edges/pr_list sources —
# they are all `gh`-backed reads, so one seam covers three of the four
# sources; tests dispatch on argv the same way test_board_replay.sh does):
#   _board_gh   — every `gh` call (board.sh's own seam; this file adds no
#                 second `gh` seam so a test overriding one place covers the
#                 board, board_edges, AND pr_list sources)
#   _sg_git     — the one non-`gh` external command (`git worktree list`)
#
# `soak` adds a THIRD seam, `_sg_reconcile`, for its one call to the SEPARATE
# `reconcile.sh` script (not sourced, unlike board.sh/cache.sh above) — see
# that seam's own definition below.
#
# No network in tests: every source above is read through one of the two
# seams, so `test_state_graph.sh` replays fixtures with zero network access
# (acceptance criterion 4).
set -euo pipefail

_SG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=workflows/scripts/board/lib/board.sh
# shellcheck disable=SC1091
source "$_SG_HERE/../board/lib/board.sh"
# shellcheck source=workflows/scripts/board/lib/cache.sh
# shellcheck disable=SC1091
source "$_SG_HERE/../board/lib/cache.sh"
# shellcheck source=workflows/scripts/config/join-keys-lib.sh
# shellcheck disable=SC1091
source "$_SG_HERE/../config/join-keys-lib.sh"
# shellcheck source=workflows/scripts/build/build.config.sh
# shellcheck disable=SC1091
source "$_SG_HERE/build.config.sh"
# shellcheck source=workflows/scripts/lib/knowledge_store.sh
# shellcheck disable=SC1091
source "$_SG_HERE/../lib/knowledge_store.sh"

# The ontology registry (ADR 0032) — the ONE source of truth for the
# `state:issue-status` alphabet a board-read Issue node's `status` must
# belong to. Overridable for tests (a throwaway fixture registry), defaults
# to the real repo-shipped one.
ONTOLOGY_REGISTRY_FILE="${ONTOLOGY_REGISTRY_FILE:-$_SG_HERE/../config/ontology-registry.tsv}"

usage() {
  cat >&2 <<'USAGE'
usage: state-graph.sh build --board <N>
       state-graph.sh clean --board <N>
       state-graph.sh bench --scale <N> --board <N>
       state-graph.sh query <name> --board <N>
                (name: status-drift | stale-claims | unlinked-prs |
                       orphan-worktrees | resume)
       state-graph.sh soak --board <N>
                build + PER-CLASS status-drift/stale-claims/unlinked-prs/
                orphan-worktrees vs. reconcile.sh --status; append one dated
                {day, type:"run", schema:2, classes:{...}} record
       state-graph.sh soak --count --board <N>
                print the number of distinct days recorded in the soak log
       state-graph.sh soak --audit --board <N> --items <file>
                record a hand-audited item set against today's day
USAGE
}

# --- overridable command seams ---------------------------------------------
# `git worktree list`'s one call site. Production runs real git; tests
# override this after sourcing to replay fixtures / fail on demand.
_sg_git() { git "$@"; }

# Millisecond wall clock for `bench` (perl Time::HiRes, same portability
# fallback gh-call-logger.sh already uses — bash on macOS is 3.2, no
# $EPOCHREALTIME, and BSD `date` has no %N; perl ships everywhere this runs).
# Falls back to whole-second resolution (never fatal) when perl is absent.
_sg_now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null ||
    printf '%s000' "$(date +%s)"
}

# `reconcile.sh`'s one call site (`soak`'s independent status-drift lens).
# Production runs the real repo-shipped script; tests override this after
# sourcing to replay canned reconcile output with no network — reconcile.sh
# itself is a separate script (not sourced like board.sh/cache.sh), so it
# needs its own seam rather than a hand-rolled subprocess call sprinkled
# through cmd_soak.
_sg_reconcile() { "$_SG_HERE/../board/reconcile.sh" "$@"; }

# "Now" for `_sg_read_transcripts`'s liveness cutoff (temperloop#1980 round
# 4 MEDIUM 1) — mirrors `reconcile.sh`'s own `_reconcile_now` seam
# (reconcile.sh:422, "so a test injects a fixed epoch"): the source's whole
# claim is equivalence with `_reconcile_session_live`, and its `<=` cutoff
# comparison is the last inch of that equivalence, so it is routed through
# a seam like every other clock read in this file (`_sg_now_ms`,
# `_sg_soak_day`) rather than a raw `date +%s` a test cannot pin to sit
# exactly on the boundary. `built_at` (this file's own snapshot timestamp)
# and `_sg_read_snapshot`'s staleness age deliberately keep calling `date
# +%s` raw — this file has precedent both ways, and this ONE call is seamed
# because a test needs to land exactly on this ONE cutoff, not because
# every timestamp in this file must be injectable.
_sg_now() { date +%s; }

# `soak`'s day key — UTC (stored/parsed timestamps stay UTC, never the
# operator's display timezone; claude/CLAUDE.kernel.md § Communication
# conventions). Its own seam (mirrors `_sg_now_ms`) so tests can pin distinct
# days deterministically instead of depending on real calendar time.
_sg_soak_day() { date -u +%F; }

# --- ontology-registry lookups (ADR 0032) -----------------------------------
# Every `state:issue-status` TOKEN column (col 2), one per line.
_sg_issue_status_tokens() {
  awk -F'\t' '$1=="state:issue-status" && $2!="" {print $2}' "$ONTOLOGY_REGISTRY_FILE" 2>/dev/null
}

# A raw board `.status` value ("Ready" / "In Progress" / "Backlog" / "Done")
# -> its ontology-registry token ("fnd:status:ready" / ... / "done"). Mirrors
# board.sh's own `unslug` in reverse (lib/board.sh's `_BOARD_ISSUES_JQ_DEFS`),
# entirely in jq so this file introduces no second, bash-side slugger that
# could drift from board.sh's.
_SG_STATUS_TOKEN_JQ='
def status_token:
  if . == "Done" then "done"
  else "fnd:status:" + (. | ascii_downcase | gsub(" "; "-"))
  end;
'

# claimed_by reader: normalize the board's VERBATIM `host/Session` claim
# stamp ("<host>:<sess8>" or "<host>:manual", lib/board.sh's board_own_stamp)
# through the join-key loader, never hand-rolled parsing (acceptance
# criterion 2). The stamp is ALREADY session8-shaped by the time board.sh
# writes it (board_own_stamp truncates before storing), so `jk_session8` —
# which validates a FULL 36-char UUID — cannot re-derive it from the
# already-short form; it is called anyway so a future writer that stores the
# untruncated id is normalized for real, and the current pre-truncated form
# falls back to the loader's own OUTPUT shape (lowercase) rather than a
# second, hand-written case-fold rule.
_sg_normalize_claimed_by() {
  local stamp="$1" host part full
  host="${stamp%%:*}"
  part="${stamp#*:}"
  if [ "$part" = "manual" ]; then
    printf '%s:manual' "$host"
    return 0
  fi
  if full="$(jk_session8 "$part" 2>/dev/null)"; then
    printf '%s:%s' "$host" "$full"
  else
    printf '%s:%s' "$host" "$(printf '%s' "$part" | tr '[:upper:]' '[:lower:]')"
  fi
}

# journal reader: normalize a workflow-journal `sessionId` field through
# jk_session_full (the join-key loader) rather than hand-rolled parsing —
# the journal source's own equivalent of _sg_normalize_claimed_by above. A
# non-UUID-shaped id (never expected in a real transcript, but a journal is
# untrusted input) falls back to the loader's own lowercase OUTPUT shape,
# same fallback discipline as _sg_normalize_claimed_by.
_sg_normalize_session_id() {
  local raw="$1" full
  if full="$(jk_session_full "$raw" 2>/dev/null)"; then
    printf '%s' "$full"
  else
    printf '%s' "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  fi
}

# --- shared per-source result envelope --------------------------------------
# Every `_sg_read_*` reader prints exactly one compact JSON object:
#   {"status": ok|absent|error, "detail": "...", "nodes": [...], "edges": [...]}
_sg_source_result() {
  local status="$1" nodes="$2" edges="$3" detail="${4:-}"
  jq -cn --arg status "$status" --arg detail "$detail" \
    --argjson nodes "$nodes" --argjson edges "$edges" \
    '{status: $status, detail: $detail, nodes: $nodes, edges: $edges}'
}

# --- source 1: board (Issue nodes, fnd:status:* state, claimed_by edges) ---
# One `board_resolve` (acceptance criterion 1). `absent` = the board legitimately
# has zero open issues; `error` = board_resolve itself failed, OR any item's
# derived status token is not a `state:issue-status` row in the ontology
# registry (acceptance criterion 1's "a node state not in the ontology
# registry makes that source error").
#
# CLOSED-ISSUE RESIDUE (temperloop#1978, this item's acceptance criterion 2):
# `board_resolve`/`board_item_list` (board.sh ~637/~1446) are a deliberate
# OPEN-only active-set convention other callers rely on — never widened here
# (principle 6, blast radius). So a closed issue that still carries an
# `fnd:status:*` label (Done on this backend is "closed + NO status label",
# workflows/scripts/board/ISSUES-ONLY-BACKEND.md; residue like a closed
# issue still wearing fnd:status:backlog) is structurally invisible to the
# primary read above. This source closes that
# gap ITSELF, entirely inside this file: one SUPPLEMENTAL, DIRECT `_board_gh
# api "repos/<repo>/issues" --method GET -f state=closed -f labels=<label>
# ...` call per `fnd:status:*` label (deliberately NOT `gh issue list` —
# that shares board.sh's own `_board_gh` call shape at the argv-matching
# granularity every existing test fixture dispatches on, which would
# silently replay the OPEN-issue fixture for this closed-issue read too;
# the distinct `api repos/.../issues` shape can never collide with an
# `issue list` mock arm), emitted as extra Issue nodes with `state:"closed"`
# so `_sg_query_status_drift`'s new `closed_with_status_label` finding can
# see them. This supplemental read is FAIL-SOFT by design, per label — a
# failure (rate limit/auth/an older test fixture that doesn't mock it)
# warns on stderr and that label contributes zero extra nodes rather than
# erroring the WHOLE board source; the primary open-issue read's own
# ok/absent/error verdict is computed exactly as before, untouched by this
# addition.
#
# Round 2 (temperloop#1978 verdict, live-run findings):
#
#   - `--method GET` is REQUIRED on every call here. `gh api` silently
#     switches to POST the instant any `-f`/`-F` param is present, unless
#     `--method`/`-X` names GET explicitly — verified live: the round-1 call
#     (no `--method`) was actually POSTing to the CREATE-an-issue endpoint
#     (422 "title wasn't supplied", swallowed whole by the fail-soft arm
#     below, so it silently contributed zero residue nodes every run).
#
#   - One page of `per_page=100`, newest-first, with no pagination
#     structurally cannot reach OLD residue (measured live: one page spans
#     #1841-#1979). Rather than paginate the entire closed-issue history
#     (unbounded cost), this queries by LABEL instead: one GET per
#     `fnd:status:*` label — GitHub's REST `labels` filter is AND, not OR,
#     so a comma-joined list would wrongly require ALL of them on one
#     issue, and must be one call per label. The label set is read from the
#     ontology registry (ADR 0032) via `_sg_issue_status_tokens` — the same
#     accessor this function already uses above for the primary read's
#     status-token validation — filtered to the `fnd:status:*` rows (i.e.
#     excluding the registry's non-label `done` token), so a future label
#     addition/removal there is picked up here for free rather than
#     hardcoded.
_sg_read_board() {
  local board="$1" items count bad nodes edges stamp norm repo closed_raw closed_nodes label extra labels page_count
  if ! board_resolve "$board" >/dev/null 2>&1; then
    _sg_source_result error '[]' '[]' "board_resolve failed"
    return 0
  fi
  items="$(printf '%s' "$BOARD_ITEMS_JSON" | jq -c '.items')"
  count="$(printf '%s' "$items" | jq 'length' 2>/dev/null)" || count=""
  if [ -z "$count" ]; then
    _sg_source_result error '[]' '[]' "unparseable board item list"
    return 0
  fi

  # Ontology-registry check — HOISTED ABOVE the closed-issue residue fan-out
  # below (round-4 verdict, LOW 3): a registry-drift board (a status token
  # outside the ontology registry) must not spend one live REST call per
  # `fnd:status:*` label on residue that its own `error` return below would
  # only discard. `bad` depends only on `$items`, already parsed above —
  # `bad` over an empty array is 0, so this stays safe ahead of the
  # `count -eq 0` check too, which stays BELOW the residue read (round-3
  # hoist preserved: bad check → residue read → count -eq 0).
  bad="$(printf '%s' "$items" | jq --argjson toks "$(_sg_issue_status_tokens | jq -Rsc 'split("\n") | map(select(length>0))')" "
    $_SG_STATUS_TOKEN_JQ
    [ .[] | (.status // \"\") as \$s
      | (if \$s == \"\" then \"\" else (\$s | status_token) end) as \$tok
      | select(\$tok == \"\" or (\$toks | index(\$tok)) == null) ] | length
  ")"
  if [ "${bad:-0}" -gt 0 ]; then
    _sg_source_result error '[]' '[]' "node status not in ontology registry"
    return 0
  fi

  # Closed-issue residue supplement — see this function's own header comment
  # above. HOISTED ABOVE the `count -eq 0` branch below (round-3 verdict,
  # MEDIUM 3): a board with zero OPEN issues but real closed-with-label
  # residue is not "absent" — there is board state, it is simply all
  # closed — so this read must run, and its nodes must reach the `absent`
  # arm too, rather than being skipped by an early return that used to
  # precede it. `repo` failing to resolve, or a per-label `_board_gh api`
  # call itself failing, is never a hard error for this source: it just
  # means today's snapshot sees no closed-issue residue for that label,
  # exactly like a repo with none for it.
  #
  # Round 3 (temperloop#1978 verdict, reviewer findings):
  #   - routes through board.sh's `_board_sanitize_control_chars` (its own
  #     INVARIANT: any new `_board_gh api … | jq` reading issue content must
  #     route through it first) — one leaked control byte in a returned
  #     title otherwise breaks jq's parse silently (`2>/dev/null` + the
  #     `|| extra='[]'` fallback turn it into a clean empty result), the
  #     same silent-zero-residue failure this whole read exists to fix.
  #   - `select(has("pull_request") | not)`: GitHub's REST
  #     `/repos/{o}/{r}/issues` endpoint returns pull requests alongside
  #     issues, but reconcile.sh's own `gh issue list` side never does — an
  #     unfiltered read turns a closed, `fnd:status:*`-labeled PR into a
  #     phantom Issue node reconcile.sh can never agree with.
  #   - warns (never silently truncates) when a label's own page returns
  #     exactly `per_page=100`, mirroring reconcile.sh's own
  #     never-silently-truncate posture at its `STATE_LIMIT` cap — sharding
  #     by label shrinks the truncation window, it does not close it.
  repo="$(board_repo "$board" 2>/dev/null)" || repo=""
  closed_nodes='[]'
  if [ -n "$repo" ]; then
    # Captured to a var before the loop (round-3 LOW finding): the loop body
    # runs a real `_board_gh` child per iteration, which inherits the
    # process-substitution FD as stdin under `done < <(...)` and could
    # otherwise consume the remaining labels out from under the producer,
    # silently truncating the fan-out. `|| true` is load-bearing under
    # `set -euo pipefail` — the producer's `grep` exits 1 on no match, which
    # is a legitimate "no fnd:status:* labels in the registry" state, not a
    # failure.
    labels="$(_sg_issue_status_tokens | grep '^fnd:status:' || true)"
    while IFS= read -r label; do
      [ -n "$label" ] || continue
      if closed_raw="$(_board_gh api "repos/$repo/issues" --method GET -f state=closed -f "labels=$label" -f per_page=100 2>/dev/null)"; then
        page_count="$(printf '%s' "$closed_raw" | _board_sanitize_control_chars | jq 'length' 2>/dev/null)" || page_count=""
        if [ -z "$page_count" ]; then
          echo "state-graph.sh: warning: closed-issue residue read for board $board repo $repo label $label returned an unparseable page — residue not read for this label this cycle" >&2
        elif [ "$page_count" -eq 100 ]; then
          echo "state-graph.sh: warning: closed-issue residue read for board $board repo $repo label $label returned a full page (100) — possible truncation, residue may be incomplete for this label this cycle" >&2
        fi
        extra="$(printf '%s' "$closed_raw" | _board_sanitize_control_chars | jq -c --arg lbl "$label" '
          [ .[]? | select(has("pull_request") | not) | { type:"Issue", id:("Issue:"+(.number|tostring)), number:.number,
                      status:$lbl, state:"closed" } ]
        ' 2>/dev/null)" || extra='[]'
        [ -n "$extra" ] || extra='[]'
        closed_nodes="$(jq -c --argjson extra "$extra" '. + $extra' <<<"$closed_nodes")"
      else
        echo "state-graph.sh: warning: closed-issue residue read failed for board $board repo $repo label $label (gh api rate-limited/auth?) — status-drift will not see closed-with-label residue for this label this cycle" >&2
      fi
    done <<<"$labels"
  fi

  if [ "$count" -eq 0 ]; then
    _sg_source_result absent "$closed_nodes" '[]' ""
    return 0
  fi
  nodes="$(printf '%s' "$items" | jq -c "
    $_SG_STATUS_TOKEN_JQ
    [ .[] | {
        type: \"Issue\",
        id: (\"Issue:\" + (.content.number | tostring)),
        number: .content.number,
        status: (.status | status_token)
      } ]
  ")"
  edges='[]'
  while IFS=$'\t' read -r from_n stamp; do
    [ -n "$from_n" ] || continue
    norm="$(_sg_normalize_claimed_by "$stamp")"
    edges="$(jq -c --arg f "Issue:${from_n}" --arg t "Session:${norm}" \
      '. + [{type:"claimed_by", from:$f, to:$t}]' <<<"$edges")"
  done < <(printf '%s' "$items" | jq -r '.[] | select((.["host/Session"] // "") != "") | [ (.content.number|tostring), .["host/Session"] ] | @tsv')

  nodes="$(jq -c --argjson extra "$closed_nodes" '. + $extra' <<<"$nodes")"

  _sg_source_result ok "$nodes" "$edges" ""
}

# --- source 2: board_edges (sub_issue_of, blocked_by) ----------------------
# `board_sub_issues` + native `board_blocked_by_open` (acceptance criterion
# 1), gated on the board's own open-issue set (source 1) — never the whole
# repo (board.sh's own per-issue-REST caveat on both accessors). Both
# accessors are FAIL-OPEN by design (lib/board.sh: a `_board_gh` failure and
# a legitimately-empty result are indistinguishable from the caller's side,
# by deliberate design — see board_sub_issues's own "NO CACHED ARM" comment),
# so this source's `error` status cascades from source 1's rather than
# inventing a signal board.sh does not expose.
_sg_read_board_edges() {
  local board="$1" board_json="$2" status numbers n child b edges
  status="$(jq -r '.status' <<<"$board_json")"
  case "$status" in
    error) _sg_source_result error '[]' '[]' "upstream board source errored"; return 0 ;;
    absent) _sg_source_result absent '[]' '[]' ""; return 0 ;;
  esac
  numbers="$(jq -r '.nodes[].number' <<<"$board_json")"
  edges='[]'
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    while IFS= read -r child; do
      [ -n "$child" ] || continue
      edges="$(jq -c --arg c "$child" --arg p "$n" \
        '. + [{type:"sub_issue_of", from:("Issue:"+$c), to:("Issue:"+$p)}]' <<<"$edges")"
    done < <(board_sub_issues "$board" "$n" all)
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      edges="$(jq -c --arg b "$b" --arg i "$n" \
        '. + [{type:"blocked_by", from:("Issue:"+$i), to:("Issue:"+$b)}]' <<<"$edges")"
    done < <(board_blocked_by_open "$board" "$n")
  done <<<"$numbers"
  if [ "$(jq 'length' <<<"$edges")" -eq 0 ]; then
    _sg_source_result absent '[]' '[]' ""
  else
    _sg_source_result ok '[]' "$edges" ""
  fi
}

# --- source 3: pr_list (PR nodes, closes edges) -----------------------------
# One `gh pr list --state open` (acceptance criterion 1). `closes` edges are
# parsed from a BARE `Closes #N` / `Fixes #N` / `Resolves #N` line in the PR
# body (own line, any tense, case-insensitive — claude/CLAUDE.kernel.md
# § Issue linkage), never a backticked or mid-sentence mention, and a body
# may carry more than one such line (one edge per line).
#
# The raw `gh` payload routes through board.sh's `_board_sanitize_control_chars`
# ONCE, right after the read, so all three downstream jq stages (the `count`
# guard, `nodes=`, `edges=`) see sanitized text (temperloop#1981). This read
# projects `title` and `body` — user-controlled fields — and a single literal
# control byte in ANY one of up to 100 open PRs makes jq exit 5, which the
# `count` guard turns into a source-wide `error` that persists for as long as
# that PR stays open; `unlinked-prs` then answers `unknown` on every run for the
# duration. The stage recovers those runs instead. It must run on the raw TEXT
# before jq (control chars break jq's parser, so a jq-based sanitizer cannot fix
# its own input). `tr` ITSELF never fails on this input class, so it adds no new
# error path of its own — but the STAGE can still produce EMPTY output (a
# payload of nothing but control bytes sanitizes down to nothing), and that
# empty-output case is handled by the `count` guard below, not by `tr`'s exit
# status. Same INVARIANT board.sh's helper header states.
_sg_read_pr_list() {
  local board="$1" repo raw count nodes edges
  repo="$(board_repo "$board" 2>/dev/null)" || { _sg_source_result error '[]' '[]' "board_repo failed"; return 0; }
  if ! raw="$(_board_gh pr list -R "$repo" --state open --json number,title,body --limit 100 2>/dev/null)"; then
    _sg_source_result error '[]' '[]' "gh pr list failed"
    return 0
  fi
  [ -n "$raw" ] || raw="[]"
  # The sanitize stage runs AFTER the `[ -n "$raw" ] || raw="[]"` default above,
  # and that ordering is load-bearing BECAUSE of the `count` guard below: that
  # guard treats EMPTY jq output as unparseable and reports `error`. So a
  # payload of nothing but control bytes — which sanitizes down to nothing —
  # reports `error`, the honest answer for a page we could not read. Swapped
  # (sanitize BEFORE the default) the same payload would be rewritten to `[]`,
  # counted as 0, and reported `absent` — asserting a genuinely empty PR list
  # when what we actually had was an unreadable one, which is the wrong-empty
  # answer downstream queries would take at face value.
  raw="$(printf '%s' "$raw" | _board_sanitize_control_chars)"
  # `|| count=""` plus the `[ -z "$count" ]` guard, not a bare `||` branch on
  # jq's exit status: jq can exit ZERO with NO OUTPUT (empty or whitespace-only
  # input — and SPACE is 0x20, outside `tr -d '\000-\037'`, so a whitespace
  # payload reaches here intact). An exit-status-only guard leaves `count`
  # empty, `[ "" -eq 0 ]` errors and evaluates false, and execution falls
  # through to `_sg_source_result ok "" ""`, whose `jq --argjson` fails hard —
  # a NON-ZERO return from a `_sg_read_*`, which `_sg_build_snapshot`'s bare
  # assignment turns into a `set -e` abort of the WHOLE snapshot build. Same
  # shape `_sg_read_board` already uses above (:515-519); every `_sg_read_*`
  # in this file returns 0 on every path.
  #
  # The program is `jq -s`, not a bare `jq 'length'`, because the guard needs
  # ARITY and TYPE, not just non-emptiness. Bare `jq 'length'` emits one line
  # PER INPUT DOCUMENT, so a multi-document payload (`[] []`) yields $'0\n0' —
  # non-empty, so `[ -z ]` passes, `[ "$count" -eq 0 ]` then errors on a
  # non-integer and falls through to the same hard abort. And `length` is
  # defined on strings (character count), objects (key count) and numbers
  # (absolute value), so `"abc"` / `{"a":1}` / `5` all pass a guard that only
  # proves "parses, non-zero length". `"abc"` and `5` then fail the `.[]`
  # projection below — but an OBJECT does NOT: `.[]` iterates an object's
  # VALUES, so `{"a":{"number":1,"title":"x"}}` projects cleanly into a
  # FABRICATED PR node and a fabricated closes edge, reported `ok`. The type
  # clause is the only guard against that class; do not simplify it away.
  # Slurping collapses the whole payload to ONE document and the type test
  # admits only a single top-level array; everything else yields `empty`, so
  # `[ -z "$count" ]` reports the honest `error`. Deliberate consequence: a
  # `null` payload now reports `error` rather than `absent` — `null` is not a
  # legitimately empty PR list.
  count="$(printf '%s' "$raw" | jq -s 'if (length == 1 and (.[0]|type) == "array") then (.[0]|length) else empty end' 2>/dev/null)" || count=""
  if [ -z "$count" ]; then
    _sg_source_result error '[]' '[]' "unparseable gh pr list output"
    return 0
  fi
  if [ "$count" -eq 0 ]; then
    _sg_source_result absent '[]' '[]' ""
    return 0
  fi
  # These arms are NOT unreachable-on-failure: they are the honest-error path
  # for a payload that parses as a single top-level array (so the `count` guard
  # above admits it, legitimately) but whose ELEMENTS are not PR objects —
  # `["a","b"]` is the worked case. They therefore report `error`, NOT the
  # belt-and-suspenders `|| extra='[]'` default the closed-residue block uses
  # (~:583-593). That default is right THERE because `extra` is supplementary
  # data, where an empty fallback loses only a little context. Here `nodes` IS
  # the answer, so defaulting it to `[]` would manufacture a confident false
  # negative: `_sg_query_unlinked_prs` refuses to answer over a DEGRADED source
  # — that refusal is the safety property — but an `ok` source with zero nodes
  # does not trigger it, so the query would assert "no unlinked PRs" over a
  # payload it could not read. That silent wrong-empty is the class
  # `_board_sanitize_control_chars`'s own header records as worse than a
  # degrade. The `[ -n ]` belts stay: neither arm may hand an empty string to
  # `_sg_source_result`'s `--argjson`, and jq can exit zero with no output.
  nodes="$(printf '%s' "$raw" | jq -c '[ .[] | {type:"PR", id:("PR:"+(.number|tostring)), number:.number, title:(.title // "")} ]' 2>/dev/null)" \
    || { _sg_source_result error '[]' '[]' "pr_list node transform failed"; return 0; }
  [ -n "$nodes" ] || { _sg_source_result error '[]' '[]' "pr_list node transform produced no output"; return 0; }
  edges="$(printf '%s' "$raw" | jq -c '
    [ .[] as $pr
      | (($pr.body // "") | split("\n")[]) as $line
      | select($line | test("^[ \t]*(close[sd]?|fix(e[sd])?|resolve[sd]?)[ \t]+#[0-9]+[ \t]*$"; "i"))
      | ($line | capture("#(?<n>[0-9]+)")) as $m
      | {type:"closes", from:("PR:"+($pr.number|tostring)), to:("Issue:"+$m.n)}
    ]' 2>/dev/null)" \
    || { _sg_source_result error '[]' '[]' "pr_list edge transform failed"; return 0; }
  [ -n "$edges" ] || { _sg_source_result error '[]' '[]' "pr_list edge transform produced no output"; return 0; }
  _sg_source_result ok "$nodes" "$edges" ""
}

# --- source 4: worktrees (Worktree nodes) -----------------------------------
# `git worktree list` (acceptance criterion 1), filtered to LINKED worktrees
# under `<repo-basename>.wt/` (ADR 0033) — the main checkout itself is never
# emitted as a node. `absent` = a git repo with no linked worktrees right
# now (the common case); `error` = `_sg_git` itself failed (not a git repo,
# or git unavailable).
_sg_read_worktrees() {
  local board="$1" repo base raw line path nodes
  repo="$(board_repo "$board" 2>/dev/null)" || { _sg_source_result error '[]' '[]' "board_repo failed"; return 0; }
  base="$(basename "$repo")"
  if ! raw="$(_sg_git worktree list --porcelain 2>/dev/null)"; then
    _sg_source_result error '[]' '[]' "git worktree list failed"
    return 0
  fi
  nodes='[]'
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path="${line#worktree }"
        case "$path" in
          */"${base}.wt/"*)
            nodes="$(jq -c --arg p "$path" '. + [{type:"Worktree", id:("Worktree:"+$p), path:$p}]' <<<"$nodes")"
            ;;
        esac
        ;;
    esac
  done <<<"$raw"
  if [ "$(jq 'length' <<<"$nodes")" -eq 0 ]; then
    _sg_source_result absent '[]' '[]' ""
  else
    _sg_source_result ok "$nodes" '[]' ""
  fi
}

# --- source 5: plan_notes (PlanItem nodes, depends_on/after edges) ---------
# One `ks_list Plans` + `ks_read` per matching note, through the knowledge-
# store interface (lib/knowledge_store.sh, `KNOWLEDGE_STORE_ROOT`) — never a
# hand-rolled vault-path read. Only a note whose frontmatter `status:` is
# `approved` or `executing` counts (a `draft`/`done`/`abandoned` plan is not
# live work — mirrors `/build`'s own `status:` gate, claude/plan-schema.md).
# `absent` = the store (or its `Plans/` prefix) does not exist, OR no note
# matched (acceptance criterion: "an absent store or no matching note is
# absent") — `ks_list` already returns nothing (not an error) for a missing
# root/prefix, so this needs no separate existence probe. `error` = an
# item's checkbox sentinel is not a `state:plan-sentinel` row in the
# ontology registry (mirrors source 1's own unknown-token error, ADR 0032).
# `depends-on:`/`after:` are parsed by SLUG (claude/plan-schema.md § Item
# identifier, never by position) and resolved to `PlanItem:<stem>:<slug>`
# node ids, `<stem>` from `jk_plan_stem` (the join-key loader — never a
# hand-stripped `basename`/`.md` trim). `pr:`/`pushed_sha:` (orchestrator-
# written fields, same section) ride as plain node fields; the ontology
# defines no edge for them.
_sg_plan_sentinel_tokens() {
  awk -F'\t' '$1=="state:plan-sentinel" && $2!="" {print $2}' "$ONTOLOGY_REGISTRY_FILE" 2>/dev/null
}

# <content> -> the frontmatter `status:` value, or nothing if absent/no
# frontmatter block. Scoped strictly to the FIRST `---`/`---` pair so a
# `status:`-shaped line in the body (an example in `notes:`, say) is never
# mistaken for the real frontmatter field.
_sg_plan_note_status() {
  awk '
    /^---[[:space:]]*$/ { d++; next }
    d==1 && /^status:[[:space:]]*/ { sub(/^status:[[:space:]]*/,""); gsub(/[[:space:]]+$/,""); print; exit }
    d>=2 { exit }
  ' <<<"$1"
}

# <sentinel-tokens-json> <stem> <slug> <sentinel-char> <depends-csv>
# <after-csv> <pr> <pushed_sha> -> {bad, node, edges} for one plan item.
# `bad`=true when the sentinel is not a registered state:plan-sentinel
# token (the caller flips the whole source to `error`); node/edges are
# null/empty in that case. Kept as its own function (rather than inlined in
# the line-scanning loop below) purely to keep that loop a plain
# state-machine walk.
_sg_plan_item_result() {
  local toks="$1" stem="$2" slug="$3" sentinel="$4" deps="$5" afters="$6" pr="$7" sha="$8"
  jq -cn --argjson toks "$toks" --arg stem "$stem" --arg slug "$slug" --arg tok "[$sentinel]" \
    --arg pr "$pr" --arg sha "$sha" --arg deps "$deps" --arg afters "$afters" '
    ("PlanItem:" + $stem + ":" + $slug) as $id |
    if ($toks | index($tok)) == null then
      {bad: true, node: null, edges: []}
    else
      {
        bad: false,
        node: ({type:"PlanItem", id:$id, slug:$slug, state:$tok}
               + (if $pr=="" then {} else {pr:$pr} end)
               + (if $sha=="" then {} else {pushed_sha:$sha} end)),
        edges: (
          ($deps | split(",") | map(select(length>0))
            | map({type:"depends_on", from:$id, to:("PlanItem:"+$stem+":"+.)}))
          + ($afters | split(",") | map(select(length>0))
            | map({type:"after", from:$id, to:("PlanItem:"+$stem+":"+.)}))
        )
      }
    end'
}

_sg_read_plan_notes() {
  local ids id content st stem nodes edges bad=0 sentinel_toks
  local line cur_slug cur_sentinel cur_deps cur_afters cur_pr cur_sha
  local records s se de af pr sh res fs
  # Item checkbox: `- [<c>] **<title>** \`slug: <kebab>\` — <scope>`, at
  # column 0 (an indented sub-bullet, e.g. an acceptance-list line, never
  # matches). Sub-field: `  - <key>: <value>`, 2-space indented under it.
  # shellcheck disable=SC2016  # the backtick is a literal pattern character
  local item_re='^- \[([^]])\].*`slug:[[:space:]]*([a-z0-9-]+)`'
  local sub_re='^[[:space:]]+- (depends-on|after|pr|pushed_sha):[[:space:]]*(.*)$'
  # Internal-only field separator for the `records` accumulator below — the
  # ASCII Unit Separator (0x1F), never TAB. Bash's `read` treats TAB (like
  # every default-IFS whitespace char) as a COLLAPSING delimiter regardless
  # of what IFS is set to: a run of them is one delimiter and an EMPTY field
  # between two of them silently vanishes, shifting every field after it one
  # slot left (`pr:`/`pushed_sha:` landing in each other's place when
  # `depends-on:`/`after:` is absent in between). \x1f is not IFS
  # whitespace, so `read` preserves empty fields exactly where TAB would not.
  fs=$'\x1f'

  sentinel_toks="$(_sg_plan_sentinel_tokens | jq -Rsc 'split("\n") | map(select(length>0))')"
  nodes='[]'; edges='[]'
  ids="$(ks_list Plans 2>/dev/null)" || ids=""

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    content="$(ks_read "$id" 2>/dev/null)" || continue
    st="$(_sg_plan_note_status "$content")"
    case "$st" in
      approved | executing) ;;
      *) continue ;;
    esac
    stem="$(jk_plan_stem "$id" 2>/dev/null)" || stem="$id"

    records=""
    cur_slug=""; cur_sentinel=""; cur_deps=""; cur_afters=""; cur_pr=""; cur_sha=""
    while IFS= read -r line; do
      if [[ $line =~ $item_re ]]; then
        if [ -n "$cur_slug" ]; then
          records="${records}${cur_slug}${fs}${cur_sentinel}${fs}${cur_deps}${fs}${cur_afters}${fs}${cur_pr}${fs}${cur_sha}"$'\n'
        fi
        cur_sentinel="${BASH_REMATCH[1]}"
        cur_slug="${BASH_REMATCH[2]}"
        cur_deps=""; cur_afters=""; cur_pr=""; cur_sha=""
      elif [ -n "$cur_slug" ] && [[ $line =~ $sub_re ]]; then
        case "${BASH_REMATCH[1]}" in
          depends-on) cur_deps="$(printf '%s' "${BASH_REMATCH[2]}" | tr -d ' ')" ;;
          after) cur_afters="$(printf '%s' "${BASH_REMATCH[2]}" | tr -d ' ')" ;;
          pr) cur_pr="${BASH_REMATCH[2]}" ;;
          pushed_sha) cur_sha="${BASH_REMATCH[2]}" ;;
        esac
      fi
    done <<<"$content"
    if [ -n "$cur_slug" ]; then
      records="${records}${cur_slug}${fs}${cur_sentinel}${fs}${cur_deps}${fs}${cur_afters}${fs}${cur_pr}${fs}${cur_sha}"$'\n'
    fi

    while IFS="$fs" read -r s se de af pr sh; do
      [ -n "$s" ] || continue
      res="$(_sg_plan_item_result "$sentinel_toks" "$stem" "$s" "$se" "$de" "$af" "$pr" "$sh")"
      if [ "$(jq -r '.bad' <<<"$res")" = "true" ]; then
        bad=1
        continue
      fi
      nodes="$(jq -c --argjson n "$(jq -c '.node' <<<"$res")" '. + [$n]' <<<"$nodes")"
      edges="$(jq -c --argjson e "$(jq -c '.edges' <<<"$res")" '. + $e' <<<"$edges")"
    done <<<"$records"
  done <<<"$ids"

  if [ "$bad" -eq 1 ]; then
    _sg_source_result error '[]' '[]' "plan-item sentinel not in ontology registry"
    return 0
  fi
  if [ "$(jq 'length' <<<"$nodes")" -eq 0 ]; then
    _sg_source_result absent '[]' '[]' ""
  else
    _sg_source_result ok "$nodes" "$edges" ""
  fi
}

# --- source 6: journal (Session nodes, step outcomes) -----------------------
# Reads every `agent-*.jsonl` workflow-runtime transcript found at any depth
# under `$SPEND_TRANSCRIPT_ROOT` (build.config.sh) — the SAME transcript
# root pipeline-spend-report.sh already reads (temperloop#958); no second
# setting for the same directory. Each line is a JSON object; a line
# carrying BOTH a `sessionId` and a `step`+`outcome` pair is a step-outcome
# record (build.md's own pr-batch-executor `{outcome:"PR_OPENED", ...}`
# shape, generalized to a named `step` so more than that one executor's
# outcomes can be recorded) and is folded into that session's `steps` array
# — every other line (an ordinary transcript message) carries neither field
# and is skipped; not every journal line is a step-outcome record.
# `sessionId` is normalized through `_sg_normalize_session_id` (the
# join-key loader), never hand-rolled. `absent` = no transcript root, no
# matching files, or no step-outcome lines in any of them found (nothing to
# report — the same "legitimately empty" convention as pr_list/worktrees;
# covers the acceptance criterion's "a missing transcript directory is
# absent" as the degenerate case of "nothing found"). `error` = a journal
# line that is not valid JSON at all (a corrupted/truncated transcript).
_sg_read_journal() {
  local root files f line sid outcome nodes malformed=0 by_sid='{}'
  root="${SPEND_TRANSCRIPT_ROOT:-}"
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    _sg_source_result absent '[]' '[]' "no transcript root"
    return 0
  fi
  files="$(find "$root" -type f -name 'agent-*.jsonl' 2>/dev/null | sort)"
  if [ -z "$files" ]; then
    _sg_source_result absent '[]' '[]' "no journal files"
    return 0
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if ! jq -e . >/dev/null 2>&1 <<<"$line"; then
        malformed=1
        break
      fi
      sid="$(jq -r '.sessionId // empty' <<<"$line")"
      [ -n "$sid" ] || continue
      if ! jq -e '((.step // "") != "") and ((.outcome // "") != "")' >/dev/null 2>&1 <<<"$line"; then
        continue
      fi
      sid="$(_sg_normalize_session_id "$sid")"
      # `slug` is an OPTIONAL passthrough (present only when the producing
      # line already carries one) — never a required field, and its absence
      # changes nothing about this object's shape (see the `resume` query
      # header comment above, tier 2). Kept additive so the exact-equality
      # assertion in test_state_graph_local.sh (a line with no `slug`) still
      # gets back exactly `{"step":...,"outcome":...}`, byte for byte.
      outcome="$(jq -c '{step:.step, outcome:.outcome} + (if ((.slug // "") | tostring) != "" then {slug: .slug} else {} end)' <<<"$line")"
      by_sid="$(jq -c --arg sid "$sid" --argjson step "$outcome" \
        '.[$sid] = ((.[$sid] // []) + [$step])' <<<"$by_sid")"
    done < "$f"
    [ "$malformed" -eq 0 ] || break
  done <<<"$files"

  if [ "$malformed" -eq 1 ]; then
    _sg_source_result error '[]' '[]' "malformed journal line"
    return 0
  fi

  nodes="$(jq -c '[ to_entries[] | {type:"Session", id:("Session:"+.key), steps:.value} ]' <<<"$by_sid")"
  if [ "$(jq 'length' <<<"$nodes")" -eq 0 ]; then
    _sg_source_result absent '[]' '[]' ""
  else
    _sg_source_result ok "$nodes" '[]' ""
  fi
}

# --- source 7: tmux (Marker nodes, marked_by edges) -------------------------
# `tmux list-windows -a` for every window's `@claimed_issue` option — the
# SAME per-window marker claim.sh/release.sh write via
# workflows/scripts/board/lib/claim_marker.sh — never a hand-rolled tmux
# query. New seam `_sg_tmux` (mirrors `_sg_git`). Its failure covers BOTH
# "no tmux binary on this host" and "tmux binary present but no server
# running": both read the same way from the caller's side (the command
# simply fails), and the acceptance criterion treats them identically —
# `absent`, never "no claims held". A host that DOES have a reachable
# server but holds zero claims right now is `ok` with an empty node/edge
# list — that zero-claims state must NEVER be reported as `absent`
# (acceptance criterion). `error` = the server answered `list-sessions` but
# a SECOND, independent call (`list-windows`) then failed unexpectedly — a
# genuine tmux-side fault, not an absence. A window's `@claimed_issue`
# value not shaped like `#<N> ...` (claim.sh's own display-string
# convention, claim_marker.sh) carries no issue to attach a `marked_by`
# edge to and is skipped — it is not ours to graph.
_sg_tmux() { tmux "$@"; }

_sg_read_tmux() {
  local raw nodes edges wid disp issue
  if ! _sg_tmux list-sessions >/dev/null 2>&1; then
    _sg_source_result absent '[]' '[]' "no tmux binary or no server"
    return 0
  fi
  if ! raw="$(_sg_tmux list-windows -a -F $'#{window_id}\t#{@claimed_issue}' 2>/dev/null)"; then
    _sg_source_result error '[]' '[]' "tmux list-windows failed"
    return 0
  fi
  nodes='[]'; edges='[]'
  while IFS=$'\t' read -r wid disp; do
    [ -n "$wid" ] || continue
    [ -n "$disp" ] || continue
    case "$disp" in
      "#"[0-9]*) issue="${disp#"#"}"; issue="${issue%%[!0-9]*}" ;;
      *) continue ;;
    esac
    nodes="$(jq -c --arg w "$wid" --arg d "$disp" \
      '. + [{type:"Marker", id:("Marker:"+$w), window:$w, display:$d}]' <<<"$nodes")"
    edges="$(jq -c --arg i "$issue" --arg w "$wid" \
      '. + [{type:"marked_by", from:("Issue:"+$i), to:("Marker:"+$w)}]' <<<"$edges")"
  done <<<"$raw"
  _sg_source_result ok "$nodes" "$edges" ""
}

# --- source 8: transcripts (Transcript nodes — stale-claims's liveness -----
# oracle, temperloop#1980 round 3) ------------------------------------------
# Reimplements `reconcile.sh`'s own `_reconcile_session_live` read-only, so
# `stale-claims` can decide liveness from the EXACT same evidence: the
# newest `$CLAUDE_PROJECTS_DIR/*/<sess>*.jsonl` (Claude Code's own per-
# session transcript — NOT the Workflow-runtime `agent-*.jsonl` files the
# journal source above reads; a different file family that happens to share
# `journal`'s own default root) mtime, within `RECONCILE_STALE_AFTER_SECS`
# of "now" — BOTH settings named identically to reconcile.sh's own (never a
# second literal; check-setting-registry.sh's "byte-identical duplicate seam
# in a non-owning file" allowance is exactly this shape). No COMMAND seam
# like `_sg_git`/`_sg_tmux`: mirrors the journal source's own precedent (no
# command to shim, only files — tests point `CLAUDE_PROJECTS_DIR` at a
# fixture directory with `touch -t`-controlled mtimes, exactly like
# `SPEND_TRANSCRIPT_ROOT` for journal). "Now" itself IS seamed, though
# (temperloop#1980 round 4 MEDIUM 1) — see `_sg_now`'s own definition
# above — so a test can pin a fixture's mtime exactly on the cutoff
# boundary and discriminate the `<=`/`<` comparison sense.
#
# `absent` = no transcript directory at all (nothing to check liveness
# against — matches tmux's prior "no server" cannot-determine case, and
# `_sg_query_stale_claims`'s own local carve-out treats it as `unknown`,
# never a confident empty set). `ok` = the directory was read, emitting a
# `Transcript` node for every session whose newest matching file is within
# the cutoff — a session with NO transcript, or whose transcript is stale
# beyond the cutoff, legitimately emits no node ("dead" is the ordinary
# empty case here, mirroring `_reconcile_session_live`'s own "no transcript
# -> dead" reading, never `absent`). `error` = the directory exists but
# could not be read (permission denied) — a genuine fault, distinct from
# absence.
_sg_read_transcripts() {
  local dir now cutoff nodes='[]' raw live sess8 mt f base
  dir="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
  [ -d "$dir" ] || { _sg_source_result absent '[]' '[]' "no transcript directory"; return 0; }
  [ -r "$dir" ] || { _sg_source_result error '[]' '[]' "transcript directory not readable"; return 0; }
  now="$(_sg_now)"
  cutoff="${RECONCILE_STALE_AFTER_SECS:-86400}"
  # one <sess8>\t<mtime> row per transcript file — portable mtime (GNU
  # `stat -c` / BSD `stat -f`, the same fallback `_reconcile_session_live`
  # itself uses).
  raw="$(
    shopt -s nullglob
    for f in "$dir"/*/*.jsonl; do
      base="$(basename "$f" .jsonl)"
      sess8="${base:0:8}"
      [ -n "$sess8" ] || continue
      mt="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)" || continue
      printf '%s\t%s\n' "$sess8" "$mt"
    done
  )"
  # collapse to the NEWEST mtime per sess8 (mirrors _reconcile_session_live's
  # own "max mtime among any matching file" reduction), keeping only those
  # within the cutoff — a live session emits a node, a dead one emits none.
  live="$(printf '%s\n' "$raw" | awk -F'\t' -v now="$now" -v cutoff="$cutoff" '
    NF != 2 { next }
    $2 > max[$1] { max[$1] = $2 }
    END { for (s in max) if ((now - max[s]) <= cutoff) print s"\t"max[s] }
  ')"
  while IFS=$'\t' read -r sess8 mt; do
    [ -n "$sess8" ] || continue
    nodes="$(jq -c --arg id "Transcript:$sess8" --arg s8 "$sess8" --argjson mt "$mt" \
      '. + [{type:"Transcript", id:$id, sess8:$s8, mtime:$mt}]' <<<"$nodes")"
  done <<<"$live"
  _sg_source_result ok "$nodes" '[]' ""
}

# --- the extensible reader table (acceptance criterion 1) -------------------
_SG_SOURCES="board board_edges pr_list worktrees plan_notes journal tmux transcripts"

# --- assemble one full snapshot (live, always fresh) ------------------------
_sg_build_snapshot() {
  local board="$1" repo built_at host r_board r_board_edges r_pr r_wt r_plan r_journal r_tmux r_transcripts
  repo="$(board_repo "$board" 2>/dev/null)" || repo=""
  r_board="$(_sg_read_board "$board")"
  r_board_edges="$(_sg_read_board_edges "$board" "$r_board")"
  r_pr="$(_sg_read_pr_list "$board")"
  r_wt="$(_sg_read_worktrees "$board")"
  r_plan="$(_sg_read_plan_notes "$board")"
  r_journal="$(_sg_read_journal "$board")"
  r_tmux="$(_sg_read_tmux "$board")"
  r_transcripts="$(_sg_read_transcripts)"
  built_at="$(date +%s)"
  # Resolved ONCE here, never per-query (stale-claims's host gate,
  # temperloop#1980 round 3 HIGH 2, reads this field so it stays a pure
  # function of the snapshot rather than shelling out to `hostname` itself).
  host="$(board_host_label)"

  jq -cn \
    --arg board "$board" --arg repo "$repo" --arg host "$host" \
    --argjson built_at "$built_at" --argjson sv 1 \
    --argjson board_r "$r_board" --argjson board_edges_r "$r_board_edges" \
    --argjson pr_r "$r_pr" --argjson wt_r "$r_wt" \
    --argjson plan_r "$r_plan" --argjson journal_r "$r_journal" --argjson tmux_r "$r_tmux" \
    --argjson transcripts_r "$r_transcripts" '
    def src($r): {status: $r.status, detail: $r.detail, n_nodes: ($r.nodes|length), n_edges: ($r.edges|length)};
    {
      schema_version: $sv,
      board: $board,
      repo: $repo,
      host: $host,
      built_at: $built_at,
      sources: {
        board: src($board_r),
        board_edges: src($board_edges_r),
        pr_list: src($pr_r),
        worktrees: src($wt_r),
        plan_notes: src($plan_r),
        journal: src($journal_r),
        tmux: src($tmux_r),
        transcripts: src($transcripts_r)
      },
      nodes: ($board_r.nodes + $board_edges_r.nodes + $pr_r.nodes + $wt_r.nodes
              + $plan_r.nodes + $journal_r.nodes + $tmux_r.nodes + $transcripts_r.nodes),
      edges: ($board_r.edges + $board_edges_r.edges + $pr_r.edges + $wt_r.edges
              + $plan_r.edges + $journal_r.edges + $tmux_r.edges + $transcripts_r.edges)
    }'
}

# --- persist through cache.sh (repo-keyed dir, meta.json, temp-then-rename) -
# Reuses cache.sh's own PATH accessors (cache_repo_dir / cache_snapshot_file /
# cache_meta_file) so the on-disk layout is byte-identical in shape to the
# issue-cache store's (repo-keyed directory under $CACHE_STORE_ROOT, a
# meta.json carrying schema_version/repo/last_refresh) — kind=state-graph
# keeps this fully namespace-isolated from the issue-cache kind
# (cache_dirty/cache_clear/cache_stale on one kind never touch the other,
# temperloop#1929). The write itself is NOT `_cache_persist_snapshot` (that
# function is hardwired to the raw-GitHub-issue-list jq transform and to
# kind="issues") — this is our own temp-then-rename writer, mirroring its
# exact discipline: write to a `.tmp.$$` file in the same directory, `mv`
# into place, only then write meta.json.
_sg_persist_snapshot() {
  local board="$1" json="$2" kind="${3:-state-graph}" dir snap meta tmp repo
  dir="$(cache_repo_dir "$board" "$kind")" || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  snap="$(cache_snapshot_file "$board" "$kind")" || return 1
  meta="$(cache_meta_file "$board" "$kind")" || return 1
  tmp="$dir/.snapshot.tmp.$$"
  printf '%s\n' "$json" >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv "$tmp" "$snap" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  repo="$(board_repo "$board" 2>/dev/null)" || repo=""
  jq -nc --arg repo "$repo" --argjson ts "$(date +%s)" --argjson sv 1 \
    '{schema_version:$sv, repo:$repo, last_refresh:$ts}' >"$meta" 2>/dev/null || return 1
}

# --- the read helper: stale-at-read-time transform --------------------------
# `_sg_read_snapshot <board> [kind]`: reads the on-disk snapshot (rc 1, no
# stdout, if none exists yet) and, when its meta.json age is at or past
# `STATE_GRAPH_MAX_AGE_S`, overrides EVERY source's status to "stale" before
# printing (ADR 0033 / acceptance criterion 2) — the recorded ok/absent/error
# status from build time is preserved verbatim when the snapshot is still
# fresh. Used internally by `build` for nothing (build always just wrote a
# fresh-by-definition snapshot) and exists as the seam `state-graph.sh query`
# (temperloop#1919) will call; test_state_graph.sh exercises it directly by
# sourcing this file and seeding a snapshot+meta pair at a controlled age.
_sg_read_snapshot() {
  local board="$1" kind="${2:-state-graph}" snap meta last age now
  snap="$(cache_snapshot_file "$board" "$kind")" || return 1
  meta="$(cache_meta_file "$board" "$kind")" || return 1
  [ -s "$snap" ] || return 1
  last="$(jq -r '.last_refresh // 0' "$meta" 2>/dev/null)"
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  now="$(date +%s)"
  age=$(( now - last ))
  if [ "$age" -ge "${STATE_GRAPH_MAX_AGE_S:-300}" ]; then
    jq -c '.sources |= with_entries(.value.status = "stale")' "$snap"
  else
    cat "$snap"
  fi
}

# --- queries (temperloop#1910 L6) -------------------------------------------
# Each `_sg_query_*` is a PURE function of a snapshot JSON string — no board/
# gh/git access of its own — so tests feed a synthetic snapshot literal
# directly. See the header comment above for what each answers and the
# absent-vs-degraded convention every one of them follows.

# _sg_source_status <snapshot> <source-name> -> that source's recorded status
# ("ok"/"absent"/"error"/"stale"), or "absent" if the source key is missing
# entirely (a snapshot built before a source existed, or a hand-written test
# fixture that omits an irrelevant source) — never a jq null propagating into
# a case statement.
_sg_source_status() {
  jq -r --arg s "$2" '.sources[$s].status // "absent"' <<<"$1"
}

# _sg_degraded <status> -> 0 (true) iff error/stale — the shared "can't tell,
# never silently answer empty" predicate every query below applies to the
# source(s) it depends on.
_sg_degraded() {
  case "$1" in
    error | stale) return 0 ;;
    *) return 1 ;;
  esac
}

_sg_query_status_drift() {
  local snap="$1" st
  st="$(_sg_source_status "$snap" board)"
  if _sg_degraded "$st"; then
    jq -cn --arg st "$st" '{query:"status-drift", status:"unknown", reason:("board source is "+$st), findings:"unknown"}'
    return 0
  fi
  jq -c '
    (.nodes | map(select(.type=="Issue"))) as $issues
    | ($issues | map(select((.state // "open") == "open"))) as $open_issues
    | ($issues | map(select((.state // "open") == "closed"))) as $closed_issues
    | (.edges | map(select(.type=="claimed_by")) | map(.from)) as $claimed
    | {
        query: "status-drift",
        status: "ok",
        findings: (
          [ $open_issues[] | .id as $iid | select(.status == "fnd:status:in-progress" and (($claimed | index($iid)) == null))
            | {id:$iid, kind:"in_progress_no_claim"} ]
          + [ $open_issues[] | .id as $iid | select(.status != "fnd:status:in-progress" and (($claimed | index($iid)) != null))
              | {id:$iid, kind:"claimed_not_in_progress"} ]
          # closed-issue residue (temperloop#1978, this board source read —
          # see _sg_read_board header comment above it): a closed Issue node
          # only ever appears here carrying a non-empty residual
          # fnd:status:* label (that presence is the read filter for
          # emitting the node at all), so status != done is always true in
          # practice here — kept explicit anyway as the honest reason this
          # branch fires, not an incidental side effect.
          + [ $closed_issues[] | .id as $iid | select(.status != "done")
              | {id:$iid, kind:"closed_with_status_label"} ]
        )
      }' <<<"$snap"
}

_sg_query_stale_claims() {
  local snap="$1" bst trst host
  bst="$(_sg_source_status "$snap" board)"
  trst="$(_sg_source_status "$snap" transcripts)"
  host="$(jq -r '.host // ""' <<<"$snap")"
  if _sg_degraded "$bst"; then
    jq -cn --arg st "$bst" '{query:"stale-claims", status:"unknown", reason:("board source is "+$st), findings:"unknown"}'
    return 0
  fi
  if _sg_degraded "$trst"; then
    jq -cn --arg st "$trst" '{query:"stale-claims", status:"unknown", reason:("transcripts source is "+$st), findings:"unknown"}'
    return 0
  fi
  # LOCAL carve-out (temperloop#1980 round 3): transcripts is this query's
  # liveness ORACLE, so — unlike every other consumer of the transcripts
  # source, where `absent` legitimately means "no live sessions found" —
  # `absent` here means "cannot determine liveness", not "nothing is live".
  # Scoped to this query only; `_sg_degraded` stays error|stale (see its own
  # header comment) and status-drift's "absent = nothing found" reading of
  # the board source is untouched. SUPERSEDES round 2's tmux-absent carve-
  # out: tmux is no longer consulted by this query at all (see the header
  # comment above and the PR body) — round 2 keyed liveness off a source the
  # comparison target, reconcile.sh --status, never actually invokes.
  if [ "$trst" = "absent" ]; then
    jq -cn '{query:"stale-claims", status:"unknown", reason:"transcripts source is absent (no transcript directory found - liveness cannot be established)", findings:"unknown"}'
    return 0
  fi
  # HOST GATE FIRST (temperloop#1980 round 3 HIGH 2): a claim stamped to
  # another host is excluded from `$claims` entirely, before liveness is
  # even considered — this host's own transcript directory cannot speak to
  # a foreign host's liveness, and reconcile.sh's own claim-liveness lens
  # gates the exact same way (`[ "$shost" = "$HOST" ]`) before ever
  # reaching `_reconcile_session_live`.
  #
  # STATUS GATE (temperloop#1980 round 4 HIGH): `$claims` is ALSO gated to
  # Issue nodes currently `fnd:status:in-progress`, matching reconcile.sh's
  # own producer (reconcile.sh:876-879), which emits its "stale claims (In
  # Progress...)" class ONLY for an In-Progress issue — a claim stamp on a
  # non-In-Progress item (the ordinary "Park, don't abandon" residue:
  # `board_set_status` moves an issue off In Progress without clearing its
  # claim stamp, only `release.sh` does that) is NOTHING on reconcile's
  # side, never a finding. Round 3 applied the host half of this gate and
  # left the status half off, so a parked issue's stranded claim stamp
  # surfaced here (`drift_query_set:[N]`) against reconcile's structurally
  # empty set for it — a standing false disagreement, the same shape this
  # query's own MEDIUM (stranded claim stamps on closed issues, see the
  # soak header comment above) was already excluded for. `$ip` is read off
  # the SAME board source already gated above (never a second source), so a
  # claim naming an Issue with no matching node at all (never emitted by
  # the board source, e.g. a fixture that omits it) is excluded exactly
  # like a real non-in-progress issue would be.
  jq -c --arg host "$host" '
    (.nodes | map(select(.type=="Transcript")) | map(.sess8)) as $live8
    | (.nodes | map(select(.type=="Issue" and .status=="fnd:status:in-progress")) | map(.id)) as $ip
    | (.edges | map(select(.type=="claimed_by"))
              | map(select((.to | split(":")[1]) == $host))
              | map(select(.from as $f | $ip | index($f) != null))) as $claims
    | { query:"stale-claims", status:"ok",
        findings: [ $claims[] | .from as $iid
                    | (.to | split(":")[2]) as $sess8
                    | select(($live8 | index($sess8)) == null)
                    | {issue:$iid, session:.to} ] }
  ' <<<"$snap"
}

_sg_query_unlinked_prs() {
  local snap="$1" st
  st="$(_sg_source_status "$snap" pr_list)"
  if _sg_degraded "$st"; then
    jq -cn --arg st "$st" '{query:"unlinked-prs", status:"unknown", reason:("pr_list source is "+$st), findings:"unknown"}'
    return 0
  fi
  jq -c '
    (.nodes | map(select(.type=="PR"))) as $prs
    | (.edges | map(select(.type=="closes")) | map(.from)) as $closing
    | { query:"unlinked-prs", status:"ok",
        findings: [ $prs[] | .id as $pid | select(($closing | index($pid)) == null) | {id:$pid, number:.number} ] }
  ' <<<"$snap"
}

_sg_query_orphan_worktrees() {
  local snap="$1" wst pst
  wst="$(_sg_source_status "$snap" worktrees)"
  pst="$(_sg_source_status "$snap" plan_notes)"
  if _sg_degraded "$wst"; then
    jq -cn --arg st "$wst" '{query:"orphan-worktrees", status:"unknown", reason:("worktrees source is "+$st), findings:"unknown"}'
    return 0
  fi
  if _sg_degraded "$pst"; then
    jq -cn --arg st "$pst" '{query:"orphan-worktrees", status:"unknown", reason:("plan_notes source is "+$st), findings:"unknown"}'
    return 0
  fi
  jq -c '
    (.nodes | map(select(.type=="Worktree"))) as $wts
    | (.nodes | map(select(.type=="PlanItem" and (.state=="[~]" or .state=="[m]" or .state=="[>]"))) | map(.slug)) as $live_slugs
    | { query:"orphan-worktrees", status:"ok",
        findings: [ $wts[] | (.path | split("/") | last) as $slug
                    | select(($live_slugs | index($slug)) == null)
                    | {id:.id, path:.path, slug:$slug} ] }
  ' <<<"$snap"
}

# resume: see the header comment's "RESUME implements..." section for the
# tier walk this jq program encodes 1:1. `route` is ALWAYS one of the
# ontology registry's `state:route` tokens (never a bare "unknown" — see
# that header comment for why); `authority` names which tier decided.
_sg_query_resume() {
  local snap="$1" jst wst bst
  jst="$(_sg_source_status "$snap" journal)"
  wst="$(_sg_source_status "$snap" worktrees)"
  bst="$(_sg_source_status "$snap" board)"
  jq -c --arg jst "$jst" --arg wst "$wst" --arg bst "$bst" '
    def degraded($s): ($s == "error" or $s == "stale");
    (.nodes | map(select(.type=="Session"))) as $sessions
    | (.nodes | map(select(.type=="Worktree")) | map(.path | split("/") | last)) as $wt_slugs
    | (.nodes | map(select(.type=="PlanItem"))) as $items
    | {
        query: "resume",
        status: "ok",
        items: [ $items[] | . as $it |
          ($it.state) as $s
          | (($it.pr // "") | tostring) as $pr
          | (($it.pushed_sha // "") | tostring) as $sha
          | (
              if ($s == "[x]" or $s == "[-]" or $s == "[v]") then
                {id:$it.id, slug:$it.slug, route:"already-done", authority:"plan"}
              elif ($pr != "") then
                {id:$it.id, slug:$it.slug, route:"adopt", authority:"plan"}
              elif ($sha != "") then
                {id:$it.id, slug:$it.slug, route:"fresh", authority:"plan"}
              elif degraded($jst) then
                {id:$it.id, slug:$it.slug, route:"probe-failed", authority:"journal"}
              else
                ( [ $sessions[] | (.steps // [])[] | select((.slug // "") == $it.slug) ] ) as $matches
                | if ($matches | length) > 0 then
                    (if ($matches | map(.outcome) | index("PR_OPENED")) != null then
                       {id:$it.id, slug:$it.slug, route:"adopt", authority:"journal"}
                     else
                       {id:$it.id, slug:$it.slug, route:"fresh", authority:"journal"}
                     end)
                  elif degraded($wst) then
                    {id:$it.id, slug:$it.slug, route:"probe-failed", authority:"git"}
                  elif ($wt_slugs | index($it.slug)) != null then
                    {id:$it.id, slug:$it.slug, route:"fresh", authority:"git"}
                  elif degraded($bst) then
                    {id:$it.id, slug:$it.slug, route:"probe-failed", authority:"board"}
                  else
                    {id:$it.id, slug:$it.slug, route:"fresh", authority:"board"}
                  end
              end
            )
        ]
      }
  ' <<<"$snap"
}

cmd_query() {
  local name="" board=""
  if [ $# -eq 0 ]; then
    echo "state-graph.sh: query requires <name> --board <N>" >&2
    usage
    exit 2
  fi
  name="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) board="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      *) echo "state-graph.sh: query: unknown arg '$1'" >&2; usage; exit 2 ;;
    esac
  done
  [ -n "$board" ] || { echo "state-graph.sh: query requires --board <N>" >&2; usage; exit 2; }
  case "$name" in
    status-drift | stale-claims | unlinked-prs | orphan-worktrees | resume) ;;
    *)
      echo "state-graph.sh: query: unknown query '$name' (expected status-drift|stale-claims|unlinked-prs|orphan-worktrees|resume)" >&2
      usage
      exit 2
      ;;
  esac

  local snapshot
  if ! snapshot="$(_sg_read_snapshot "$board" 2>/dev/null)"; then
    snapshot="$(_sg_build_snapshot "$board")"
    _sg_persist_snapshot "$board" "$snapshot" "state-graph" ||
      echo "state-graph.sh: warning: snapshot persist failed for board $board (disk/permission?) — printing unpersisted result" >&2
  fi
  case "$name" in
    status-drift) _sg_query_status_drift "$snapshot" ;;
    stale-claims) _sg_query_stale_claims "$snapshot" ;;
    unlinked-prs) _sg_query_unlinked_prs "$snapshot" ;;
    orphan-worktrees) _sg_query_orphan_worktrees "$snapshot" ;;
    resume) _sg_query_resume "$snapshot" ;;
  esac
}

# --- soak (temperloop#1910, this item) --------------------------------------
# The soak log's own cache.sh kind — fully namespace-isolated from
# "state-graph"/"state-graph-bench" (cache_dirty/cache_clear on one kind
# never touches another, temperloop#1929). Its file is `cache_snapshot_file`
# (`.../snapshot.jsonl`) reused for real this time as an APPEND-ONLY JSON
# LINES log (every other kind treats that path as a single-record snapshot
# overwritten whole) — never a hand-rolled path, per this file's own
# cache.sh-persistence convention (`_sg_persist_snapshot`'s header comment).
_SG_SOAK_KIND="state-graph-soak"

_sg_soak_log_file() {
  local board="$1" dir file
  dir="$(cache_repo_dir "$board" "$_SG_SOAK_KIND")" || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  file="$(cache_snapshot_file "$board" "$_SG_SOAK_KIND")" || return 1
  printf '%s' "$file"
}

# --- soak: per-class reduction helpers (temperloop#1978) --------------------
# Reduce one `_sg_query_*` result to a comparable SORTED-UNIQUE JSON array —
# or the literal string "unknown" when the query's own `status` reads
# "unknown" (its source is degraded), mirroring every `_sg_query_*`'s own
# never-a-bare-empty-set convention. One reducer per findings SHAPE (issue-id
# findings for status-drift/stale-claims, PR-number findings for
# unlinked-prs, slug findings for orphan-worktrees — orphan-worktrees has no
# issue-number domain at all, so its set is worktree SLUGS, never compared
# against reconcile.sh, which has no worktree concept either).
_sg_soak_reduce_issue_findings() {
  local qj="$1" field="$2"
  if [ "$(jq -r '.status' <<<"$qj")" = "unknown" ]; then
    echo '"unknown"'
  else
    jq -c --arg f "$field" '[ .findings[] | .[$f] | ltrimstr("Issue:") | tonumber ] | sort | unique' <<<"$qj"
  fi
}
_sg_soak_reduce_pr_findings() {
  local qj="$1"
  if [ "$(jq -r '.status' <<<"$qj")" = "unknown" ]; then
    echo '"unknown"'
  else
    jq -c '[ .findings[].number ] | sort | unique' <<<"$qj"
  fi
}
_sg_soak_reduce_slug_findings() {
  local qj="$1"
  if [ "$(jq -r '.status' <<<"$qj")" = "unknown" ]; then
    echo '"unknown"'
  else
    jq -c '[ .findings[].slug ] | sort | unique' <<<"$qj"
  fi
}

# Reconcile-side per-class extraction (temperloop#1978): reconcile.sh's
# --status report prints several section headers, each covering a distinct
# drift class (reconcile.sh's own `status_reconcile_main`) — see this file's
# own header comment for the full class->domain mapping this implements.
# Anchored on the report's line-leading `  #N` shape reconcile.sh uses for
# its own marker parse (`sed -n 's/^#\([0-9][0-9]*\).*/\1/p'`,
# reconcile.sh:468), so a `#N` embedded mid-line in a flagged item's TITLE is
# never mistaken for a ref. `<class>` is `status-drift` or `stale-claims`;
# any other value returns an empty set (there is nothing to map it to).
_sg_reconcile_class_set() {
  local text="$1" class="$2" nums
  nums="$(awk -v want="$class" '
    /^terminal-but-not-Done/                       { sec="status-drift"; next }
    /^residual status labels on closed issues/     { sec="status-drift"; next }
    /^orphaned In-Progress/                         { sec="status-drift"; next }
    /^stale claims \(In Progress/                   { sec="stale-claims"; next }
    # NOT mapped (temperloop#1980 round 3 MEDIUM): the board-source closed-
    # issue residue read never attaches a claimed_by edge to a closed Issue
    # node, so this reconcile class can only ever land in only_in_reconcile
    # — see the header comment above (the stale-claims <-> reconcile
    # mapping) for the full rationale.
    /^stranded claim stamps on closed issues/       { sec=""; next }
    /^foreign claims \(In Progress on another host/ { sec=""; next }
    /^foreign claims \(STALE/                       { sec=""; next }
    /^unresolved \(state not found/                 { sec=""; next }
    /^In sync:/                                     { sec=""; next }
    /^[[:space:]]*$/                                { next }
    /^[[:space:]]*#[0-9]+[[:space:]]/ {
      if (sec == want) {
        n = $0
        sub(/^[[:space:]]*#/, "", n)
        sub(/[^0-9].*/, "", n)
        print n
      }
      next
    }
    { sec = "" }
  ' <<<"$text" | sort -n | uniq)"
  printf '%s' "$nums" | jq -Rsc 'split("\n") | map(select(length>0) | tonumber)'
}

# One per-class {drift_query_set, reconcile_set, diff} entry. `rset` is
# either a real (possibly empty) sorted-unique array, the literal string
# "unknown" (reconcile.sh itself failed this run), or the literal string
# "not-covered" (unlinked-prs / orphan-worktrees: reconcile.sh has no
# matching class, ever — see this file's header comment). `diff` is
# "unknown" whenever EITHER side is (never a false empty-set agreement
# computed over a side that couldn't actually be read — checked first, so a
# degraded drift-query side still reads "unknown" even against a
# structurally not-covered reconcile side), else "not-covered" when the
# reconcile side has nothing to compare against, else the real per-class
# `{only_in_drift_query, only_in_reconcile, agree}` object.
_sg_soak_class_entry() {
  local dset="$1" rset="$2" diff
  if [ "$dset" = '"unknown"' ] || [ "$rset" = '"unknown"' ]; then
    diff='"unknown"'
  elif [ "$rset" = '"not-covered"' ]; then
    diff='"not-covered"'
  else
    diff="$(jq -cn --argjson a "$dset" --argjson b "$rset" '
      { only_in_drift_query: ($a - $b), only_in_reconcile: ($b - $a),
        agree: (($a - $b) == [] and ($b - $a) == []) }')"
  fi
  jq -cn --argjson dq "$dset" --argjson rc "$rset" --argjson diff "$diff" \
    '{drift_query_set:$dq, reconcile_set:$rc, diff:$diff}'
}

# One soak run: build + persist a fresh snapshot, run all four board/PR/
# worktree-comparable queries — status-drift, stale-claims, unlinked-prs,
# orphan-worktrees — over that SAME snapshot (no second live build),
# separately run ONE `reconcile.sh --status` through the `_sg_reconcile` seam
# (its report reused for every mapped class, never one call per class), and
# append one PER-CLASS dated record. See this file's own header comment for
# the full class->reconcile-class mapping and the unknown/not-covered
# semantics `_sg_soak_class_entry` implements.
_sg_soak_run() {
  local board="$1" snapshot day logf record
  local dq_status dq_stale dq_pr dq_wt
  local status_set stale_set pr_set wt_set
  local rc_out rc_rc=0 rc_status_set rc_stale_set
  local status_entry stale_entry pr_entry wt_entry

  snapshot="$(_sg_build_snapshot "$board")"
  _sg_persist_snapshot "$board" "$snapshot" "state-graph" ||
    echo "state-graph.sh: warning: soak snapshot persist failed for board $board (disk/permission?)" >&2

  dq_status="$(_sg_query_status_drift "$snapshot")"
  dq_stale="$(_sg_query_stale_claims "$snapshot")"
  dq_pr="$(_sg_query_unlinked_prs "$snapshot")"
  dq_wt="$(_sg_query_orphan_worktrees "$snapshot")"

  status_set="$(_sg_soak_reduce_issue_findings "$dq_status" id)"
  stale_set="$(_sg_soak_reduce_issue_findings "$dq_stale" issue)"
  pr_set="$(_sg_soak_reduce_pr_findings "$dq_pr")"
  wt_set="$(_sg_soak_reduce_slug_findings "$dq_wt")"

  # stdout only (`2>/dev/null`) — reconcile.sh's flagged lines carry the
  # item's TITLE on the same line, and titles routinely contain `#N`
  # themselves (`fix … (temperloop#1910)`); a stray board.sh warning routed
  # to stderr can carry an unrelated `#N` too. Merging either into the
  # parsed text manufactures a phantom issue number and a false
  # disagreement — the one thing this cross-check exists to avoid.
  rc_out="$(_sg_reconcile --board "$board" --status 2>/dev/null)" || rc_rc=$?
  if [ "$rc_rc" -ne 0 ]; then
    rc_status_set='"unknown"'
    rc_stale_set='"unknown"'
  else
    rc_status_set="$(_sg_reconcile_class_set "$rc_out" status-drift)"
    rc_stale_set="$(_sg_reconcile_class_set "$rc_out" stale-claims)"
  fi

  status_entry="$(_sg_soak_class_entry "$status_set" "$rc_status_set")"
  stale_entry="$(_sg_soak_class_entry "$stale_set" "$rc_stale_set")"
  pr_entry="$(_sg_soak_class_entry "$pr_set" '"not-covered"')"
  wt_entry="$(_sg_soak_class_entry "$wt_set" '"not-covered"')"

  day="$(_sg_soak_day)"
  logf="$(_sg_soak_log_file "$board")" || { echo "state-graph.sh: soak: could not resolve soak log path" >&2; return 1; }
  record="$(jq -cn --arg day "$day" \
    --argjson sd "$status_entry" --argjson sc "$stale_entry" \
    --argjson pr "$pr_entry" --argjson wt "$wt_entry" \
    '{day:$day, type:"run", schema:2,
      classes: {"status-drift":$sd, "stale-claims":$sc,
                "unlinked-prs":$pr, "orphan-worktrees":$wt}}')"
  printf '%s\n' "$record" >>"$logf"
  printf '%s\n' "$record"
}

# `soak --count --board N`: the number of DISTINCT `day` values across every
# CURRENT-SCHEMA-COMPARABLE record in the log — a missing or empty log
# prints 0, never an error (nothing recorded yet). `type:"audit"` /
# `type:"bench"` records are unaffected by the temperloop#1978 per-class
# rewrite and always count; a `type:"run"` record counts only at `schema:2`
# — the OLD flat-schema run record (temperloop#1910: `{day,
# drift_query_set, reconcile_set, diff}`, no `type` field at all) is
# deliberately EXCLUDED rather than misread as a per-class one (acceptance
# criterion 4; see this file's header comment's SCHEMA VERSIONING section).
_sg_soak_count() {
  local board="$1" logf
  logf="$(_sg_soak_log_file "$board")" || { echo "state-graph.sh: soak: could not resolve soak log path" >&2; return 1; }
  if [ ! -s "$logf" ]; then
    echo 0
    return 0
  fi
  # No `2>/dev/null` on the `jq` here: under `pipefail` a torn/malformed line
  # already makes this pipeline (and, as the function's last command, the
  # whole script) exit non-zero — discarding jq's stderr left that exit code
  # legible but its REASON silent. Surface it instead of a bare rc.
  jq -r 'select(.type == "audit" or .type == "bench" or (.type == "run" and .schema == 2)) | .day' "$logf" |
    sort -u | wc -l | tr -d ' ' ||
    { echo "state-graph.sh: soak --count: unreadable soak log $logf" >&2; return 1; }
}

# `soak --audit --board N --items <file>`: a hand-audited item set logged
# against today, for a human to compare against the same day's mechanical
# diff. `<file>` is one ANCHORED issue reference per line — a bare number,
# `#N`, or `Issue:N`, matched only against the line's leading ref (never
# every digit run on the line, so a line like `#20 build fails on 2026-09`
# records just `20`, not `2026`/`09` too).
_sg_soak_audit() {
  local board="$1" items_file="$2" items day logf record
  [ -f "$items_file" ] || { echo "state-graph.sh: soak --audit: items file not found: $items_file" >&2; return 1; }
  # `sed` exits 0 on zero matches (unlike `grep -oE`), so a file naming zero
  # issues is a legitimate empty audit set with no pipefail/set -e trip.
  items="$(sed -nE 's/^[[:space:]]*(#|Issue:)?([0-9]+).*/\2/p' "$items_file" | sort -n | uniq | jq -Rsc 'split("\n") | map(select(length>0) | tonumber)')"
  day="$(_sg_soak_day)"
  logf="$(_sg_soak_log_file "$board")" || { echo "state-graph.sh: soak: could not resolve soak log path" >&2; return 1; }
  record="$(jq -cn --arg day "$day" --argjson items "$items" '{day:$day, type:"audit", audited_items:$items}')"
  printf '%s\n' "$record" >>"$logf"
  printf '%s\n' "$record"
}

cmd_soak() {
  local board="" mode="run" items_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) board="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --count) mode="count"; shift ;;
      --audit) mode="audit"; shift ;;
      --items) items_file="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      # `usage` writes to stderr everywhere else in this file (the error-path
      # convention every other subcommand's `-h|--help` also follows) — this
      # ONE case redirects it to stdout instead (`2>&1`, not a second usage
      # text), because the class-A activation predicate this item is gated
      # on (temperloop#1934) is `soak --help 2>/dev/null | grep -q --
      # '--count'` and would otherwise discard the very text it greps for.
      -h|--help) usage 2>&1; exit 0 ;;
      *) echo "state-graph.sh: soak: unknown arg '$1'" >&2; usage; exit 2 ;;
    esac
  done
  [ -n "$board" ] || { echo "state-graph.sh: soak requires --board <N>" >&2; usage; exit 2; }
  case "$mode" in
    run) _sg_soak_run "$board" ;;
    count) _sg_soak_count "$board" ;;
    audit)
      [ -n "$items_file" ] || { echo "state-graph.sh: soak --audit requires --items <file>" >&2; usage; exit 2; }
      _sg_soak_audit "$board" "$items_file"
      ;;
  esac
}

# --- commands ----------------------------------------------------------------
cmd_build() {
  local board=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) board="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      *) echo "state-graph.sh: build: unknown arg '$1'" >&2; usage; exit 2 ;;
    esac
  done
  [ -n "$board" ] || { echo "state-graph.sh: build requires --board <N>" >&2; usage; exit 2; }

  local snapshot
  snapshot="$(_sg_build_snapshot "$board")"
  _sg_persist_snapshot "$board" "$snapshot" "state-graph" ||
    echo "state-graph.sh: warning: snapshot persist failed for board $board (disk/permission?) — printing unpersisted result" >&2
  printf '%s\n' "$snapshot"
}

cmd_clean() {
  local board=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) board="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      *) echo "state-graph.sh: clean: unknown arg '$1'" >&2; usage; exit 2 ;;
    esac
  done
  [ -n "$board" ] || { echo "state-graph.sh: clean requires --board <N>" >&2; usage; exit 2; }
  cache_clear "$board" "state-graph"
}

# `bench --scale <N> --board <N>`: builds the REAL board's snapshot once (same
# four sources, same seams — no network in tests), then synthesizes a
# snapshot at N times its node/edge count (fabricated Bench-typed nodes, no
# real host names/session ids/paths) and times the persist step, writing the
# synthetic result to its OWN cache kind (state-graph-bench) so a bench run
# never clobbers the real state-graph-kind snapshot for that board.
cmd_bench() {
  local board="" scale=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) board="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --scale) scale="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      *) echo "state-graph.sh: bench: unknown arg '$1'" >&2; usage; exit 2 ;;
    esac
  done
  [ -n "$board" ] || { echo "state-graph.sh: bench requires --board <N>" >&2; usage; exit 2; }
  case "$scale" in
    '' | *[!0-9]*) echo "state-graph.sh: bench requires --scale <N> (positive integer)" >&2; usage; exit 2 ;;
  esac

  local base n0 m0 synth start_ms end_ms elapsed_ms
  base="$(_sg_build_snapshot "$board")"
  n0="$(jq '.nodes|length' <<<"$base")"
  m0="$(jq '.edges|length' <<<"$base")"

  start_ms="$(_sg_now_ms)"
  synth="$(jq -cn --argjson n "$n0" --argjson m "$m0" --argjson scale "$scale" '
    {
      nodes: [ range(0; ($n * $scale)) | {type:"Bench", id:("Bench:"+(.|tostring))} ],
      edges: [ range(0; ($m * $scale)) | {type:"bench_edge", from:("Bench:"+(.|tostring)), to:("Bench:"+(((.+1) % ($n*$scale+1))|tostring))} ]
    }')"
  local snapshot repo built_at
  repo="$(board_repo "$board" 2>/dev/null)" || repo=""
  built_at="$(date +%s)"
  snapshot="$(jq -cn --arg board "$board" --arg repo "$repo" --argjson built_at "$built_at" \
    --argjson scale "$scale" --argjson synth "$synth" --argjson sv 1 '
    {schema_version:$sv, board:$board, repo:$repo, built_at:$built_at, bench_scale:$scale,
     sources: {bench:{status:"ok", detail:"synthetic", n_nodes:($synth.nodes|length), n_edges:($synth.edges|length)}},
     nodes: $synth.nodes, edges: $synth.edges}')"
  _sg_persist_snapshot "$board" "$snapshot" "state-graph-bench" ||
    echo "state-graph.sh: warning: bench snapshot persist failed for board $board" >&2
  end_ms="$(_sg_now_ms)"
  elapsed_ms=$(( end_ms - start_ms ))

  echo "state-graph bench: board=$board scale=$scale nodes=$(jq '.nodes|length' <<<"$synth") edges=$(jq '.edges|length' <<<"$synth") build_ms=$elapsed_ms"

  # Time each of the five named queries against this synthetic snapshot and
  # append ONE bench-type record to the soak log (temperloop#1910, this
  # item's acceptance criterion 2) — never a second persisted-snapshot store,
  # the SAME log `soak` itself appends to. Running bench at scale 1, then 10,
  # then 100 (this file's doc convention for "one of these values") leaves a
  # per-scale trail a soak reviewer scans for the first scale whose
  # `query_ms` exceeds `STATE_GRAPH_QUERY_SLOW_MS`.
  local qname qstart qend qms query_ms='{}' slow_queries='[]' slow_ms day logf bench_record
  slow_ms="${STATE_GRAPH_QUERY_SLOW_MS:-500}"
  # Same digit guard `--scale` uses above — a bad env override (`500ms`)
  # would otherwise reach `[ -gt ]`/`--argjson` below and die non-zero AFTER
  # the summary line already printed (a half-completed run, no soak-log
  # record). Warn and fall back to the config default instead.
  case "$slow_ms" in
    '' | *[!0-9]*)
      echo "state-graph.sh: bench: STATE_GRAPH_QUERY_SLOW_MS='$slow_ms' is not a positive integer; using default 500" >&2
      slow_ms=500
      ;;
  esac
  for qname in status-drift stale-claims unlinked-prs orphan-worktrees resume; do
    qstart="$(_sg_now_ms)"
    case "$qname" in
      status-drift)     _sg_query_status_drift "$snapshot" >/dev/null ;;
      stale-claims)     _sg_query_stale_claims "$snapshot" >/dev/null ;;
      unlinked-prs)     _sg_query_unlinked_prs "$snapshot" >/dev/null ;;
      orphan-worktrees) _sg_query_orphan_worktrees "$snapshot" >/dev/null ;;
      resume)           _sg_query_resume "$snapshot" >/dev/null ;;
    esac
    qend="$(_sg_now_ms)"
    qms=$(( qend - qstart ))
    query_ms="$(jq -c --arg q "$qname" --argjson ms "$qms" '. + {($q): $ms}' <<<"$query_ms")"
    if [ "$qms" -gt "$slow_ms" ]; then
      slow_queries="$(jq -c --arg q "$qname" '. + [$q]' <<<"$slow_queries")"
    fi
  done

  day="$(_sg_soak_day)"
  if logf="$(_sg_soak_log_file "$board")"; then
    bench_record="$(jq -cn --arg day "$day" --argjson scale "$scale" --argjson slow "$slow_ms" \
      --argjson query_ms "$query_ms" --argjson slow_queries "$slow_queries" \
      '{day:$day, type:"bench", scale:$scale, slow_ms:$slow, query_ms:$query_ms, slow_queries:$slow_queries}')"
    printf '%s\n' "$bench_record" >>"$logf"
  else
    echo "state-graph.sh: warning: bench soak-log append failed for board $board" >&2
  fi
}

# --- dispatch (skipped when sourced for tests) -------------------------------
# Mirrors gate.sh: a test `source`s this file to override the `_board_gh` /
# `_sg_git` seams and call `_sg_read_*` / `cmd_*` / `_sg_read_snapshot`
# directly, so the dispatch must NOT run on source. The guard compares $0 to
# BASH_SOURCE.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ $# -eq 0 ]; then
    usage
    exit 2
  fi
  cmd="$1"; shift
  case "$cmd" in
    build) cmd_build "$@" ;;
    clean) cmd_clean "$@" ;;
    bench) cmd_bench "$@" ;;
    query) cmd_query "$@" ;;
    soak) cmd_soak "$@" ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "state-graph.sh: unknown subcommand '$cmd'" >&2
      usage
      exit 2
      ;;
  esac
fi
