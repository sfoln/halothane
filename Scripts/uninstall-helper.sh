#!/bin/bash
#
# Removes the Halothane privileged supervisor LaunchDaemon.
# Usage: sudo ./uninstall-helper.sh
#
set -euo pipefail

LABEL="com.sfoln.Halothane.Helper"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
AGENT_LABEL="com.sfoln.Halothane.GUI"
AGENT_PLIST="/Library/LaunchAgents/${AGENT_LABEL}.plist"

if [[ $EUID -ne 0 ]]; then
  echo "Must run as root: sudo $0" >&2
  exit 1
fi

echo "Booting out daemon (this resumes anything it had paused)…"
launchctl bootout "system/${LABEL}" 2>/dev/null || true
rm -f "$PLIST"
echo "Removed $PLIST"

echo "Booting out menu-bar agent…"
CONSOLE_USER="$(stat -f%Su /dev/console)"
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]]; then
  UID_NUM="$(id -u "$CONSOLE_USER")"
  launchctl bootout "gui/${UID_NUM}/${AGENT_LABEL}" 2>/dev/null || true
fi
rm -f "$AGENT_PLIST"
echo "Removed $AGENT_PLIST"

echo "Note: config is left at /Library/Application Support/Halothane/ — delete manually if desired."
