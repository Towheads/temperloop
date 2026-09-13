---
description: Standalone frontier-round interview — turn a topic, a knowledge-store pointer, or an issue number into a `## Shared understanding` section (the problem in the operator's words, facts the facilitator found itself, numbered decisions, deferrals, risks) by asking the design tree's whole frontier each round through `AskUserQuestion` calls of at most four questions, recommended option first, facts looked up rather than asked. `/workshop` runs it inline as Phase 1; usable by hand on a plan, a decision, or a bug description with no brief behind it. Operator-present only — no unattended arm.
argument-hint: "<topic | <pointer-note> | <issue#>> [--into <note>] [--first-question <block>] [--check-questions <block>]"
---

You are running the **interview** command. Goal: build a shared
understanding of a piece of work *by asking the operator the decisions and
looking up the facts yourself* — the inverse of drafting a document and
asking the operator to audit it. The design is a **decision tree**: the
outcome at the root, every decision that hangs off it as a node. Each round
asks the tree's **frontier** — every decision whose prerequisites are
settled — in one or more `AskUserQuestion` calls, records the answers in
the operator's own words, recomputes the frontier, and opens the next round
in the same turn. When the frontier is empty, the operator confirms the
understanding once and the command returns the note it wrote.

The shape comes from the ratified brief behind temperloop#1938 (dimension 5)
and the "grilling" pattern it adopted: frontier rounds, facts-not-questions,
recommended option first. The measured reason it exists: the coverage walk
it replaces took 26 modal stops on one brief, 10 of them acknowledgement-
only, with about a minute of dead time between each; the prototype of this
shape took 5 calls, 0 acknowledgement-only, on the same day.

`/workshop` Phase 1 is this command executed inline against a `Designs/`
brief (see § Invocation contract); a hand-run lands the same section in a
`Context/` note with no brief created around it.

## Inputs

- `$1` (required) — the thing to interview about, one of:
  - a **topic** — a one-line statement in the operator's words;
  - a **knowledge-store pointer** — a note path such as `Context/…`,
    `Plans/…`, or `Issues/…`, read in full as the seed;
  - an **issue number** — `#N` or `N` on the local repo's tracker, read via
    `gh issue view N --json title,body` (when `gh` is unavailable, ask the
    operator to paste the issue text in place of it — never proceed on the
    number alone).
  If `$1` is omitted, ask the operator to state the topic live at Step 1;
  there is no non-interactive path into this command.

## Parameters

Three named parameters, and only these three — a caller executing this spec
inline passes them as a parameter block (§ Invocation contract). Their names
are a frozen surface (`claude/presentation-plane.md` § Kernel table): a
caller's prose and this spec's prose are the only two sides of the "call",
so a renamed flag desyncs them with no runtime error to catch it.

- **`--into <note>`** — the knowledge-store note the `## Shared
  understanding` section is written to. Default: `Context/<repo> -
  <topic>.md`, where `<repo>` is the local repo's name and `<topic>` is the
  seed's short title (an issue's title, a pointer note's title, or the topic
  line trimmed to a filename). An existing note is **adopted**: the section
  is inserted under the title, before the first `## ` heading, or replaced
  in place if one is already there. A missing note is created only in the
  default `Context/` shape (Step 1.5); a caller that wants a differently
  shaped note (a `Designs/` brief with its own frontmatter) creates it
  first and passes it here.
- **`--first-question <block>`** — a caller-supplied question asked as
  **Q1 of round 1**, ahead of the frontier's own questions and inside the
  same call. The block is a fully formed question: text, two to four
  options with the recommended one first, and optionally, per option, a
  `then:` action the *caller* performs on return (e.g. `/workshop`'s
  premise gate names `drop` as a terminating answer). The interview asks
  and records it exactly like any other question (it becomes `D1`); when
  the chosen option carries a terminating `then:`, the interview persists
  that one decision and returns immediately — the caller runs the action.
- **`--check-questions <block>`** — up to **three** caller questions
  appended to the understanding-check call (Step 3) after the interview's
  own question, so the whole check stays one call of at most four. Each is
  a fully formed question in the same shape. Their answers are recorded in
  the call's working-notes entry and returned to the caller verbatim; the
  caller decides what they mean (`/workshop` uses them for the review
  tier).

Absent parameters take their defaults; a parameter this spec does not name
is an error to surface, not to guess at.

## Invocation contract

