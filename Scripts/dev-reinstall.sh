#!/bin/bash
#
# One-step rebuild + reinstall for development.
#   1. Builds Halothane (as you — NOT root, so DerivedData stays yours).
#   2. Finds the freshly built Halothane.app.
#   3. Installs it (escalates with sudo only for the install step), which copies
#      to /Applications and (re)starts the root daemon + per-account menu-bar
#      agent.
#
# Run WITHOUT sudo:  Scripts/dev-reinstall.sh [Debug|Release]   (default Debug)
#
set -euo pipefail

CONFIG="${1:-Debug}"
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(dirname "$DIR")"

if [[ $EUID -eq 0 ]]; then
  echo "Run this WITHOUT sudo — it builds as you, then escalates for the install." >&2
  exit 1
fi

echo "=== Building Halothane ($CONFIG) ==="
xcodebuild -project "$PROJ_DIR/Halothane.xcodeproj" -scheme Halothane \
  -configuration "$CONFIG" -destination 'platform=macOS' build

# Newest matching built app for this configuration.
APP="$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Halothane-*/Build/Products/"$CONFIG"/Halothane.app 2>/dev/null | head -1)"
if [[ -z "${APP:-}" || ! -x "$APP/Contents/MacOS/Halothane" ]]; then
  echo "Could not find a built Halothane.app for $CONFIG under DerivedData." >&2
  exit 1
fi
echo "Built: $APP"

echo
echo "=== Installing (sudo) ==="
sudo "$DIR/install.sh" "$APP"

echo
echo "Done. Verify:  sudo launchctl print system/com.sfoln.Halothane.Helper | grep -E 'state|pid'"
