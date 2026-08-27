- **Duplicate-entry lint on both governance manifests, plus a generalised
  two-manifest pre-claim contract** (#1801). `check-kernel-manifest.sh` and
  `validate-feature-docs.sh` (`DUPLICATE-CLAIM`) now each fail on a glob
  claimed by more than one manifest line — the residue a missed pre-claim
  leaves behind. The pre-claim convention is hoisted out of ADR-0000's
  ADR-only scope: any new-subtree pre-claim MUST add its claim to both
  `docs/features/feature-manifest.txt` and
  `workflows/scripts/kernel/kernel-manifest.txt` in the same change
  (canonical statement in feature-manifest.txt's header; ADR-0000
  § Manifest registration now defers to it). The two pre-existing
  kernel-manifest duplicates (`workflows/scripts/model-comparison/*`,
  `workflows/scripts/testbed/*`) are removed.