A caller executes this spec **inline, in the same session** — it reads <!-- cite: I.1 class:interview-context-lost-to-subagent -->
`claude/commands/interview.md` and runs its steps with the parameter block
in hand, exactly as an operator typing `/interview` would. **Never as a
subagent.** The caller's context *is* the interview's context: the seed it
already read, the terminology it already resolved, the operator it is
already talking to. A subagent would re-read all of it, could not open
`AskUserQuestion` against the operator's live turn, and would hand back a
summary in its own words — the drafting-then-auditing inversion this
command exists to remove. When the interview "returns" (Step 4), the caller
simply continues at its own next step holding the note path, the tally,
and the check-question answers.

## Operating principles

- **Operator-present only — no unattended arm.** Every ask is a direct, <!-- cite: I.2 incident:K#1938 -->
  interactive `AskUserQuestion`; there is no `--unattended` flag, no
  deferred-variant question, no poll. If `AskUserQuestion` is unavailable
  (a headless or `-p` run), stop at Step 0 with one line saying so.
- **Facts are found, never asked.** A fact reachable by reading the <!-- cite: I.3 class:operator-asked-for-readable-facts -->
  codebase, a config file, the tracker, or the knowledge store is a probe
  (Step 2.2), not a question. A question spends the operator's attention on
  a *decision*; spending it on a lookup the facilitator could have done is
  the cheapest way to make the interview feel like an audit.
- **No acknowledgement-only question.** Every question offers a real <!-- cite: I.4 incident:K#1938 -->
  choice: at least two options, or a free-text ask. A question with fewer
  than two options and no free-text ask is acknowledgement-only, and the
  tally (Step 4) classifies it mechanically from the persisted call entry —
  the count is reported and expected to be zero. "Confirm you read this"
  is not a question shape this command has.
- **No dead time.** The next call opens in the *same facilitator turn* as <!-- cite: I.5 incident:K#1938 -->
  the previous answer, unless a fact probe the next questions depend on is
  still running. Persisting happens per round, not per question, so the
  write never sits between two calls of one round. This is a constraint on
  empty calls and idle gaps, deliberately **not a cap on the number of
  calls** — more rounds mean more refinement, and the operator's own words
  on the baseline brief were that more calls is a sign of more context
  being provided.
- **Persist before you ask, and prove the persist.** A `round N pending:` <!-- cite: I.6 incident:K#670 -->
  line naming the call's questions is written before every call, and every
  round's results are written as a full-file rewrite followed by a
  read-back (Step 2.6). A write's OK return is not proof it landed; a
  crashed round must be locatable from the note alone (§ Resume). One
  retry policy covers every note write in this spec: a read-back mismatch
  is retried once, and a second mismatch stops the interview with a
  one-line error naming the note — never continue asking over a write the
  note does not carry.
- **The operator's words are the record.** A decision the operator gave in
  their own words (via `Other`) is quoted verbatim in its `D<n>` line and
  its `interview` record line, never paraphrased. Where the operator picked
  an option, the option's text is the decision.
- **Plain language inside the question block.** Every question carries <!-- cite: I.7 incident:K#923 -->
  the context needed to answer it *inside* the `AskUserQuestion` block —
  the decision in plain terms, why it matters, and what each option
  forecloses — never only in chat prose above it, and never as a step
  number, slug, or schema section name left for the operator to decode.
  This is the **Decision presentation** template's plain-language rule
  applied to a batched question; the block is a **Question block**
  template instance whose Context slot is that presentation.
- **The section shape belongs to `claude/design-schema.md`.** What a
  `## Shared understanding` section contains, and the `interview`-kind
  stop-line grammar, are that file's § Shared understanding and
  § Challenge record — this spec writes them, it never restates them.

## Step 0 — Validate

Run in parallel; the first two are fatal, the rest degrade legibly:

1. **Knowledge store reachable.** Resolve the store per
   `workflows/scripts/lib/knowledge_store.contract.md` (a plain-files
   checkout: `KNOWLEDGE_STORE_ROOT` resolves; an Obsidian-backed one: the
   agent-plane tools are loaded). No store → stop with one line; there is
   no interview without a note to write.
2. **`AskUserQuestion` available.** A run that cannot open a blocking
   question to a live operator stops here: "operator-present only — no
   unattended arm."
3. **Config sourced best-effort.**
   `source workflows/scripts/build/build.config.sh 2>/dev/null || true` —
   the one place the fact-probe tier's default lives. From here on the
   spec names that tier only as `$INTERVIEW_PROBE_MODEL`, never a literal <!-- cite: I.8 guard:workflows/scripts/build/build.config.sh -->
   (`claude/CLAUDE.kernel.md` § Named-setting convention). In a consuming
   checkout that does not vendor the config file, `${INTERVIEW_PROBE_MODEL:-}`
   is empty: probes then run at the session tier, and the run says so on
   one line at the first probe rather than silently.
