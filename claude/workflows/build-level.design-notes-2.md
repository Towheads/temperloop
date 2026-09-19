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

> **Part 2 of 4.** Split to stay under the repo's per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). Other parts: [`build-level.design-notes.md`](build-level.design-notes.md), [`build-level.design-notes-3.md`](build-level.design-notes-3.md), [`build-level.design-notes-4.md`](build-level.design-notes-4.md).

## temperloop#2065 "worker-cost-capture" — the per-item WORKER COST
<a id="temperloop-2065-worker-cost-capture-the-per-item-worker-cost"></a>

```text
 temperloop#2065 "worker-cost-capture" — the per-item WORKER COST
 seam. Neither comes from a machinery script proper; both are
 workflows/scripts/build/worker-usage.sh, the SAME emitted-shell
 pattern review-wait.sh established for giving this runtime a
 wall-clock tick it otherwise has none of. WORKER_CLOCK is a bare
 `date` read (no side effect); WORKER_USAGE is that same reading
 PLUS the durable per-seat attribution write (model-usage-
 envelope.sh's model_usage_emit_from_envelope, seat "build-worker" —
 see that file's own header). See workerClockNow()/workerUsageEmit().
```

## `'null'` IS LOAD-BEARING HERE, not defensive padding (temperloop#1698,
<a id="null-is-load-bearing-here-not-defensive-padding-temperloop-1"></a>

```text
 `'null'` IS LOAD-BEARING HERE, not defensive padding (temperloop#1698,
 review round 2). The gate emitter below deliberately prints a bareword
 `null` when the elapsed figure is unreadable — that IS the fix: an
 unknown duration must degrade to "I don't know", never to a plausible
 `0`. This object is what `agent({schema})` validates the executor's
 returned line against, so leaving `null` out of the type array would
 reject (or silently coerce) the ONE shape the fix exists to produce —
 reintroducing the same degrade-to-a-believable-value defect one layer
 up, on the path that only fires when the figure is already unknown.
 Same precedent as `input_tokens` / `output_tokens` above, declared
 `['number', 'null']` for exactly this reason. Kept honest by the K1698
 producer↔schema case in test_workflow.sh, which runs the REAL emitted
 shell fragment and validates the REAL line it prints against THIS object
 rather than against an injected outcome object.
```

## temperloop#1698 — these three are the NON-canonical (wire) spelling: t
<a id="temperloop-1698-these-three-are-the-non-canonical-wire-spell"></a>

```text
 temperloop#1698 — these three are the NON-canonical (wire) spelling: the
 emitted `__lb` shell prints them, so the schema must keep admitting them
 or the bound's own STEP_TIMEOUT would fail validation. They are
 canonicalized to `ceilingSecs` / `elapsedSecs` / `slowSecs` by
 canonicalizeOutcome() at the transport boundary, and NO consumer in this
 file reads a snake_case duration key any more. The camelCase twins are
 declared alongside so an emitter that already speaks canonical (the 3e.5
 gate does, for `elapsedSecs`/`budgetSecs` above) validates unchanged.
```

## STEP_OUTCOME_SCHEMA — one element of a BATCH's results array (temperlo
<a id="step-outcome-schema-one-element-of-a-batch-s-results-array-t"></a>

```text
 STEP_OUTCOME_SCHEMA — one element of a BATCH's results array (temperloop#942).
 Same permissive shape as SPINE_OUTCOME_SCHEMA (whose `properties` it reuses
 verbatim — #543's "do NOT touch SPINE_OUTCOME_SCHEMA" still holds; this derives
 from it, it does not mutate it) with two differences:
   - `outcome` is NOT required, because one batched step is the read-only
     merge-state probe (`gh pr view --json mergeable,mergeStateStatus`), whose
     object carries no `outcome` key at all. When `outcome` IS present the
     closed enum still applies.
   - the merge-state fields are declared so the .mjs can branch on them.
```

## WORKER_VERDICT_SCHEMA — matches build.md §3c's return contract. The
<a id="worker-verdict-schema-matches-build-md-3c-s-return-contract-"></a>

```text
 WORKER_VERDICT_SCHEMA — matches build.md §3c's return contract. The
 worker owns only these fields (never branch/pr/pushed_sha — orchestrator-
 owned). `status` is a closed enum, 1:1 with the 3d handling branches.

 Output shape (temperloop#1080): the `description` on each free-prose field
 states what that field is FOR, so the shape rule reaches the worker on the
 schema surface too, not only in the prompt. Deliberately NO word numbers
 here — a JSON schema cannot enforce a string length, so the numeric bounds
 live in exactly one place (the WORKER_*_MAX_WORDS constants, interpolated
 into the prompt's `## Output shape` section) rather than being restated in a
 second surface that could drift. The two surfaces are complementary: the
 schema fixes the SHAPE (machine-validated), the prompt fixes the SIZE.
```

## Kill ORDER is load-bearing, and the obvious order is wrong. Killing th
<a id="kill-order-is-load-bearing-and-the-obvious-order-is-wrong-ki"></a>

```text
 Kill ORDER is load-bearing, and the obvious order is wrong. Killing the
 step's children FIRST unblocks the step body — which then races ahead and
 runs its NEXT command (printing a result the workflow must not believe)
 before the kill of the body itself lands. Measured, not theorised: with
 children-first, a `sleep 30; printf …` step still printed its `printf`.
 So: SNAPSHOT the direct children, kill the body, THEN kill the snapshot
 (once the body dies its children reparent, and `pgrep -P` can no longer
 find them — hence the snapshot rather than a second lookup).
