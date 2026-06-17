---
name: run-sim
description: Build, install, launch, and screenshot the Pinfold app on the iOS 26.5 simulator. Use to visually verify a change or confirm the app runs without a launch crash.
---

Run the Pinfold app on the iOS 26.5 simulator and capture a screenshot. This is the only
known-good way to launch the app here (no signing team is configured).

Steps (run from the repo root):

1. Pick the simulator. Default to **iPhone 17 Pro** on iOS 26.5; fall back to **iPhone 17**.
   Get its UDID and boot it:
   ```bash
   SIM=$(xcrun simctl list devices available | awk '/iOS 26.5/{f=1} f&&/iPhone 17 Pro \(/{print $NF; exit}' | tr -d '()')
   [ -z "$SIM" ] && SIM=$(xcrun simctl list devices available | awk '/iOS 26.5/{f=1} f&&/iPhone 17 \(/{print $NF; exit}' | tr -d '()')
   xcrun simctl boot "$SIM" 2>/dev/null; xcrun simctl bootstatus "$SIM" -b >/dev/null
   ```

2. Regenerate the project and build to a fixed path (signing disabled):
   ```bash
   xcodegen generate >/dev/null
   xcodebuild build -project Pinfold.xcodeproj -scheme Pinfold \
     -destination "id=$SIM" -derivedDataPath /tmp/pinfold-dd CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|\*\* BUILD"
   ```
   Stop and report if the build fails.

3. Install, launch, confirm it stays alive (catches launch crashes), and screenshot:
   ```bash
   APP=$(find /tmp/pinfold-dd/Build/Products -name "Pinfold.app" -maxdepth 3 | head -1)
   xcrun simctl terminate "$SIM" tech.inkhorn.pinfold 2>/dev/null
   xcrun simctl install "$SIM" "$APP"
   xcrun simctl launch "$SIM" tech.inkhorn.pinfold
   sleep 3
   xcrun simctl spawn "$SIM" launchctl list | grep -q tech.inkhorn.pinfold && echo "RUNNING (no launch crash)" || echo "NOT RUNNING — check for a crash report"
   xcrun simctl io "$SIM" screenshot /tmp/pinfold-screenshot.png
   ```

4. Read `/tmp/pinfold-screenshot.png` to inspect the result, and surface it to the user with SendUserFile.

Notes:
- The app installs into the simulator's existing data container, so previously imported files persist across reinstalls (don't `uninstall` unless you want a clean slate).
- This launches to the Home screen. Codex cannot tap to navigate the simulator headlessly — to verify a deeper screen, ask the user, or seed data and rely on the screenshot of what's reachable.
- If a build complains the iOS platform isn't installed, the simulator runtime is missing: `xcodebuild -downloadPlatform iOS`.