4. **`gh` (best-effort — needed only for an issue-number seed).**
   `gh auth status`; on failure with an issue-number `$1`, ask the operator
   to paste the issue text (§ Inputs). A topic or pointer seed never needs
   `gh`.
5. **Repo name.** `basename "$(git rev-parse --show-toplevel)"`, used for
   the default note name; outside a git repo, ask the operator for the
   `<repo>` prefix rather than inventing one.

## Step 1 — Intake

1. **Read the seed.** The topic line, the pointer note in full, or the
   issue's title and body — and for an issue, treat a non-zero exit or an
   empty body from `gh issue view` (a mistyped number, a deleted issue, a
   repo the token cannot see) exactly like an unavailable `gh`: ask the
   operator to paste the issue text, never proceed on the number alone.
   Read the project's instruction files
   (`CLAUDE.md`, `AGENTS.md` where present) for terminology, so questions
   use the repo's own names for things.
2. **Triviality bar.** A one-line fix, a typo, a comment, or a mechanical
   config tweak gets **no interview**: say in one line that the seed is
   below the bar and stop, writing nothing. The bar is the same one
   `claude/CLAUDE.kernel.md` § Plan-first default uses for skipping a plan;
   an interview over a trivial change costs the operator a round for
   nothing it would not have known already.
3. **The problem in the operator's words.** Quote the seed's own framing of
   the problem — the topic line, the issue's defect statement, the pointer
   note's own words. If the seed was written by the facilitator (a pointer
   note in Claude's words, say), the problem statement is the first
   frontier question of round 1, asked as a free-text ask, not restated
   from the note.
4. **Build the design tree.** From the seed, lay out the root decision and
   every decision that hangs off it, with the prerequisites each one has
   (a naming choice cannot be asked before the thing being named is
   decided). Keep the tree in working memory; it is what the frontier is
   computed from, and it grows as answers open new decisions. This is a
   facilitator judgment, not a template — the tree is as deep as the work,
   and a shallow seed yields a one-round interview.
5. **Create or adopt the note.** If the `--into` note (or the default)
   exists, adopt it (§ Parameters). Otherwise create `Context/<repo> -
   <topic>.md` with a minimal frontmatter (`tags: [context,
   project/<repo>]`, `date`, `source_kind: claude-stamped`, and the
   session/model provenance the kernel's note-provenance convention names
   when the session id is in context) and the empty `## Shared
   understanding` skeleton per `claude/design-schema.md` § Shared
   understanding, with `### Deferrals` reading `(none yet)`. **State the
   single-tenant caveat once, here, at this first write, and never again <!-- cite: I.9 class:cross-project-note-collision -->
   at later writes:** the store is one flat corpus per `$HOME`
   (`docs/features/knowledge-store.md` § Limitations) — the default name
   is repo-prefixed so two repos sharing one store do not overwrite each
   other's `<topic>` note, and a search run while working in another
   project can still surface this one; an operator working across
   confidential engagements picks a separate store per that section's
   options before continuing.

## Step 2 — Frontier rounds

Repeat until the frontier is empty. `N` counts rounds from 1; `D<n>`
numbers decisions sequentially across the whole interview and never
restarts or renumbers.

1. **Compute the frontier.** Every decision in the tree whose
   prerequisites are all settled and which is not yet decided. Round 1's
   frontier is the root-level set; when `--first-question` was passed, its
   block is Q1 ahead of them. A frontier larger than four spans consecutive
   calls **within the same round** — the calls are numbered, the round is
   one persist.
2. **Facts go to a probe, downstream questions wait.** For each frontier
   decision, ask: does composing a fair recommendation need a fact from the
   environment (which files exist, what a script's flags are, what a
   config defaults to, what the tracker says)? If so, dispatch a **fresh,
   explicitly read-only subagent** (`Explore` or `general-purpose`) at
   `$INTERVIEW_PROBE_MODEL` with a return-findings-only prompt — never a
   context-inheriting fork, which would carry this whole spec and may act
   on it. A question whose recommendation depends on a running probe
   **waits for it**; every other frontier question is asked now. A probe
   that returns while a call is open feeds the next call or round. Facts
   found land in `### Facts found (facilitator, not asked)` at the round's
   persist. With no subagent available, do the lookup inline at the
   session tier and say so once — the fact is still found, not asked.
