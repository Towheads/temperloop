- **`docs/cost-and-autonomy.md` and `temperloop init`'s handoff now disclose
  the first-epic cost position instead of leaving it as "no fixed figure /
  none by default"** (#1130). The temperloop#1348 spike found no source in
  this repo's own telemetry supports a published spend band for the first
  epic (every candidate was either too thin or measured the wrong
  population — an operator's own established checkout, never a fresh
  testbed); § Cost at a glance now states that finding directly and routes
  the actual measurement to temperloop#1352, rather than publishing a
  fabricated number. It also states plainly, and explains why, there is no
  *tool-enforced* dollar ceiling on `/assess`/`/build`: `--max-budget-usd`
  only caps a **headless** `claude -p` call, and those commands instead run
  in your own **interactive** `claude` session. `temperloop testbed` and
  `temperloop init` are now priced at their verified **$0** (no `claude`
  invocation in either path) instead of being left unpriced next to the
  un-figured first-epic row, and the first epic is described accurately as a
  fixed, kernel-shipped 5-item/3-level epic rather than "scales w/ the
  work". `temperloop init`'s closing handoff block gains a new `cost:` line
  — distinct from the stable `next step:` marker `install-tier2.yml` greps —
  naming this cost position before handing the reader to `/assess`.
