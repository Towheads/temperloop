# build-level.mjs — design notes

Extracted from `claude/workflows/build-level.mjs` (temperloop#2126). The module
is invoked by the Workflow tool via `scriptPath`, which refuses a file over
524288 bytes; PR #2125 pushed it to 554776 and the pipeline stopped loading. The
notes below were moved out verbatim to reclaim headroom. **Nothing here is
decoration** — each one records why a mechanism exists, and several were cited
directly by review agents. Each extraction site in the module carries a one-line
summary plus a pointer to its anchor here.

Keep a note with its code: when you change the mechanism, change its note.

**Never extract a MACHINE-PARSED comment block.** Two blocks in the module are
read by tooling, not by people: the `HANDOFF-CAPABILITIES-BEGIN`/`-END` sentinel
pair that `workflows/scripts/build/handoff-capability.sh` parses, and the
`hostConfigDeferralSection()` rationale that `test_workflow.sh` pins by string.
Both were moved here during the first extraction and both had to be put back —
the first silently turned every `/fix`, `/sweep` and `/build` Step 0 capability
probe into `CAPABILITIES_INDETERMINATE`. A comment is not automatically prose.

> **Part 1 of 3.** Split to stay under the repo's per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). Other parts: [`build-level.design-notes-2.md`](build-level.design-notes-2.md), [`build-level.design-notes-3.md`](build-level.design-notes-3.md).

> **Part 4 of 4.** Split to stay under the repo's per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). Other parts: [`build-level.design-notes.md`](build-level.design-notes.md), [`build-level.design-notes-2.md`](build-level.design-notes-2.md), [`build-level.design-notes-3.md`](build-level.design-notes-3.md).

## NO `|| default=main` guess. worktree.sh's own default_branch() (its
<a id="no-default-main-guess-worktree-sh-s-own-default-branch-its"></a>

```text
 NO `|| default=main` guess. worktree.sh's own default_branch() (its
 "The repo's default branch" helper) `return 1`s rather than inventing a
 base, and this path must do the same, because the guess does not fail
 LOUDLY here — it fails into a rev-list that errors, `ahead` that reads 0
 and a WORK_PRESERVE_SKIP "no unlanded commits". Verified against a
 throwaway fixture (bare origin defaulting to `trunk`, origin/HEAD
 deleted, one real unpushed commit): the old chain emitted
 `{"outcome":"WORK_PRESERVE_SKIP","commits_ahead":0}` over real work. And
 because preserveOnEscalation logs its "the worktree may be the ONLY
 copy" warning on every outcome EXCEPT the skip, that false negative
 silenced the one warning this whole seam exists to raise.

 So: `base_resolved` splits "genuinely zero commits ahead" from "could
 not compute". Only the FIRST may skip. The second PUSHES ANYWAY —
 pushing is the fail-safe direction on a preservation path: the cost of a
 needless push is one ref on the branch 3f already owns, while the cost
 of a needless skip is the destroyed-work incident this file documents.
 `ahead` is normalized before it is ever read as a number, so nothing
 non-numeric can reach the unquoted `"commits_ahead":%s` position and
 make the line unparseable (the pr.sh `case` idiom, e.g. its cmd_push
 ahead-count normalization).
```

## Bring the remote tip's objects local so the supersede test can run at
<a id="bring-the-remote-tip-s-objects-local-so-the-supersede-test-c"></a>

```text
 Bring the remote tip's objects local so the supersede test can run at
 all; a fetch failure leaves `unique` unset and the arm refuses.

 `--no-merges` is a DELIBERATE, acknowledged narrowing, not an oversight:
 an ordinary merge commit's underlying unique commits are still counted
 (so a normal merge is not a blind spot), but an "evil merge" — one whose
 own conflict-resolution edits exist nowhere else — carries content this
 count cannot see. Accepted because a `/build` worker branch does not
 normally carry merge commits at all, and because dropping the flag would
 count every merge's whole second parent as remote-only work and refuse
 essentially every rescue. The narrowing is bounded by property 1: the
 push is still leased, so it can only ever land on the exact sha read here.

 THREE outcomes, not two (temperloop#2103 review round 1). A refusal on an
 UNANSWERABLE probe is right, but it must not be reported as a refusal on
 an ESTABLISHED conflict: `stale_remote_not_superseded` is what the log
 turns into the flat assertion "origin carries commits this worktree does
 NOT", and a human disposes the escalation against that sentence. When the
 fetch simply failed (the network dropped between the `ls-remote` above
 and this fetch), that sentence is unproven. So `unique` empty ⇒
 `supersede_probe_failed`, `unique > 0` ⇒ `stale_remote_not_superseded`.
 Both refuse identically — only the claim made about why differs.
```

## gateVerdict(terminalOutcome, ledger) — the ONE reconciliation point be
<a id="gateverdict-terminaloutcome-ledger-the-one-reconciliation-po"></a>

```text
 gateVerdict(terminalOutcome, ledger) — the ONE reconciliation point between
 the slice loop's terminal outcome and its failure ledger. Every arm's kind,
 counts and reason are computed HERE, from one input, so no arm can ship a
 payload that contradicts its own verdict.

 `verdict` is the single field a consumer may trust:
   RED     — at least one gate FAILED. The branch is known-broken.
   UNKNOWN — nothing failed and the suite never finished (Bash-tool timeout or
             slice-cap exhaustion). It says NOTHING about the tree — the whole
             point of temperloop#1021, preserved exactly: this and only this
             verdict escalates `acceptance-gate-timeout`.
   GREEN   — the suite finished and every gate that ran passed.

 Precedence: an OBSERVED failure dominates an UNFINISHED remainder. A run that
 failed in slice 1 and then timed out in slice 3 is RED — the failures are
 real evidence, the missing verdict for the un-run gates cannot un-fail them —
 and the reason says both halves. This is the same precedence the pre-#1587
 code already applied to a GATE_PASS terminal after a failing slice, now
 applied to the TIMEOUT arm too, so "timeout" never launders a known failure
 into an unknown. A timeout with NO observed failure is untouched.
```

## reviewDiffTsvText(diffOut) — temperloop#2020. The ONE place that turns
<a id="reviewdifftsvtext-diffout-temperloop-2020-the-one-place-that"></a>

```text
 reviewDiffTsvText(diffOut) — temperloop#2020. The ONE place that turns a
 REVIEW_DIFF result's routing-table field into the text parseTsvRows() and
 tsvChecksum() consume, so the gap check and the routing decision can never
 read two different renderings of the same payload.

 Accepts BOTH wire shapes, in this precedence:
   `tsv_lines` — the current shape (an array of data-row strings, #2020).
                 Joined on `\n`, which is byte-identical to the string the
                 previous `tsv` scalar carried: reviewDiffCmd's awk `print`
                 emitted one kept line per row, and both consumers re-append
                 their own trailing newline per kept line, so a joined array
                 and the old blob canonicalize to the same bytes and hence
                 the same row count and the same checksum.
   `tsv`       — the legacy scalar, still ACCEPTED (never emitted). An
                 un-migrated caller, a replayed older payload, or a relay
                 that reconstructed the old field keeps routing normally
                 instead of degrading.
 Returns null when NEITHER shape is present in a usable form — the caller
 distinguishes "dropped" from "legitimately empty" (`tsv_lines: []` is an
 empty ARRAY, a real zero-row table, not a missing field).
```

## temperloop#2032 — THE LAST-CHANCE READ, and the reason the disposition
<a id="temperloop-2032-the-last-chance-read-and-the-reason-the-disp"></a>

```text
 temperloop#2032 — THE LAST-CHANCE READ, and the reason the disposition
 below is three passes rather than one loop. `slot.done` is set by the
 settlement recorder attached at the spawn above, which runs as a MICROTASK
 on the reviewer's own promise — so the ceiling's race can return with a
 reviewer whose result has ALREADY arrived but whose recorder has not run
 yet. The pre-#2032 loop read `!slot.done` exactly once, immediately after
 that await, and never again: such a reviewer was reported
 `skipped — exceeded the §3e review ceiling` while its full review sat in
 hand, unread. That is not a hang — the result ARRIVES and is thrown away
 (run wf_c71d1576-e9d discarded two complete reviews that way, one of which
 had already found the defect a hand-routed reviewer re-found later and
 PR #2039 then fixed).

 The ceiling is NOT at fault and is untouched: it still bounds how long the
 pass WAITS, and this changes only what happens to a result that arrives
 anyway. Every read below is therefore as late as it can HONESTLY be —
 bounded settlement drains only (no wall clock, no timer spawn, and never a
 re-spawn of a reviewer whose result is already in hand), never a second
 wait: re-introducing one would be exactly the unbounded stall
 temperloop#2003 removed.
```

## temperloop#2003 — the CEILING BREACH. This reviewer is abandoned, neve
<a id="temperloop-2003-the-ceiling-breach-this-reviewer-is-abandone"></a>

```text
 temperloop#2003 — the CEILING BREACH. This reviewer is abandoned, never
 killed: the runtime offers no cancellation, so the promise is simply
 never awaited again and the pass proceeds. The note names the cause, so
 an operator reading the PR body sees a bounded outcome rather than the
 silence the incident actually produced. Disposition splits
 mandatory-vs-advisory below: this is the ADVISORY half (a degraded
 notice + a `mandatory_ok`-preserving tally entry); a MANDATORY route
 additionally ESCALATES after the loop.

 TEMPERLOOP#2064 — WHY THIS LINE NO LONGER SAYS "unavailable". It used to,
 to match the documented `skipped — <agent> unavailable` shape
 (CLAUDE.kernel.md § Subagent usage, legible agent-gate degradation) —
 but in that rule `unavailable` is the CAPABILITY-PROBE verdict: the
 agent is not declared in `CLAUDE.md § Subagents` or `.claude/agents/`,
 so it could not be spawned at all. A ceiling breach is the OPPOSITE
 fact: the agent IS installed and WAS spawned, and did not return in
 time. Conflating them sent the #2064 investigator at the agent roster
 while the defect sat one layer below, in the timer — and cost a live
 session ~1200s of apparent hang. disposeReviewSlot() still emits the
 true capability-probe form for the real thing (an agent-resolution
 failure), so the two senses now carry two distinct wordings, which is
 what makes either of them diagnostic. The duration reported is the tick
 this pass actually HONOURED, never the nominal ceiling: when those two
 numbers disagree, that gap IS the bug (#2064 measured 41s against 1200s).
```

## awaitReviewFanout — temperloop#2003's ceiling, applied to the whole §3
<a id="awaitreviewfanout-temperloop-2003-s-ceiling-applied-to-the-w"></a>

```text
 awaitReviewFanout — temperloop#2003's ceiling, applied to the whole §3e
 fanout. Returns once every reviewer has settled OR the ceiling elapses,
 whichever comes first; it never rejects and never throws, and the caller reads
 each slot's own `done` flag to decide the per-reviewer disposition.

 RETURNS the seconds of wall clock this pass ACTUALLY waited — the sum of the
 slices whose ticks were honoured, never the nominal ceiling (temperloop#2064).
 That number is the `<actual>` the ceiling-breach notice reports, so a reader
 of the notice is told what was measured rather than what was budgeted: the
 #2064 incident is precisely a run whose two numbers differed by ~30x while
 only the budgeted one was ever printed.

 HOW IT MEASURES TIME WITHOUT A CLOCK. `Date.now()` throws in this runtime and
 there is no timer primitive, so the wait is raced against something that
 resolves ON a clock: reviewWaitAgent(), a machinery executor whose entire job
 is one `sleep`. Each slice is a separate spawn, so the elapsed total is the
 sum of the slices that have RETURNED — an accounting this file can do with
 integers alone.

 FAIL-OPEN, DELIBERATELY. If the timer itself cannot run (the auto-mode safety
 classifier denies it, the executor returns something else), the bound is
 simply unavailable and we fall back to the pre-#2003 behaviour — await the
 fanout — with a legible notice. A timer that resolved without actually
 sleeping would otherwise manufacture an INSTANT false ceiling breach on
 perfectly healthy reviews, which is far worse than the stall it bounds
 (kernel principle 7: advisory over enforced discipline).
```

## REVIEW_BLOCK_MARK — the EXPLICIT, machine-readable boundary of one rev
<a id="review-block-mark-the-explicit-machine-readable-boundary-of-"></a>

```text
 REVIEW_BLOCK_MARK — the EXPLICIT, machine-readable boundary of one reviewer's
 block inside `## Review notes` (temperloop#2009 review round 2).

 The `### <reviewer>` heading below is for a HUMAN. It is not a parseable
 boundary and never was: reviewBodySuffix splices `sec.text` VERBATIM, and a
 reviewer's own findings text carries `### ` headings of its own (ADR 0007's
 `### [HIGH] <name> in <file>`) plus free prose headings — a single-word
 `### Notes` is indistinguishable from `### docs-reviewer` by shape alone, and
 a fenced code block can contain literally anything. pr.sh's PR-body cap has to
 know where one round's prose ends to drop the OLDEST rounds first, and two
 successive passes at inferring that from Markdown were both spoofable by
 ordinary reviewer prose (the second dropped the NEWEST round's residual HIGH
 findings — precisely what temperloop#1970 routes into this section for the
 human at the merge gate).

 So the PRODUCER marks its own blocks. An HTML comment renders as nothing on
 GitHub, is anchored at line start, and carries the two facts the consumer
 needs (which reviewer, which round) as attributes rather than as prose to be
 re-derived. `sec.text` is neutralized before splicing, so a reviewer QUOTING
 this very design — entirely likely, since one already did — cannot inject a
 boundary. Consumer: review_notes() in workflows/scripts/build/pr.sh, which
 matches this token exactly, at line start, and never guesses from a heading.
 The two literals are kept in lockstep by a static guard in test_pr.sh.
