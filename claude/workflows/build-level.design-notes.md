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

> **Part 1 of 3.** Split to stay under the repo's per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). Other parts: [`build-level.design-notes-2.md`](build-level.design-notes-2.md), [`build-level.design-notes-3.md`](build-level.design-notes-3.md).

## `meta` MUST be a PURE literal — no vars, calls, or spreads (runtime co
<a id="meta-must-be-a-pure-literal-no-vars-calls-or-spreads-runtime"></a>

```text
 `meta` MUST be a PURE literal — no vars, calls, or spreads (runtime constraint).
 Consequence (temperloop#903): `description` can NEVER carry run context — it is
 the same bytes on every run. So it is written for the operator as a plain
 statement of what the run DOES, deliberately WITHOUT asserting a scope (a
 "level") or a single caller: this script is invoked by THREE commands —
 /build (a full dependency level), /fix (a 1-item level), and /sweep (a
 chunk of singleton issues) — and a description that named only one of them,
 or asserted a single dependency-level scope, would misdescribe the other
 two invocations byte-for-byte identically (temperloop#1941 — the /fix and
 /sweep launch/completion lines used to inherit build's level-scoped wording
 on runs that drove neither a level nor a dependency edge). The
 run-IDENTIFYING half (caller, repo, items, issues, round) rides two
 dynamic surfaces instead:
 the phase() title — see levelPhaseTitle() near the entry point, emitted
 ONCE PER STAGE (temperloop#1294) — and, pushed unconditionally rather than
 left to the opt-in `/workflows` surface, the orchestrator's own Workflow
 launch/return line printed immediately around every invocation of this
 script (`claude/message-schema.md` §§ Workflow launch line / Workflow
 return line; `claude/commands/build.md` Step 3 + 3d-esc, `fix.md` Step 4a,
 `sweep.md` Phase 2). The optional `phases` key is deliberately ABSENT from
 this literal: meta.phases entries are matched against phase() titles
 EXACTLY, and every title this workflow emits is dynamic, so a static entry
 could only ever render an empty duplicate group. See the levelPhaseTitle
 block for the full reasoning. Return shape, the never-merges rule and
 the never-writes-the-plan-note rule are contract detail and live in the I/O
 CONTRACT block above; do not re-state them here.
```

## The §3e.5 PRE-gate freshness/rebase step (temperloop#1937): brings
<a id="the-3e-5-pre-gate-freshness-rebase-step-temperloop-1937-brin"></a>

```text
 The §3e.5 PRE-gate freshness/rebase step (temperloop#1937): brings
 the worktree up to current origin/main before the gate runs, so an
 origin/main-ratcheted validator never false-fails on rows main
 gained after this worktree's base was cut. NO_GATE (round 3, HIGH)
 means the worktree carries no `scripts/quality-gates.sh` at all —
 the same presence check gateCmd's own GATE_ABSENT arm makes — so
 there is nothing for this step to protect and it takes the
 byte-identical pre-change path with no fetch/rebase attempted.
 CURRENT/REBASED are the two non-blocking outcomes (proceed to the
 gate); DIRTY (round 2, HIGH) means git refused to even start the
 rebase over uncommitted tracked-file edits, probed BEFORE the
 rebase and escalated as `dirty-worktree`, never misread as a
 conflict; CONFLICT means the rebase hit a real clash and was
 aborted (worktree left intact, escalates `stale-worktree` — the
 gate never runs); REBASE_ERROR (round 3, MEDIUM) is a rebase
 failure with NO conflicted files (a pre-rebase hook, a missing
 identity, a leftover in-progress rebase) — never misreported as
 CONFLICT's empty-list false positive, its own not-a-conflict
 outcome carrying git's own output tail; ERROR is a fail-open
 (fetch/resolve itself could not run; proceed on the tree as-is,
 exactly the pre-#1937 behavior); TIMEOUT (round 2, MEDIUM) is the
 OUTER Bash-tool kill mid-fetch/rebase — never fail-open, always
 routed through a follow-up abort-and-probe before escalating
 `stale-worktree`. TIMEOUT_PROBE(_ERROR) are that follow-up probe's
 own closed outcomes.
```

## The §3e REVIEW-AGENT liveness bound's timer (temperloop#2003), whose
<a id="the-3e-review-agent-liveness-bound-s-timer-temperloop-2003-w"></a>

```text
 The §3e REVIEW-AGENT liveness bound's timer (temperloop#2003), whose
 executor runs workflows/scripts/build/review-wait.sh to give this
 runtime the wall-clock tick it otherwise has none of (`Date.now()`
 THROWS here — DESIGN NOTE 1). FOUR closed outcomes, each a pure
 OBSERVATION the executor can make without inventing anything — the
 distinction temperloop#2049 turned on, plus the fourth
 temperloop#2064 had to split out of it:
   REVIEW_WAIT_ELAPSED       the script printed its line. It carries
                             `realized_secs`, the script's OWN measure
                             of the wait, which reviewWaitAgent()
                             checks against the interval it asked for.
   REVIEW_WAIT_TOOL_TIMEOUT  the Bash tool's own timeout killed the
                             command. That budget is secs+60s, so this
                             can only fire AFTER the interval — the
                             same fact, reported honestly.
   REVIEW_WAIT_BLOCKED       a harness PERMISSION CONTROL refused the
                             command outright ("<tool_use_error>Blocked:
                             …"). NO time passed. This is SPLIT OUT of
                             REVIEW_WAIT_UNAVAILABLE by temperloop#2064
                             because a block and a TOOL_TIMEOUT are the
                             same observation to the executor — "no JSON
                             line" — while only ONE of them (the tool
                             timeout) is the PERMISSIVE arm. Naming the
                             block is what lets reviewWaitAgent() refuse
                             to let a refusal land on that arm.
   REVIEW_WAIT_UNAVAILABLE   the command never ran to completion for any
                             OTHER reason (it errored; the helper was
                             missing). NO time passed either, so the
                             caller FAILS OPEN on both.
 None of them says anything whatsoever about the review being bounded.
```

## RETRY-LOOP INVENTORY (temperloop#976)
<a id="retry-loop-inventory-temperloop-976"></a>

