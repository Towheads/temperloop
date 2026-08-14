---
tags: [plan, project/temperloop]
date: 2026-08-14
source_kind: claude-stamped
source_session: 7369a4fe
source_model: "claude-opus-5[1m]"
last_verified: 2026-08-14
epic: 1415
sources:
  - "#1415"
  - "#1318"
  - "#1326"
  - "#1343"
status: done
---

# temperloop - gate suite coverage and cost

## Problem

The quality-gate suite is itself under-built. Two whole defect classes ship because no gate looks for them — Python has no linter at all while shell gets a pinned shellcheck, and a script can lose its executable bit and stay green forever because every gate invokes scripts as `bash <path>`. A third gate's cost grows without bound on developers' machines: it starts one `python3` process per record against a lake nothing prunes, so it gets slower every week for whoever runs it locally, and only for them.

## Summary

- **A language the gate suite does not look at**
  - **L0** — Decide whether Python is gated or deliberately un-gated, on a measured count of what a linter would actually flag across the 26 tracked files (#1318)
- **A defect class invisible to every gate**
  - **L1** — Add a gate for the dropped executable bit, keyed to a registry rather than a rule that fires on 96 files (#1326)
- **A gate whose cost grows without bound**
  - **L1** — Batch the model-usage validator so its process starts are constant rather than one per record (#1343)

Build order: L0 first → L1 last; items in the same level ship together.

## Sequencing notes

- **The spike sits alone in L0, and this costs nothing.** I initially drafted all three at L0 on the reasoning that the spike's verdict cannot reshape the other two — different subsystems entirely — and that isolating it would over-serialize two independent builds for no benefit. **That reasoning was wrong**, and the requirements audit corrected it: `/build`'s speculative-execution rule starts a level-*k+1* item immediately, in parallel, when it carries no `depends-on` and no unsatisfied `after:`. Both L1 items qualify, so they begin at once regardless of the level label. Isolating the spike therefore buys the rule's guarantee at zero wall-clock cost, and a spike-only level needs no merge gate.
- **The two L1 items are genuinely independent** — disjoint file sets, different subsystems, no shared surface. Verified.
- **#1343's fix lands on a file this session already changed twice tonight** (`validate-model-usage-emit.sh` — the scoped `exec` redirect and the POSIX-mode guard). Build against merged `main`, not against the issue's line numbers, which predate both.

## Re-triage signals

- **A live instance of #1326 exists, and this session created it.** Of the 16 `validate-*.sh` scripts, 15 are `100755`; exactly one is `100644` — `workflows/scripts/validate-check-surface-degenerate-coverage.sh`, added in `abeaedd` a few hours ago as epic #1409's deliverable, the gate built to require every check surface to prove it can fail. It shipped without its executable bit and no gate caught it. **Nuance worth stating rather than dramatising:** it is invoked as `bash workflows/scripts/validate-check-surface-degenerate-coverage.sh` (`scripts/quality-gates.sh:721`), so nothing is broken today — which is precisely #1326's thesis, that the bit is invisible to CI and can therefore drift indefinitely. It is folded into the L1 item as its discrimination case, not filed separately.
- **#1343's body carries a non-defect observation that deserved its own home.** Because the lake is gitignored, the validator's content-level checks never execute in CI — only its presence-lint and legal-empty early return do. Its author flagged this explicitly as *"NOT a defect"* and *"probably intended"*, but the current state is neither documented nor decided. Filed as **temperloop#1511** on the audit's recommendation, rather than folded into the L1 build item's technical acceptance or left as prose.
- **#1318 carried no `spike` label** despite its body posing an explicit two-defensible-answers policy question. The plan item's `kind: spike` was therefore a manual override of the mechanical prefill, which a future regeneration would silently flip back to `kind: code`. The label has been added to the issue so board and plan agree.

## Items

- [v] **Decide whether Python is gated, on measured evidence** `slug: python-gate-decision` — Run a linter across the 26 tracked Python files, report what it actually flags, and recommend either adoption with a baseline or a recorded accepted gap.
  - branch: `chore/python-gate-decision`
  - size: M
  - kind: spike
  - gh_issue: 1318
  - source: #1318
  - files: `scripts/quality-gates.sh`, `workflows/scripts/docs/`, `workflows/scripts/drain/`
  - acceptance:
    - A `Decisions/` note reports a **measured** finding count from running a linter (ruff, and mypy if it is weighed) across all 26 tracked `.py` files, broken down by rule category — not an estimate. A count that cannot be produced is reported as unproduced with the reason, never guessed.
    - The note states what a day-one baseline or ignore file would have to suppress, concretely: which rules, how many findings each. This is the number that decides whether adoption is cheap or a standing tax.
    - It recommends **adopt-with-baseline** or **accepted-gap**, citing kernel engineering principles 5 and 7 by name. **Accepted-gap is a legitimate verdict** — the issue itself says either is defensible and that the fault is the question being unexamined, not unanswered a particular way.
    - It states explicitly whether the recommended mechanism can report success when it did not evaluate — the bar epic #1409 was built on. A linter that silently skips a file it cannot parse is that failure.
    - A follow-up issue is routed for whatever the verdict does not cover, **including** the accepted-gap case, which needs the gap recorded where a future reader will find it rather than left implicit.
  - notes: The asymmetry is the point the issue makes: shell gets a *pinned* shellcheck gate specifically so CI and local agree, and every shell file is swept; Python gets no lint, no type check, no import-time check, and the `.py` files that are tested at all are tested through hand-written `.sh` harnesses. Verified at assess time: **26** tracked `.py` files (the issue said 22 — it grew), **zero** linter config anywhere in the tree, **zero** ruff/mypy/pylint/flake8 references in `scripts/quality-gates.sh`. Weigh the noise honestly: an hour before this plan was written, a sibling spike measured two candidate detection shapes at 88% and 97% false positives and rejected both as blocking gates on that evidence. The same discipline applies here — a linter that flags 400 findings on day one is a different proposition from one that flags 12.

- [x] **Gate the dropped executable bit, keyed to a registry** `slug: exec-bit-gate` — Add a gate that catches a script losing its executable bit, using a registry of files that must be executable rather than a rule that fires on 96 files.
  - branch: `feat/exec-bit-gate`
  - size: M
  - kind: code
  - model: sonnet
  - after: python-gate-decision
  - gh_issue: 1326
  - source: #1326
  - files: `workflows/scripts/`, `scripts/quality-gates.sh`, `workflows/scripts/config/`, `workflows/scripts/tests/`
  - activation:
    - class: A
    - proof: "grep -qE 'exec-bit|exec_bit|file-mode' scripts/quality-gates.sh"
  - acceptance:
    - A gate fails when a file registered as requiring the executable bit does not have it, naming the file and its actual mode — never a bare non-zero.
    - **The rule is registry-keyed, not shebang-keyed.** The issue proposes flagging any tracked `.sh`/`.py` carrying a shebang whose mode is not 755; measured against the tree that fires on **96 files**, of which the audit classified ~35 sourced libraries, 58 test harnesses, 2 config files, and 15 others — with exactly **one** a genuine defect. A one-in-96 signal is not a gate. Follow the shape temperloop#1476 merged earlier today: an explicit registry plus a grandfather allowlist that may only shrink, so the debt is visible and payable rather than blocking unrelated work.
    - **Discrimination is demonstrated on the live instance:** `workflows/scripts/validate-check-surface-degenerate-coverage.sh` is `100644` while all 15 of its `validate-*.sh` siblings are `100755`. Restore its bit, and show the gate red before and green after. Note honestly that nothing is broken today — it is invoked as `bash <path>` — which is the invisibility the issue is about, not a live breakage.
    - The gate does not report success when it could not evaluate: an absent, unreadable or empty registry fails, rather than passing with nothing checked. `workflows/scripts/lib/cannot-evaluate.sh` exists for this.
    - `scripts/quality-gates.sh` (note `scripts/`, not `workflows/scripts/`) runs clean.
  - notes: The issue is explicit that this cannot be a blanket rule — `model-comparison/allowlist.sh` is correctly `100644` as a sourced library, matching `board/lib/board.sh` — and names an explicit manifest column as one option. The measurement above says the manifest option is the one that survives contact with the tree. Both files the issue originally cited as instances are `100755` today; they were fixed by hand. So this item is about the missing gate, and its only live instance is the one this session's own earlier work introduced.
  - pr: 1521

- [x] **Make the model-usage validator's process starts constant** `slug: batch-model-usage-validation` — Replace one `python3` process per record with a single batched invocation, so a growing local lake stops making the gate slower every week.
  - branch: `refactor/batch-model-usage-validation`
  - size: M
  - kind: code
  - model: sonnet
  - after: python-gate-decision
  - gh_issue: 1343
  - source: #1343
  - files: `workflows/scripts/validate-model-usage-emit.sh`, `workflows/scripts/tests/test_model_usage_emit.sh`
  - activation:
    - class: A
    - proof: "grep -q 'PYTHON3_CALLS' workflows/scripts/tests/test_model_usage_emit.sh"
  - acceptance:
    - **The proof is a process count, not a wall-clock number.** A test asserts the `python3` invocation count directly and requires it to stay flat between a 1-record and a 10,000-record lake. Wall-clock alone is gameable — a chunked-but-not-batched rewrite looks flat at small N — and this repo already has the convention of proving fork-count fixes by counting forks rather than timing them.
    - The synthetic lake used for the measurement is **10,000 records**, matching the scale the issue itself measured (~28ms/record, ~5 minutes added at 10k). A smaller N is permitted only if stated, with the reason.
    - Behaviour on every existing fixture is unchanged — the suite is the proof, and it must pass without modification to its assertions. A batching rewrite that requires loosening an existing assertion has changed behaviour, not just cost.
    - The degenerate-input cases the validator already covers still fail closed: absent, unreadable and empty input each still produce `CANNOT EVALUATE` and a non-zero exit. This is load-bearing — a batched rewrite that swallows a per-record parse failure into an aggregate pass would reintroduce epic #1409's exact defect on a file that already carries its fixtures.
    - `scripts/quality-gates.sh` runs clean.
  - notes: The O(n) shape is at `validate_record_py()` (~:269, spawning `python3` at ~:271), called inside a `while IFS= read -r line` loop nested in a `for f in ${files[@]}` loop. **Line numbers predate two changes this session merged tonight** — the scoped `exec` redirect and the POSIX-mode guard — so locate the code, do not trust the numbers. Bounded blast radius today: the lake is gitignored so CI always sees it empty and pays nothing; the entire cost falls on developers' local checkouts, where the lake grows monotonically and nothing prunes it. A retention window would also help but is the lesser half — the process-per-record cost is the dominant term. **Deliberately out of scope:** that the validator's content checks never run in CI at all, filed as temperloop#1511.
  - pr: 1522