```

## reviewBodySuffix — the ONE renderer of §3e evidence into the PR body
<a id="reviewbodysuffix-the-one-renderer-of-3e-evidence-into-the-pr"></a>

```text
 reviewBodySuffix — the ONE renderer of §3e evidence into the PR body
 (temperloop#1846), across EVERY round handed to it: rounds[0] is the
 original 3f pass, rounds[1..] are ciPollLoop's CI-fix re-reviews. Before
 this, the body suffix was built from rounds[0] alone while park()'s tally
 merged every round — so a reviewer that ran only in a CI-fix round (its
 diff includes the fix commit, which can touch file classes the original
 diff never did) had its findings affirmatively OMITTED from the body's
 "ran:" line and ## Review notes, the exact #1846 failure (body said
 "ran: docs-reviewer" while review.ran carried shell-reviewer and its three
 findings). Rendering rules:
   - the "ran:" line names every DISTINCT reviewer across all rounds — a
     name-set union, so it can never be a subset of the tally's review.ran;
   - every round's findings section is spliced, none de-duped away: a
     CI-fix round's block is relabeled `### <reviewer> (ci-fix round N)` so
     a reviewer that ran in two rounds keeps BOTH blocks, distinguishable;
   - skip notices are de-duped by their full note text only (byte-identical
     notices from re-running the same degraded route add no information);
   - each block opens with a REVIEW_BLOCK_MARK delimiter line (above) that
     names its reviewer and round, so the PR-body cap can find block edges
     without parsing Markdown out of reviewer prose.
 For a single round this renders the pre-#1846 shape plus those delimiters.
