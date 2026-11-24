#!/bin/zsh
# Builds dist/Blanko.app (universal, ad-hoc signed) and dist/Blanko.zip.
# Usage: scripts/build-app.sh [--install]   (--install copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.2.0"
BUILD="$(date +%Y%m%d%H%M)"
# The classic build system, by name: with Xcode on the Mac, SwiftPM's newer one stamps the binary
# with the SDK of the deployment target, and AppKit then treats the app like a macOS 14 app.
SPM=(--build-system native)

ARCHS=(${=BLANKO_ARCHS:-arm64 x86_64})
SLICES=()
for arch in $ARCHS; do
  swift build $SPM -c release --scratch-path ".build/$arch" --triple "$arch-apple-macosx14.0" --product Blanko
  SLICES+=("$(swift build $SPM -c release --scratch-path ".build/$arch" --triple "$arch-apple-macosx14.0" --show-bin-path)/Blanko")
done

APP=dist/Blanko.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create $SLICES -output "$APP/Contents/MacOS/Blanko"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
STAMP="$(otool -l "$APP/Contents/MacOS/Blanko" | awk '/LC_BUILD_VERSION/{f=1} f && $1=="sdk"{print $2; exit}')"
[[ "$STAMP" != 14.* ]] || { echo "error: the binary is stamped with SDK $STAMP, not the SDK it was built with" >&2; exit 1; }

ditto -c -k --keepParent "$APP" dist/Blanko.zip
echo "Built $APP ($VERSION, build $BUILD, sdk $STAMP)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Blanko || true
  sleep 0.5
  rm -rf /Applications/Blanko.app
  cp -R "$APP" /Applications/Blanko.app
  echo "Installed /Applications/Blanko.app"
fi
