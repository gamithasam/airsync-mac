# App handoff

Enable **App handoff** in Android's AirSync Settings → App, grant Usage Access,
and enable **Show app handoffs in the Dock** in the Mac's Sync settings.
Both clients must be connected through WebSocket and advertise handoff version 1.
BLE-only connections and older clients do not report handoffs.

AirSync offers the currently foreground eligible Android app. Its icon appears in a
separate **AirSync Handoff** Dock app, with a phone badge. Click the tile or use its
Dock menu to open the app. The order is an installed mapped Mac app, an Android
app window via scrcpy, then the mapped website. Existing notification mappings
and custom preferences apply, including disabled mappings. Mirroring keeps its
existing ADB, scrcpy, and Plus requirements.

Locking the phone, returning home, leaving the foreground app, or visiting an app
without a launch route clears the tile. Android polls once per second; in
split-screen, the most recently resumed app is offered. Opening or dismissing consumes that app session;
switch away and back to offer it again. Disconnecting, disabling the feature, or
revoking Usage Access clears it. The feature opens apps and does not transfer
private screen state. Android sends only package, name, and session identifier;
existing icon synchronization supplies icons.

The helper is bundled at `AirSync.app/Contents/Helpers/AirSync Handoff.app`.
It starts without activation and is independent of AirSync's Dock visibility
setting. macOS controls its ordinary Dock placement and running indicators.
Pinning it may leave a static icon after it exits.

The parent owns state and launching. The helper communicates over a length-framed
local Unix socket in a randomly named directory with mode 0700 and socket mode
0600. AirSync checks the connecting user and helper process bundle path. A Unix
socket replaces the initially proposed archived XPC endpoint: macOS permits
encoding `NSXPCListenerEndpoint` only inside another XPC message, not in a file.
No persistent launch agent, broker, or shared app-group setting is required.

## Validation

- Build the Mac app: `./script/build_and_run.sh --build-only`.
- For an Icon Composer format unsupported by the local Xcode, set
  `AIRSYNC_SKIP_ICON_COMPOSER=1` for a local diagnostic build. Distribution builds
  should use an Xcode version compatible with the project's icon assets.
- Run policy/lifetime checks: `./script/test_handoff.sh`.
- Include live helper IPC/reopen/cleanup checks by passing the built helper's
  absolute `.app` path to `./script/test_handoff.sh`.
- In the Android repo, run `./gradlew :app:assembleDebug :app:testDebugUnitTest`.
  The repository targets Android SDK 37 and requires its configured Gradle/JDK.
- On a paired phone, check permissions, app changes, split-screen, locking,
  disconnecting, disabled mappings, and Mac → mirror → web routing. Unit tests
  cannot establish physical-device Usage Access or scrcpy behavior.

### Local results (2026-10-08)

These results predate the foreground-only lifetime change on 2026-10-10.

- Android debug APK and unit tests passed, including three foreground-session tests.
- Standard Debug and Self Compiled Mac schemes built with the Icon Composer
  diagnostic workaround; both include the helper at the expected bundle path.
- Ad-hoc signing and strict nested-bundle verification passed for both builds.
  Developer ID distribution signing was not exercised.
- Routing/session policy checks and live helper launch, focus preservation,
  reopen, update, shutdown, and IPC-loss cleanup checks passed.
- Paired-device permission, split-screen, and scrcpy routing checks remain manual.