```

## activationProofCmd — run the class-A `proof:` predicate from <dir>'s r
<a id="activationproofcmd-run-the-class-a-proof-predicate-from-dir-"></a>

```text
 activationProofCmd — run the class-A `proof:` predicate from <dir>'s root and
 report Pass/Fail as the predicate's OWN exit code.

 THE VERDICT IS READ UN-PIPED, WHICH IS §3e.5'S *PREFERRED* SHAPE, NOT A
 WEAKER ONE (temperloop#68/#801). The predicate runs inside a command
 substitution — not a pipe — so `$?` is already the predicate's own status
 under both bash and zsh, with no PIPESTATUS/pipestatus read to get
 dialect-wrong and no `tee` to swallow it. build.md §3e.5 names exactly this:
 "prefer running the gate un-piped and branching on its exit directly".

 DO NOT ADD `set -o pipefail` HERE. It looks like belt-and-suspenders and is
 the opposite: it silently rewrites the meaning of the AUTHOR'S OWN predicate,
 in the one direction that makes this gate theater. `pipefail` reports the
 rightmost NON-ZERO status, and a predicate whose tail exits early on a match
 (`grep -q`, `head`) SIGPIPEs its upstream writer, which dies 141. For the
 wrap-immune ABSENCE idiom plan-schema.md documents
 (`! tr '\n' ' ' < f | tr -s ' ' | grep -q '<phrase>'`) that inverts the
 verdict on the case that matters:
   phrase PRESENT (must FAIL):  pipefail -> 141 -> `!` -> 0  == false PASS
                                no pipefail -> 0 -> `!` -> 1 == correct FAIL
 Reproduced deterministically, and asserted by the "pipefail" case in
 test_workflow.sh. `scripts/lint-pipe-grep-q.sh` (temperloop#1050) is the
 tree-wide guard for the same footgun. A false PASS on an absence proof is
 precisely what the temperloop#944 control pass exists to stop, so
 reintroducing it here would defeat the control one layer up.
```

## gateFreshnessTimeoutProbeCmd — round 2 (temperloop#1937 MEDIUM): what 
<a id="gatefreshnesstimeoutprobecmd-round-2-temperloop-1937-medium-"></a>

```text
 gateFreshnessTimeoutProbeCmd — round 2 (temperloop#1937 MEDIUM): what to run
 when the OUTER Bash-tool timeout (FRESHNESS_TIMEOUT) kills gateFreshnessCmd()
 mid-flight, possibly mid-`git rebase`. A second, cheap machinery call —
 mirroring the shape of disposeStepTimeout()'s own follow-up probe for the
 inner STEP_TIMEOUT path, not that function itself (its probeSideEffects()
 ladder is push/PR-open specific and has nothing to say about a rebase). If a
 rebase is left in progress it is aborted, restoring the worktree to its
 pre-rebase commit exactly like gateFreshnessCmd's own FRESHNESS_CONFLICT
 arm; either way the caller escalates rather than proceeding blind.

 round 3 (HIGH, shell, temperloop#1937): every /build worktree is a LINKED
 worktree (`git worktree add`), whose `.git` is a pointer FILE, not a
 directory — `[ -d .git/rebase-merge ]` is therefore ALWAYS false here; the
 real state lives under `git rev-parse --git-dir` (…/.git/worktrees/<slug>/
 rebase-merge). Rather than resolve and test that path by hand, run
 `git rebase --abort` UNCONDITIONALLY and read ITS OWN exit status as the
 in-progress verdict: exit 0 means a rebase WAS in progress and is now
 aborted; a non-zero "no rebase in progress" exit means there was none to
 abort, which is not itself an error worth surfacing.
```

## 3b-0 / 3b are prelude steps only for a NON-spike item: a spike is read
<a id="3b-0-3b-are-prelude-steps-only-for-a-non-spike-item-a-spike-"></a>

```text
 3b-0 / 3b are prelude steps only for a NON-spike item: a spike is read-only
 and skips 3b–3h entirely, so it must never create a worktree. Its prelude is
 the claim alone (or nothing at all when the board is OFF).

 3b-0. Dep-merge precondition gate (#108).
 A `depends-on` edge REQUIRES its target be [x] MERGED before this item's
 worker starts — the worker must build and self-verify against the merged
 dependency code, NOT a pre-merge base. The orchestrator's level ordering
 (it runs level k's merge gate before invoking build-level for level k+1) is
 the primary guarantee; this is the mechanical backstop that refuses to
 create the worktree until every depended-on PR has actually landed in
 origin/<default> (guarding a resume race, a partial merge, an ordering bug).
 Without it, worktree.sh create bases the branch on an origin/<default> that
 LACKS the dep, the worker self-verifies against stale code, and the 3f
 unconditional rebase (#525) only repairs the branch TEXTUALLY at push —
 too late for the worker's own build/verify. item.dependsOn is [{slug,sha}]
 (each dep's merged head SHA, from the plan note's pushed_sha:); an
 absent/empty list (level-0 or after:-only deps) is a no-op. Skipped on a
 continuation — the worktree already exists and its base was gated at first
 create; re-gating would need SHAs the continuation input does not carry.
```

## Resolve the gate script from the WORKTREE, not repoRoot (temperloop#62
<a id="resolve-the-gate-script-from-the-worktree-not-reporoot-tempe"></a>

```text
 Resolve the gate script from the WORKTREE, not repoRoot (temperloop#626).
 The point of 3e.5 is to validate the worker's CHANGES, and the `cd ${wt}`
 below intends exactly that — but quality-gates.sh's first act is
 `cd "$REPO_ROOT"` where REPO_ROOT is derived from the SCRIPT's own path
 (BASH_SOURCE/..). If we ran repoRoot's copy, that cd would jump straight
 back to the main checkout and the gate would validate main's tree, not the
 worktree — silently defeating the cd. Running the worktree's own copy makes
 REPO_ROOT resolve to the worktree, so every gate (make targets, the
 diff-scoped leak guard that diffs the branch's additions, the freshness
 check) runs against the worker's tree — matching what CI sees on the PR's
 merge. The worktree is a full checkout of the branch, so this copy always
 exists whenever repoRoot's would (GATE_ABSENT still fires for a repo with
 no vendored gate). Only build-SPINE scripts (worktree.sh / pr.sh / …) route
 through machineryBin's foundation fallback; the repo-local gate resolves
 directly against the worktree.

 Resolved BEFORE the freshness step below (round 3, HIGH, temperloop#1937)
 so runGateFreshness() can gate itself behind the identical presence check
 gateCmd's own GATE_ABSENT arm makes — a project with no vendored gate
 script has nothing for the freshness step to protect.
```

## A RESUME POINT THIS SLICE PRINTED IS THE VERDICT (temperloop#2094).
<a id="a-resume-point-this-slice-printed-is-the-verdict-temperloop-"></a>

```text
 A RESUME POINT THIS SLICE PRINTED IS THE VERDICT (temperloop#2094).
 quality-gates.sh emits `QUALITY_GATES_RESUME_AT=` on exactly one path:
 it spent its budget, stopped CLEANLY BETWEEN GATES, and is telling the
 caller where the remaining gates start. That is a PARTIAL slice by
 construction, and its own `QUALITY_GATES_FAILED=` line is the count it
 established. Keying the branch on the exit code INSTEAD made that fact
 conditional on a number the script prints the trailer before producing:
 one unexpected code — a SIGTERM after the trailer, a wrapper that
 remapped the status — and a clean partial was relabelled GATE_FAIL,
 where gateSliceFailed()'s "RED by construction" floor manufactured the
 one failure the slice had just reported as zero. Observed live: three
 slices, `QUALITY_GATES_FAILED=0` in every one, stopped at gate 152 of
 200, reported `verdict: RED, failedGates: 1, suiteFinished: true`.
 So the resume point is checked FIRST and on its own; `$__rc` rides along
 as `rc` for the record (75 is the protocol code, anything else is an
 anomaly worth seeing in the ledger, neither changes the classification).
 Safe against a stale trailer because ${gateSliceLog} holds THIS slice's
 output alone — see its declaration above.
```

## ciPollLoop — bounded short-slice CI poll (DESIGN NOTE 2).
<a id="cipollloop-bounded-short-slice-ci-poll-design-note-2"></a>

```text
 -----------------------------------------------------------------------------
 ciPollLoop — bounded short-slice CI poll (DESIGN NOTE 2).
 -----------------------------------------------------------------------------
 Drives CI_POLL_SLICE_SECS-timeout ci-poll.sh calls until the outcome resolves.
 TIMEOUT on a slice = "still pending, poll again" (NOT a failure) — we keep
 looping while the total budget remains. On CI_FAILED, within
 CI_FAIL_RETRY_BUDGET, we re-spawn the worker + force-push + re-poll PINNED to
 the new SHA (#254 false-green guard).

 temperloop#942: the slices no longer cost an agent spawn EACH. One
 `ci-batch:<slug>#n` executor runs CI_POLL_SLICES_PER_BATCH
 (merge-state probe → poll slice) PAIRS in a single Bash invocation and returns
 all their JSON lines; this loop then consumes them one slice at a time from a
 buffer and branches on each exactly as it did when each came from its own
 agent. Interleaving is preserved: the merge-state probe still runs immediately
 before EVERY poll slice (#543), not once per batch. The buffer is FLUSHED
 whenever the head SHA changes (a CI-fix re-push), because buffered results are
 pinned to the OLD sha — keeping the #254 false-green guard intact. And the
 batch never runs one long poll: see DESIGN NOTE 2 for the derived slice count.
 Returns:
   { ok:true, finalSha }                         — CI green
   { ok:true, finalSha, noCi:true }              — NO_CI (temperloop#605/#618):
        no CI configured on this repo/SHA — a legible skip mirroring build.md
        3g, NOT a failure; 3h parks [m] with the no_ci sentinel stamped
   { escalation:'ci-failed', payload:{...} }      — budget exhausted / hard fail
   { escalation:'merge-conflict', payload:{...} } — PR is CONFLICTING/DIRTY
```

## The pushed-SHA hand-off guard (temperloop#2014).
<a id="the-pushed-sha-hand-off-guard-temperloop-2014"></a>

```text
 -----------------------------------------------------------------------------
 The pushed-SHA hand-off guard (temperloop#2014).
 -----------------------------------------------------------------------------
 ciPollCmd pins `--sha` to the SHA the push reported — the #254 false-green
 guard, and the one argument of the poll that this file, not the machinery,
 is responsible for. sq() stringifies whatever it is handed, so an ABSENT
 value does not crash: it renders as the literal `undefined` (or `null`),
 ci-poll.sh's own argument validation refuses to run on it, and the driver
 read that refusal back through the catch-all ERROR arm as `ci-failed` — i.e.
 reported a PR whose CI was still running (temperloop#2014: PR #2013 was OPEN
 with checks IN_PROGRESS) as a red one. Two halves close it:
   • hexSha() is the PRE-FLIGHT. Every value that can become the poll's
     `--sha` passes through it before a poll is spawned, so the driver never
     spends a slice on an argument ci-poll.sh is certain to reject.
   • a bad argument that reaches ci-poll.sh anyway (a vendored older copy, a
     validation this file does not model) comes back as its OWN escalation
     kind, `ci-poll-bad-argument`, never `ci-failed` — see isBadArgumentError
     and the ERROR arm at the bottom of ciPollLoop.
 The predicate is hex-only, matching ci-poll.sh's own `*[!0-9a-fA-F]*`
 rejection exactly. It must never be LOOSER than the check it protects, or
 the pre-flight passes something the poll then refuses — which is the whole
 failure being fixed, one layer down.
```

## ======================================================================
<a id="note-4"></a>

```text
 =============================================================================
 ITEM-KEY NORMALIZATION AT THE ORCHESTRATOR→WORKFLOW SEAM (temperloop#1700).
 =============================================================================
 This file reads the item's issue number as `item.ghIssue`. `claude/plan-schema.md`
 DOCUMENTS the field as `gh_issue:`, and `also_closes:` / `depends-on:` likewise.
 A caller that constructs items from the documented schema — a legitimate
 calling pattern, since the schema is what documents it — therefore gets:

   no `--gh-issue` flag on `pr.sh open` → no `Closes #N` in the body →
   a PR that merges green and leaves its issue OPEN → and no warning anywhere.

 Observed on PR #1697 (`closingIssuesReferences` empty); three PRs from one
 level merged closing nothing. The SILENCE is the defect: "this item has no
 tracked issue" is a legal state (`gh_issue:` is optional), so an unread key is
 indistinguishable from an absent one, and the merged-with-no-linkage PR leaves
 a stranded `fnd:status:in-progress` item wearing a live claim stamp.

 Same family as #1698 above — one meaning wearing two names across a seam, with
 the consumer's absent-key path producing a plausible-looking result instead of
 an error. Both halves the issue asks for are implemented, because each catches
 what the other cannot:
   (1) ACCEPT the documented spelling, normalizing once here. Fixes the three
       aliases we know about.
   (2) WARN on a key nothing reads. Catches the NEXT one — the class, not the
       instance.
```

## temperloop#2006 — the LEVEL-SUMMARY half of the sideline notice. Each
<a id="temperloop-2006-the-level-summary-half-of-the-sideline-notic"></a>

```text
 temperloop#2006 — the LEVEL-SUMMARY half of the sideline notice. Each
 per-item record already carries its own `sidelined` object (stampSideline
 at the fan-out above); this rolls the level's set up onto the returned
 object so the orchestrator's Step 6 summary and the merge gate see it
 without re-walking two arrays. Omitted entirely when nothing sidelined, so
 an ordinary level's return is byte-identical to before this item.

 temperloop#2080 — the map is keyed by the RECORD key, which for a
 dual-build arm is `<slug>@<arm>` (that is what phase 1 sees as item.slug).
 Walking `activeItems` alone would therefore find NEITHER arm's notice and
 the level would report zero sideline notices while two builds sat shelved.
 So the rollup walks the map's own keys and splits the arm back out: a
 two-arm item that sidelined both arms produces TWO entries, one per arm,
 and a single-arm level produces exactly the pre-#2080 list (same entries,
 same order, no `arm` key) because the arm lookups simply miss. The walk
 stays over `activeItems` rather than over the map's own insertion order so
 the list is deterministic — insertion order is parallel-completion order,
 which would reshuffle the rollup run to run.
```

## 3e. Mandatory/routed pre-push review (temperloop#1430)
<a id="3e-mandatory-routed-pre-push-review-temperloop-1430"></a>

```text
 --- 3e. Mandatory/routed pre-push review (temperloop#1430) --------------
 Runs HERE — between 3d and 3e.5, inside this driver — spawning the routed
 reviewer(s) itself via `agent({agentType})`. See build.md §3e's own "why
 this runs inside the workflow, not the orchestrator" paragraph: by the
 time this driver RETURNS to the orchestrator, the item is already pushed
 with its PR open (irreversible), and the orchestrator's post-return
 partition removes the parked item's worktree — the tree a review would
 need to inspect. A loop-back to 3c is only reachable from INSIDE
 driveItem, never after. (This driver does NOT merge: build.md §3h.5's
 as-you-go merge is conversational-path-only — temperloop#1452.)
```

## Carried into the PR body at 3f below (verdictJson.summary) — the PR mu
<a id="carried-into-the-pr-body-at-3f-below-verdictjson-summary-the"></a>

```text
 Carried into the PR body at 3f below (verdictJson.summary) — the PR must
 carry REAL evidence a review ran (or a legible, non-guaranteed skip
 notice), never silently read as if the gate had passed by default.
 `notes` (temperloop#1450) is the reviewer's FULL findings text, rendered
 as its own `## Review notes` section so a non-blocking (MEDIUM/LOW-only)
 pass is still visible to the human reviewer — not computed, checked for
 HIGH, and thrown away. Rendered via reviewBodySuffix (temperloop#1846) —
 the SAME renderer 3g.5's post-CI-fix re-render uses, so the two surfaces
 can never drift; with the single round it renders the pre-#1846 shape
 byte-identically.
```

## SLICE-STABLE SELECTION (temperloop#1663). `QUALITY_GATES_START_AT` is 
<a id="slice-stable-selection-temperloop-1663-quality-gates-start-a"></a>

```text
 SLICE-STABLE SELECTION (temperloop#1663). `QUALITY_GATES_START_AT` is an
 ORDINAL into the gate list, and now that the list can be a SCOPED subset
 re-derived from a live working-tree probe, two slices of one suite could
 resolve DIFFERENT lists — leaving the ordinal pointing at a different gate,
 silently skipping one, and still exiting 0. Before scoping, §3e.5 always
 resolved the static full array, so the ordinal was stable by construction.

 The pin file is the prevention half: slice 0 writes the resolved changed set
 there and every later slice reads it instead of re-probing, so the selection's
 INPUT cannot move mid-suite. It is removed on slice 0 for the same reason the
 log is truncated there — a re-drive must not inherit a previous attempt's
 state.

 The fingerprint is the detection half behind it: each slice reports the
 identity of the list its resume index was measured in, and the next slice is
 handed it back. On a mismatch the gate restarts from 0 on the FULL set and
 says so, rather than resuming an index that no longer means anything.
```

## THE RESUME POINT IS LOAD-BEARING, SO ITS SHAPE IS CHECKED (review roun
<a id="the-resume-point-is-load-bearing-so-its-shape-is-checked-rev"></a>

```text
 THE RESUME POINT IS LOAD-BEARING, SO ITS SHAPE IS CHECKED (review round 1).
 Dropping the old `[ "$__rc" = 75 ]` co-condition removed the only
 cross-check on a value that is matched against the whole slice log, gate
 output included, and then interpolated RAW into JSON by `%s` below. A
 non-numeric or half-written trailer would emit a syntactically invalid
 line, which lands in the executor's "outside the closed set" path instead
 of being classified. Anchoring to digits here is the whole defense: a
 reading that is not a plain integer is treated as ABSENT, exactly as a
 missing trailer already is. (`0` is not a resume point either — the
 trailer is only ever printed with gates REMAINING — and gateSliceResumeAt()
 already drops it downstream.)
```

## AN UNKNOWN ELAPSED IS `null`, NEVER `0` (temperloop#1698). `__el` is a
<a id="an-unknown-elapsed-is-null-never-0-temperloop-1698-el-is-a"></a>

```text
 AN UNKNOWN ELAPSED IS `null`, NEVER `0` (temperloop#1698). `__el` is a
 best-effort sed over the slice log: a vendored gate whose summary line
 this pattern does not match, or a slice killed before printing one,
 leaves it EMPTY. The old `${__el:-0}` turned that straight into a
 confident `"elapsedSecs":0` — a plausible-looking number in place of an
 admission that the figure is unknown, on the one instrument built to make
 suite growth visible. Emitting JSON `null` instead makes the consumer's
 strict read (numOrNull) return null and render `?`.
```

## temperloop#865 — CLASSIFY THE WORKER'S OWN GATE SENTINEL, parent-side.
<a id="temperloop-865-classify-the-worker-s-own-gate-sentinel-paren"></a>

```text
 temperloop#865 — CLASSIFY THE WORKER'S OWN GATE SENTINEL, parent-side.
 The worker is handed a gate invocation that always writes a result
 sentinel (workerGateCmd below); this reads that artifact from the very
 worktree the acceptance gate is about and reports one of four words. It
 is how a worker that BACKGROUNDED its gate and abandoned it becomes
 distinguishable, in the driver's own log and in the gate payload, from a
 worker whose gate was merely slow — the #865 acceptance criterion that a
 re-worded warning cannot meet. Read-only, fail-open: a repo whose workers
 predate the sentinel reports 'absent' and nothing changes.
```

## temperloop#865 — THE LOUD HALF. A worker that backgrounded its gate an
<a id="temperloop-865-the-loud-half-a-worker-that-backgrounded-its-"></a>

```text
 temperloop#865 — THE LOUD HALF. A worker that backgrounded its gate and
 yielded leaves a sentinel still reading `running` (or, if it never issued
 the handed invocation at all, none). Today "waiting for the gate" is
 indistinguishable from a healthy long gate until the budget is gone; this
 is the one place in the run that can tell them apart, because it reads the
 artifact from the same worktree the acceptance gate just ran in. It is a
 NOTICE, never a block: 3e.5 is the acceptance authority and its verdict
 stands on its own, so a stale sentinel must not fail an otherwise-green
 item — it must be impossible to miss.
```

## ======================================================================
<a id="note-5"></a>

```text
 =============================================================================
 driveItemPr — PHASE 2 (temperloop#2080): 3f push + PR → 3g CI → 3g.5 →  3h.
 =============================================================================
 The callable boundary ADR 0038's level barrier needs. Takes the context
 phase 1 produced and returns the item's terminal record. Every line below is
 the pre-split 3f–3h body, re-homed verbatim; the only edit is the
 destructuring header that replaces the closure it used to read from.

 On a dual-build level this is NOT called for an in-scope item's arms — that
 is the barrier. It is called (by driveItem, unchanged) for a not-in-scope
 item, and it is what `level-pick-and-operator-levers` will call for the
 winning arm once the pick is made.
```

## 3f-0a. Rebase onto fresh origin/<default> — the unconditional stale-ba
<a id="3f-0a-rebase-onto-fresh-origin-default-the-unconditional-sta"></a>

```text
 3f-0a. Rebase onto fresh origin/<default> — the unconditional stale-base
 guard (#525). EVERY worker (not just speculative ones) branched off the
 default at the start of its run; on a fast-moving default a long run lets
 the default advance mid-build, so by here the worker's base may be stale
 and a straight push would land a PR whose cumulative diff REVERTS whatever
 merged in between (W49/W52). pr.sh rebase fetches the default fresh and
 replays the worker's commits onto its tip (a no-op when already current).
 On REBASE_CONFLICT it has already `git rebase --abort`ed (worktree left
 clean, NEVER a silent revert) → escalate as a rebase conflict for a human.

 SKIPPED on a recovery whose branch is ALREADY on origin (temperloop#939).
 The rebase rewrites the worker's commits, so the plain (non-force) push
 below would then be a non-fast-forward and come back PUSH_REJECTED —
 converting a clean recovery of already-landed work into a spurious
 escalation, which is the exact class of failure #939 is about. The
 RECOVER_COMMITTED stage has pushed nothing yet, so it still rebases
 normally; so does every non-recovery drive.
```

## temperloop#1430: the §3e review outcome rides the PR body via `summary
<a id="temperloop-1430-the-3e-review-outcome-rides-the-pr-body-via-"></a>

```text
 temperloop#1430: the §3e review outcome rides the PR body via `summary`
 (the one verdict field pr.sh always renders) — this is what lets a real
 review pass (or a genuine, non-guaranteed skip) be OBSERVED on the PR
 itself, rather than living only in this run's transcript.
 The worker's own prose is neutralized for the same reason reviewer prose
 is (see REVIEW_BLOCK_MARK): it is spliced verbatim ABOVE `## Review
 notes`, so an un-neutralized delimiter there would open a phantom first
 block whose span swallowed the `§3e review — ran:` line the cap must
 never cut.
```

## Cross-repo `Closes` qualification (temperloop#852, build.md 3f "Cross-
<a id="cross-repo-closes-qualification-temperloop-852-build-md-3f-c"></a>

```text
 Cross-repo `Closes` qualification (temperloop#852, build.md 3f "Cross-repo
 `repo:` honor point"). `item.repo` (plan-schema.md § Optional `repo:`
 field) names the repo THIS item's PR opens against; it is absent for the
 common same-repo case. `gh_issue:`/`also_closes:` numbers are tracked
 wherever the item was triaged — the plan's HOME repo, i.e. `ownerRepo` —
 NOT necessarily `item.repo` (the kernel-classified-item case is the
 mirror image of the `repo:` case: the PR lands in the kernel repo but the
 issue was triaged, and stays tracked, in the plan's home repo). So a
 cross-repo item (`item.repo` set AND different from `ownerRepo`) must
 emit the fully-qualified `owner/repo#N` form — a bare `Closes #N` is
 same-repo only and would resolve against the wrong repo (or nothing) once
 pushed. pr.sh's `closes_line()`/`validate_issue()` already accept either
 shape verbatim (do not change pr.sh) — the qualification decision belongs
 here, at the one call site that knows both repos. A same-repo item (no
 `repo:`, or `repo:` equal to `ownerRepo`) is unaffected: bare `Closes #N`
 exactly as before.
```

## temperloop#1071 — a pr-batch step that outlived the liveness ceiling. 
<a id="temperloop-1071-a-pr-batch-step-that-outlived-the-liveness-c"></a>

```text
 temperloop#1071 — a pr-batch step that outlived the liveness ceiling. THIS is
 the incident's own shape: the 9h49m call was a `pr-batch` whose steps all in
 fact completed (PR #1070 opened) while the workflow sat waiting. So the
 disposal probes for exactly that — an already-opened PR is ADOPTED and the
 item flows straight on to CI, never re-pushed and never re-opened. Any other
 probe stage escalates. Either way, the rebase/scan/push/pr-open branches
 below are SKIPPED: their step objects were destroyed by the kill, and
 re-deriving them from a truncated batch is how a double-push happens.
```

## 3f-1 branch — the push decision. Before escalating a non-PUSHED,
<a id="3f-1-branch-the-push-decision-before-escalating-a-non-pushed"></a>

```text
 3f-1 branch — the push decision. Before escalating a non-PUSHED,
 non-PUSH_REJECTED outcome, probe for a LOST pr-batch return
 (temperloop#1067): batchStep synthesizes the same 'ERROR'/'produced no
 result' sentinel for both a genuine short-circuit and a dropped last JSON
 line, and by this point rebase+scan are ALREADY confirmed successful (the
 branches above), so a sentinel here specifically means push's own result
 line was lost, not that push never ran. A genuine PUSH_REJECTED (or any
 other real failure) is unaffected — it never reaches isLostReturn().
```

## 3f-2 branch — the PR-open decision. Skipped entirely when the push-bra
<a id="3f-2-branch-the-pr-open-decision-skipped-entirely-when-the-p"></a>

```text
 3f-2 branch — the PR-open decision. Skipped entirely when the push-branch
 recovery above already adopted or opened a PR (`pr` is already set) —
 re-running open against a branch that already has one is exactly the
 duplicate-PR hazard this wiring must never cause.
 EXISTS means the branch already had an open PR (a create-retry after a
 succeeded first attempt). Treat it as PR_OPENED — adopt the existing PR and
 continue to CI-poll/park-with-pr. Any other non-PR_OPENED outcome is
 probed for the same lost-return sentinel (temperloop#1067) before it
 escalates as a genuine pr-open-failed.
```

## 3f→3g SHA hand-off guard (temperloop#2014)
<a id="3f-3g-sha-hand-off-guard-temperloop-2014"></a>

```text
 --- 3f→3g SHA hand-off guard (temperloop#2014) --------------------------
 The ONE choke point every arm above converges on. FOUR paths can set
 `pushedSha` and all four are covered here rather than four times over:
   1. the timeout-ADOPT arm       — `adopted.sha ?? null` (probe.sha; the
      `?? null` makes a probe that landed a PR but resolved no SHA reach
      this guard as an explicit null rather than an `undefined`);
   2. the push lost-return RECOVERY arm      — `rec.pushedSha`;
   3. the pr-open lost-return RECOVERY arm   — `rec.pushedSha ?? pushedSha`;
   4. the plain PUSHED arm        — `pushOut.sha`, unguarded until now: the
      push outcome is transported through an executor agent's structured
      return, so a `sha` key that never makes it back leaves this
      `undefined` while the step still reports success — the temperloop#2014
      reproduction's own path.
 A guard at each assignment would have to be written (and kept) four times
 and would still miss a fifth arm added later; one guard on the value the
 poll actually receives cannot be bypassed by a new arm. The CI-fix re-push
 inside ciPollLoop re-pins `sha` after this point and carries its own copy.
```

## gh pr view returns JSON; if it fails (e.g. auth error) the executor ca
<a id="gh-pr-view-returns-json-if-it-fails-e-g-auth-error-the-execu"></a>

```text
 gh pr view returns JSON; if it fails (e.g. auth error) the executor catches
 non-zero exit and returns whatever gh printed — the caller handles missing fields.

 `tr -d ' \n'` COMPACTS the object onto one line (temperloop#942). gh may
 pretty-print `--json` output, and a batched step's result must be a single
 JSON line for both the executor's line-per-step contract and the `case`
 stop-early glob above (which would miss `"mergeable": "CONFLICTING"` with a
 space). Only `mergeable`/`mergeStateStatus` are requested and both are
 space-free enum values, so stripping spaces cannot corrupt a value.
```

## isBadArgumentError — true iff a ci-poll.sh ERROR is the script REFUSIN
<a id="isbadargumenterror-true-iff-a-ci-poll-sh-error-is-the-script"></a>

```text
 isBadArgumentError — true iff a ci-poll.sh ERROR is the script REFUSING TO
 RUN on its own arguments, rather than a poll that ran and went wrong. The
 primary signal is the structured `usage_error:true` field ci-poll.sh stamps
 on every argument-validation die (its own header documents it alongside
 transient_retries_exhausted / deterministic_failure). The error-text fallback
 covers a vendored or older ci-poll.sh predating that stamp: every one of its
 argument dies renders as `<name> '<value>' invalid — must be …`, or the
 `usage: ci-poll.sh …` line — phrasings no API/transport error shares. Narrow
 on purpose: a genuine CI failure must never be laundered out of `ci-failed`.
```

## temperloop#2065 review round 1 [HIGH]: agent({schema}) THROWS on a
<a id="temperloop-2065-review-round-1-high-agent-schema-throws-on-a"></a>

```text
 temperloop#2065 review round 1 [HIGH]: agent({schema}) THROWS on a
 StructuredOutput-absent / retry-cap-exceeded subagent — the SAME
 primitive callWorker() wraps in try/catch for exactly this reason
 (see that function's own comment). This call used to be bare: an
 uncaught throw here skipped the workerUsageEmit() block below
 entirely (never reaching it) AND propagated past this function
 uncaught, converting to a generic top-level `worker-error`
 escalation whose payload carries no cost field — silently dropping
 not just the retry's own tokens but the item's WHOLE ledger (the
 main worker's already-successful tokens/wall-clock too), since
 driveItem never reaches park(). Catch it here and normalize into the
 SAME "no verdict" shape the null-return arm below already handles,
 so the emit call is never skippable and this always resolves to a
 clean, in-band escalation instead of an uncaught throw.
```

## temperloop#2065 — the retry's own cost, regardless of what fixVerdict
<a id="temperloop-2065-the-retry-s-own-cost-regardless-of-what-fixv"></a>

```text
 temperloop#2065 — the retry's own cost, regardless of what fixVerdict
 turns out to be below (or whether agent() threw above instead): the
 tokens were spent (and the wall-clock burned) the moment agent()
 returned OR threw, and a fix that FAILS — or never returns a verdict
 at all — still cost real money. Tokens roll up into ONE combined
 `retryTokens` figure (the epic's ledger names "retry tokens" as a
 single number, unlike the main worker's split tokens_in/tokens_out —
 see park()); wall-clock rolls into the SAME total `wall_clock_ms` the
 main worker contributes to (driveItem sums it into mainCost at the
 ciPollLoop call site) — there is one wall-clock figure for the whole
 item, not a per-phase one.
```

## Push the fixed SHA and pin the re-poll to it. This is a plain push — n
<a id="push-the-fixed-sha-and-pin-the-re-poll-to-it-this-is-a-plain"></a>

```text
 Push the fixed SHA and pin the re-poll to it. This is a plain push — no
 --force — because the CI-fix worker's head is a fast-forward descendant
 by construction: it resets to the remote tip (`git reset --hard
 FETCH_HEAD`) and commits on top, so the local head strictly descends
 from the current remote tip. A plain push therefore always succeeds on
 the intended path. We deliberately do NOT pass a classifier-visible
 --force here: pr.sh's internal downgrade cannot prevent the git-
 destructive safety classifier from pre-emptively denying the command
 as SPINE_DENIED (#437), which would mask a routine retry as an opaque
 pre-execution denial. If the head is somehow a genuine non-fast-forward,
 the plain push surfaces as a visible PUSH_REJECTED outcome (triaged
 below), not an opaque SPINE_DENIED. (pr.sh's --force→plain downgrade is
 retained for other callers that legitimately rewrite history — #335.)
```

## ERROR or any unexpected outcome (e.g. ci-poll.sh itself errored) →
<a id="error-or-any-unexpected-outcome-e-g-ci-poll-sh-itself-errore"></a>

```text
 ERROR or any unexpected outcome (e.g. ci-poll.sh itself errored) →
 escalate rather than spin.

 temperloop#2014 — but NOT as `ci-failed` when ci-poll.sh refused to run on
 its own arguments. `ci-failed` means "this PR's CI is red", and a run
 disposing on it parks or re-drives a healthy PR; a bad argument means the
 poll never observed CI at all, so it is its own kind with its own
 disposition. The pre-flight above makes this unreachable from the
 driver's own hand-off — this arm catches the argument errors the driver
 does not own (a stale vendored ci-poll.sh, an owner/repo or PR number
 this file passed through from its input).
```

## Every key this file actually READS off an item. This list is not a
<a id="every-key-this-file-actually-reads-off-an-item-this-list-is-"></a>

```text
 Every key this file actually READS off an item. This list is not a
 hand-maintained copy that drifts: the K1700 lockstep guard in
 test_workflow.sh greps THIS file for `item.<key>` dereferences and
 reconciles the resulting set against this array in BOTH directions — a read
 missing from the list, or a listed key nothing reads any more, fails the
 suite. (Round 2: the comment used to claim that guard before it existed,
 which is the same "a backstop that is only asserted in prose" defect this PR
 removes elsewhere. The guard is real now.)
```

## Name the run in the progress row (temperloop#903). Set AFTER the onlyS
<a id="name-the-run-in-the-progress-row-temperloop-903-set-after-th"></a>

```text
 Name the run in the progress row (temperloop#903). Set AFTER the onlySlugs
 filter on purpose: on a continuation the heading must name the slugs actually
 being re-driven, not the level's full membership (whose siblings are already
 parked and untouched). Nothing above this point awaits, so the row is never
 observed unlabelled.

 temperloop#1294: `phaseItems` is the ONE assignment that binds every later
 stage heading to this run's active items — it must land before any agent
 spawns. enterStage() then opens the first stage (claim) and each later stage
 advances the cursor from its own spawn site inside driveItem().
```
