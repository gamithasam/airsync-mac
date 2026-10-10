#!/usr/bin/env bash
set -euo pipefail

mode="${1:-run}"
case "$mode" in run|--build-only|--verify|--debug|--logs|--telemetry) ;; *) echo "Usage: $0 [--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Optional machine-local settings live in the Git-ignored build directory.
if [[ -f "$task_root/.build/handoff-local.env" ]]; then
    source "$task_root/.build/handoff-local.env"
fi
task_build="${AIRSYNC_DERIVED_DATA:-$task_root/.build/handoff}"
task_configuration="${AIRSYNC_CONFIGURATION:-Self Compiled}"
task_scheme="${AIRSYNC_SCHEME:-AirSync Self Compiled}"
cd "$task_root"
if [[ "$mode" != --build-only ]]; then
    pkill -x AirSync >/dev/null 2>&1 || true
    pkill -x 'AirSync Handoff' >/dev/null 2>&1 || true
fi
build_options=()
# Local diagnostic workaround for newer Icon Composer files on older Xcode.
if [[ "${AIRSYNC_SKIP_ICON_COMPOSER:-0}" == 1 ]]; then
    build_options+=(EXCLUDED_SOURCE_FILE_NAMES=AppIcon.icon ASSETCATALOG_COMPILER_APPICON_NAME=)
fi
xcodebuild -project AirSync.xcodeproj -scheme "$task_scheme" -configuration "$task_configuration" \
    -derivedDataPath "$task_build" CODE_SIGNING_ALLOWED=NO "${build_options[@]}" build
task_bundle="$task_build/Build/Products/$task_configuration/AirSync.app"
case "$mode" in
    --build-only) exit 0 ;;
    --debug) exec lldb -- "$task_bundle/Contents/MacOS/AirSync" ;;
    *) /usr/bin/open -n "$task_bundle" ;;
esac
case "$mode" in
    --verify) sleep 2; pgrep -x AirSync >/dev/null ;;
    --logs|--telemetry) exec /usr/bin/log stream --info --style compact --predicate 'process == "AirSync" OR process == "AirSync Handoff"' ;;
esac
