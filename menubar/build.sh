#!/bin/zsh
# Builds Sift.app into menubar/build/ (Command Line Tools are enough), with the core inside.
# Universal binary (Apple Silicon + Intel); the version comes from ../VERSION.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(cat ../VERSION)"
# The updater replaces the app only when this changes; core-only releases keep the app (and its folder permissions).
SOURCE="$(cat Sift.swift build.sh | shasum -a 256 | cut -c1-16)"
APP=build/Sift.app
rm -rf "$APP" build/slices
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/slices
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macosx13.0 \
    -o build/slices/$arch Sift.swift
done
lipo -create -output "$APP/Contents/MacOS/Sift" build/slices/arm64 build/slices/x86_64
rm -rf build/slices
# the app installs this core on first run, so Sift.app works without install.sh
mkdir -p "$APP/Contents/Resources/core"
rsync -a --exclude __pycache__ ../core/pa "$APP/Contents/Resources/core/"
cp ../VERSION "$APP/Contents/Resources/core/VERSION"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.kpiljoong.sift</string>
  <key>CFBundleName</key><string>Sift</string>
  <key>CFBundleExecutable</key><string>Sift</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>SiftSource</key><string>$SOURCE</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
