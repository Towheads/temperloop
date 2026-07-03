---
title: A polling loop on the wrong API drains a shared rate-limit budget
---

## The failure

A CI-automation pipeline needed to do two unrelated things against the same
external API host: watch a pull request's checks until they finished, and
read/write a project board. The check-watching used a convenient built-in
CLI subcommand that streams status updates every few seconds until the
checks resolve. The board reads and writes had no REST equivalent — the
board API is only exposed over GraphQL.

Both operations shared a single GraphQL rate-limit budget, and that budget
started running out during ordinary use — first attributed to the board
operations, which seemed like the obvious suspect since the acute failures
showed up as board calls being rejected.

## The mechanism

Investigating the actual point cost told a different story:

- The GraphQL API's cost accounting was **flat per query** — a query that
  reads one item and a query that reads a hundred cost the same number of
  points. That meant optimizing the board code to fetch fewer items per
  call, the obvious first fix, **didn't reduce the points spent at all**;
  only the *number of queries* mattered, not their size.
- Idle usage of the budget was flat — no leak, no background daemon eating
  points.
- The convenient "watch until done" CLI helper for CI checks turned out to
  be **GraphQL-backed** under the hood, polling every few seconds for the
  multi-minute lifetime of a CI run. Run several units of work in parallel
  — each one watching its own pull request's checks — and that's N
  concurrent, several-seconds-interval GraphQL pollers running continuously
  for the length of the slowest CI run. That dwarfed anything the board
  operations were doing.

The root cause was invisible from the symptom: the calls that were being
*rejected* (board operations) were not the calls that were *causing* the
exhaustion (CI-check polling). Two independent uses of the same API had been
merged onto the same budget without either one being deliberately rate-
limited, and the convenient default (streaming, sub-10-second polling) was
silently the expensive one.

## The guard

The fix was to split the traffic by API surface, not to optimize either
side's query shape:

- **Route CI-check watching onto REST**, which exposes the same pass/fail
  data as a plain commit-status/check-run lookup, on a *separate* rate
  bucket from GraphQL. A hand-rolled poll loop (fetch the check state,
  sleep, repeat) at a much coarser interval — tens of seconds, not
  seconds — replaced the streaming helper.
- **Reserve the GraphQL budget for the operations that have no REST
  equivalent** — here, only the project-board API. With CI polling moved
  off it entirely, the remaining GraphQL traffic dropped to well within
  budget without any change to the board code itself.

The general lesson: when multiple independent subsystems share a metered
resource, a "convenient" default that seems unrelated to the resource
you're worried about can be the actual consumer — measure per-call cost and
call *volume* separately before optimizing the thing that merely happens to
be visible when the budget runs out. And where a metered API exposes two
equivalent surfaces (here, REST vs. GraphQL) with independent budgets,
routing high-frequency polling onto the cheaper/separate one is often a
bigger win than shrinking the expensive calls you can't avoid.