```

## runMachinery — the sh() replacement (spike §1).
<a id="runmachinery-the-sh-replacement-spike-1"></a>

```text
 -----------------------------------------------------------------------------
 runMachinery — the sh() replacement (spike §1).
 -----------------------------------------------------------------------------
 Spawns a one-shot executor agent that runs EXACTLY one machinery command via Bash
 and returns its single closed-outcome JSON line, schema-validated. No model
 override beyond haiku (cheapest tier — the executor does no reasoning); NO
 isolation:'worktree' (the machinery scripts manage their own worktrees, §5).
 `phase` (temperloop#1294) is the caller's STAGE group name — the string
 enterStage()/stagePhase() returned. It is passed EXPLICITLY rather than read
 off the global phase() cursor, which races under parallel(). The `?? 'machinery'`
 fallback keeps a caller that omits it on the pre-#1294 flat group rather than
 on whatever stage happens to be current.
```

## Wording (temperloop#72): describe the command as a KNOWN build-machine
<a id="wording-temperloop-72-describe-the-command-as-a-known-build-"></a>

```text
 Wording (temperloop#72): describe the command as a KNOWN build-machinery helper
 script that self-reports its result, rather than telling the sub-agent to
 "run exactly / do NOT interpret" an opaque line. The old phrasing, paired
 with the nested-readlink path resolution, read to the auto-mode safety
 classifier as an instruction to blindly execute an obfuscated command.
 BOTH framing lines stay in the LEAN prompt too: the auto-mode classifier
 sees the prompt (and the agent type), never the agent's system prompt, so
 the #72 framing is not something the executor definition can absorb.
```

## temperloop#1021: name the TIMEOUT case explicitly. NOT lean-guarded, a
<a id="temperloop-1021-name-the-timeout-case-explicitly-not-lean-gu"></a>

```text
 temperloop#1021: name the TIMEOUT case explicitly. NOT lean-guarded, and
 deliberately so: unlike the three standing lines above, this one is
 per-call (it fires only when a caller passes `timeoutOutcome`) and it
 interpolates a dynamic outcome name, so it cannot live in the static
 machinery-executor.md agent definition the lean prompt relies on.
 Without this line the executor, having been killed by the Bash tool
 before any JSON line was
 printed, picks the closest failure-shaped enum member it knows — which
 for the gate is GATE_FAIL. That silently reported a GREEN suite as
 BROKEN and made a budget-exhaustion escalation indistinguishable from a
 real gate failure. The timeout is a fact about the BUDGET, never about
 the tree, so it gets its own outcome and the executor is told to use it
 rather than guess.
```

## temperloop#982: orchestrator-supplied workflow input, NOT a config-fil
<a id="temperloop-982-orchestrator-supplied-workflow-input-not-a-co"></a>

```text
 temperloop#982: orchestrator-supplied workflow input, NOT a config-file
 read (this runtime has no shell — DESIGN NOTE 1). `||`, NOT `??` —
 `??` only falls through on null/undefined, and a caller (or an
 omitted-vs-empty prose mistake upstream) can easily hand this an
 empty string, which `??` would pass straight through as a literal
 "" model and silently defeat the fallback. `||` collapses BOTH the
 absent-input case (build.md didn't resolve BUILD_MACHINERY_SOLO_MODEL,
 or the key was omitted) AND an empty-string input to the same
 'haiku' default — UNCHANGED from before this setting existed, the
 byte-identical-when-unset contract this item ships under. This is the
 load-bearing invariant; it lives here (the consumer), not in the
 orchestrator prose (the producer), so it holds regardless of how
 build.md/sweep.md/fix.md construct the input.
```

## Null-guard (temperloop#72): agent() returns null when the run is DENIE
<a id="null-guard-temperloop-72-agent-returns-null-when-the-run-is-"></a>

```text
 Null-guard (temperloop#72): agent() returns null when the run is DENIED by
 the auto-mode safety classifier (or a user skip / transient API error).
 Every consumer below dereferences `.outcome`, so a raw null crashed the
 whole level with `null is not an object`. Normalize it to a closed
 SPINE_DENIED sentinel — a well-formed outcome object every call site can
 detect (via machineryDenied()) and turn into a parkable `machinery-denied`
 escalation instead of a TypeError.
 temperloop#1698 — canonicalize the duration keys ONCE, here at the
 transport boundary, so every consumer below reads exactly one spelling.
```

## temperloop#1071 — PARTITION the advisory notices out of the results ar
<a id="temperloop-1071-partition-the-advisory-notices-out-of-the-re"></a>

```text
 temperloop#1071 — PARTITION the advisory notices out of the results array
 BEFORE anyone indexes it. A STEP_SLOW line is emitted alongside a real
 result, not in place of one, so leaving it in would shift every later step's
 index by one and silently mis-branch the whole batch. Filtering here (once,
 at the transport) is what lets every `batchStep(batch, i)` call site below
 stay exactly as it was.
 temperloop#1698 — canonicalize every step's duration keys at this same
 transport boundary (the batch twin of runMachinery's call above), BEFORE
 the partition below and before any `batchStep(batch, i)` consumer.
```

## discriminationEvidenceSection — the §3c "test-discrimination evidence"
<a id="discriminationevidencesection-the-3c-test-discrimination-evi"></a>

```text
 discriminationEvidenceSection — the §3c "test-discrimination evidence"
 requirement (temperloop#1319), a SELF-CONTAINED section appended once into
 workerPrompt()'s array, mirroring principlesSection()'s shape so a sibling
 edit to workerPrompt() rebases cleanly. Gated on REQUIRE_DISCRIMINATION_
 EVIDENCE (see that constant's own comment above for the full rationale,
 including the correction on why /sweep and /fix are excluded — an
 operational scope decision, not a structural one) — returns an EMPTY
 array, not a degraded/notice variant, when the caller didn't ask for it:
 unlike principlesSummaries' "never silence" rule, an unrequired discipline
 staying silent is correct here, since REQUIRE_DISCRIMINATION_EVIDENCE is
 false for any caller that never armed the requirement in the first place.
```

## parentSummarySection — the epic #1847 Produces #7 companion: injects t
<a id="parentsummarysection-the-epic-1847-produces-7-companion-inje"></a>

```text
 parentSummarySection — the epic #1847 Produces #7 companion: injects the
 parent epic's own "group summary" into an admitted epic member's worker
 prompt, a SELF-CONTAINED section appended once into workerPrompt()'s
 array, mirroring changelogFragmentSection()'s shape so a sibling edit to
 workerPrompt() rebases cleanly. Gated on `item.parentSummary` — set ONLY
 by /sweep's Step 3 items[] construction for a member it admitted via Step
 1 item 6 (Operational-epic member admission); a plain singleton, and every
 /build plan item, never carries the field, so this returns an empty array
 and the section is silently absent. Unlike principlesSection()'s DEGRADED
 notice, there is no "missing" case to flag here: an item with no parent
 epic genuinely has no group summary to inject, so silence is correct, not
 a degradation.
```

## #1072 — the near-miss this institutionalizes: a build worker (temperlo
<a id="1072-the-near-miss-this-institutionalizes-a-build-worker-tem"></a>

```text
 #1072 — the near-miss this institutionalizes: a build worker (temperloop#635)
 spawned a context-inheriting fork for a narrow read-only sub-task; the fork
 INHERITED the "drive to done and commit" mission, fabricated a completion
 report, and committed to the shared worktree (self-recovered — see
 Mistakes/foundation - research fork inherits drive-to-done context and
 commits to shared worktree). Embedded here, structurally, rather than left
 to a vault note someone has to remember to re-paste — mirrors how the
 foreground-only contract below is embedded rather than left to prose alone.
```

## ## Output shape (temperloop#1080) — the SIZE half of the return contra
<a id="output-shape-temperloop-1080-the-size-half-of-the-return-con"></a>

```text
 ## Output shape (temperloop#1080) — the SIZE half of the return contract.
 The schema below fixes the shape; nothing fixed the length, and measured
 across 83 real worker verdicts the two prose slots ran 2-4x past what the
 spec asked for. Stated as an explicit bound here — the one surface the
 worker actually reads — with the routing rule that makes the bound safe:
 detail goes to the verification-surface FILE, which reaches the PR body
 without entering orchestrator context. build.md §3c carries the same
 contract; the two must stay in lockstep (static guard in test_workflow.sh).
```

## temperloop#2065 review round 2 [HIGH]: workerClockNow()/workerUsageEmi
<a id="temperloop-2065-review-round-2-high-workerclocknow-workerusa"></a>

```text
 temperloop#2065 review round 2 [HIGH]: workerClockNow()/workerUsageEmit()
 both bottom out in runMachinery() -> machineryAgent(), which explicitly
 re-throws (does not degrade) an unresolvable-agentType / StructuredOutput-
 absent / retry-cap-exceeded executor spawn — the exact throw shape
 callWorker()'s own agent({schema}) call is documented as capable of, two
 blocks below. The block comment above these two functions promises they
 are FAIL-OPEN and "never a thrown error" — that promise covers only a
 malformed VALUE in a successful response (numOrNull()'s job); it does not
 cover the underlying machinery spawn itself throwing. These two guards are
 what backs the promise with code: every call site below goes through one
 of these instead of calling workerClockNow()/workerUsageEmit() bare, so a
 cost-ledger bookkeeping failure can never abort the item build it is only
 supposed to be measuring.
```

## callWorker — spawn the implementation worker so a lost return channel 
<a id="callworker-spawn-the-implementation-worker-so-a-lost-return-"></a>

```text
 callWorker — spawn the implementation worker so a lost return channel can
 never escape as a throw. agent({schema}) THROWS on a StructuredOutput-absent
 / retry-cap-exceeded subagent and returns null on a skip / terminal API error;
 both are the same thing to the caller ("no verdict"), and neither is evidence
 about the work. Normalize both into { verdict, error } so driveItem decides
 what they MEAN only after the side-effect probe has run.
 `phaseName` (temperloop#1294) — the STAGE group this worker belongs to,
 passed explicitly (the global phase() cursor races under parallel()).

 temperloop#2065 — every call also brackets the worker in the clock/usage
 seam above and returns its reading as { wallClockMs, tokensIn, tokensOut },
 on BOTH the return and the throw arm: a re-spawned worker that itself
 blows its return channel still spent real tokens, and the ledger records
 that spend rather than silently dropping it.
```

## temperloop#982: item.model || undefined, NOT bare item.model — an
<a id="temperloop-982-item-model-undefined-not-bare-item-model-an"></a>

```text
 temperloop#982: item.model || undefined, NOT bare item.model — an
 empty-string item.model (e.g. an orchestrator that resolved
 SWEEP_WORKER_MODEL/FIX_WORKER_MODEL to "" and passed it through
 unfiltered) must collapse to undefined here, the sentinel the agent()
 hook reads as "inherit session model" — a bare "" would instead be
 sent as a literal (invalid) model name. undefined/absent item.model
 already coerces to undefined via `||`, so this is a strict
 widening (covers "" too), never a behavior change for the existing
 undefined case.
```

## isVerdictUnparseable — the pr-open outcome temperloop#1805 is about: p
<a id="isverdictunparseable-the-pr-open-outcome-temperloop-1805-is-"></a>

```text
 isVerdictUnparseable — the pr-open outcome temperloop#1805 is about: pr.sh's
 own `die` when the verdict file it was handed is not usable JSON. It is
 deliberately NARROW — three literal messages pr.sh emits about the VERDICT
 (`open`'s `jq -e .` guard, and assemble_body's two field checks) — because the
 tolerance path below re-issues the PR-open command, and a blind re-issue of a
 non-idempotent machinery step on any broader class is exactly the double-open
 hazard the rest of this file is built to avoid. Anything else — a `gh` failure,
 a push race, a missing surface file — keeps the unchanged escalation.
```

## recoverLostReturn — the 3f push/pr-open twin of disposeStepTimeout's p
<a id="recoverlostreturn-the-3f-push-pr-open-twin-of-disposesteptim"></a>

```text
 recoverLostReturn — the 3f push/pr-open twin of disposeStepTimeout's probe,
 for the NON-timeout case: a pr-batch step's own JSON line was dropped (lost
 pr-batch return) with every step before it in the SAME batch already
 confirmed successful (the caller only reaches this after its own
 rebase/scan/push branches above already passed) — temperloop#1067, distinct
 from #1071's liveness-kill. Reuses the EXISTING probeSideEffects/RECOVER_*
 ladder — no second probe, no new machinery. Returns one of:
   { kind: 'adopted', pr, pushedSha }   — landed; caller skips re-push/re-open
   { kind: 'escalate', escKind, payload } — a resume attempt itself failed
   { kind: 'none' }                      — RECOVER_NONE/RECOVER_DIRTY/unusable
                                            probe; caller does its UNCHANGED
                                            escalation exactly as before this
                                            wiring existed.
```

## RELAY ONLY THE DATA ROWS (temperloop#1982 round 3). The field crosses 
<a id="relay-only-the-data-rows-temperloop-1982-round-3-the-field-c"></a>

```text
 RELAY ONLY THE DATA ROWS (temperloop#1982 round 3). The field crosses a
 machinery-executor agent, which is specified to return the command's JSON
 line verbatim and has instead been observed omitting this one field
 outright, and once replacing it with an English sentence describing the
 table ("The reviewer-routing.tsv file contains 11 data rows routing files
 to review subagents…"). Rounds 1 and 2 added receiving-end checks — a row
 count, then a position-weighted checksum — which detect the substitution
 but cannot prevent it: no check on this side stops a model on the other
 side from paraphrasing. What CAN be reduced is the bait. The raw file is
 3,834 bytes of which 699 are data (11 rows); the other 82% is comment
 prose, i.e. the executor was being handed ~4KB of mostly-English text and
 asked to echo it. Sending `rowFilterAwk`'s output instead ships only the
 rows the routing decision actually reads.

 Invariant-neutral by construction, which is why this needs no JS or test
 change: BOTH receiving-end readers already apply this same filter before
 they compute anything — parseTsvRows() drops blank/`#` lines, and
 tsvChecksum() canonicalises with the identical trimmed-emptiness rule —
 so filtering here is idempotent and every gap check yields the same value
 it did on the unfiltered text. The filter itself is `rowFilterAwk`, the
 SAME expression the checksum below already uses, so this adds no second
 implementation of the row rule to drift against.

 MITIGATION, NOT A PROOF: a model can still paraphrase 699 bytes. The
 structural fix — keeping the table out of the relay entirely, or emitting
 parsed rows the executor has no prose reading of — stayed open on #1982
 and is closed HERE (temperloop#2020, second half): the field is no longer
 a `tsv` SCALAR holding a multi-line table, it is `tsv_lines`, a JSON
 ARRAY OF ROW STRINGS built by the SAME
 `jq -R -s -c 'split("\n") | map(select(length>0))'` idiom `files_json`
 above already uses. The shape is chosen on evidence, not taste: across
 every observed mangling (#1976 wf_cbc556f5-7be; #1982's three shapes;
 #2020's own foundation#1869 reproduction, where BOTH retry agents
 dropped it identically) `files` — a jq array of strings produced by this
 exact idiom — arrived INTACT in the same JSON line whose `tsv` blob was
 dropped, paraphrased, or double-encoded. An array of short opaque row
 strings offers no English reading to paraphrase into and no "quote the
 table" framing to re-encode; a ~700-byte tab-delimited blob offers both.

 Invariant-neutral for the SECOND time by construction: the array's rows
 joined on `\n` are byte-identical to the string this used to emit (see
 reviewDiffTsvText), so `tsv_rows`, `tsv_checksum`, parseTsvRows() and
 tsvChecksum() all yield exactly the values they did before — the
 #1976/#1982 gap checks are untouched DETECTORS, not weakened ones.
 `tsv` itself is no longer emitted; the reader still ACCEPTS it
 (reviewDiffTsvText) so a relay or caller that yields the legacy scalar
 keeps routing rather than degrading.
```

## tsvChecksum — temperloop#1982, made POSITION-SENSITIVE in round 2: a
<a id="tsvchecksum-temperloop-1982-made-position-sensitive-in-round"></a>

```text
 tsvChecksum — temperloop#1982, made POSITION-SENSITIVE in round 2: a
 pure-arithmetic content checksum over the SAME row-count-filtered lines
 parseTsvRows()'s first stage keeps (blank and `#`-comment lines stripped),
 so a corrupted comment header (which carries this repo's own non-ASCII
 punctuation, e.g. em dashes) never enters the sum and cannot desync the
 two independent implementations of this algorithm — this one, and
 reviewDiffCmd's bash pipeline (`od`-computed byte values, weighted and
 summed in awk).

 WHY POSITION-WEIGHTED, NOT A BARE SUM (round 1's shape): a bare sum of
 character codes is COMMUTATIVE — invariant under any rearrangement of the
 same characters. The round-2 reviewer reproduced this against this repo's
 OWN tracked reviewer-routing.tsv: swapping the reviewer+path columns
 between the `.sh` row and the `docs/**` row (same row count, same overall
 character multiset — a plausible hand-copy slip, and the exact shape of
 the temperloop#1978 round-4 incident: a .sh diff silently routed to
 docs-reviewer) left the bare-sum checksum byte-IDENTICAL. Multiplying each
 character's code by its 1-based position in the canonicalized stream
 before summing breaks that: the SAME characters at DIFFERENT offsets sum
 to a different total (verified against this repo's live tsv — see
 test_workflow.sh's "K1982 position-sensitive: transposed columns" case).
 This is still an INTEGRITY check against relay noise, not a cryptographic
 one — collisions are not the concern, only whether the `tsv` string
 runReviewers() received is the same content, in the same arrangement,
 reviewDiffCmd actually read off the worktree.

 Needs no hashing primitive: canonicalize (kept lines, each with its own
 trailing newline — matching awk's `print`, ORS appended after every line,
 none added at the very end beyond that, so a run over zero lines sums to
 0), then `sum += code * (i + 1)` over that string. Verified — by an
 automated test that executes reviewDiffCmd's REAL bash pipeline, not a
 restated comment — to agree with the bash side against this repo's own
 reviewer-routing.tsv (test_workflow.sh's "bash/JS parity" case). That
 agreement holds only while every DATA row (not the comment header, which
 is filtered out before either side sums) is pure ASCII — reviewer-routing
 .tsv's own header names that constraint for whoever next edits a data row.
```

## reviewDiffTsvGap — temperloop#1976 (row-count), extended by temperloop
<a id="reviewdifftsvgap-temperloop-1976-row-count-extended-by-tempe"></a>

```text
 reviewDiffTsvGap — temperloop#1976 (row-count), extended by temperloop#1982
 (content). The routing-table field (`tsv_lines` since temperloop#2020, the
 legacy `tsv` scalar before it — reviewDiffTsvText normalizes both) is
 hand-copied by the machinery-executor agent from the diff-fetch command's
 own JSON line, a SEPARATE step from the one that computed
 `tsv_rows`/`tsv_checksum` off the same worktree file — so any of the three
 can disagree only if the relay dropped, truncated, or otherwise garbled the
 (potentially large) table field on the way through.

 Both detectors below are UNCHANGED by #2020 — that item moved only the
 DISPOSITION after detection (runReviewers now degrades legibly rather than
 escalating `review-diff-error` on a persistent gap), never how much is
 detected.

 PATH A (missing/truncated — temperloop#1976, evidence: wf_cbc556f5-7be):
 neither table shape is present, or the received table's own non-comment row
 count disagrees with the relayed `tsv_rows` — a row-count mismatch.

 PATH B (content-preserving garble — temperloop#1982, evidence:
 temperloop#1978 round 4): `tsv` IS a string, and its row count DOES match
 `tsv_rows` (the guard above sees nothing wrong), yet its content differs
 from what reviewDiffCmd actually read off the worktree — the relay
 reproduced a plausible-LOOKING table (right length) that was not the real
 one, and determineReviewers() silently routed off it (that run's diff
 touched four `.sh` files with a `reviewer-routing.tsv` `.sh` row, yet only
 docs-reviewer ran). A row-count check structurally cannot see this: the
 row count survives the garble unchanged. Caught here by comparing
 `tsv_checksum` (relayed off the source file, a short scalar exactly like
 `tsv_rows`, and observed — same as `tsv_rows` — to survive the relay even
 when `tsv` itself does not) against `tsvChecksum(diffOut.tsv)` (recomputed
 HERE from the received string, no hashing primitive needed — see
 tsvChecksum()'s own comment for why the prior sha256 attempt, temperloop
 #1976 round 1, couldn't close this gap and this can).

 Returns null when the table is trustworthy, else the payload naming what's
 wrong, always carrying `files` (the changed-file list) so the degradation
 notice names what would have been routed: `{ missing: 'tsv', files }` when
 neither shape is present (the key stays `'tsv'` — it names the ROUTING
 TABLE, not one wire field, and is a stable payload key across both
 shapes); `{ mismatch: { expected, got }, files }` on a row-count
 disagreement (`got` is `?? null` since `tsv_rows` can itself be absent, and
 JSON.stringify silently drops an `undefined` key); `{ content_mismatch: {
 expected, got }, files }` when the row count agrees but the checksum
 doesn't (`got` is likewise `?? null` for an absent `tsv_checksum`). Only
 checked when `files` is non-empty: an empty diff never needs a routing
 table, so this never fires on the legitimate no-tsv-worktree case
 (`tsv_lines: []`, `tsv_rows:0`, `tsv_checksum:0`) either, regardless of
 `files` — a genuinely empty tsv is complete by construction (0 === 0 and
 tsvChecksum('') === 0).
```

## runReviewers — the §3e driver. Fetches the routing inputs (one machine
<a id="runreviewers-the-3e-driver-fetches-the-routing-inputs-one-ma"></a>

```text
 runReviewers — the §3e driver. Fetches the routing inputs (one machinery
 call), resolves the matching reviewer set, and spawns EACH directly via
 `agent({agentType})` — never delegated to the 3c worker. Every routed reviewer
 is spawned CONCURRENTLY and the whole fanout waits under one wall-clock
 ceiling (temperloop#2003, awaitReviewFanout), so one agent that never returns
 can neither block a later one from launching nor stall the level. Returns:
   { escalation }                                   — the diff fetch itself failed
   { summary, notes, blocking: [], ran, skipped }   — normal return (blocking may be non-empty)
 A THIRD shape (temperloop#2020) is a normal return, not a third branch: when
 the routing table does not survive the relay even after the one-shot retry,
 this returns the normal shape with one extra `skipped` degradation notice
 and `routing_degraded` carrying the gap payload — the drive continues to
 3e.5/3f with the skip notice on the PR body. A post-commit advisory pass
 that cannot route is a DEGRADATION, never a halt. The degradation is
 PARTIAL: only the table-dependent axes are withdrawn, so the mandatory
 command-doc route (foundation#1007), the `review:` override and the
 `kind: architectural` axis — all computed from `item`/`files`, never from
 the table — still route and still run, and `ran` is therefore NOT
 necessarily empty in this shape.
   { …the normal return, plus `escalation` }        — a MANDATORY reviewer hit
     the ceiling (temperloop#2003): the tally is still computed and returned,
     AND the item escalates `review-agent-timeout` rather than reading as if the
     mandatory gate had passed. Callers check `.escalation` first either way.
 `summary` is a short tally line for the PR body (criterion: the PR must
 carry real evidence of a real pass, never a guaranteed-skip default).
 `notes` (temperloop#1450) is the FULL findings text for every reviewer that
 ran, one `### <reviewer>` block each — a non-blocking (MEDIUM/LOW-only)
 review is still advisory OUTPUT, not silently discarded after the HIGH
 check. Empty string when nothing ran. Callers splice `notes` into a durable
 surface (the PR body, at the 3f call site) rather than letting it evaporate
 once the blocking check has read it.

 `round` (temperloop#1970) is this pass's 1-based round number for THIS item's
 worktree, durable across the escalate→re-invoke loop (see reviewDiffCmd). The
 two blocking call sites compare it against REVIEW_BLOCKING_MAX_ROUNDS.
```

## temperloop#2020 — DEGRADE, never halt. Before this item a persistent
<a id="temperloop-2020-degrade-never-halt-before-this-item-a-persis"></a>

```text
 temperloop#2020 — DEGRADE, never halt. Before this item a persistent
 gap escalated `review-diff-error`, and that disposition was the
 reported harm, not the drop: by the time §3e runs the worker has
 ALREADY COMMITTED (3c) and passed acceptance (3d), so escalating here
 stops a drive whose work is complete, for the sake of an ADVISORY pass
 that is explicitly never a `checks` gate (build.md §3e). On
 Towheads/foundation at kernel v0.39.0 (run wf_967c2878-0a7, driving
 foundation#1869) that cost 515 verified lines: the item escalated
 committed-but-un-PR'd, and /fix's escalation-park path removed the
 worktree and its local `build/` branch.

 The DETECTORS are untouched — the row/checksum gap check and the
 one-shot retry above both still run, and this arm is reached only
 after both have fired. What changed is what happens next: the
 TABLE-DEPENDENT part of the routing decision cannot be made (routing
 off a missing/partial table is the #1976/#1982 silent-misroute this
 whole mechanism exists to prevent), so the extension axis and the
 prose-`*.md` fallback are withdrawn and that is said out loud — never
 implied by silence. The notice is a mode-2 `skipped — …` line per
 `claude/message-schema.md` § Degradation notice, carried into the PR
 body by reviewBodySuffix() exactly like every other skip notice, so a
 cold reader of the PR sees which part of §3e did not route rather than
 reading a thin review section as a clean pass.

 NOT a return (temperloop#2020 round 2). Returning here conflated "the
 extension-axis table is broken" with "no route can be determined" and
 silently dropped the one route that never needed the table: the
 MANDATORY command-doc rule (foundation#1007) is computed purely from
 `files`, the field that relays reliably, and fires regardless of any
 tsv row. A `claude/commands/*.md` diff whose relay dropped would then
 have reported `mandatory_ok: true` with workflow-reviewer never run —
 byte-identical to a clean pass, i.e. the K.49/foundation#164 silent-skip
 class reintroduced through this very fallback. So the arm now falls
 THROUGH with `tableAvailable: false`: every table-independent route
 still runs, and `mandatory_ok` is computed from real routes again.

 Deliberately NOT the remedy-bearing variant: that one clause is
 sanctioned only for a subagent that ships as source under
 claude/agents/ and is merely uninstalled. This is a relay fault with
 no in-the-moment operator fix, so it takes the bare default shape.
```

## reviewWaitAgent — the wall-clock TICK this runtime does not otherwise 
<a id="reviewwaitagent-the-wall-clock-tick-this-runtime-does-not-ot"></a>

```text
 reviewWaitAgent — the wall-clock TICK this runtime does not otherwise have.
 One machinery executor, one `review-wait.sh <secs>` call, one closed outcome.
 Resolves to 'REVIEW_WAIT_ELAPSED' ONLY when the interval genuinely elapsed,
 and to a `timer-*` string otherwise — which the caller reads as "no usable
 timer" and fails open on.

 TEMPERLOOP#2049 — WHY THE COMMAND IS A SCRIPT AND WHY THE RETURN IS CHECKED.
 This was an inline `sleep <secs>; printf '<json>'` Bash command, and the
 prompt told the executor to report the interval elapsed if the command never
 printed. In the machinery executor's seat that command shape is REFUSED by a
 harness permission control ("Blocked: sleep 300 followed by: printf …") in a
 millisecond — so the executor took that sanctioned escape and reported an
 elapse that had not happened. Measured in run wf_ebd4b5e0-3a8's own agent
 transcripts: three slices asking 300s/540s/360s returned in 8s/9s/9s, so the
 nominal 1200s ceiling realized in ~30s of wall clock, while the two reviewers
 it was bounding completed normally at 177s and 257s. Nothing was slow — the
 CEILING was ~40x fast, which is why three consecutive items reported
 `ran: []` with every routed reviewer "timed out".

 Two changes, and BOTH are load-bearing:
   1. THE WAIT IS REAL. The command is now the named project helper
      workflows/scripts/build/review-wait.sh, whose deadline loop runs inside
      a script — the same shape ci-poll.sh already uses and which the same
      machinery seat observably honours (that run's ci-batch executor held one
      Bash call open for 280 real seconds).
   2. THE RETURN IS NOT TAKEN ON TRUST. An elapse is honoured only when it
      carries `realized_secs` — the script's OWN measurement, printed only
      after the wait — and that value reaches the interval asked for. The
      prompt no longer sanctions reporting an elapse the command did not
      produce; a refused or errored command is REVIEW_WAIT_UNAVAILABLE, a
      pure observation, and the caller fails open on it loudly. Without (2),
      any future permission-control change silently re-breaks the ceiling in
      exactly this way and nothing reports it (kernel principle 5 — counter a
      known AI failure mode STRUCTURALLY, not with "be careful").
 A tool timeout stays honoured as elapsed: its budget is secs+60s, so it can
 only fire AFTER the interval. That is an observation too, and gets its own
 outcome rather than being folded into a guess.

 TEMPERLOOP#2064 — THE THIRD CHANGE: A BLOCK IS NOT A TIMEOUT. (2) above still
 left one coin flip standing. A permission BLOCK and a Bash-tool TIMEOUT kill
 are the same observation to the executor — no JSON line — and the tool-timeout
 arm is PERMISSIVE. Asked to label a state it cannot see, the executor picked
 the permissive one: measured in run wf_1b4c373b-8c1, slices asking
 300s/540s/360s returned in 11s/11s/17s, a 1200s ceiling realized in ~41s, and
 a docs-reviewer that returned a full clean review at 98s was discarded — the
 item then reported `skipped — docs-reviewer unavailable`, sending the next
 investigator at the AGENT ROSTER rather than at the timer. So: REVIEW_WAIT_
 BLOCKED is its own outcome, the refusal is classified from the harness's OWN
 text before any label is read (REVIEW_WAIT_REFUSAL_RE), and the ceiling-breach
 notice says `timed out after <actual>s` — reserving `unavailable` for the
 kernel's capability-probe sense (CLAUDE.kernel.md § Subagent usage).

 Deliberately NOT runMachinery(): that path batches its steps and wraps them
 in the #1071 watchdog, whose own ceiling would then race this one. A timer
 needs neither.
```

## reviewTally — merge one or more runReviewers() rounds (the original 3e
<a id="reviewtally-merge-one-or-more-runreviewers-rounds-the-origin"></a>

```text
 reviewTally — merge one or more runReviewers() rounds (the original 3e pass
 plus any CI-fix re-review, temperloop#1450) into the ONE summary object
 park() threads through to the orchestrator's Step 6 tally. `mandatory_ok`
 is false iff any SKIPPED entry across every round carried `mandatory: true`
 — i.e. the foundation#1007 command-doc rule was genuinely degraded at least
 once, never merely "some optional reviewer wasn't available".

 temperloop#1984 — `routed_not_run`, the WEAKER companion field.
 `mandatory: true` is set by determineReviewers() for `workflow-reviewer` on a
 command-doc diff and for nothing else, so EVERY extension-axis route
 (shell-reviewer for `.sh`, typescript-reviewer for `.mjs`, …) could be
 skipped with `mandatory_ok` still reading `true` — a tally that reads fully
 clean while the shell diff went unreviewed (observed live: six unrun §3e
 shell reviews across three items, every one caught by a human reading the
 roster, never by this tally). `routed_not_run` is the distinct set of
 reviewer names the routing RESOLVED but that did not run in the round they
 were routed for — deliberately a VISIBILITY field, not a second gate (ADR
 0037; kernel principle 7: a hard block here deadlocks legitimate work in a
 consuming checkout where a reviewer agent is genuinely absent, which is the
 ordinary case, not the pathological one). Invariant that closes the hole:
 `routed_not_run` is non-empty exactly when `skipped` is, so the tally can
 never read fully clean while any routed reviewer was skipped. A reviewer
 skipped in one round and run in another stays listed — the skip was real,
 and which round covered which diff is exactly what a reader needs to see.

 temperloop#1970 adds `residual_blocking` — the convergence bound's PER-RUN
 EXECUTION SIGNAL (§ Mandatory-step birth rule): one entry per round that hit
 the bound, carrying the round number and the findings that were CARRIED into
 the PR body rather than re-escalated. So an operator reading the Step 6
 summary can see the bound firing, on which items, with what still outstanding
 — never a prose-only declaration that it exists. OMITTED ENTIRELY when no
 round hit the bound, so an ordinary item's parked record stays byte-identical.
```

## gateFreshnessCmd — the §3e.5 pre-gate freshness step (temperloop#1937)
<a id="gatefreshnesscmd-the-3e-5-pre-gate-freshness-step-temperloop"></a>

```text
 -----------------------------------------------------------------------------
 gateFreshnessCmd — the §3e.5 pre-gate freshness step (temperloop#1937).
 -----------------------------------------------------------------------------
 build.md §3e.5 runs `scripts/quality-gates.sh` against the worktree, and a
 handful of its gates (validate-check-surface-degenerate-coverage.sh,
 validate-exec-bit-registry.sh, validate-mandatory-step-signal.sh) RATCHET
 against the CURRENT `origin/main` — they diff the worktree's registry rows
 against main's own, and flag any row main gained that the worktree never
 touched as REGRESSED. A worktree branched from main hours or days earlier
 (a long worker run, or a slow level) can be behind by the time the gate
 runs, so those rows are false positives: real work that landed on main
 AFTER this branch was cut, misread as this item's own regression. The live
 incident: the temperloop#1934 fix (a sibling item on this same level) merged
 while this worktree was mid-build and cost it a full gate round.

 Fetch origin and bring the worktree up to `origin/main` HERE, strictly
 before the gate runs, so the gate always measures against a tree that is
 least as current as main — never behind it. ONE combined shell script
 (fetch, ancestor-check, conditional rebase): this is always exactly ONE
 runMachinery call, never a separate check-then-rebase pair, so handling the
 stale case costs no additional machinery step beyond the check itself.

 `origin/main` is hardcoded rather than resolved through the
 default_branch()-style fallback chain reviewDiffCmd/activationControlCmd
 use (origin/HEAD, else main/master): this step exists specifically to match
 the exact ratchet target the named §3e.5 validators use — `origin/main`,
 by their own construction — not a generic default branch. A repo whose
 protected branch is genuinely not `main` needs a different fix than this
 one, not a guessed fallback here.

 Eight outcomes:
   FRESHNESS_NO_GATE  — round 3 (temperloop#1937 HIGH, workflow): the
     worktree carries no `scripts/quality-gates.sh` at all — the SAME
     `[ -x … ]` presence test gateCmd's own GATE_ABSENT arm makes, checked
     HERE first, before the fetch. There is nothing for this step to
     protect on a gate-absent project, so it takes the byte-identical
     pre-change path: no fetch, no rebase, no follow-on machinery.
   FRESHNESS_CURRENT  — `git merge-base --is-ancestor origin/main HEAD`
     already true (the worktree is at or ahead of main). No rebase is
     attempted — the JSON line still names both SHAs for the record.
   FRESHNESS_REBASED  — origin/main was ahead; `git rebase origin/main`
     replayed the worker's commits onto it cleanly. The JSON line names both
     SHAs (`worktree_base` = the worktree's HEAD after the rebase,
     `main` = the origin/main tip it was rebased onto).
   FRESHNESS_DIRTY    — round 2 (temperloop#1937 HIGH): origin/main was
     ahead, but the worktree carries uncommitted TRACKED-file edits, so git
     would refuse to even START the rebase ("cannot rebase: You have
     unstaged changes") — a non-zero exit exactly like a real content
     clash. Probed via `git status --porcelain --untracked-files=no`
     immediately BEFORE the rebase is attempted (never after), mirroring
     `pr.sh cmd_rebase`'s DIRTY_WORKTREE vs REBASE_CONFLICT split
     (temperloop#735) — untracked files are deliberately not dirt here
     (the worktree always carries at least the untracked `.build-guard`).
     The rebase is NEVER attempted on this path, so it can never be
     misread as FRESHNESS_CONFLICT (which would report an empty
     `conflict_files` and a false "rebase aborted" disposition).
   FRESHNESS_CONFLICT — the rebase hit a real content clash: `git diff
     --name-only --diff-filter=U` (read BEFORE the abort — the merge
     markers vanish once it runs) names at least one conflicted path. Then
     `git rebase --abort` runs so the worktree is left intact on its
     PRE-rebase commit — never a half-applied rebase, never a silent
     revert, and NEVER pushed as a known-stale branch. The JSON line's
     `detail` (round 3, MEDIUM) carries the tail of the rebase's own
     stdout+stderr, and `disposition` names exactly what was done, so a
     human resolving `stale-worktree` by hand knows the worktree was not
     touched.
   FRESHNESS_REBASE_ERROR — round 3 (temperloop#1937 MEDIUM): the rebase
     failed (non-zero exit) but `--diff-filter=U` found NO conflicted
     files — a pre-rebase hook, a missing commit identity, or a leftover
     in-progress rebase, none of which are a content clash. Reported as its
     OWN outcome (never collapsed into FRESHNESS_CONFLICT's shape, which
     would report an empty `conflict_files` and falsely claim a clash was
     aborted) with the same abort + `detail` tail treatment.
   FRESHNESS_ERROR    — the fetch/resolve step itself could not run (no
     network, no `origin/main`, or `git fetch` itself failed after one
     retry). This step's job is to PREVENT a false gate failure, never to
     manufacture one of its own — runGateFreshness() below treats this as
     fail-OPEN (log and proceed to the gate on the tree as it stands),
     exactly the pre-#1937 behavior. `detail` carries the fetch's own
     stderr (round 3, MEDIUM) so a genuine outage is diagnosable rather than
     a bare constant string.
   FRESHNESS_TIMEOUT  — round 2 (temperloop#1937 MEDIUM): the OUTER Bash-tool
     timeout killed this whole script before it printed any JSON line —
     possibly mid-`git rebase`, leaving a rebase in progress on disk. Unlike
     FRESHNESS_ERROR (nothing ran), the tree may now be mid-rebase, so
     fail-open would run the gate against a half-rebased tree — worse than
     the pre-#1937 behavior. runGateFreshness() below gives this its OWN
     arm: a follow-up probe checks for an in-progress rebase and aborts it,
     then ALWAYS escalates `stale-worktree` — never the fail-open
     FRESHNESS_ERROR path.

 `git fetch origin main`'s stderr is captured rather than discarded (round 3,
 MEDIUM): under `parallel()` sibling worktrees fetch concurrently, and a
 transient `cannot lock ref` race is retried ONCE (short sleep) before it is
 reported as FRESHNESS_ERROR — a race is not evidence the network or
 `origin/main` itself is unreachable, and silently swallowing it would fail
 open back to the pre-#1937 behavior for no real reason.

 Every JSON line below is built with `jq -cn --arg …`, never a raw `printf`
 substitution (round 3, LOW) — the same discipline `pr.sh cmd_rebase` uses —
 so no interpolated value (a path, a git-output tail) can break the line's
 JSON shape. All payload field names are snake_case throughout (round 3, LOW).
```

## candidateArmGate — the candidate arm's host-supply + containment seam.
<a id="candidatearmgate-the-candidate-arm-s-host-supply-containment"></a>

```text
 -----------------------------------------------------------------------------
 candidateArmGate — the candidate arm's host-supply + containment seam.
 -----------------------------------------------------------------------------
 Every candidate arm passes through `candidate-session.sh` BEFORE it builds:
 `resolve` proves the containment overlay is present, readable and well-formed
 (the same fail-closed check judge.sh's own pairwise mode runs), and
 `preflight` proves the candidate provider's credential is actually SET rather
 than merely named. A refusal is an INFRA loss for that arm, recorded as such —
 never a silent single-arm level.

 WHY THE WORKER ITSELF IS NOT SPAWNED BY `candidate-session.sh spawn`, AND WHY
 A NON-DEFAULT PROVIDER IS THEREFORE REFUSED HERE. `spawn` runs a `claude` CLI
 child inside whatever shell invokes it. In this driver the only shell is an
 executor agent's Bash tool, hard-capped at AGENT_BASH_CAP_MS (~10 minutes) —
 DESIGN NOTE 1/2. A build worker is an hour-scale process, so routing it
 through `spawn` would not produce a contained candidate session; it would
 produce a worker killed mid-build on every non-trivial item. The reachable
 spawn seam with no such cap is the runtime's own `agent({ model })`, which
 addresses the host session's provider only.

 So the seam is honest about its edge rather than silently exceeding it: a
 candidate naming the DEFAULT provider builds through `agent({ model })` (the
 A/A instrument check and every same-provider tier comparison — the epic's own
 first live run), and a candidate naming a NON-DEFAULT provider is REFUSED by
 name with an `infra` row. It is never spawned uncontained, which is the one
 outcome that would defeat candidate-session.sh's whole purpose. Lifting that
 edge needs an uncapped spawn seam, which is its own piece of work, not a
 silent widening here.
```

## ======================================================================
<a id="note"></a>

```text
 =============================================================================
 THE TWO PHASES OF driveItem (temperloop#2080, epic #2065 "dual-build")
 =============================================================================
 driveItem used to be ONE function that interleaved build → local gate → PR →
 CI per item. The dual-build harness cannot: ADR 0038 fixes the PICK at the
 LEVEL, so every in-scope item's build, local gate and pairwise judge must be
 known BEFORE any PR opens for the level (the "level barrier"). That is a
 phase split, not a flag — so the split is made STRUCTURAL here rather than
 left as an `if (dualBuild)` branch threaded through 700 lines:

   driveItemBuildPhase()  3a claim → 3b worktree → 3c worker → 3d verdict →
                          3e review → 3e.5 gate → 3e.6 activation gate.
                          Returns a TERMINAL record (parked/escalation), or
                          null having filled `box.ctx` with everything the
                          second phase needs. NOTHING here pushes, opens a
                          PR, or merges — that property is what makes the
                          barrier expressible at all.
   driveItemPr()          3f push+PR → 3g CI → 3g.5 re-render → 3h park.

 THE SINGLE-ARM PATH IS UNCHANGED BY CONSTRUCTION: driveItem() below calls
 both phases back to back, in the same order, with nothing between them — so
 the stage transcript, the agent-spawn sequence and the machinery step
 ordering a flag-less run produces are byte-for-byte what they were before
 the split (workflows/scripts/build/tests/test_workflow.sh pins the ORDERING
 explicitly, not merely the return object).

 WHY A `box` RATHER THAN A RETURNED CONTEXT. The build phase has ~25 early
 `return escalate(...)` / `return park(...)` sites. Rewriting every one of
 them into `{ result: … }` would be 25 chances to typo a control-flow edge
 that only one specific failure fixture exercises. Instead the phase function
 keeps EVERY existing return statement byte-identical (a terminal record, or
 null on the fall-through) and hands its context out through the one
 out-parameter — so the diff touches the fall-through alone.
 =============================================================================
```

## 3b. Pre-create the deterministic worktree (worktree.sh create).
<a id="3b-pre-create-the-deterministic-worktree-worktree-sh-create"></a>

```text
 3b. Pre-create the deterministic worktree (worktree.sh create).
 On a continuation we REUSE the existing worktree (MINOR fix): the escalated
 item's worktree + its committed build + the .build-guard marker are all
 intact, and worktree.sh create force-removes-and-re-adds (worktree.sh:113),
 which would DISCARD the escalated build. So skip create entirely and resume
 against the deterministic path. The injected verdict (3c) makes resuming on
 the existing worktree correct — the worker builds on its own prior work
 plus the human's decision, exactly the escalation-resume contract.

 temperloop#2080 adds TWO things to this one step, both of which leave a
 flag-less, residue-free run's OUTPUT byte-identical:

  (a) THE ARM FLAG. A dual-build arm creates `<repoRoot>.wt/<slug>@<arm>` on
      `build/<slug>@<arm>` via `create --arm <name>[:<sibling>]`
      (temperloop#2076). `item.slug` is already the ARM KEY here, so the
      command is built from `arm.slug` — the real plan slug — and the
      deterministic path worktree.sh returns equals `worktreePath` above by
      construction, exactly as it does on the arm-less path.

  (b) THE FLAG-LESS-RESUME REFUSAL (ADR 0038's "Consequences"). A `/build`
      re-run over a level a dual build left half-finished must refuse
      LEGIBLY — never silently complete it single-arm, and never pick a side
      by accident. The signal is the arm worktrees themselves:
      `<repoRoot>.wt/<slug>@*` exists only while an arm of THIS slug is
      mid-flight (the pick deletes the losing arm's tree and `worktree.sh
      prune` reaps the rest), so it is precisely "partially dual-built" and
      nothing else. The ledger is deliberately NOT consulted: its rows
      outlive the run by `DUAL_BUILD_ARCHIVE_RETENTION_DAYS`, so a slug
      dual-built last week would refuse every ordinary build since.

      The check is emitted INSIDE this step's own command rather than as a
      new probe step, and that is the load-bearing choice: a level-wide
      probe agent would add a spawn to every flag-less run, changing the
      very transcript this item's acceptance pins as unchanged. Here the
      clean path runs `worktree.sh create` and prints its CREATED line with
      nothing added — same step count, same agent count, same JSON.
```
