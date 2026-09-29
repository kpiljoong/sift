#!/bin/zsh
# Stops and removes the launchd jobs and the app bundle.
# Leaves config/state and everything in the vault untouched.
set -uo pipefail
DOMAIN="gui/$(id -u)"
for label in io.github.kpiljoong.sift.core io.github.kpiljoong.sift.menubar; do
  launchctl bootout "$DOMAIN/$label" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
rm -rf "$HOME/Applications/Sift.app"
echo "Uninstalled (the vault and ~/Library/Application Support/Sift were left as they are)"
