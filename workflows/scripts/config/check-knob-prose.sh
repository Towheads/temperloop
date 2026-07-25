#!/usr/bin/env bash
# check-knob-prose.sh — forwarding stub (terminology consolidation v0.17.0,
# temperloop#729). Renamed to check-setting-prose.sh; this stub forwards through
# the legacy window and is removed in v0.19.0. See CHANGELOG 0.17.0 BREAKING.
printf 'NOTE: %s was renamed %s in v0.17.0 (temperloop#729); this forwarding stub is removed in v0.19.0.\n' "check-knob-prose.sh" "check-setting-prose.sh" >&2
exec "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-setting-prose.sh" "$@"
