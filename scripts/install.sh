#!/bin/zsh
# Installs the core and the menu bar app (launchd, at login). The app runs the core every
# minute (the check interval is a setting); as its child, the core gets the folder access
# macOS grants to Sift, so vaults in Documents/Desktop/iCloud work.
# Works from the source tree (builds the app) or from a release zip (prebuilt app).
# Optional: opening Sift.app alone does the same setup on first run.
# Safe to re-run: existing config/state and vault files are kept.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/Sift"
AGENTS="$HOME/Library/LaunchAgents"
OLD_CORE_LABEL=io.github.kpiljoong.sift.core  # 0.2.0 ran the core as its own launchd job
UI_LABEL=io.github.kpiljoong.sift.menubar
APP_DEST="$HOME/Applications/Sift.app"
DOMAIN="gui/$(id -u)"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "The core runs on /usr/bin/python3. Install the Command Line Tools first with 'xcode-select --install'." >&2
  exit 1
fi

# Earlier installs: 0.1.x ("PersonalAssistant") and the 0.2.0 core job. Settings and history move over once.
OLD_SUPPORT="$HOME/Library/Application Support/personal-assistant"
for label in com.personal-assistant.core com.personal-assistant.menubar $OLD_CORE_LABEL; do
  if [[ -f "$AGENTS/$label.plist" ]]; then
    echo "• Removing old launchd job: $label"
    while pgrep -qf "python3 -m pa run"; do sleep 1; done  # let a running pass finish
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    rm -f "$AGENTS/$label.plist"
  fi
done
rm -rf "$HOME/Applications/PersonalAssistant.app"
if [[ -d "$OLD_SUPPORT" && ! -e "$SUPPORT" ]]; then
  echo "• Moving settings and history: $OLD_SUPPORT → $SUPPORT"
  mv "$OLD_SUPPORT" "$SUPPORT"
fi

mkdir -p "$SUPPORT/app" "$SUPPORT/logs" "$AGENTS" "$HOME/Applications"

echo "• Copying the core"
rsync -a --delete --exclude __pycache__ "$ROOT/core/pa/" "$SUPPORT/app/pa/"
cp "$ROOT/VERSION" "$SUPPORT/app/VERSION"  # the in-app updater compares against this

if [[ -d "$ROOT/Sift.app" ]]; then
  echo "• Installing the menu bar app (prebuilt)"
  APP_SRC="$ROOT/Sift.app"
else
  echo "• Building the menu bar app"
  "$ROOT/menubar/build.sh" >/dev/null
  APP_SRC="$ROOT/menubar/build/Sift.app"
fi
rsync -a --delete "$APP_SRC/" "$APP_DEST/"
# unsigned build: running this script is the user's consent to open it
xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true

echo "• Registering with launchd"
cat > "$AGENTS/$UI_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$UI_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP_DEST/Contents/MacOS/Sift</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST

while pgrep -qf "python3 -m pa run"; do sleep 1; done  # let a running pass finish
for label in $UI_LABEL; do
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  for _ in {1..50}; do  # bootout is asynchronous
    launchctl print "$DOMAIN/$label" >/dev/null 2>&1 || break
    sleep 0.2
  done
  launchctl bootstrap "$DOMAIN" "$AGENTS/$label.plist"
done

echo "Done. On first install, choose the vault and inbox in the menu bar. Settings: $SUPPORT/config.json  Log: $SUPPORT/logs/core.log"