3. **Compose the questions.** One `AskUserQuestion` question per frontier
   decision, at most four per call, each carrying inside its own block:
   - the decision in plain terms and why it matters now;
   - **two to four options, the recommended one first and labelled
     `(Recommended)`**, each option's description stating what choosing it
     commits to or forecloses — the recommendation's reasoning and the
     alternatives' losing reasons are the option descriptions, so the
     block is the **Decision presentation** template's five parts
     compressed into one question;
   - the harness's free-text `Other` slot, which carries the operator's own
     words — when the harness offers none, add an explicit `Other — in my
     own words` option so a free-text answer is always reachable;
   - a free-text ask (a question with no options, answered in prose) only
     where the honest option set is genuinely open — the problem statement
     of a facilitator-written seed, a name the operator alone can supply.
   Group related decisions into one call where they fit; never split one
   decision across calls.
4. **Persist `round N pending:` before the call.** Under `## Working notes`
   → `### Interview calls`, write one line naming the round, the call
   number, and each question's text — `round N pending: call k — Q1
   "<text>"; Q2 "<text>"; …` — and persist it (a full-file rewrite via
   `ks_write` on the plain-files backend, the vault's write-small append
   on an Obsidian-backed one, both followed by a read-back under the
   retry-once policy in § Operating principles). Only then open the call.
   A crash between the write and the answer leaves a note that says
   exactly which questions were in flight (§ Resume).
5. **Ask.** Open the `AskUserQuestion` call. When the frontier needs
   another call in this round, open it in the same turn as soon as the
   previous one returns — no chat prose, no persist, between them.
6. **Record and persist the round — full-file rewrite + read-back.** With
   the round's answers in hand, rewrite the note in one write carrying:
   - one `D<n>` bullet per answered question under `### Decisions — round
     N (<date>)`: `D<n> **<short title>.** <the chosen option's text, or
     the operator's verbatim words quoted when they used Other>`; a
     decision that supersedes an earlier one keeps both numbers and states
     the supersession inline (`D4 … — superseded by D11`);
   - any new facts under `### Facts found (facilitator, not asked)`;
   - any deferral the operator chose (`Other: "later"` on a decision, or
     an option that explicitly defers) under `### Deferrals`, each with
     the tracking ref it names — `(none yet)` stays until the first one;
   - any risk the answers surfaced under `### Risks` as `R<n>`, premortem-
     framed with its kill condition inline;
   - the round's `### Interview record` line: `round N: D<a>–D<b>
     [interview] operator: <k> asked, <k> answered<, notes>` (the notes
     name decisions taken against the recommendation and any operator-
     edited answer);
   - the `interview`-kind stop lines under `## Working notes` →
     `### Challenge record`, one per decision (clustered where the verdict
     is identical), `source` always the literal `operator`: a recommended
     option chosen is `accepted`; a non-recommended option chosen is
     `challenged → revised ×1`; an `Other` answer is `operator-edited —
     response: "<verbatim>"`. When this round writes the record's first
     stop line, the `challenge-record-start: <date>` marker is written in
     the **same** write, never ahead of it (`claude/design-schema.md`
     § Challenge record);
   - the call entries replacing the `round N pending:` line under
     `### Interview calls` (§ Output).
   Then **read the note back** and confirm the round's `D<n>` lines and
   call entries are present, under the retry-once policy in § Operating
   principles.
7. **Recompute and continue.** Answers settle prerequisites and may add
   nodes (an `Other` answer often opens a decision the tree did not have).
   Recompute the frontier; if it is non-empty, round `N+1` opens **in this
   same turn** (back to 2.1). If it is empty, go to Step 3.

## Step 3 — Understanding check

1. **Render the whole `## Shared understanding` section in chat**, as it
   stands in the note — problem, facts, every `D<n>`, deferrals, risks,
   the interview record — so the operator confirms the text itself, not a
   gist of it.
