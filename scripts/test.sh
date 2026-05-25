#!/bin/bash
# Regenerate the Xcode project and run the PinfoldTests bundle on the iOS 26.5 simulator.
# Pass extra args through, e.g. -only-testing:PinfoldTests/ImportServiceTests
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
xcodebuild test \
  -project Pinfold.xcodeproj \
  -scheme Pinfold \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  CODE_SIGNING_ALLOWED=NO \
  "$@"
