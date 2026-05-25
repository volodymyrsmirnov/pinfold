#!/bin/bash
# Regenerate the Xcode project (picks up newly added files under App/, ShareExtension/,
# AppTests/) and build the app + share extension for the iOS 26.5 simulator.
# Code signing is disabled because there is no development team configured.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
xcodebuild build \
  -project Pinfold.xcodeproj \
  -scheme Pinfold \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  CODE_SIGNING_ALLOWED=NO \
  "$@"
