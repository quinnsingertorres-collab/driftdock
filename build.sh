#!/usr/bin/env bash
# Builds Driftdock.app from source. Needs the Xcode Command Line Tools (xcode-select --install).
#   ./build.sh            → build/Driftdock.app
#   ./build.sh --install  → also copies it to /Applications and opens it
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Driftdock"
APP="build/${APP_NAME}.app"

echo "→ Compiling (release)…"
mkdir -p build
# If the build fails, nothing below runs: your installed Driftdock keeps working as it was.
set +e
swift build -c release 2>&1 | tee build/build-log.txt
status=${PIPESTATUS[0]}
set -e
if [[ $status -ne 0 ]]; then
  grep -E "error:|^[0-9 ]+\|" build/build-log.txt > build/errors.txt || true
  pbcopy < build/errors.txt 2>/dev/null || true
  echo ""
  echo "✗ Build failed. Your current Driftdock is still installed and running."
  echo "  The errors are copied to your clipboard (also saved in build/errors.txt)."
  echo "  Paste them to Claude to get a fix."
  exit 1
fi
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "→ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable local certificate so macOS keeps Accessibility and other
# permissions between builds. (An ad-hoc signature changes every build, which is
# why macOS kept asking again.)
SIGN_ID="Driftdock Local Signing"
if ! security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  echo "→ First build with stable signing: creating a local certificate…"
  ./setup-signing.sh || true
fi
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1 \
   && codesign --force --deep --sign "$SIGN_ID" "$APP" 2>/dev/null; then
  echo "→ Signed with \"$SIGN_ID\""
else
  echo "→ Signing (ad-hoc; permissions may need re-granting after each build)…"
  codesign --force --deep --sign - "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
  echo "→ Installing to /Applications…"
  pkill -x "$APP_NAME" 2>/dev/null || true
  # Wait for the old copy to fully quit, or macOS refuses to open the new one (error -600).
  for _ in $(seq 1 30); do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.2; done
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$APP" /Applications/
  sleep 0.5
  if ! open "/Applications/${APP_NAME}.app"; then
    echo "✗ macOS couldn't open Driftdock. To see why, run:"
    echo "  /Applications/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
    exit 1
  fi
  echo "✓ Driftdock is running. Look for the dock icon in your menu bar."
else
  echo "✓ Built $APP — run: open \"$APP\""
fi
