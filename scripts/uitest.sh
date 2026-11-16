#!/bin/zsh
# Runs the debug build as a real app (so it can become active) with a UI script, then takes a
# window screenshot.   scripts/uitest.sh <pdf or ""> "<script>" <seconds> <out.png> [extra app args…]
cd "$(dirname "$0")/.."
pkill -x Blanko; sleep 0.4
APP=.build/dev/Blanko.app
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/Blanko "$APP/Contents/MacOS/Blanko"
sed -e "s/__VERSION__/dev/" -e "s/__BUILD__/0/" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null
PDF="$1"; SCRIPT="$2"; WAIT="$3"; OUT="$4"; shift 4
ARGS=(--library-dir "${BLANKO_LIB:-$PWD/testdata}" --uitest "$SCRIPT" "$@")
[[ -n "$PDF" ]] && ARGS+=(--open "$PDF")
open -n "$APP" --env BLANKO_TRACE=1 --stderr "${TMPDIR}blanko-trace.txt" --args $ARGS
sleep "$WAIT"
scripts/winshot.sh "$OUT"
