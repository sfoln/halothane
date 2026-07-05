#!/bin/bash
#
# Build a distributable, signed, notarized Halothane.pkg.
#
#   1. Release build signed with Developer ID Application (hardened runtime,
#      secure timestamp).
#   2. Stage the app into /Applications and attach a postinstall that installs
#      the root daemon + per-user menu-bar agent and launches the UI.
#   3. Build a component .pkg signed with Developer ID Installer.
#   4. Notarize with notarytool and staple the ticket.
#
# Run WITHOUT sudo. Requires (SFOLN LLC, team MXBM8H7F26):
#   - "Developer ID Application" + "Developer ID Installer" certs in the keychain
#   - a notarytool keychain profile (default: halothane-notary)
#
# Usage:  Scripts/build-pkg.sh [version]          (default version: 0.1)
#         NOTARY_PROFILE=other Scripts/build-pkg.sh 1.0
#
set -euo pipefail

VERSION="${1:-0.1}"
PROFILE="${NOTARY_PROFILE:-halothane-notary}"
TEAM="MXBM8H7F26"
APP_NAME="Halothane"
BUNDLE_ID="com.sfoln.Halothane"
DEV_ID_APP="Developer ID Application: SFOLN LLC (${TEAM})"
DEV_ID_INSTALLER="Developer ID Installer: SFOLN LLC (${TEAM})"

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$DIR")"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
DD="$BUILD/DerivedData"

if [[ $EUID -eq 0 ]]; then
  echo "Run WITHOUT sudo (signing uses your login keychain)." >&2
  exit 1
fi

echo "=== Clean ==="
rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

echo "=== Build Release (Developer ID, hardened runtime, secure timestamp) ==="
# NOTE: the first Developer ID signing may pop a keychain "allow access" dialog —
# click "Always Allow" once.
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO drops the get-task-allow entitlement
# Xcode injects for development signing (notarization rejects it). The app needs
# no entitlements (no sandbox; signalling/XPC need none).
xcodebuild -project "$ROOT/${APP_NAME}.xcodeproj" -scheme "$APP_NAME" \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY="$DEV_ID_APP" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  clean build

APP="$DD/Build/Products/Release/${APP_NAME}.app"
[[ -x "$APP/Contents/MacOS/$APP_NAME" ]] || { echo "Build did not produce $APP" >&2; exit 1; }

echo "=== Verify signature ==="
codesign --verify --strict --verbose=2 "$APP"
echo "--- signing details ---"
codesign -dvvv "$APP" 2>&1 | grep -E "Authority=|Timestamp=|flags=|TeamIdentifier=" || true
# Must satisfy the XPC designated requirement the daemon enforces (team-OU pin).
codesign -v -R="identifier \"$BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$APP" \
  && echo "ClientTrust designated requirement satisfied."
# Guard: get-task-allow must be absent or notarization will reject it.
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "ERROR: get-task-allow entitlement present — notarization would fail." >&2
  exit 1
fi
echo "No get-task-allow entitlement — OK for notarization."

echo "=== Stage payload (app -> /Applications) ==="
PAYLOAD="$BUILD/payload"
mkdir -p "$PAYLOAD/Applications"
cp -R "$APP" "$PAYLOAD/Applications/"

echo "=== Stage pkg scripts (daemon + agent install at postinstall) ==="
SCRIPTS="$BUILD/scripts"
mkdir -p "$SCRIPTS"
cp "$DIR/install-helper.sh" "$DIR/install-agent.sh" "$SCRIPTS/"
cat > "$SCRIPTS/postinstall" <<'POST'
#!/bin/bash
# Runs as root during install. The app is already in /Applications; wire up the
# privileged daemon + per-account menu-bar agent and launch the UI.
set -euo pipefail
APP="/Applications/Halothane.app"
HERE="$(cd "$(dirname "$0")" && pwd)"
chown -R root:wheel "$APP" || true
"$HERE/install-helper.sh" "$APP"
"$HERE/install-agent.sh" "$APP"
# The LaunchAgent (RunAtLoad) is the single launcher for the menu-bar UI. Do NOT
# also `open` it here — a second launch races the agent's before it registers
# with LaunchServices and produces two menu bar items.
exit 0
POST
chmod +x "$SCRIPTS/postinstall" "$SCRIPTS/install-helper.sh" "$SCRIPTS/install-agent.sh"

PKG="$DIST/${APP_NAME}-${VERSION}.pkg"
echo "=== Build component pkg (signed: Developer ID Installer) ==="
pkgbuild --root "$PAYLOAD" --install-location / --ownership recommended \
  --identifier "${BUNDLE_ID}.pkg" --version "$VERSION" \
  --scripts "$SCRIPTS" \
  --sign "$DEV_ID_INSTALLER" \
  "$PKG"
echo "Built: $PKG"

echo "=== Notarize (can take a few minutes) ==="
xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait

echo "=== Staple + verify ==="
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
spctl -a -vvv -t install "$PKG" 2>&1 | head -5 || true

echo
echo "Done. Distributable installer: $PKG"