```text
 -----------------------------------------------------------------------------
 RETRY-LOOP INVENTORY (temperloop#976)
 -----------------------------------------------------------------------------
 Every loop in this file that can RE-ATTEMPT something, with its hard cap and
 its transient-vs-deterministic disposition. Repeating a deterministically-
 failing operation cannot change its outcome, so a loop either classifies
 before retrying or states why classification does not apply. The audit is
 kept HERE, beside the budgets, so a new loop cannot be added without a
 reviewer seeing the shape it has to satisfy.

   1. ciPollLoop slice loop — CAP: maxSlices = ceil(CI_POLL_TOTAL_SECS /
      CI_POLL_SLICE_SECS). NOT A RETRY: each slice waits on external state
      (pending check-runs) that genuinely changes between polls, and every
      terminal verdict (CI_GREEN / CI_FAILED / NO_CI) exits the loop on the
      spot. The deterministic cases it MUST not spin on are already short-
      circuited by name, not by budget: CONFLICTING/DIRTY escalates
      merge-conflict immediately (#543), a NO_CI SHA resolves through
      ci-poll.sh's bounded grace window (temperloop#605), and any ERROR
      escalates rather than re-polls. No classification step applies.
   2. CI_FAILED worker re-spawn — CAP: CI_FAIL_RETRY_BUDGET (below), past
      which the item escalates `ci-failed` for a human. NOT A RETRY EITHER, in
      the sense that matters here: the re-attempt does not re-issue the failed
      operation, it spawns a worker to FIX the failure and pushes a NEW SHA, so
      the input to the next CI run differs by construction. That is what makes
      a classify-before-retry step inapplicable — and the budget is already at
      its floor of one, so a deterministic repeat cannot cost a second one.
   3. null-verdict main-worker re-spawn (driveItem, ~1145) — CAP: exactly one,
      and CLASSIFIED BEFORE IT FIRES on both axes: the recover-probe runs FIRST
      and adopts any work that already landed (so a lost return is never re-
      built), and the retry prompt is deliberately DIFFERENT from the first
      (FOREGROUND_CURE appended) because a byte-identical retry re-stalls
      identically. The read-only spike worker's null escalates with NO retry.
   4. pr.sh `EXISTS` adoption (3f) — not a loop: a create-retry whose first
      attempt in fact succeeded is ADOPTED as PR_OPENED rather than re-issued.
   5. STEP_TIMEOUT disposal (temperloop#1071) — NOT A RETRY AT ALL, and named
      here so a future edit cannot quietly make it one. A machinery step killed
      by the workflow liveness ceiling is CLASSIFIED FIRST (pr.sh recover-probe,
      the same ladder rule 3 uses) and then either ADOPTED (rule 4's shape: an
      already-opened PR is taken, never re-opened) or ESCALATED. There is no arm
      that re-issues the bounded step — push and pr-create are not idempotent,
      and the ceiling firing is precisely the case where you cannot know whether
      the first attempt landed.

 The two loops this file DELEGATES to carry their own caps + classification
 and are documented in their own scripts, not restated here: ci-poll.sh's
 gh_retry (CI_POLL_API_MAX_ATTEMPTS / _RETRY_BACKOFF / _DETERMINISTIC_PATTERN)
 and quality-gates.sh's per-gate retry via workflows/scripts/lib/gate-retry.sh
 (GATE_MAX_ATTEMPTS / GATE_RETRY_BACKOFF / GATE_DETERMINISTIC_PATTERN). The
 3e.5 acceptance gate itself does NOT retry: a GATE_FAIL escalates
 `acceptance-gate-failed` on the first failure.

 -----------------------------------------------------------------------------
 Tunables (no Date.now()/Math.random() — those THROW in the runtime; all
 budgets are expressed as counts/seconds the executor agent enforces itself).
 The Workflow runtime has no shell, so these stay named constants here rather
 than build.config.sh settings — the same structural constraint that forces
 machinerySoloModel/machineryBatchModel through build.md's Step-0 hand-off.
 A tunable that genuinely needs to be operator-configurable rides that SAME
 Step-0 hand-off (an `input.*` key with an in-file default), never a config
 read from inside this file: GATE_SLICE_SECS below is the worked example.
 -----------------------------------------------------------------------------
```

## §3e review-blocking convergence bound (temperloop#1970)
<a id="3e-review-blocking-convergence-bound-temperloop-1970"></a>

```text
 --- §3e review-blocking convergence bound (temperloop#1970) -----------------
 THE FAILURE THIS BOUNDS. §3e is a cold, one-shot advisory pass, and a HIGH
 finding escalates `review-blocking` → the orchestrator loops the item back to
 3c → the worker fixes it → a FRESH reviewer reads the now-LARGER diff. Nothing
 bounded that loop. Measured on one live item (temperloop#1938 L1, item
 `interview-command-spec`/#1962): FIVE consecutive §3e passes, four DISTINCT
 HIGHs, ZERO repeats, ~2h45m and ~1.05M subagent tokens before convergence —
 and pass 4's HIGH was CAUSED by pass 3's directed fix, while the reviewed spec
 grew 447 → 635 lines across the rounds. So the loop is partly SELF-FEEDING,
 not merely serial discovery: each round enlarges the surface the next one
 reads, and the orchestrator had to invent a stopping rule by hand at pass 5.

 THE OTHER HALF IS THE REVIEWER SEAT, NOT THIS BOUND. claude/agents/
 workflow-reviewer.md now instructs the seat to enumerate EVERY HIGH it can
 identify in ONE pass before it ranks or narrows; this constant is the backstop
 for when that still does not converge. Deliberately NOT a model-tier change:
 that seat is pinned `model: sonnet` by its own frontmatter, on purpose.

 WHAT IT DOES, PRECISELY. `REVIEW_BLOCKING_MAX_ROUNDS` caps the number of
 review ROUNDS one item's worktree may spend. On the round that reaches the
 cap, a blocking finding no longer escalates: the item continues to 3e.5/3f
 with the findings carried in the return value — into the PR body's
 `## Review notes` (the same reviewBodySuffix() render every round uses) and
 into the parked record's `review.residual_blocking` tally — so the human at
 the merge gate reads exactly what the reviewer said. ADVISORY, NEVER A
 SUPPRESSION: what stops is the automatic build-review-build loop, not the
 findings. An item that converges in fewer rounds is byte-identical to
 pre-#1970 behaviour, which is why the default preserves today's path for
 everything under the bound.

 ROUND COUNTING IS DURABLE, because the loop spans PROCESSES: each
 review-blocking escalation returns to the orchestrator, which re-invokes this
 workflow. The Workflow runtime has no filesystem (DESIGN NOTE 1), so the
 counter lives in the worktree's own GIT DIR (never the working tree — it must
 not show up in `git status`, in a `--scoped` gate's untracked-path resolution,
 or in a coverage manifest) and is read+bumped by reviewDiffCmd in the SAME
 machinery call §3e already makes: zero extra agent spawns. A continuation
 re-uses the worktree (3b is skipped), so the count survives exactly the loop
 it bounds; a fresh item gets a fresh worktree and therefore a fresh count.
 The CI-fix re-review (§3g) shares the counter deliberately — it is the same
 item's review budget, and counting it is the conservative direction.

 REVIEW_BLOCKING_MAX_ROUNDS is a NAMED SETTING (BUILD_REVIEW_BLOCKING_MAX_ROUNDS),
 handed in by the orchestrator at Step 0 exactly like GATE_SLICE_SECS above —
 the Workflow runtime cannot source build.config.sh itself. A non-positive or
 unparseable value falls back to the in-file default rather than disabling the
 bound, and the floor of 1 means no caller can configure the loop back to
 unbounded.
