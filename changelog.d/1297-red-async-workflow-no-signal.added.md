- **A red asynchronous workflow now reaches a surface someone actually reads**
  (#1297). Nothing surfaced a broken non-PR-triggered workflow, so a dead
  quality gate could sit on `main` for weeks — `nightly-macos.yml` was red for
  seven consecutive nights, and `install-tier2.yml` lost its only notification
  silently when its weekly cron was retired.
  `workflows/scripts/async-workflow-health.sh` classifies every workflow in
  `.github/workflows/` from its own `on:` triggers, reports each asynchronous
  one's **current** state (not just a red *transition* — both real instances
  were found while already red), and renders into the kernel telemetry brief's
  "1. Attention" section, which `/check-in` and `/telemetry` already render.
  `workflows/scripts/config/async-workflow-registry.tsv` records each
  workflow's disposition and **fails closed**: an unregistered asynchronous
  workflow, an absent registry, or a stale row all raise an alarm instead of
  going quiet.
