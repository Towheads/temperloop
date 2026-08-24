# macOS vs ubuntu CI: where the 1.4–2× actually goes

**Verdict: the gap is two independent multipliers, not "macOS is slower."**
macOS runs the gate suite on **3 workers to ubuntu's 4** (a 1.33× parallelism
handicap) and spends **1.36–1.71× more CPU-seconds** doing the same 180 gates.
Their product predicts the observed wall ratio to within 0.05× on every night
measured. The CPU half is **concentrated, not diffuse**: on 2026-08-24, 12 of
180 gates carried 73% of the 1036-second delta, 53 gates were second-for-second
identical, and 15 were *faster* on macOS.

**No reintroduction target is set here.** This is the measurement half of
[temperloop#968](https://github.com/Towheads/temperloop/issues/968) only. What
to do about the numbers — a target, restoring `macos-latest` to `ci.yml`'s
`checks` matrix, and the branch-protection `required_status_checks` PATCH that
must follow it — is deliberately left to the follow-up, because restoring the
matrix leg without the settings change produces a macOS run that *looks*
protected and is not.

Recompute every table below from the recorded data with
`make macos-gate-timing-report`. Nothing here is hand-typed: the numbers come
out of `docs/validation/data/macos-ci-gate-timing/`, and the script refuses to
print if any recorded file disagrees with the run-level totals its own run
reported.

## What was measured

`.github/workflows/nightly-macos.yml` runs `bash scripts/quality-gates.sh` on
`macos-latest` and — purely for this comparison — the identical script on
`ubuntu-latest`, in the **same workflow run, against the same commit**, both
with `QUALITY_GATES_STEP_SUMMARY=1`. Five nights were captured: 2026-08-12,
-13, -22, -23 and -24. The suite grew from 153 to 180 gates across that window,
which is why the run-level totals rise; the *ratios* are what carry across.

Runner images: `macos-26-arm64` (Apple silicon, Azure westus) and
`ubuntu-24.04` (Azure westus2), runner 2.336.0 on both.

## Run level

| Night | ubuntu wall | macOS wall | wall ratio | ubuntu gate-secs | macOS gate-secs | CPU ratio | workers u/m | macOS queue |
|:--|--:|--:|--:|--:|--:|--:|:--:|--:|
| 2026-08-12 | 248s | 475s | 1.92x | 957s | 1409s | 1.47x | 4/3 | 3s |
| 2026-08-13 | 240s | 474s | 1.98x | 931s | 1391s | 1.49x | 4/3 | **304s** |
| 2026-08-22 | 383s | 692s | 1.81x | 1514s | 2059s | 1.36x | 4/3 | 2s |
| 2026-08-23 | 377s | 751s | 1.99x | 1458s | 2224s | 1.53x | 4/3 | 3s |
| 2026-08-24 | 376s | 837s | 2.23x | 1461s | 2497s | 1.71x | 4/3 | 3s |

`gate-secs` is the sum of the per-gate wall times — what a *serial* run of the
same set costs — so it measures the work independently of how many workers ran
it. `wall` is the gate step's own clock. `queue` is runner-allocation wait,
which is **not** inside either.

**ubuntu is the tight leg**: 376–383s across the three 180-gate nights, and its
gate-seconds move by 4%. macOS moves by 21% (2059 → 2497s) over the same three
nights on the same gate set, with the same worker count. So the variance the
issue flagged is not queue time and not a fluctuating core allocation — it is
the gate execution itself, on a host whose throughput visibly changes night to
night.

## The delta is a product of two things

| Night | CPU ratio | worker ratio | product (predicted) | wall ratio (observed) |
|:--|--:|--:|--:|--:|
| 2026-08-12 | 1.47x | 1.33x | 1.96x | 1.92x |
| 2026-08-13 | 1.49x | 1.33x | 1.99x | 1.98x |
| 2026-08-22 | 1.36x | 1.33x | 1.81x | 1.81x |
| 2026-08-23 | 1.53x | 1.33x | 2.03x | 1.99x |
| 2026-08-24 | 1.71x | 1.33x | 2.28x | 2.23x |

Prediction tracks observation within 0.05× on all five nights. That is the
useful shape of the answer: **anything that fixes only one multiplier caps out
around 1.33× or around 1.4–1.7×, never at parity.**

## Where the CPU half lands — named gates, 2026-08-24

| macOS − ubuntu | ubuntu | macOS | ratio | share | Gate |
|--:|--:|--:|--:|--:|:--|
| +193s | 60s | 253s | 4.22x | 18.6% | `bash workflows/scripts/model-comparison/tests/test_score_gate_env.sh` |
| +134s | 127s | 261s | 2.06x | 12.9% | `bash workflows/scripts/model-comparison/tests/test_replay_batch.sh` |
| +127s | 122s | 249s | 2.04x | 12.3% | `make test-build` |
| +95s | 190s | 285s | 1.50x | 9.2% | `make test-cli-subcommands` |
| +45s | 81s | 126s | 1.56x | 4.3% | `bash workflows/scripts/tests/test_check_surface_degenerate_backfill.sh` |
| +38s | 25s | 63s | 2.52x | 3.7% | `make test-board` |
| +34s | 45s | 79s | 1.76x | 3.3% | `bash workflows/scripts/validate-mandatory-step-signal.sh` |
| +27s | 19s | 46s | 2.42x | 2.6% | `bash workflows/scripts/tests/test_validate_prose_budget.sh` |
| +19s | 21s | 40s | 1.90x | 1.8% | `bash workflows/scripts/model-comparison/tests/test_replay_score.sh` |
| +17s | 16s | 33s | 2.06x | 1.6% | `bash workflows/scripts/model-comparison/tests/test_judge.sh` |
| +16s | 12s | 28s | 2.33x | 1.5% | `make test-vault-hygiene` |
| +15s | 33s | 48s | 1.45x | 1.4% | `bash workflows/scripts/model-comparison/tests/test_comparison_report.sh` |

Total delta 1036s. **Top 12 gates: 760s, 73% of it.** 112 gates are slower on
macOS, **53 are identical**, and **15 are faster**.

Stable across all five nights (ubuntu→macOS seconds):

| Gate | 08-12 | 08-13 | 08-22 | 08-23 | 08-24 |
|:--|:-:|:-:|:-:|:-:|:-:|
| `test_score_gate_env.sh` | 41→118 | 39→112 | 60→223 | 57→229 | 60→253 |
| `test_replay_batch.sh` | 42→105 | 42→80 | 125→204 | 131→247 | 127→261 |
| `make test-build` | 97→139 | 94→134 | 120→154 | 122→172 | 122→249 |
| `make test-cli-subcommands` | 141→172 | 133→186 | 191→251 | 174→274 | 190→285 |
| `make test-board` | 20→31 | 20→29 | 27→41 | 25→32 | 25→63 |
| `make shellcheck` | 65→**42** | 56→**39** | 75→**40** | 64→**42** | 70→**66** |

The last row is the one that reframes the problem. `make shellcheck` — the
single heaviest *compiled-binary* gate, one Haskell binary over the whole tree —
is **faster on macOS every single night**, by up to 47%. Whatever is costing
macOS 1.7× is not "the CPU is slower."

## The four hypotheses

The issue listed four, none tested at filing time. All four now are.

### 1. Different CPU/core allocation — **CONFIRMED, and it is exactly 1.33×**

`quality-gates.sh`'s pool resolves its width from the host's core count and
reports it. Every night, on both gate-set sizes: **ubuntu 4 workers, macOS 3**.
Never once did either move. That is a fixed 1.33× parallelism handicap, and it
is the multiplier that no per-gate optimisation can touch.

One residual ambiguity, deliberately named rather than papered over: the pool's
`auto` width is `min(cores, 4)` (`_gate_pool_auto_cap`, `gate-pool.sh`), so
"ubuntu resolves to 4" proves ubuntu has *at least* 4 cores, not exactly 4. If
it has more, raising the cap speeds ubuntu and widens the gap rather than
closing it — a materially different situation. The
`Runner characterization` step added to both legs of `nightly-macos.yml` in
this change prints the **raw** logical/physical core count next to the clamped
width, so the next nightly closes that gap with a number.

### 2. `ensure-shellcheck.sh`'s pinned-download path — **FALSIFIED, decisively**

The suspicion was that provisioning a pinned shellcheck (temperloop#567)
behaves very differently per-OS. It does — in macOS's favour.

| | 08-12 | 08-13 | 08-22 | 08-23 | 08-24 |
|:--|:-:|:-:|:-:|:-:|:-:|
| `make shellcheck` (u→m) | 65→42 | 56→39 | 75→40 | 64→42 | 70→66 |
| `test_ensure_shellcheck.sh` (u→m) | 1→1 | 1→1 | 1→1 | 1→1 | 0→2 |

Net contribution of the whole shellcheck-provisioning surface to 2026-08-24's
1036s delta: **−2 seconds**. It is not a contributor; it is a small credit.

### 3. A specific gate pathological on BSD tooling — **CONFIRMED in shape, wrong suspect**

The issue named the prose-budget fixture test, which `git clone`s HEAD. It is
genuinely slower — 19→46s, 2.42× — but that is **+27s, 2.6% of the delta**.
Naming it as the likely culprit would have sent the fix at 2.6% of the problem.

The real pathological gate is `test_score_gate_env.sh`: **4.22×**, +193s,
18.6% of the delta on its own, and it has been the worst offender on all five
nights (2.9×, 2.9×, 3.7×, 4.0×, 4.2×). It is not a BSD-*dialect* problem —
neither leg fails — it is a cost problem.

The shape underneath is visible in the table above and is what the follow-up
should chase: gates dominated by **one long-running compiled binary** are at
parity or faster on macOS (`make shellcheck`, −6% to −47%), while gates that
are **bash harnesses shelling out per assertion** run 1.5–4.2× slower. That is
a hypothesis about process-spawn and filesystem-syscall cost, and it is
*labelled* a hypothesis: the `Runner characterization` step this change adds
measures spawn throughput and file create/stat/unlink throughput on both legs,
which is what turns it into a measurement.

### 4. Reported duration includes queue/provisioning — **FALSIFIED for the duration, REAL for end-to-end latency**

Two different numbers, and the issue's baseline table used the first one.

*Job duration excludes queue.* GitHub's `job.started_at` is stamped after
runner allocation, so the 6m46s–9m37s figures in the issue are pure execution.
Provisioning inside the job is negligible and near-identical: `Set up job` 1–2s
both legs, `actions/checkout@v6` with `fetch-depth: 0` is 2–3s on macOS vs 1–2s
on ubuntu. **The compute gap is real and is not a measurement artefact.**

*End-to-end latency does not.* Wait time between `run_started_at` and the job
starting was ≤4s on nine of the ten job-runs measured — and **304 seconds** for
the macOS job on 2026-08-13, against 3s for that same run's ubuntu job. ubuntu
never exceeded 4s on any night. So macOS-runner allocation is occasionally
minutes-scale, and only the macOS leg pays it.

That distinction matters for the follow-up in a specific way: restoring
`macos-latest` to the `checks` matrix means a PR author waits for macOS
allocation *plus* macOS execution, and the allocation term is invisible in
every per-job duration anyone would quote when picking a target.

## What this leaves for the follow-up

Facts, not a plan:

1. Two multipliers, 1.33× (fixed, structural) × 1.36–1.71× (concentrated,
   addressable). Fixing either alone cannot reach parity.
2. 73% of the CPU delta sits in 12 named gates; four gates carry 53%.
3. The shellcheck provisioning path is exonerated with numbers.
4. macOS-runner queue is a real, occasionally minutes-scale latency term that
   no per-job duration shows.
5. The mechanism behind the concentrated 1.7× is not yet measured; the probe
   that measures it ships in this change and reports on the next nightly.

**A target is not proposed here, and macOS is not restored to pre-merge
gating here.** Both are the follow-up's call, made against these numbers.

## Reproducing

```
make macos-gate-timing-report                        # every table above
bash workflows/scripts/dev/macos-gate-timing-report.sh --night 2026-08-22
bash workflows/scripts/dev/runner-characterization.sh # what this host is
```

The report reads only committed files — no network, no `gh`, no live Actions
logs (which expire, which is exactly why the datasets are committed rather than
re-fetched). It cross-checks each recorded per-gate file's row count and column
sum against the totals that run itself reported, and refuses to print on a
mismatch, so a truncated capture is a loud failure rather than a smaller
number. The capture recipe for adding a night is in the script's own header.

---

*Written by claude-opus-5 on 2026-08-24.*
