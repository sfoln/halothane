#!/bin/bash
#
# Completely removes Halothane from a Mac.
# Usage: sudo ./uninstall-helper.sh
#
# For an isolated filesystem test only, set HALOTHANE_UNINSTALL_ROOT to a
# temporary directory. System services and processes are not touched in that mode.

set -euo pipefail

DAEMON_LABEL="com.sfoln.Halothane.Helper"
AGENT_LABEL="com.sfoln.Halothane.GUI"
PACKAGE_ID="com.sfoln.Halothane.pkg"
FS_ROOT="${HALOTHANE_UNINSTALL_ROOT:-}"

if [[ "$FS_ROOT" == "/" ]]; then
  echo "HALOTHANE_UNINSTALL_ROOT must be empty for a real uninstall or a temporary directory for testing." >&2
  exit 1
fi

if [[ -n "$FS_ROOT" && "$FS_ROOT" != /* ]]; then
  echo "HALOTHANE_UNINSTALL_ROOT must be an absolute path." >&2
  exit 1
fi

if [[ -z "$FS_ROOT" && $EUID -ne 0 ]]; then
  echo "Must run as root: sudo $0" >&2
  exit 1
fi

root_path() {
  printf '%s%s' "$FS_ROOT" "$1"
}

remove_path() {
  local target
  target="$(root_path "$1")"
  if [[ -e "$target" || -L "$target" ]]; then
    rm -rf -- "$target"
    echo "Removed $1"
  fi
}

echo "Halothane uninstaller"
echo "Before continuing, use Halothane's menu to resume anything it paused."
echo "If a process remains paused afterward, restarting the Mac will resume it."

if [[ -z "$FS_ROOT" ]]; then
  echo "Stopping the privileged helper…"
  launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true

  echo "Stopping menu-bar agents in active login sessions…"
  for user_name in $(who | awk '$2=="console"{print $1}' | sort -u); do
    [[ "$user_name" == "root" ]] && continue
    uid_number="$(id -u "$user_name" 2>/dev/null)" || continue
    [[ -z "$uid_number" ]] && continue
    launchctl bootout "gui/${uid_number}/${AGENT_LABEL}" 2>/dev/null || true
  done

  pkill -x Halothane 2>/dev/null || true
fi

remove_path "/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
remove_path "/Library/LaunchAgents/${AGENT_LABEL}.plist"
remove_path "/Applications/Halothane.app"
remove_path "/Library/Application Support/Halothane"
remove_path "/var/log/halothane-helper.log"

# Remove per-user preferences and caches. The loop is intentionally limited to
# explicit Library locations beneath each local home directory.
users_root="$(root_path "/Users")"
if [[ -d "$users_root" ]]; then
  for user_home in "$users_root"/*; do
    [[ -d "$user_home" ]] || continue
    rm -f -- "$user_home/Library/Preferences/com.sfoln.Halothane.plist"
    rm -f -- "$user_home/Library/Preferences/ByHost"/com.sfoln.Halothane.*.plist 2>/dev/null || true
    rm -rf -- "$user_home/Library/Caches/com.sfoln.Halothane"
    rm -rf -- "$user_home/Library/Saved Application State/com.sfoln.Halothane.savedState"
    rm -rf -- "$user_home/Library/Application Support/Halothane"
  done
fi

if [[ -z "$FS_ROOT" ]]; then
  pkgutil --forget "$PACKAGE_ID" >/dev/null 2>&1 || true
fi

echo "Halothane has been removed."
