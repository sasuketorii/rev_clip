#!/usr/bin/env bash
# Install only the checksum-verified official binary into a caller-owned directory.
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
destination="${1:?usage: install_xcodegen.sh destination}"
mkdir -p "$destination"
read -r version url digest < <(python3 - "$root/build-tools.json" <<'PY'
import json, sys
pin = json.load(open(sys.argv[1]))['xcodegen']
print(pin['version'], pin['url'], pin['sha256'])
PY
)
archive="$destination/xcodegen.zip"
curl --fail --silent --show-error --location --connect-timeout 15 --max-time 120 "$url" -o "$archive"
printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c -
ditto -xk "$archive" "$destination/unpacked"
binary="$destination/unpacked/xcodegen/bin/xcodegen"
[[ -x "$binary" ]] || { echo 'Pinned XcodeGen executable missing' >&2; exit 1; }
[[ "$("$binary" --version)" == "Version: $version" ]] || { echo 'XcodeGen version mismatch' >&2; exit 1; }
mkdir -p "$destination/bin"
cp "$binary" "$destination/bin/xcodegen"
# XcodeGen resolves SettingPresets relative to its executable prefix.
# A binary-only copy can generate a project with missing default build settings.
[[ -d "$destination/unpacked/xcodegen/share/xcodegen/SettingPresets" ]] || { echo 'XcodeGen SettingPresets missing' >&2; exit 1; }
ditto "$destination/unpacked/xcodegen/share" "$destination/share"
