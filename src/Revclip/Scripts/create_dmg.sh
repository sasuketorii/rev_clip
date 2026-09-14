#!/usr/bin/env bash
# Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../../../design/Revclip-Installer.dmgtemplate"
RILMAZAFONE_APP="${RILMAZAFONE_APP:-/Applications/Rilmazafone.app}"
BUILDER="$RILMAZAFONE_APP/Contents/MacOS/Rilmazafone"

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  echo 'Usage: create_dmg.sh [APP_PATH] [OUTPUT_DMG]'
  echo 'Requires Rilmazafone 2.6 (GitHub edition); override RILMAZAFONE_APP if needed.'
  exit 0
fi
[[ $# -le 2 ]] || { echo 'Expected at most two arguments.' >&2; exit 1; }
APP_PATH="${1:-${APP_PATH:-build/Release/Revclip.app}}"
[[ -d "$APP_PATH" && -x "$BUILDER" ]] || { echo 'App bundle or Rilmazafone missing.' >&2; exit 1; }
BUILDER_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RILMAZAFONE_APP/Contents/Info.plist")"
[[ "$BUILDER_VERSION" == 2.6 ]] || { echo 'Rilmazafone 2.6 is required for reproducible layout.' >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
OUTPUT_DMG="${2:-${OUTPUT_DMG:-build/Revclip-${VERSION}.dmg}}"
[[ ! -e "$OUTPUT_DMG" ]] || { echo "Output already exists: $OUTPUT_DMG" >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT_DMG")"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/revclip-package.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
# Use the approved design unchanged; bind only the app built for this release.
ditto "$TEMPLATE" "$TEMP_DIR/Revclip.dmgtemplate"
python3 - "$TEMP_DIR/Revclip.dmgtemplate/document.json" "$APP_PATH" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text())
apps = [item for item in config['items'] if item['kind'] == 'app']
if len(apps) != 1:
    raise SystemExit('Expected exactly one application in the installer template')
apps[0]['sourcePath'] = str(pathlib.Path(sys.argv[2]).resolve(strict=True))
path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + '\n')
PY
"$BUILDER" build "$TEMP_DIR/Revclip.dmgtemplate" -o "$OUTPUT_DMG"
