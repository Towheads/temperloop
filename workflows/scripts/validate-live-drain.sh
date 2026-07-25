#!/usr/bin/env bash
# validate-live-drain.sh — forwarding stub (terminology consolidation v0.17.0,
# temperloop#729). Renamed to validate-capture-backstop.sh; this stub forwards through
# the legacy window and is removed in v0.19.0. See CHANGELOG 0.17.0 BREAKING.
# (Deployment-shape caveat: resolves the renamed target RELATIVE to this
# stub's own real directory — a symlink to this stub forwards correctly only
# if the renamed sibling is reachable beside the resolved path.)
printf 'NOTE: %s was renamed %s in v0.17.0 (temperloop#729); this forwarding stub is removed in v0.19.0.\n' "validate-live-drain.sh" "validate-capture-backstop.sh" >&2
exec "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/validate-capture-backstop.sh" "$@"