2. **One call, at most four questions.** Q1 is the interview's own:
   *"Is this the shared understanding?"* with options `Understood
   (Recommended)` and `One fix — I will say what` (the fix arrives via
   `Other`, in the operator's words). The `--check-questions` block's
   questions (at most three) follow in the same call; their answers are
   recorded in the call entry and returned to the caller. Persist a `round
   N pending:` line for this call like any other (2.4).
3. **`One fix` reopens a round.** The fix is recorded as a new decision
   (`D<n>`, verbatim), superseding whichever it changes; if it opens new
   frontier, Step 2 runs again for it; then the check re-renders and
   re-asks (2 above). `Understood` records the check's call entry, writes
   the final `### Interview record` line for the check round, persists
   with read-back, and returns.

## Step 4 — Return

Return to the caller (or, on a hand-run, end) with:

- the note path;
- the `--first-question` answer and the `--check-questions` answers,
  verbatim;
- the **run tally**, computed from the persisted call entries, never from
  memory: calls; questions; decisions taken against the recommendation;
  verbatim (`Other`) responses; **acknowledgement-only calls (must be
  zero)** — a question with fewer than two options and no free-text ask;
  per-call timestamps, from which the chunk-accept latency (the gap
  between one call's timestamp and the next) and the wall-clock from the
  first question to `Understood` are read.

On a hand-run, print the tally under a one-line completion summary
(`claude/CLAUDE.kernel.md` § Communication conventions) with the note path
in full. A caller folds the tally into its own summary (`/workshop` Step 6).

## Output

Two surfaces, both in the note named by `--into`:

1. **`## Shared understanding`** — the shape is owned by
   `claude/design-schema.md` § Shared understanding (problem in the
   operator's words; facts found; `### Decisions — round <n> (<date>)`
   with `D<n>` bullets; deferrals; risks; `### Interview record`) and its
   § Challenge record `interview`-kind lines under `## Working notes`.
   Written per round, never as one end-of-interview dump. In a `Designs/`
   brief those record lines are what `validate-design-brief.sh`'s
   completeness check reads; in a standalone `Context/` note the same
   lines are written with no validator over them — one writer, one shape.
2. **Per-call working-notes entries** under `## Working notes` →
   `### Interview calls` — the interview's own record, from which Step 4's
   tally is computed. One entry per `AskUserQuestion` call:

   ```
   ### Interview calls
   - call 1 · round 1 · 2026-09-12T18:04:11Z · 4 questions
     - Q1 "<question text>" · options: 3 · recommended: yes
     - Q2 "<question text>" · options: 2 · recommended: yes
     - Q3 "<question text>" · options: 0 · free-text ask
     - Q4 "<question text>" · options: 4 · recommended: yes · answered via Other
   - call 2 · round 2 · 2026-09-12T18:09:40Z · 2 questions
     …
   - call 4 · understanding check · 2026-09-12T18:21:02Z · 3 questions
   ```

   Each question line carries its text, its option count, and whether a
   recommended option was marked (or `free-text ask`); an `Other` answer is
   flagged. Timestamps are ISO-8601 UTC — a stored record, not a display
   (`claude/CLAUDE.kernel.md` § Communication conventions' store-in-UTC
   carve-out). A `round N pending:` line lives in this same subsection
   between its write and the round's persist, and is gone once the call
   entries replace it.

## Resume

Re-running `/interview` against a note that already carries a
`## Shared understanding` section adopts it and reads its state from the
note alone:

- a **`round N pending:` line present** means round `N`'s call was opened
  but its answers were never persisted (a crash or an aborted turn): tell
  the operator it is a re-ask after an interrupted round, re-ask exactly
  the questions the line names, and continue from 2.6. Answers not in the
  note were never recorded; re-asking is the honest recovery, not a
  duplicate;
- **no pending line and a non-empty frontier** (decisions the tree needs
  that no `D<n>` settles): continue at 2.1 with round `N+1`, where `N` is
  the last round the interview record names;
- **no pending line, an empty frontier, and the last `### Interview
  record` line is an ordinary round** (not the check): the rounds finished
  but the check never opened — a crash in the window between 2.7's empty
  frontier and 3.2's pending-line write, which persists nothing in
  between; go straight to Step 3.1;
- **no pending line and the last `### Interview record` line is the
  understanding check**: the interview is complete; say so and return
  (Step 4) without asking anything.

## Failure modes

Every external call has a named failure path; none is silent:

- **Knowledge store unreachable** → stop at Step 0 (no note, no
  interview). **Note write fails or read-back mismatches twice** → stop
  with the note path and the round in flight; the `round N pending:` line
  (if the pending write itself landed) is the resume point.
- **`AskUserQuestion` unavailable** → stop at Step 0: operator-present
  only.
- **`build.config.sh` absent** → continue; probes run at the session tier,
  stated once at the first probe.
- **No subagent available for a probe** → look the fact up inline, stated
  once; the fact is still found rather than asked.
- **`gh` unavailable with an issue-number seed, or `gh issue view` exits
  non-zero or returns an empty body** → ask the operator to paste the
  issue text; never interview over a bare number.
- **Probe returns nothing usable** → the affected question is asked with
  the gap stated inside its block ("I could not confirm X; the options
  assume Y"), so the operator answers knowing what was not found — never
  asked as if the fact were known, and never silently dropped from the
  frontier.
