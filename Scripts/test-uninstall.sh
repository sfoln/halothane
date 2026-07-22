#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNINSTALLER="$REPO_ROOT/Scripts/uninstall-helper.sh"
PUBLIC_UNINSTALLER="$REPO_ROOT/site/uninstall-halothane.sh"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/halothane-uninstall.XXXXXX")"

cleanup() {
  rm -rf -- "$FIXTURE_ROOT"
}
trap cleanup EXIT

cmp "$UNINSTALLER" "$PUBLIC_UNINSTALLER"

targets=(
  "/Library/LaunchDaemons/com.sfoln.Halothane.Helper.plist"
  "/Library/LaunchAgents/com.sfoln.Halothane.GUI.plist"
  "/Applications/Halothane.app/Contents/MacOS/Halothane"
  "/Library/Application Support/Halothane/config.json"
  "/var/log/halothane-helper.log"
  "/Users/tester/Library/Preferences/com.sfoln.Halothane.plist"
  "/Users/tester/Library/Preferences/ByHost/com.sfoln.Halothane.test.plist"
  "/Users/tester/Library/Caches/com.sfoln.Halothane/cache.db"
  "/Users/tester/Library/Saved Application State/com.sfoln.Halothane.savedState/state"
  "/Users/tester/Library/Application Support/Halothane/state.json"
)

for target in "${targets[@]}"; do
  mkdir -p "$(dirname "$FIXTURE_ROOT$target")"
  touch "$FIXTURE_ROOT$target"
done

mkdir -p "$FIXTURE_ROOT/Users/tester/Documents"
touch "$FIXTURE_ROOT/Users/tester/Documents/keep-me.txt"

HALOTHANE_UNINSTALL_ROOT="$FIXTURE_ROOT" bash "$UNINSTALLER"

for target in "${targets[@]}"; do
  if [[ -e "$FIXTURE_ROOT$target" ]]; then
    echo "Uninstaller left target behind: $target" >&2
    exit 1
  fi
done

[[ -f "$FIXTURE_ROOT/Users/tester/Documents/keep-me.txt" ]]
echo "Uninstaller fixture test passed."
