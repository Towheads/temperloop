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

> **Part 1 of 2.** Split to stay under the repo's per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). The other half is
> [`build-level.design-notes-2.md`](build-level.design-notes-2.md).

> **Part 3 of 3.** Split to stay under the repo's per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). Other parts: [`build-level.design-notes.md`](build-level.design-notes.md), [`build-level.design-notes-2.md`](build-level.design-notes-2.md).

## ======================================================================
<a id="note-3"></a>

```text
 =============================================================================
 The ZERO-DISPOSITION guard (temperloop#2004).

 /build Step 3, /fix Step 4a and /sweep Phase 2 all branch on the returned
 {parked, escalations}: each handles `parked` non-empty and `escalations`
 non-empty, and NONE had an arm for both being empty. A {parked:[],
 escalations:[]} return therefore matched no branch and fell through as "the
 level completed with nothing to report" — so an item that was asked for and
 disposed of nowhere vanished with no PR, no park, no escalation and no
 signal. (Observed 2026-09-13, run wf_f3b9c160-6ca: a stopped-and-resumed run
 returned an empty object in ~13 ms having re-run nothing, while the tracked
 issue was still in-progress with a live claim stamp.)

 The guard lives HERE, below the three drivers, so all three inherit it once
 rather than each restating it — the same hoist shape temperloop#2006 used
 for the sideline notice. It returns a NAMED, branchable value (never a bare
 throw): the drivers re-probe real state on it instead of concluding
 anything.

 The two CONTROLS are what make it discriminating rather than noisy — a guard
 that flags every legitimately empty level is worse than none:
   1. nothing was asked to drive (empty `items`, or an onlySlugs filter that
      matched no item) → disposing of nothing is a tautology, not a
      contradiction. Silent, and the returned object is byte-identical to
      before this item.
   2. something WAS disposed → any parked record or any escalation means the
      drive reported on the set. This is also what clears the kind:spike
      path: a spike opens no PR and pushes no SHA, but it still `park()`s a
      verdict marker (`park(slug, null, null, …)`), so a spike-only level
      lands in control 2 and is never flagged.
 Returns null when either control holds; otherwise the named outcome.
 =============================================================================
```

## Drive every active item through 3a–3h. The items in one level are
<a id="drive-every-active-item-through-3a-3h-the-items-in-one-level"></a>

```text
 Drive every active item through 3a–3h. The items in one level are
 independent by construction (no merge edge between them), so we fan them
 out with parallel() — the substrate caps concurrency (~cores-2). This
 matches build.md's "express each item's pipeline as a parallel() over
 the level's items" (within-level execution). parallel() returns the array
 of per-item results in item order; a blocked/failed item escalates rather
 than halting its siblings (the orchestrator batches escalations at the
 boundary). On a continuation run only the named slugs enter parallel(); the
 rest are already parked and are left untouched.
 A thrown exception in driveItem must NOT vanish: parallel() drops a rejected
 thunk to null, which would leave the item in NEITHER parked NOR escalations —
 silently lost, violating the no-silent-stall invariant. Convert any throw into
 a generic `worker-error` escalation so it always surfaces. (#437: a real run
 hit item.acceptance.map on a string and the item was silently dropped.)
 temperloop#2020: `.then(preserveOnEscalation)` is applied to the SETTLED
 result — after the #437/#1819 catch above, so a THROWN item's synthesized
 escalation gets the same work-preservation push a returned one does. This
 is the single choke point for "an escalation is about to leave this
 driver"; see preserveOnEscalation's own comment for why it lives here and
 not at the ~30 individual escalate() call sites.

 temperloop#2080 — the DUAL-BUILD fan-out is an alternative to this one, not
 a flag inside it. A `dualBuild` input restructures the level into build →
 barrier → judge → record (driveLevelDualBuild), which is a different
 control flow, not a different parameter; keeping the two apart is what
 makes "no dualBuild input → this exact fan-out, unchanged" true by reading
 the code rather than by tracing a branch through it.
```

## machineryBin — resolve a build-SPINE script (worktree.sh / pr.sh / ci-
<a id="machinerybin-resolve-a-build-spine-script-worktree-sh-pr-sh-"></a>

