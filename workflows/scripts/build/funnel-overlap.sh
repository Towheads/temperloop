#!/usr/bin/env bash
# funnel-overlap.sh — forwarding stub (terminology consolidation v0.17.0,
# temperloop#729). Renamed to pipeline-overlap.sh; this stub forwards through
# the legacy window and is removed in v0.19.0. See CHANGELOG 0.17.0 BREAKING.
printf 'NOTE: %s was renamed %s in v0.17.0 (temperloop#729); this forwarding stub is removed in v0.19.0.\n' "funnel-overlap.sh" "pipeline-overlap.sh" >&2
exec "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pipeline-overlap.sh" "$@"
