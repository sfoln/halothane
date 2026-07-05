#!/bin/bash
#
# Installs the Halothane privileged supervisor as a system LaunchDaemon.
# The daemon is the *same* Halothane binary run with `--daemon`, executing as
# root so it can monitor and pause processes across ALL accounts (including the
# other fast-user-switched login).
#
# Usage:  sudo ./install-helper.sh [/path/to/Halothane.app]
# Default app path: /Applications/Halothane.app
#
set -euo pipefail

LABEL="com.sfoln.Halothane.Helper"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
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

echo "Installing daemon for binary: $BIN"

# If already loaded, tear it down first so we can replace it cleanly.
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  echo "Unloading existing daemon…"
  launchctl bootout "system/${LABEL}" 2>/dev/null || true
fi

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
        <string>--daemon</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>${LABEL}</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>/var/log/halothane-helper.log</string>
    <key>StandardOutPath</key>
    <string>/var/log/halothane-helper.log</string>
</dict>
</plist>
PLIST_EOF

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

echo "Bootstrapping daemon into the system domain…"
launchctl bootstrap system "$PLIST"
launchctl enable "system/${LABEL}"
launchctl kickstart -k "system/${LABEL}" 2>/dev/null || true

echo "Done. Logs: /var/log/halothane-helper.log"
echo "Verify:  sudo launchctl print system/${LABEL} | grep -E 'state|pid'"
