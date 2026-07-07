# Presentation-plane index

> **Source of truth: `claude/presentation-plane.md`**, deployed to
> `~/.claude/presentation-plane.md` by `make install-claude` (same symlink
> convention as the rest of `claude/`). Epic #94 (communication-style model),
> plan item `plane-enumeration`.

The kernel ships (or will ship) style templates that restyle how commands talk
to the operator — tone, verbosity, formatting of human-facing prose. Some of
the kernel's output surfaces are not prose at all: they are grammars a parser
(GitHub's closing-keyword scanner, `/build`'s orchestrator, a shell script's
`jq` caller, a CI validator) reads back mechanically. A style template that
"helpfully" reformats one of those breaks the parser silently — the #164
failure shape (looks like it worked; nothing downstream notices until the
mechanism that depended on the exact bytes fails).

This file is the **index of which surfaces are which**. It is deliberately
**not** a second copy of any contract: each row below names a surface,
classifies it, and points at the ONE place that surface's real shape is owned
(spec-centralization — the same discipline foundation's F#741 telemetry-sink
README uses so emit sites point at one canonical spec instead of restating
it). If a contract's shape ever changes, this index does not need editing —
only the pointer needs to keep resolving. **Never paste or paraphrase an
owning contract's content into a row here** — a stale enumeration that
mislabels a parsed surface as style-free would license the very breakage this
index exists to prevent.

## How to use this index

For any concrete output you're about to restyle:

1. Find the surface (or the smallest surface it contains — see "Mixed
   surfaces" below) in the **kernel table**, then the **overlay-extension
   table** if the project has one installed.
2. **Frozen** → do not change its literal bytes: keyword, casing, delimiter,
   field name, heading path, label string, JSON key/value, whatever the
   owning contract specifies. Follow the pointer and read the real contract
   before touching anything nearby.
3. **Not listed** → treat as **style-free**: human-facing prose (PR
   descriptions, plan-item titles and notes prose, commit-message bodies
   minus any closing-keyword line, decision-issue question prose, session
   summaries) that a style template may restyle freely.
4. Found a machine-parsed surface that isn't listed? That's a gap in this
   index, not license to guess — file it (kernel: an issue against this repo;
   overlay: per that project's capture-at-source rule) and add a row once the
   real owner is confirmed.

### Mixed surfaces (the common trap)

Most frozen surfaces are not whole documents — they are **exact lines or
fields embedded inside an otherwise free-form document**. A PR body is mostly
style-free prose, EXCEPT a bare `Closes #N` line and the `## Verification`
section's resolved content. A plan-note item is mostly free-form prose,
EXCEPT its checkbox sentinel and its indented sub-line fields. A decision
issue comment is mostly free-form question prose, EXCEPT the fenced
` ```decision ` block / `/choose` / `/approve` grammar and (for a plan-approval
poll specifically) the `plan-approval-poll:` marker line. Restyle the
document; leave the embedded frozen line(s) byte-for-byte alone.

---

## Kernel table

Surfaces generic enough that a stranger's kernel-only checkout (no overlay,
no board, no vault) needs them frozen too.

| Surface | Class | Owning contract / parser | Why |
|---|---|---|---|
| Bare `Closes #N` / `Fixes #N` issue-closing line in a PR body or commit message | **Frozen** | `claude/CLAUDE.kernel.md` § Issue linkage (grammar) + `workflows/scripts/build/pr.sh` `open` (mechanical emitter) | GitHub's own closing-keyword scanner reads this exact bare-line, non-backticked form; a reformatted or combined (`Closes #1 and #2`) line silently fails to close. |
| Plan-note status sentinels `[ ]`/`[~]`/`[m]`/`[x]`/`[v]`/`[-]` | **Frozen** | `claude/plan-schema.md` § Status sentinels (meaning) + `workflows/scripts/build/plan.sh` `writeback`/`toposort` (mechanical parser/writer) | `/build`'s crash-resume, dependency-level toposort, and merge-gate logic branch on these exact tokens — see `plan.sh`'s closed `{"outcome":…}` contract. |
| Orchestrator/author sub-line fields on a plan item: `pr:`, `pushed_sha:`, `gh_issue:`, `also_closes:`, `epic:`, `split_from:`, `gate_check:`, `slug:`, `branch:`, `depends-on:`, `after:` | **Frozen** | `claude/plan-schema.md` (field definitions) + `workflows/scripts/build/plan.sh` `validate`/`writeback` | `/build` resume, `worktree.sh`'s deterministic `<slug>` path, `pr.sh`'s `Closes` emission, and `gate.sh`'s risk read all key off these exact field names. |
| `speculative: true` / `escalated: true` sentinel sub-lines | **Frozen** | `claude/commands/build.md` §§ "Crash-safe sentinel" / "Stamp `escalated: true`" (not in `plan-schema.md`) | Step 0.5 reconcile and Step 1.4 resume use presence/absence of these exact tokens to discriminate a held speculative worker / an escalated-awaiting-continuation item from a plain stuck worker — a renamed or reworded sentinel collapses the discrimination. |
| Decision-issue reply grammar: fenced ` ```decision ` block, `chosen:` key, `/choose <label>`, `/approve` shorthand, the `decision` label | **Frozen** | `claude/decision-queue-contract.md` §§ 2–3 | The driver's typed-reply parser and closed-enum-or-escalate rule read this exact grammar; the `decision` label is also the queue's drain filter (`--label decision --assignee ""`). |
| `plan-approval-poll: [[Plans/<vault-path>]]` marker line | **Frozen** | `claude/commands/assess.md` Step 6 (minted; "load-bearing... must not change") / `claude/commands/build.md` Step 0a (consumed as filter) | Literal-string filter `/build` Step 0a uses to distinguish a plan-approval decision issue from any other decision issue in the same queue. |
| `gate.sh` structured `.outcome` JSON (`READ`/`STRICT`/`NON_STRICT`/`RISKY`/`CLEAN_DISJOINT_INDEPENDENT`/`QUEUED`/`NUDGED`/`NUDGE_NOOP`/`MERGED`/`CONFLICTING`/`TIMEOUT`/`NATIVE`/`MANAGED`/`EJECTED`/`MERGE_REJECTED`/`ERROR`) | **Frozen** | `workflows/scripts/build/gate.sh` header (closed outcome-set contract) | The orchestrator branches on `.outcome` and associated keys only — never parses prose; a reworded outcome value is a silent no-match. |
| `pr.sh` structured outcomes (`SCAN_CLEAN`/`SCAN_BLOCKED`/`BASE_CURRENT`/`BASE_STALE`/`REBASED`/`REBASE_CONFLICT`/`PUSHED`/`PUSH_REJECTED`/`PR_OPENED`/`EXISTS`/`ERROR`) | **Frozen** | `workflows/scripts/build/pr.sh` header | Same closed-outcome-set contract as `gate.sh`; `open --body-only` is the one exception (prints raw prose body, not JSON — see that surface separately, style-free). |
| `worktree.sh` structured outcomes (`CREATED`/`REMOVED`/`NOT_FOUND`/`PRUNED`/`SKIPPED_DIRTY`/`SKIPPED_UNMERGED`/`ERROR`) | **Frozen** | `workflows/scripts/build/worktree.sh` header | Same closed-outcome-set contract; the deterministic `<repo-root>.wt/<slug>` path it derives is also frozen (a pure function of `slug:`, never restated by a worker). |
| `ci-poll.sh` structured outcomes (`CI_GREEN`/`CI_FAILED`/`TIMEOUT`/`ERROR`) | **Frozen** | `workflows/scripts/build/ci-poll.sh` header | Same closed-outcome-set contract; `failed_run_ids` shape is part of it. |
| `.build-guard` worktree marker file (JSON: `slug`/`branch`/`created`) | **Frozen** | `workflows/scripts/build/worktree.sh` (`create`, writer) + `claude/hooks/build-worktree-guard.sh` (reader) | The PreToolUse write-jail hook arms itself by checking for this exact filename's presence — a renamed marker file silently disarms the guard. |
| Telemetry / raw-lake record shapes (`command-run`, `issue-touches`, `claims`, `funnel`, `knowledge-search-fallback` streams; the `schema_version` convention) | **Frozen** | `meta/data/raw/README.md` (canonical sink spec) | Every emit site (`emit-command-run.sh`, `emit-issue-touch.sh`, `emit-gh-perf.sh`, …) and every reader points here rather than restating the shape; a stream's readers key off exact field names, and a breaking change requires the documented `schema_version` bump. |
| Board adapter field names/values: `Status` single-select option strings, the `Host/Session` claim-stamp format, `Seq`, `Component` | **Frozen** | `workflows/scripts/board/lib/board.sh` (field-name constants) + `claim.sh`/`worklist.sh`/`reconcile.sh` (consumers) | The distributed-lock read (claim/release/reconcile) and the board's Ready/In-Progress/Done routing key off these exact option strings and the stamp format; a restyled option string desyncs the board from every reader. |
| Work-class labels `Operational` / `Foundational` | **Frozen** | `claude/work-class-policy.md` | The autonomous funnel driver's autonomy-policy branch (fully-autonomous vs prep-then-gate) matches on these exact label strings. |
| Live/Drain pairing registry table (`claude/commands/tidy.md` § "Live/Drain pairings" table) | **Frozen** | `workflows/scripts/validate-live-drain.sh` (mechanical table parser) | The validator parses this table's literal row/column structure to assert every live rule has a paired drain backstop; reflowing the table (not just its prose) breaks the CI gate silently. |

## Overlay-extension table

Surfaces owned by a downstream overlay (an org/personal composition on top of
this kernel checkout) that a bare kernel checkout has no knowledge of and
cannot verify. **This table is scaffold-only here** — the kernel repo does
not know the real shape of an overlay's frozen surfaces; the consuming
overlay populates its own rows once its style templates are wired up (plan
item `overlay-adoption`). The rows below are illustrative of the *pattern*,
not an exhaustive or verified enumeration.

| Surface | Class | Owning contract / parser | Why |
|---|---|---|---|
| *(example, foundation)* Overlay-only telemetry streams layered onto `meta/data/raw/` (rework-tracking, richer issue-metadata snapshots, retrospective-verdict snapshots) | **Frozen** | *(overlay's own `meta/data/raw/README.md` extension — not this kernel's)* | Same reasoning as the kernel `command-run`/`issue-touches` row, scoped to overlay-only emit sites; the overlay's README extends this kernel's stub additively rather than replacing it (per `meta/data/raw/README.md` § Scope). |
| *(example, foundation)* `claude/live-drain-registry.overlay.md` § "Live/Drain pairings — overlay extension" table | **Frozen** | `workflows/scripts/validate-live-drain.sh` (unions this table in when present) | Same mechanical-parse reasoning as the kernel Live/Drain row, for pairs whose live half is a personal/vault-backed rule with no meaning in a standalone kernel checkout. |
| *(placeholder — add real overlay-specific frozen surfaces here as they're identified)* | — | — | — |

---

## Maintenance

Add a row here whenever a new machine-parsed output surface is introduced
(a new `.outcome` value on an existing script is not a new row — it's covered
by the existing row's pointer to that script's header; a genuinely new
script or grammar is). Do not let this index drift ahead of or behind the
contracts it points at — if a pointer stops resolving (file moved, section
renamed), fix the pointer in the same change that moves the target.