```text
 machineryBin — resolve a build-SPINE script (worktree.sh / pr.sh / ci-poll.sh),
 which lives in the FOUNDATION repo (workflows/scripts/build/). A consuming repo
 (stageFind) normally reaches it via a dev-local `workflows/` symlink into
 foundation — but that symlink is NOT guaranteed in every checkout (#560: a
 stageFind checkout lacking it escalated at pr.sh with `push-error: script path
 does not exist`). We run in the Workflow sandbox (no fs / Node API), so the
 fallback is done in BASH, emitted as a quoted command-substitution: prefer
 <repoRoot>/workflows/scripts/build; if that dir is absent, locate the
 foundation checkout via $FOUNDATION, the deployed workflow symlink
 ($HOME/.claude/workflows/build-level.mjs → foundation, best-effort — a BSD
 readlink without -f just fails that candidate), or the TEMPERLOOP_HOME
 bootstrap-clone convention (bin/bootstrap.sh's own default,
 $HOME/.local/share/temperloop — never a hardcoded personal dev path,
 temperloop#406; the legacy FOUNDATION_HOME fallback was removed in
 v0.19.0 with the rest of the temperloop#165 window). If none resolve, the
 emitted path points at the missing
 repo-local dir and the machinery script's own "not found" (exit 127) surfaces
 loudly. NOTE:
 only machinery scripts route through here; the project's OWN vendored gate
 (scripts/quality-gates.sh) is repo-local and is resolved directly against
 the WORKTREE checkout (see 3e.5, temperloop#626), never via this fallback.
```

## ONE MEANING, ONE NAME — the machinery-outcome key canonicalizer (tempe
<a id="one-meaning-one-name-the-machinery-outcome-key-canonicalizer"></a>

```text
 -----------------------------------------------------------------------------
 ONE MEANING, ONE NAME — the machinery-outcome key canonicalizer (temperloop#1698).
 -----------------------------------------------------------------------------
 The closed outcome set carries TWO names for one concept. The step-liveness
 bound (temperloop#1071) emits `elapsed_secs` / `ceiling_secs` / `slow_secs`;
 the 3e.5 gate emits `elapsedSecs` / `budgetSecs`; and the permissive
 passthrough schema admits BOTH on ANY outcome. An executor that normalizes a
 GATE_PASS toward the sibling spelling therefore produces a structurally VALID
 object that the consumer — `Number(gateOut.elapsedSecs) || 0` — reads as
 `Number(undefined) || 0` → **0**. Observed live (run wf_9ce4bd0c-58b): a gate
 whose own log said "passed in 215s" was reported as "0s of gate wall time".

 That figure is the DECAY SIGNAL — the instrument whose whole job is to make
 suite growth visible on GREEN runs, before it blows a budget (the failure
 #1021 and #1663 both exist because of). An instrument that reads zero when it
 does not know is worse than one that reads nothing.

 The fix is a single normalization at the TRANSPORT boundary rather than a
 `??` chain at each read site (which re-opens the defect for the next field):
 CANONICAL = camelCase, everywhere downstream of here. The snake_case key is
 left in place on the object — it is what the emitted shell actually prints and
 what escalation payloads echo verbatim — but no CONSUMER in this file reads it
 any more, so the two spellings can no longer disagree about one value.
```

## runMachineryBatch — the BATCHED sh() replacement (temperloop#942).
<a id="runmachinerybatch-the-batched-sh-replacement-temperloop-942"></a>

```text
 -----------------------------------------------------------------------------
 runMachineryBatch — the BATCHED sh() replacement (temperloop#942).
 -----------------------------------------------------------------------------
 Runs SEVERAL machinery commands inside ONE executor agent (one Bash
 invocation), returning each step's own closed-outcome JSON object so the
 driver keeps branching per-step in .mjs. See DESIGN NOTE 1 for why this does
 not weaken the bridge's invariant.

 A step is { kind, cmd, continueOutcomes?, stopGlobs? }:
   kind             — a short name; it appears in the prompt's `Steps:` manifest
                      and in a denial payload, and is what the .mjs indexes by.
   cmd              — the fully sq()-quoted command text, byte-identical to what
                      the un-batched runMachinery call used to send.
   continueOutcomes — the outcome(s) that permit the NEXT step to run. Anything
                      else stops the sequence (the .mjs then branches on this
                      step's object and escalates, exactly as before).
   stopGlobs        — the inverse form, for a step with no `outcome` key (the
                      merge-state probe): raw substrings that, if present, stop
                      the sequence.
 The last step needs neither — nothing follows it.

 The bash short-circuit is a STOP-EARLY MIRROR, not the decision: it only
 avoids running steps whose result the .mjs is about to discard anyway. The
 authoritative branch is always the `if` in .mjs reading the same JSON.
```

## gateRegistrationChecklistSection — the §3c "new gate script? register 
<a id="gateregistrationchecklistsection-the-3c-new-gate-script-regi"></a>

