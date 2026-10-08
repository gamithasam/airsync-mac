#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/airsync-handoff-checks.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
cd "$task_root"
xcrun swiftc airsync-mac/Model/MacAppLaunchPreference.swift airsync-mac/Core/Handoff/HandoffPolicy.swift \
    Tests/HandoffBehaviorTests.swift -o "$task_temp/behavior"
"$task_temp/behavior"
if [[ $# -gt 0 ]]; then
    xcrun swiftc HandoffShared/HandoffIPC.swift Tests/HandoffHelperIntegration.swift -o "$task_temp/helper-integration"
    "$task_temp/helper-integration" "$1"
fi
