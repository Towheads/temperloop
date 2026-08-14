`validate-model-usage-emit.sh` now validates every record in a raw-lake file
with a single batched `python3` process instead of spawning one `python3`
process per record. The old shape measured ~28ms/record of pure fork/exec
overhead: 100 records added ~3s to `make gates`, 500 added ~14s, and a
10,000-record raw lake (a lake that only grows, since `meta/data/raw/*` is
gitignored and nothing prunes it) added roughly 5 minutes locally. CI itself
paid nothing (the gitignored lake is always empty there), so this only ever
cost developers, silently, more every week.

Behavior is unchanged: the same per-record shape/enum/no-host checks run
against every record, `FAIL` lines still cite the exact same `file:line`,
and every degenerate-input case (a missing/unreadable raw-lake directory, a
closed stdin, an unresolvable repo root) still exits non-zero as
`CANNOT EVALUATE`. The batched call also fails closed if `python3` itself
crashes mid-batch, or returns fewer verdicts than records sent, rather than
risk silently treating an unvalidated tail of records as passing.
