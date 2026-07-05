#!/bin/bash
#
# Installs the Halothane menu-bar UI as a per-user LaunchAgent. Agents in
# /Library/LaunchAgents load once for EVERY GUI login session, so both
# fast-user-switched accounts get the Halothane menu bar item automatically and
# each connects to the shared root daemon over XPC — giving every account full
# control of the one engine.
#
# Usage:  sudo ./install-agent.sh [/path/to/Halothane.app]
# Default app path: /Applications/Halothane.app
#
set -euo pipefail

LABEL="com.sfoln.Halothane.GUI"
PLIST="/Library/LaunchAgents/${LABEL}.plist"
APP="${1:-/Applications/Halothane.app}"
BIN="${APP}/Contents/MacOS/Halothane"

if [[ $EUID -ne 0 ]]; then
  echo "Must run as root: sudo $0 ${1:-}" >&2
  exit 1
fi

if [[ ! -x "$BIN" ]]; then
  echo "Halothane binary not found at: $BIN" >&2
  echo "Pass the app path: sudo $0 /path/to/Halothane.app" >&2
  exit 1
fi

echo "Installing GUI agent for binary: $BIN"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Relaunch on crash, but NOT when the user quits from the menu (clean exit). -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <!-- GUI sessions only. -->
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST_EOF

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# Boot it into EVERY active GUI session (every fast-user-switched account that's
# currently logged in) so it appears immediately for all of them. Accounts that
# aren't logged in yet pick it up at their next login. Without this, an account
# that was already logged in before the plist existed wouldn't load it until it
# logs out and back in.
for U in $(who | awk '$2=="console"{print $1}' | sort -u); do
  [[ "$U" == "root" ]] && continue
  UID_NUM="$(id -u "$U" 2>/dev/null)" || continue
  [[ -z "$UID_NUM" ]] && continue
  echo "Bootstrapping into gui/${UID_NUM} (${U})…"
  launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/${UID_NUM}" "$PLIST" 2>/dev/null || true
  launchctl kickstart -k "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
done

echo "Done. The Halothane menu bar item loads for every account at login."
