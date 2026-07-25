#!/usr/bin/env bash
# knob-registry-lib.sh — COMPAT SOURCE-FORWARDER (terminology consolidation
# v0.17.0, temperloop#729). The setting registry's parse lib was renamed:
#
#   workflows/scripts/config/knob-registry-lib.sh
#     -> workflows/scripts/config/setting-registry-lib.sh
#
# Sourcing this path keeps working through the legacy window (closes in
# v0.19.0): it sources the renamed lib and re-exposes the old public
# function names as thin wrappers. Migrate callers to the new path + the
# setting_registry_* names; see CHANGELOG 0.17.0 BREAKING migration note.
# shellcheck shell=bash

if [[ "${_TEMPERLOOP_KNOB_REGISTRY_COMPAT_LOADED:-}" == "1" ]]; then
  return 0
fi
_TEMPERLOOP_KNOB_REGISTRY_COMPAT_LOADED=1

printf 'NOTE: knob-registry-lib.sh was renamed setting-registry-lib.sh in v0.17.0 (temperloop#729); this source-forwarder is removed in v0.19.0.\n' >&2

# shellcheck source=setting-registry-lib.sh
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setting-registry-lib.sh"

knob_registry_kernel_file()  { setting_registry_kernel_file "$@"; }
knob_registry_overlay_file() { setting_registry_overlay_file "$@"; }
knob_registry_validate()     { setting_registry_validate "$@"; }
knob_registry_rows()         { setting_registry_rows "$@"; }
knob_registry_get()          { setting_registry_get "$@"; }