```text
 gateRegistrationChecklistSection — the §3c "new gate script? register it"
 checklist (temperloop#1931), a SELF-CONTAINED section appended once into
 workerPrompt()'s array, mirroring discriminationEvidenceSection()'s shape.
 UNGATED, like hostConfigDeferralSection() — every /build, /sweep and /fix
 worker can add a new check-*.sh/validate-*.sh/test_*.sh, so every worker
 needs the checklist, not just an opted-in caller.

 WHY THIS EXISTS: #1931's observed instance — three of five workers in one
 /build level shipped a new validator/test that went RED on
 validate-check-surface-degenerate-coverage.sh (and its test), and two also
 missed gate-paths.tsv/setting-registry.tsv rows, because the worker's own
 `--scoped` run (temperloop#957) selects gates by DIFF PATH: a brand-new
 script's path matched no row in gate-paths.tsv until the worker itself
 registered one, so the very gates that would have caught the omission
 never ran worker-side — each miss cost a full parent-side sliced
 acceptance-gate round trip (about 10-20 minutes). gate-paths.tsv now also
 carries generic new-surface globs closing the SELECTION half of that gap
 (see its own header, temperloop#1931) — this section is the PREVENTION
 half: naming the registries up front so the worker registers before its
 own scoped run ever needs to catch the omission after the fact.
```

## activationProofSection — the temperloop#1934 "show the worker its own
<a id="activationproofsection-the-temperloop-1934-show-the-worker-i"></a>

```text
 activationProofSection — the temperloop#1934 "show the worker its own
 class-A activation predicate" section, a SELF-CONTAINED section appended
 once into workerPrompt()'s array, mirroring gateRegistrationChecklistSection()'s
 shape so a sibling edit to workerPrompt() rebases cleanly. Gated on
 activationClass(item) === 'A' (defined below — hoisted, so the forward
 reference from here is fine): an absent `activation` block, or a class
 B/C block, renders NOTHING, so this section changes zero bytes of the
 prompt for those items (the acceptance's byte-identical requirement).

 WHY THIS EXISTS: the live instance (epic #1910, item join-key-registry) —
 the worker built and wired `join-keys-lib.sh`, but the plan's `proof:`
 predicate grepped for the producer-chosen literal `join_keys`, a name the
 worker never saw and had no reason to preserve. The worker's own
 acceptance bullets all passed; §3e.6 then failed the whole item on a name
 mismatch the worker was never shown, costing a full re-drive round trip.
 Rendering the `proof:` command VERBATIM — not a paraphrase of what it
 checks — lets the worker see the exact reachability surface the
 orchestrator will run and either name its own artifacts to match, or, if
 the predicate genuinely conflicts with the acceptance bullets, say so
 (`blocked`) instead of guessing a silent rename that may or may not agree
 with what §3e.6 actually runs.
```

## §3c "No long-running background work" (#1219). Embedded in the generat
<a id="3c-no-long-running-background-work-1219-embedded-in-the-gene"></a>

```text
 §3c "No long-running background work" (#1219). Embedded in the generated
 prompt — NOT left to prose the caller may forget — so every worker (main
 AND spike, both route through workerPrompt) is told up front to foreground
 the gate. Without this the worker backgrounds quality-gates.sh, yields, and
 returns no verdict (build.md §3c/§3d must stay in lockstep with this block).

 temperloop#997 adds the SCOPE half of the same contract: the worker must not
 run the BARE, repo-wide suite in its own context at all. That run is minutes-
 scale, and one blocking turn that long blows the ~5-min prompt-cache TTL — the
 worker's whole ~213K-token context is then re-WRITTEN (weight 1.25) instead of
 re-READ (0.1) on the next call. The ACCEPTANCE run stays parent-side at 3e.5
 (unchanged, still the authority — the PR #309 silent-red lesson; since
 temperloop#1663 that run is itself diff-scoped through the same map, which
 changes WHICH gates it runs but not WHO decides acceptance). The two
 halves live in ONE section on purpose: foreground-only governs HOW the worker
 runs its checks, #997 governs WHICH checks it runs, and dropping either one
 re-opens a measured defect. build.md §3c carries both in lockstep.
```

## Lost-return recovery (temperloop#939).
<a id="lost-return-recovery-temperloop-939"></a>

```text
 -----------------------------------------------------------------------------
 Lost-return recovery (temperloop#939).
 -----------------------------------------------------------------------------
 The 3c worker can die in TWO different ways that look identical from here:
   (a) it genuinely failed — nothing was built, and escalating is correct;
   (b) it did the whole job and only the RETURN CHANNEL failed — the subagent
       completed without calling StructuredOutput, or blew the StructuredOutput
       retry cap, so `agent({schema})` THROWS (it does not return null).
 Case (b) is not hypothetical: in the #939 run it hit 2 of 5 workers. One had
 committed, pushed, opened PR #936 and gone green; the other had committed but
 not pushed. Both were reported as `worker-error` — a `ask-now` halt over work
 that had already landed, with a live risk of re-spawning a worker onto a
 worktree that already held the finished commit (a second PR, a stacked commit).

 The fix is to STOP GUESSING from the exception and go LOOK: probe the
 observable side-effects (commit / push / PR) before classifying. What we can
 never recover is the worker's own self-verification — so a recovered record is
 honest about that and marks its acceptance results UNVERIFIED rather than
 letting them read as passing.
```

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
