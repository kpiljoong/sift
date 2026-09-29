#!/bin/zsh
# Builds the release zip: dist/Sift-<version>.zip
# (prebuilt app + core + install/uninstall scripts). Run it from the source tree.
# With SIFT_UPDATE_KEY set it also builds the in-app update: sift-core-<v>.zip,
# sift-app-<v>.zip, and the signed list sift-update.json / sift-update.sig.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
NAME="Sift-$VERSION"
STAGE="$ROOT/dist/$NAME"
rm -rf "$ROOT/dist"
mkdir -p "$STAGE/core" "$STAGE/scripts"
"$ROOT/menubar/build.sh" >/dev/null
cp -R "$ROOT/menubar/build/Sift.app" "$STAGE/"
rsync -a --exclude __pycache__ "$ROOT/core/pa" "$STAGE/core/"
cp "$ROOT/scripts/install.sh" "$ROOT/scripts/uninstall.sh" "$STAGE/scripts/"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$ROOT/VERSION" "$STAGE/"
(cd "$ROOT/dist" && ditto -c -k --keepParent "$NAME" "$NAME.zip")
echo "$ROOT/dist/$NAME.zip"

if [[ -z "${SIFT_UPDATE_KEY:-}" ]]; then
  echo "SIFT_UPDATE_KEY is not set; skipping the in-app update files" >&2
  exit 0
fi
cd "$ROOT/dist"
ditto -c -k --keepParent "$NAME/core/pa" "sift-core-$VERSION.zip"
ditto -c -k --keepParent "$NAME/Sift.app" "sift-app-$VERSION.zip"
SOURCE="$(/usr/libexec/PlistBuddy -c 'Print :SiftSource' "$NAME/Sift.app/Contents/Info.plist")"
python3 - "$VERSION" "$SOURCE" > sift-update.json <<'PY'
import hashlib, json, os, sys
version, source = sys.argv[1:]
def part(name, **extra):
    data = open(name, "rb").read()
    return {"file": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(), **extra}
print(json.dumps({"version": version, "core": part(f"sift-core-{version}.zip"),
                  "app": part(f"sift-app-{version}.zip", source=source)}, indent=2))
PY
swift "$ROOT/scripts/update-sign.swift" sign sift-update.json > sift-update.sig
echo "$ROOT/dist/sift-update.json (signed)"
