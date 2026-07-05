#!/bin/bash
#
# Full Halothane install:
#   1. Copies the built app to /Applications/Halothane.app (a stable location, so
#      a later Xcode rebuild doesn't wipe the path the daemon/agent point at).
#   2. Installs the privileged root daemon (system-wide engine, all accounts).
#   3. Installs the per-user menu-bar agent (UI in every GUI login session).
#
# Usage:  sudo ./install.sh /path/to/Halothane.app
#   e.g.  sudo ./install.sh \
#           ~/Library/Developer/Xcode/DerivedData/Halothane-*/Build/Products/Debug/Halothane.app
#
set -euo pipefail

SRC="${1:?Usage: sudo ./install.sh /path/to/built/Halothane.app}"
DEST="/Applications/Halothane.app"
DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Must run as root: sudo $0 $SRC" >&2
  exit 1
fi

if [[ ! -x "${SRC}/Contents/MacOS/Halothane" ]]; then
  echo "No Halothane binary under: $SRC" >&2
  exit 1
fi

echo "Copying ${SRC} -> ${DEST}"
# Quit any running copy from the old location first.
pkill -x Halothane 2>/dev/null || true
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
chown -R root:wheel "$DEST"

echo
echo "=== Installing root daemon ==="
"$DIR/install-helper.sh" "$DEST"

echo
echo "=== Installing menu-bar agent ==="
# install-agent.sh bootstraps the LaunchAgent (RunAtLoad) and kickstarts it, which
# launches the menu-bar UI in each logged-in account. That is the SINGLE launcher
# — we intentionally do not also `open` the app (a second launch races the agent's
# before it registers with LaunchServices and yields two menu bar items).
"$DIR/install-agent.sh" "$DEST"

echo
echo "All set. Halothane is running (daemon + menu bar). Re-run this script after"
echo "rebuilding to update the installed copy."