```

## §3e review-agent LIVENESS BOUND (temperloop#2003)
<a id="3e-review-agent-liveness-bound-temperloop-2003"></a>

```text
 --- §3e review-agent LIVENESS BOUND (temperloop#2003) -----------------------
 THE FAILURE THIS BOUNDS — the sibling of temperloop#1071 one layer up. Run
 `wf_f3b9c160-6ca` routed four §3e reviewers. Two returned. `shell-reviewer`
 was spawned and never returned: its own agent transcript ends mid-sentence at
 "Now compiling the final review output", the workflow stopped writing its
 journal, and ~41 minutes of silence followed until a human ran `TaskStop`.
 `workflow-reviewer` — MANDATORY for that item's `claude/commands/*.md` diff —
 never launched at all, because the §3e pass awaited each reviewer in turn and
 the second one never resolved.

 WHY THAT IS WORSE THAN A PLAIN HANG. The mandatory-reviewer contract
 (foundation#1007) guarantees `workflow-reviewer` RUNS, and `review.
 mandatory_ok` reports whether it did. A hang UPSTREAM of it in the same pass
 means neither the guarantee nor the tally is ever EVALUATED: the gate does not
 fail, it never resolves. An operator watching the tally sees nothing wrong,
 because there is no tally yet — which is exactly why the incident stayed
 invisible for 41 minutes. So the bound's job is not only to stop waiting; it
 is to make the pass ALWAYS produce a disposition.

 WHY THE BOUND CANNOT BE A TIMER. Same two runtime facts temperloop#1071 hit:
 `Date.now()` THROWS here and there is no timer primitive, so a deadline is not
 directly expressible. But `Promise.race` IS — what #1071 lacked was something
 that resolves ON A CLOCK to race against, and this file already owns one: a
 machinery executor running a WAIT. reviewWaitAgent() is that tick.

 TEMPERLOOP#2049 — WHERE THAT TICK HAS TO LIVE. The wait was first written as
 a bare inline `sleep N; printf '<json>'` Bash command. A harness permission
 control REFUSES that command shape in the machinery executor's seat, and the
 executor's prompt then told it to report the interval elapsed anyway: the
 nominal 1200s ceiling realized in ~30s, abandoning reviewers that were
 finishing normally at 177-257s. The wait now runs inside the named helper
 workflows/scripts/build/review-wait.sh (the shape ci-poll.sh already uses,
 observably honoured in the same seat for a 280s single call), and an elapse
 is honoured only when it carries the script's OWN `realized_secs`. See
 reviewWaitAgent() for the measurements and both halves of the fix.
 A reviewer is an `agent({agentType})` call, NOT a shell command, so #1071's
 emitted-shell watchdog cannot reach it; the race is the only seam that can.

 THE SHAPE, mirroring #1071's ceiling+observability pair exactly:
   • REVIEW_AGENT_CEILING_SECS — the wall-clock ceiling on the WHOLE §3e pass,
     measured from fanout start. Every routed reviewer is spawned CONCURRENTLY
     (they are independent read-only passes; nothing ordered them), so one
     hung agent can no longer keep a later one from launching — the observed
     failure — and the pass costs max(reviewer) rather than sum(reviewer).
     A reviewer still unsettled at the ceiling is ABANDONED, not killed: this
     runtime cannot cancel an agent, and the promise is simply never awaited
     again. Its disposition then respects mandatory-vs-advisory (runReviewers).
   • REVIEW_AGENT_SLOW_SECS — the observability half: a pass still running at
     this threshold emits a log() progress notice naming who is outstanding, so
     a long review is VISIBLE well before it is given up on. 0 disables it.
 Both are NAMED SETTINGS (BUILD_REVIEW_AGENT_CEILING_SECS /
 BUILD_REVIEW_AGENT_SLOW_SECS), handed in by the orchestrator at Step 0 on the
 SAME seam as GATE_SLICE_SECS / the #1071 pair above, for the same structural
 reason (this runtime has no shell to source build.config.sh).
```

## Machinery-step LIVENESS BOUND (temperloop#1071)
<a id="machinery-step-liveness-bound-temperloop-1071"></a>

```text
 --- Machinery-step LIVENESS BOUND (temperloop#1071) -------------------------
 THE FAILURE THIS BOUNDS. A `pr-batch` machinery agent ran 35,362,333ms — 9h49m
 — on TWO tool calls and 45k tokens. Not a retry loop, not a runaway: ONE Bash
 invocation blocked and then completed successfully (all four steps green, the
 PR opened). Every bound that should have made that unreachable failed: the
 Bash tool's `timeout` parameter is capped at AGENT_BASH_CAP_MS and the prompt
 above asks for less than that, so a 9.8h call is not supposed to exist — and
 NOTHING ELSE bounded it. The root cause is NOT established (candidates exist;
 none is acted on here without a disconfirming probe), so this is deliberately
 a ROOT-CAUSE-AGNOSTIC seam: a bound that holds regardless of WHICH hypothesis
 is true.

 WHY IT LIVES IN THE EMITTED SHELL, NOT IN THIS FILE'S CONTROL FLOW. Two hard
 runtime facts. (a) `Date.now()` THROWS in the Workflow runtime (see the
 tunables header above), so this file cannot measure elapsed time at all — a
 `Promise.race` deadline is not expressible here, there is no timer primitive
 to race against. (b) The thing that failed to fire IS the harness's own
 tool-timeout layer, so putting the new bound in that same layer would inherit
 the failure. So the ceiling is compiled INTO the command text every machinery
 step already runs through: a bash + `sleep` + `kill` watchdog, modelled on
 `workflows/scripts/lib/portable-timeout.sh`'s dependency-free fallback tier
 (its pipe-leak redirect included, verbatim in spirit — see stepBoundPreamble).
 It is still a WORKFLOW-LEVEL bound: this file decides it, this file emits it,
 this file branches on the STEP_TIMEOUT it produces, and it applies to every
 machinery executor (`prelude` / `pr-batch` / `ci-batch` / solo `gate`) rather
 than to any one script.

 WHY NOT run_with_timeout(1) ITSELF. `portable-timeout.sh`'s preferred backends
 are `timeout`/`gtimeout`, which `exec` a BINARY — they cannot run a shell
 FUNCTION, and a batched step body is exactly that (a multi-command shell
 snippet with `&&`, `;`, redirections and command substitutions). Re-wrapping
 each body as `bash -c '<quoted script>'` to reach those backends would also
 re-introduce the nested-quoting shape temperloop#72 found the auto-mode safety
 classifier reads as an obfuscated command — the class of failure that denied
 every push/worktree step on unattended runs. So the fallback tier is
 reproduced inline, with its provenance named here.

 The two settings are NAMED SETTINGS (BUILD_MACHINERY_STEP_CEILING_SECS /
 BUILD_MACHINERY_STEP_SLOW_SECS), handed in by the orchestrator at Step 0 on
 the SAME seam as gateSliceSecs above, and for the same structural reason. `||`
 vs `??`: same empty-string safety documented at the model settings.
```

## 3c worker return-value output-shape bounds (temperloop#1080)
<a id="3c-worker-return-value-output-shape-bounds-temperloop-1080"></a>

```text
 --- 3c worker return-value output-shape bounds (temperloop#1080) ------------
 The verdict's SHAPE is already machine-enforced (WORKER_VERDICT_SCHEMA below,
 passed to every worker agent({schema}) call) — but a JSON schema can constrain
 a field's TYPE and never its LENGTH, so the two free-prose slots were bounded
 by nothing but the worker's judgment. Measured across 83 real /build worker
 verdicts recovered from subagent transcripts: `summary` ran to a median 119
 words (mean 145, max 557) against a spec asking for "1-3 sentences", and each
 `acceptance_results[].evidence` to a median 33 words (max 244) against a spec
 asking for "<file:line or test name>". Every one of those words is an OUTPUT
 token — the weight-5 class, the most expensive token this pipeline emits — and
 the orchestrator then ingests all of them.

 The bound is NOT information loss, and that is the whole reason it is safe:
 the worker already writes its full argument to `.build-verification.md`, a
 FILE whose path (not content) rides the verdict, and pr.sh splices that file
 into the PR body's `## Verification` section by path (`--verification-surface-
 file`) so it reaches the human reviewer WITHOUT ever entering orchestrator
 context. Bounding the verdict moves prose off the expensive path; it does not
 delete it. What must NOT survive anywhere is process narration — the worker's
 route to the answer ("first I read X, then ruled out Y") is not a finding.

 NAMED SETTINGS (BUILD_WORKER_SUMMARY_MAX_WORDS / BUILD_WORKER_EVIDENCE_MAX_
 WORDS), handed in by the orchestrator at Step 0 exactly like GATE_SLICE_SECS
 above — the Workflow runtime has no shell to source build.config.sh itself
 (DESIGN NOTE 1). `||`, not `??`, for the documented empty-string reason. A
 caller that omits the keys (sweep.md / fix.md today) still emits a BOUNDED
 prompt: the shape is inherited by every caller of the shared workerPrompt(),
 only the tuning is build.md's.
```

## The step LIVENESS BOUND, compiled into the command text (temperloop#10
<a id="the-step-liveness-bound-compiled-into-the-command-text-tempe"></a>

```text
 -----------------------------------------------------------------------------
 The step LIVENESS BOUND, compiled into the command text (temperloop#1071).
 -----------------------------------------------------------------------------
 See the STEP_CEILING_SECS block above for WHY the bound lives in the emitted
 shell rather than in this file's control flow (no Date.now(), no timer, and
 the layer that failed to fire IS the tool-timeout layer). These three helpers
 are the HOW.

 stepBoundPreamble(slowSecs) — the prologue every bounded command carries: the
 two budgets as plain shell variables, then `__lb`, which runs ONE step body
 under them. `__lb` is the dependency-free fallback tier of
 `workflows/scripts/lib/portable-timeout.sh`, reproduced here (that library's
 preferred `timeout`/`gtimeout` backends `exec` a BINARY and cannot run a shell
 FUNCTION, which is what a step body is). Two details are load-bearing and both
 come straight from that file's header:
   • the watchdog subshell is redirected AT THE SUBSHELL BOUNDARY
     (`) </dev/null >/dev/null 2>&1 &`). Without it, its `sleep` grandchild
     inherits the caller's `$( … )` pipe write-end and every FAST, successful
     step stalls for the full ceiling waiting on EOF (foundation #861).
   • the watchdog is killed AND reaped on the fast path, so a completed step
     leaves nothing behind.
 The kill is best-effort DEEP: direct children first (`pkill -P`, so the helper
 script dies before the subshell that owns it), then the subshell itself. A
 deeper grandchild (a `gh` inside a `pr.sh`) can still outlive the bound — which
 is exactly why a timed-out step is disposed through the recover-probe rather
 than blind-retried: the workflow stops WAITING on it without ever assuming it
 did nothing.

 The step body's own stdout is untouched — it flows to wherever the caller put
 it (a `$( … )` capture in a batch, the script's stdout for a solo call), so the
 machinery's "one JSON line per step" contract is preserved byte for byte on
 every healthy run. `__lb` only ADDS a line, and only in the two abnormal cases:
 STEP_TIMEOUT (replacing a result the kill destroyed) and STEP_SLOW (an advisory
 riding alongside a real result — hence `slowSecs` is 0 on the SOLO path, whose
 schema admits exactly one object).
```

## THE EXECUTOR AGENT TYPE — context size is the machinery agents' cost (
<a id="the-executor-agent-type-context-size-is-the-machinery-agents"></a>

```text
 -----------------------------------------------------------------------------
 THE EXECUTOR AGENT TYPE — context size is the machinery agents' cost (#1014).
 -----------------------------------------------------------------------------
 A machinery executor's whole job is one Bash call, but a `general-purpose`
 agent carries the FULL harness surface to make it: every tool schema, the
 skill listing, the deferred-tool listing. That is dead weight on every spawn
 and it is charged TWICE for the two executors that exceed the ~300s
 prompt-cache TTL by construction — the CI poll (waiting IS its job) and the
 minutes-scale 3e.5 gate. Their post-wait call is a total cache miss: the whole
 context is re-WRITTEN at weight 1.25 instead of re-READ at 0.1, so the excess
 is proportional to CONTEXT SIZE, not to the length of the wait (#1014).

 So machinery executors run as `machinery-executor` (claude/agents/), whose
 tool surface is Bash alone (+ the runtime's own StructuredOutput, appended
 automatically when a schema is passed) and whose system prompt carries the
 standing "run it verbatim, return each step's JSON line" contract that every
 per-call prompt used to restate. Measured on this harness, same prompts, same
 machine (temperloop#1014): ci-batch 37,428 -> 30,856 first-call
 cache_creation tokens, 3e.5 gate 37,201 -> 30,734 (-17.5%). The residual is
 almost entirely the installed CLAUDE.md (measured at 25,714 tokens, identical
 under both agent types) — which the harness injects into every non-built-in
 agent and NO agent definition can decline, so it is out of this file's reach.
 Of the context this file CAN reach, the lean type removes 56%.

 FALLBACK, NOT A DEPENDENCY. A checkout that has not deployed the agent
 definition (`workflows/scripts/install/project-agents.sh`) must still build.
 agent() rejects an unresolvable (or permission-denied) agentType at RESOLUTION
 time — before any subagent is spawned, so nothing has run and re-issuing the
 call is safe — with a message naming `agent({agentType})` and the type it could
 not resolve. machineryAgent() catches exactly that shape once, pins the type to
 'general-purpose' for the rest of the run, and re-issues with the full prompt.
 Any OTHER failure propagates untouched: a blind retry of a machinery command is
 NEVER safe (push / pr-create are not idempotent), so the match is deliberately
 narrow — two independent markers of a resolution failure, never a catch-all.
 An explicit input.machineryAgentType (orchestrator-supplied) overrides the
 default and disables the probe.
```

## THE WORKER GATE SENTINEL — a RESULT artifact, not a process (temperloo
<a id="the-worker-gate-sentinel-a-result-artifact-not-a-process-tem"></a>

```text
 -----------------------------------------------------------------------------
 THE WORKER GATE SENTINEL — a RESULT artifact, not a process (temperloop#865).
 -----------------------------------------------------------------------------
 Both Level-1 workers of epic #810 backgrounded `scripts/quality-gates.sh`,
 then polled for a PID to exit instead of reading the run's result, and ended
 their turn with no verdict. 2/2 — AGAINST A PROMPT THAT NAMED THE EXACT
 FAILURE AND PRESCRIBED THE FIX, and one of them re-stalled after being told in
 so many words to go read the output file. The issue's own acceptance forbids
 the obvious response: "demonstrated by whatever mechanism is chosen, not by a
 re-worded warning". A third wording is not a fix; this is kernel principle 5
 (counter AI failure modes STRUCTURALLY) applied to the engine's own seam.

 So THREE structural changes replace the warning:

  1. THE WORKER NO LONGER COMPOSES ITS OWN GATE INVOCATION. workerGateCmd()
     below is built by the orchestrator and handed over verbatim, so the shape
     of the run is not a choice the worker makes turn by turn.
  2. THAT INVOCATION ALWAYS LEAVES A RESULT. It writes `{"state":"running"}`
     before the suite starts and overwrites it with
     `{"state":"finished","rc":N,"elapsedSecs":S}` when the suite ends, then
     prints the sentinel as its final line. A worker that loses the tool output
     — backgrounded, reaped, timed out — polls the FILE and gets a verdict. A
     PID poll cannot ever succeed (the exit status is gone with the process,
     and a subagent receives no background-task notification at all); an
     ARTIFACT poll can. That is the issue's candidate 2, and candidate 1's
     "hand the worker an invocation" half.
  3. THE RESIDUAL FAILURE IS LOUD. The parent-side 3e.5 gate command classifies
     this same file from the same worktree and reports `workerGate` on its own
     outcome, so the driver logs a NAMED notice when the sentinel still reads
     `running`. Today "waiting for the gate" is indistinguishable from a
     healthy long gate until the budget is gone; after this, a stalled worker
     reads differently from a slow one in the run log and in the gate payload.

 NOT IN SCOPE (recorded, deliberately not implemented): the issue's candidate 3
 — move the gate out of the worker entirely. It is an architectural subtraction
 touching every worker on every run and must not ride a five-defect PR.

 WHY /tmp, NOT THE WORKTREE. It mirrors the 3e.5 gate's own `/tmp/qg-<slug>.log`
 convention, and it keeps a machine-written file out of the tree `pr.sh rebase`
 and the leak guard inspect — an untracked artifact inside the worktree would
 need a matching `info/exclude` entry in worktree.sh, which is outside this
 item's scope and would make the fix a cross-script change.
```

## workerGateCmd — the ONE invocation the worker is handed. Foreground by
<a id="workergatecmd-the-one-invocation-the-worker-is-handed-foregr"></a>

```text
 workerGateCmd — the ONE invocation the worker is handed. Foreground by
 construction (it ends by printing its own result), always-sentinel-writing by
 construction (both the `running` and the `finished` writes are unconditional
 steps of the same command line), and it exits with the gate's own status so a
 worker that only reads the exit code still gets the truth.

 `set -o pipefail` is load-bearing for the same reason it is in gateCmd
 (temperloop#68): the suite is piped through `tee`, and without it `$?` would
 be tee's 0 and a RED gate would write `"rc":0` into the sentinel — a silent
 green, which is the single worst thing this artifact could do. The exit status
 is read as a bare `$?`, never PIPESTATUS[0], which expands empty under the zsh
 this harness's Bash tool actually runs (temperloop#801).

 EVERY PROLOGUE STEP HARD-REFUSES; NONE OF THEM IS `&&`-CHAINED INTO THE RUN
 (review round 2, the HIGH). `A && B && C; D` is NOT a guard: it skips `B..C`
 on `A`'s failure and then runs `D` anyway. That shape — which this function
 shipped in its first cut — meant a failed `cd` (worktree pruned, moved, or an
 unresolvable path) skipped both the `running` sentinel AND `set -o pipefail`
 and then ran `./scripts/quality-gates.sh` in whatever directory the worker's
 shell happened to start in, recording a RED suite in the WRONG repo as
 `{"state":"finished","rc":0}` with a nonsense `elapsedSecs` (`__t0` unset, so
 the arithmetic read it as 0). That is precisely the silent green the comment
 above calls the worst thing this artifact could do, reintroduced by the fix
 for it. So each prologue step is now its own statement ending in an explicit
 `|| exit`, and `set -o pipefail` comes FIRST — before anything it protects —
 rather than being `&&`-chained after work that has already happened:

   - `set -o pipefail || exit 1` — a shell without pipefail refuses here. A
     POSIX special builtin's failure exits a non-interactive shell outright
     (dash), and the `|| exit 1` catches the lenient shells that merely return
     non-zero. Either way nothing downstream runs unprotected.
   - `[ -x ./scripts/quality-gates.sh ] || exit 127` — "this repo has no gate"
     refuses BEFORE any sentinel is written, so `absent` (never `finished`)
     is what both the worker and §3e.5 see. Before this, a missing script ran
     as an ENOENT through the pipe and the NEXT statement wrote
     `{"state":"finished","rc":127}` unconditionally — which the handed prompt
     then told the worker to report as "a real FAIL", turning a repo with no
     gate into a gate failure (review round 2, the MEDIUM).
   - `cd … || exit 1` and the `running` write's own `|| exit 1` — the suite
     can never run outside the worktree, and can never run with no artifact to
     poll.

 The invariant to preserve on any future edit: a `finished` sentinel is
 reachable ONLY after the suite actually ran, in the worktree, under pipefail.
```

## Worker cost capture (temperloop#2065, epic #2062's dual-build ledger).
<a id="worker-cost-capture-temperloop-2065-epic-2062-s-dual-build-l"></a>

```text
 -----------------------------------------------------------------------------
 Worker cost capture (temperloop#2065, epic #2062's dual-build ledger).
 -----------------------------------------------------------------------------
 The worker `agent()` spawn is the Workflow runtime's own subagent primitive:
 it returns no usage envelope, and the runtime has no timer (`Date.now()`
 throws — see the STEP CEILING block, DESIGN NOTE 1's sibling). Both gaps
 are closed the SAME way every other shell-only fact this file needs is:
 an emitted-shell machinery call (DESIGN NOTE 1's runMachinery bridge).
 workflows/scripts/build/worker-usage.sh is that bridge — the SAME pattern
 review-wait.sh established for giving this runtime a wall-clock tick it
 otherwise has none of (temperloop#2049).

   workerClockNow()  — a bare `date` read, no side effect. Returns epoch
                       SECONDS (a plain number — safe to subtract, since
                       only Date.now()/Math.random() throw here, never
                       arithmetic on a value already in hand) or null on
                       anything but a clean numeric reading.
   workerUsageEmit() — the SAME reading PLUS the durable per-seat
                       attribution write: model-usage-envelope.sh's shared
                       model_usage_emit_from_envelope, seat "build-worker" —
                       the SAME helper pipeline-drive.sh's A7/A8 and
                       pipeline-retro-judge-spawn.sh's A9 already call, so
                       the build worker joins their attribution stream as a
                       FOURTH emitting seat (ADR 0026) — the coverage
                       denominator in report-producers/model-comparison
                       names it. No `claude -p --output-format json`
                       envelope exists for a Workflow agent() call, so this
                       degrades to usage_source:"unavailable" (no tokens) on
                       every REAL call today — worker-usage.sh's own header
                       carries that honesty disclosure; the fields still
                       flow through byte-for-byte the day a real envelope
                       becomes available, and the offline test harness
                       exercises exactly that path.

 Both are FAIL-OPEN and never escalate: a cost-ledger entry must never be
 the thing that stalls a build. A malformed/absent reading degrades to
 null, never a thrown error or a denial.
```

## The SIDELINE notice — the consumer half of worktree.sh's CREATED verdi
<a id="the-sideline-notice-the-consumer-half-of-worktree-sh-s-creat"></a>

```text
 -----------------------------------------------------------------------------
 The SIDELINE notice — the consumer half of worktree.sh's CREATED verdict
 (temperloop#2006).
 -----------------------------------------------------------------------------
 `worktree.sh create` must NEVER refuse (its own contract at worktree.sh:783-787
 — a refusing create turns /build's prelude batch from CREATED into escalated),
 so when the deterministic path is already occupied by committed work that
 preservation could not capture, it SIDELINES: the occupant is MOVED — never
 copied, never removed — to `<path>.unpreserved-<sha8>` on branch
 `<branch>.unpreserved-<sha8>`, which frees the path so create still CREATES.
 It already REPORTS that, as fields on the CREATED line it was always going to
 print: `sidelined` / `sidelined_path` / `sidelined_branch`.

 This driver used to DROP all three. That is the whole of the defect #2006
 names: an intact, committed, reviewed build gets shelved while a fresh worker
 rebuilds the same item from scratch, and nothing reports it — not because the
 information is missing, but because nobody read it. The cost is a wasted
 re-drive plus an orphaned worktree nobody knows to reclaim, and it silently
 defeats the point of temperloop#1988's preserve-the-build fix.

 WHY THE CONSUMER LIVES HERE, below the drivers. The "is there a commit ahead
 of base at the deterministic path?" reading is the same fact /fix's Step 4a
 worktree state table reasons about in prose. /build and /sweep have no such
 table: they invoke this file on its normal `fresh` route (no onlySlugs, no
 verdicts) and reach `worktree.sh create` through the prelude batch below. A
 guard that lives in one driver's prose holds only for that driver — the
 per-instance-fix smell the kernel names ("hoist the mechanism rather than
 patch the instance, or you re-patch every sibling in turn"). Putting the
 consumer in the ONE file all three drivers route through is what lets /build
 and /sweep inherit what /fix has without any of them restating the rule.

 NOTHING here touches worktree.sh. `create` still never refuses, still
 sidelines rather than destroys, and still emits the identical CREATED line;
 this is purely the reading half that was missing.

 Keyed by slug rather than threaded through driveItem's ~30 return points:
 the notice is discovered at 3b and must ride whichever record the item
 eventually produces (parked OR escalation), which is exactly the shape
 preserveOnEscalation already solved with one choke point at the fan-out.
```

## preserveCommittedWorkCmd / preserveOnEscalation — temperloop#2020.
<a id="preservecommittedworkcmd-preserveonescalation-temperloop-202"></a>

```text
 -----------------------------------------------------------------------------
 preserveCommittedWorkCmd / preserveOnEscalation — temperloop#2020.
 -----------------------------------------------------------------------------
 THE DATA-LOSS SEAM. An escalation leaves the worktree intact, and every
 downstream spec says so — but "intact" is a promise about a LOCAL directory
 and a LOCAL `build/<slug>` branch, and the specs that dispose an escalated
 item are AI-executed prose. On Towheads/foundation (kernel v0.39.0, run
 wf_967c2878-0a7 driving foundation#1869) a §3e `review-diff-error` fired
 with the worker's work committed but un-pushed and un-PR'd; /fix's 4a
 escalation-park path then ran `worktree.sh remove`, taking the directory and
 the only branch pointing at those commits with it. 515 verified lines were
 hand-rescued from the parent session's transcript. fix.md's prose guard for
 exactly this hazard (its `FX.8 class:escalated-work-destruction` cite, and a
 worktree state table that permits removal on one row only) was already in
 place and did not hold — which is the whole argument for fixing it HERE:
 kernel principle 5, counter a known AI failure mode STRUCTURALLY rather than
 with more prose the next agent may also misread.

 So: before an escalation LEAVES this driver, any commit the worker made that
 is not yet on origin is PUSHED. After that, every destructive disposition a
 caller can take — `worktree.sh remove`, its `git branch -D`, a force-clearing
 `worktree.sh create` on a later run — destroys only a local copy of work that
 already exists on the remote. This protects callers whose escalation paths
 this file cannot see, which a fix in any one caller's prose cannot.

 Fail-soft in every direction, and deliberately so — this runs on a path that
 is ALREADY failing, and must never convert an escalation into a worse one:
 no worktree, no commits, a rejected push, a denied executor, a thrown
 machinery call — each returns the original escalation unchanged, annotated
 with what happened. The annotation is the point on the failing arm:
 WORK_PRESERVE_FAILED tells the operator disposing this escalation that the
 worktree IS the only copy.

 NOT a substitute for 3f: this pushes the BRANCH only — no PR, no CI, no
 rebase, no closing-keyword scan. A pushed branch with no PR merges into
 nothing; it is a durable copy, not a landing.

 `branch` is the PLAN's `item.branch` (`<type>/<slug>`), NOT the worktree's
 throwaway local `build/<slug>` HEAD (worktree.sh's own header). It has to be:
 3f pushes via `pr.sh push <wt> <item.branch>`, which sends
 `$sha:refs/heads/$branch` — so preserving `HEAD` under its LOCAL name would
 mint a SECOND remote ref (`build/<slug>`) on every post-3f escalation
 (ci-failed, gate-fail, review-blocking), one that no PR watches and that
 neither `delete_branch_on_merge` nor prune-merged-branches.sh can ever
 reclaim. That is precisely the two-ref split pr.sh's PUSHED_UNWATCHED logic
 (temperloop#1688) exists to make visible. Pushing the ref 3f already owns
 makes the idempotency claim below TRUE of what the code does, and leaves the
 rescue copy on a ref a human already has a handle for.
```

## temperloop#2103 — THE REBASED-BRANCH-ALREADY-ON-ORIGIN ARM.
<a id="temperloop-2103-the-rebased-branch-already-on-origin-arm"></a>

```text
 temperloop#2103 — THE REBASED-BRANCH-ALREADY-ON-ORIGIN ARM.

 The plain push below is right on the ordinary path and CANNOT work on the
 one that produced this issue three times in a single session: a
 continuation round whose branch an EARLIER round already pushed, which
 3f-0a then rebased onto a newer origin/<default>. The rewritten history
 does not contain the remote tip, so a plain push is a non-fast-forward by
 construction — not a transient — and the seam whose entire job is to make
 the work durable reported WORK_PRESERVE_FAILED over four commits that
 existed nowhere else.

 Three properties the arm below holds to, in this order:

   1. READ THE REMOTE VALUE FIRST. Nothing here ever issues a bare
      `--force`. The retry is `--force-with-lease=refs/heads/$branch:$sha`
      against the value `git ls-remote` just returned, so a concurrent
      writer that moved the ref in between gets a REJECTION, not a silent
      overwrite. An unreadable remote means no force at all.
   2. ONLY OVER WORK THE LOCAL HISTORY SUPERSEDES. This path runs
      unattended on an already-failing item and nobody ASKED it to rewrite
      anything (unlike 3f, which force-requests the rebase it just
      performed). So the force is gated on the operator's own manual
      recovery criterion from the issue — "after confirming the local
      history superseded the remote tip": every commit reachable from the
      remote tip but not from HEAD must have a patch-equivalent in HEAD
      (`rev-list --cherry-pick --right-only`, `git cherry`'s own test).
      Zero such commits ⇒ the remote holds a stale pre-rebase copy of
      exactly this work ⇒ overwriting it destroys nothing. Otherwise the
      remote carries commits this worktree does not, and the arm REFUSES
      and says so — a loud WORK_PRESERVE_FAILED naming the remote sha is
      recoverable; destroying someone else's commits is not.
   3. `preserved` IS READ BACK FROM ORIGIN, NEVER INFERRED FROM AN EXIT
      CODE. The third occurrence recorded the exact reason: a push from
      the same run HAD landed a pre-rebase state on origin while the field
      read false, so "the branch exists on origin" overstated and
      `preserved:false` understated. The final `ls-remote` below decides
      the outcome by comparing the remote value to this worktree's HEAD,
      and BOTH shas ride the record, so neither signal has to be trusted
      alone.

 Idempotent, and TRULY so: this pushes the same `refs/heads/$branch` 3f
 pushes, so when 3f already pushed this sha git reports "Everything
 up-to-date" and exits 0 — a post-3f escalation (a CI failure, say) costs
 one no-op push and reports WORK_PRESERVED truthfully, minting no second
 ref. No `-u`: this is a one-shot rescue push and has no business writing
 branch.<name>.remote/.merge into the worktree's config.

 Still no jq (the fail-soft argument above): every value interpolated into
 the JSON below is either the plan's validated `branch:`, a literal, or a
 40-hex sha normalized through the `case` guard before it is read.
```

## Session-quota death classification (temperloop#1819).
<a id="session-quota-death-classification-temperloop-1819"></a>

```text
 -----------------------------------------------------------------------------
 Session-quota death classification (temperloop#1819).
 -----------------------------------------------------------------------------
 A step or worker that dies because the SESSION hit its usage limit ("You've
 hit your session limit · resets 5:30pm") used to collapse into the two
 pre-existing kinds — `machinery-denied`/SPINE_DENIED (whose documented cure
 is rewriting the command for the auto-mode classifier) and `worker-error`
 "agent returned null" (whose cure is re-driving with sharper instructions).
 BOTH cures are wrong for a quota death: the command was never the problem
 and the work is usually INTACT in the worktree (the #1819 incident's item
 held three clean commits and a finished verification surface — re-driving
 would have discarded a finished item). So a quota death gets its OWN kind,
 `quota-exhausted`, whose disposition is wait-for-reset then RESUME.

 The death reaches this script through TWO shapes, classified differently:
   • agent() THREW and the error text carries the harness's limit message —
     quotaDeath(text) matches it directly and extracts the reset time.
   • agent() returned a bare NULL (the #1819 incident's shape) — no text
     reaches this script at all (the truth lives only in the harness's own
     <failures> block, a channel the orchestrator reads, not this script).
     The one in-process discriminator left is BEHAVIORAL: a classifier
     denial is per-command (an innocuous probe still spawns), while a quota
     death kills EVERY spawn. harnessCanSpawnAgents() runs that probe — a
     cheap canary agent, re-run per bare-null with only its DEAD verdict
     memoized (see its own comment) — and a failed canary reclassifies the
     null as quota-exhausted. A canary that spawns fine leaves the pre-#1819
     kinds untouched, so genuine denials/skips keep their meanings.
```

## reviewDiffCmd — ONE solo runMachinery call that reads the two raw inpu
<a id="reviewdiffcmd-one-solo-runmachinery-call-that-reads-the-two-"></a>

```text
 reviewDiffCmd — ONE solo runMachinery call that reads the two raw inputs the
 routing DECISION needs off the worktree: the changed-file list (relative to
 the fresh origin/<default>, three-dot so only THIS branch's own commits
 count) and the raw reviewer-routing.tsv text (empty string when the
 worktree ships none — a consuming repo that has not vendored it). Mirrors
 pr.sh's own `default_branch()` fallback chain (origin/HEAD, else
 main/master) so this never depends on pr.sh being invoked first.

 temperloop#1976: alongside `tsv` this also emits `tsv_rows` (count of
 non-blank, non-`#` lines — the SAME first-stage filter parseTsvRows()
 applies before its column check), computed HERE off the worktree's own
 file, independently of whatever the machinery-executor relay hands back
 for `tsv` itself. That independence is the whole point: the relay is a
 separate agent copying this step's JSON line, and it has been observed
 dropping the (large) `tsv` field entirely while leaving `files` intact
 (evidence: wf_cbc556f5-7be). `tsv_rows` gives runReviewers() a cheap
 row-count check that the `tsv` it received is the SAME one this command
 actually read, without re-reading the file itself — a ROW-COUNT check
 only: it catches a dropped or truncated table (a row-count mismatch), not
 a same-length garble (content corrupted without changing the row count).

 temperloop#1982: this also emits `tsv_checksum` — a content checksum, not
 a row count. A prior attempt at a content check (`tsv_sha256`, temperloop
 #1976 round 1) was reverted as dead code: it hashed the SOURCE file but
 nothing could ever recompute a comparable hash from the RECEIVED `tsv`
 string, because SHA-256 needs a matching implementation on the JS side and
 none existed — "no hashing primitive" meant no SHA-256, not that no check
 is possible. `tsvChecksum()` below closes that gap with a checksum needing
 no primitive at all: a POSITION-WEIGHTED sum of character codes over the
 SAME row-count-filtered lines (temperloop#1982 round 2 — see tsvChecksum's
 own comment for why position-sensitivity, not just a sum, is the point),
 expressible in pure arithmetic on both sides — this bash pipeline (byte
 values via `od`, weighted and summed in awk) and tsvChecksum() (JS char
 codes, weighted and summed in a loop) are independent implementations of
 the identical algorithm, verified (by an automated test that executes
 THIS bash pipeline for real — test_workflow.sh, "bash/JS parity") to agree
 against this repo's own reviewer-routing.tsv (including its non-ASCII
 comment-header punctuation, which is excluded from the sum by the same
 comment/blank filter tsv_rows already applies). The two sides agree only
 while every DATA row stays pure ASCII (byte value == UTF-16 code unit) —
 see reviewer-routing.tsv's own header for that constraint, which governs
 data rows only; the comment header's non-ASCII punctuation is filtered out
 before either side sums, so it never touches this. A worktree that
 genuinely ships no tsv
 emits `tsv:""`, `tsv_rows:0`, `tsv_checksum:0` — never an omitted `tsv`
 key — so "missing" stays a signal of the relay dropping the field, not of
 a legitimate no-tsv worktree.

 temperloop#1970: it ALSO reads — and, on a bumping call, increments — the
 per-worktree §3e ROUND COUNTER the REVIEW_BLOCKING convergence bound reads.
 `review_rounds` is the PRE-increment value: how many review rounds this
 worktree had already run before this one. Three properties are load-bearing:
   - it lives in the worktree's GIT DIR (`git rev-parse --git-dir`, which for a
     linked worktree is that worktree's own `…/.git/worktrees/<name>`), NEVER
     in the working tree — a stray untracked file there would surface in
     `git status`, in the 3e.5 gate's `--scoped` untracked-path resolution, and
     in the tracked-path coverage manifests. It is removed with the worktree.
   - it rides THIS call, which §3e already makes — zero extra agent spawns, and
     the counter survives the escalate → orchestrator → re-invoke loop it
     bounds (a continuation skips 3b, so the worktree and its git dir persist).
   - `bump` is false on the #1976 tsv-gap RE-FETCH, so one driver round bumps
     the counter exactly once no matter how many times the command runs.
 Every step fails SOFT (a missing/unwritable marker reads 0, and a
 corrupted-but-present one degrades to 0 rather than aborting the step), so a
 worktree whose git dir cannot be resolved simply behaves as it did before
 this item.
```
