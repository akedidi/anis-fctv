#!/usr/bin/env bash
# Runs the real-network live playback UI test (see FCTVUITests/LivePlaybackUITests.swift).
# Usage:
#   ./scripts/run-live-playback-ui-test.sh
#   ./scripts/run-live-playback-ui-test.sh "https://example.com/fr/football/...html"
#
# Optional: FCTV_LIVE_PLAYBACK_URL overrides the default event URL for xcodebuild.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/FCTV"

URL="${1:-}"
if [[ -n "$URL" ]]; then
  export FCTV_LIVE_PLAYBACK_URL="$URL"
fi

DEST="${DESTINATION:-platform=iOS Simulator,name=iPhone 16}"

echo "==> xcodebuild test scheme=FCTV destination=$DEST (LivePlaybackUITests)"
xcodebuild \
  -workspace FCTV.xcworkspace \
  -scheme FCTV \
  -destination "$DEST" \
  -only-testing:FCTVUITests/LivePlaybackUITests/testLivePlayback_resolvesEventURLAndStartsStream \
  test

echo "==> OK"
