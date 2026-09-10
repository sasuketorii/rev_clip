#!/usr/bin/env bash
# Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
VOLUME_NAME="Revclip"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

usage() {
  cat <<'EOF'
Usage:
  create_dmg.sh [APP_PATH] [OUTPUT_DMG]

Environment variables:
  APP_PATH    Path to signed .app bundle (default: build/Release/Revclip.app)
  OUTPUT_DMG  Output DMG path (default: build/Revclip-<version>.dmg)
EOF
}

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

escape_apple_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [ "$#" -gt 2 ]; then
  usage >&2
  die "Too many arguments: expected at most 2, got $#."
fi

if [[ "$OSTYPE" != darwin* ]]; then
  die "This script can only run on macOS."
fi

command -v hdiutil >/dev/null 2>&1 || die "hdiutil is required."
command -v osascript >/dev/null 2>&1 || die "osascript is required."
[ -x "$PLIST_BUDDY" ] || die "PlistBuddy is required at $PLIST_BUDDY."

APP_PATH="${APP_PATH:-build/Release/Revclip.app}"
if [ "${1:-}" != "" ]; then
  APP_PATH="$1"
fi

[ -d "$APP_PATH" ] || die "App bundle not found: $APP_PATH"

APP_NAME="$(basename "$APP_PATH")"
APP_PLIST_PATH="$APP_PATH/Contents/Info.plist"
[ -f "$APP_PLIST_PATH" ] || die "Info.plist not found: $APP_PLIST_PATH"

VERSION="$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' "$APP_PLIST_PATH" 2>/dev/null || true)"
[ -n "$VERSION" ] || die "CFBundleShortVersionString not found in $APP_PLIST_PATH"

OUTPUT_DMG="${OUTPUT_DMG:-build/Revclip-${VERSION}.dmg}"
if [ "${2:-}" != "" ]; then
  OUTPUT_DMG="$2"
fi

OUTPUT_DIR="$(dirname "$OUTPUT_DMG")"
mkdir -p "$OUTPUT_DIR"
/bin/rm -f "$OUTPUT_DMG"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/revclip-dmg.XXXXXX")"
STAGING_DIR="$TMP_DIR/staging"
RW_DMG="$TMP_DIR/${VOLUME_NAME}-rw.dmg"
DEVICE_NODE=""
MOUNT_POINT=""

cleanup() {
  set +e
  if [ -n "$DEVICE_NODE" ]; then
    hdiutil detach "$DEVICE_NODE" -quiet >/dev/null 2>&1 || \
      hdiutil detach "$DEVICE_NODE" -force -quiet >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"

log "Creating temporary read/write DMG..."
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$RW_DMG" >/dev/null

log "Mounting temporary DMG..."
ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
DEVICE_NODE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/^\/dev\// {print $1; exit}')"
MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '/\/Volumes\// {print $NF; exit}')"
[ -n "$DEVICE_NODE" ] || die "Failed to resolve mounted device node."
[ -n "$MOUNT_POINT" ] || die "Failed to resolve mounted volume path."

MOUNTED_VOLUME_NAME="$(basename "$MOUNT_POINT")"
APP_NAME_ESCAPED="$(escape_apple_string "$APP_NAME")"
MOUNTED_VOLUME_NAME_ESCAPED="$(escape_apple_string "$MOUNTED_VOLUME_NAME")"

log "Configuring Finder window layout..."
osascript <<EOF >/dev/null
tell application "Finder"
  tell disk "$MOUNTED_VOLUME_NAME_ESCAPED"
    open
    set containerWindow to container window
    set current view of containerWindow to icon view
    set toolbar visible of containerWindow to false
    set statusbar visible of containerWindow to false
    set pathbar visible of containerWindow to false
    set sidebar width of containerWindow to 0
    set bounds of containerWindow to {100, 100, 700, 500}
    set iconOptions to icon view options of containerWindow
    set arrangement of iconOptions to not arranged
    set icon size of iconOptions to 128
    set text size of iconOptions to 16
    set position of item "$APP_NAME_ESCAPED" of containerWindow to {170, 200}
    set position of item "Applications" of containerWindow to {430, 200}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
EOF

sync

log "Detaching temporary DMG..."
hdiutil detach "$DEVICE_NODE" -quiet >/dev/null
DEVICE_NODE=""

log "Converting to compressed UDZO DMG..."
hdiutil convert \
  "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$OUTPUT_DMG" >/dev/null

log "Done: $OUTPUT_DMG"
