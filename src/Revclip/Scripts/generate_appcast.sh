#!/usr/bin/env bash
# Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_OUTPUT_PATH="build/appcast.xml"
DEFAULT_CHANNEL_TITLE="Revclip Changelog"
DEFAULT_CHANNEL_LINK="https://github.com/sasuketorii/rev_clip/releases"
DEFAULT_CHANNEL_DESCRIPTION="Latest Revclip releases."

usage() {
  cat <<'EOF'
Usage:
  generate_appcast.sh [options] <dmg_path> <short_version> <build_version> <download_url> [output_path]

Arguments:
  dmg_path        Path to release DMG
  short_version   Version string for sparkle:shortVersionString (for display)
  build_version   Internal build number for sparkle:version (CFBundleVersion)
  download_url    Public URL to the DMG on GitHub Releases
  output_path     Optional output path (default: build/appcast.xml)

Options:
  -o, --output <path>           Output appcast path (default: build/appcast.xml)
  --ed-signature <signature>    Optional Sparkle EdDSA signature
  -h, --help                    Show this help

Environment variables:
  APPCAST_CHANNEL_TITLE         Channel title (default: Revclip Changelog)
  APPCAST_CHANNEL_LINK          Channel link (default: GitHub Releases page)
  APPCAST_CHANNEL_DESCRIPTION   Channel description

Release operation notes:
  - Attach appcast.xml and the signed DMG to the same public GitHub release.
  - SUFeedURL in project.yml points to releases/latest/download/appcast.xml.
  - Forks must configure their own update URL and Sparkle signing key.
EOF
}

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

file_size_bytes() {
  local file_path="$1"
  if stat -f '%z' "$file_path" >/dev/null 2>&1; then
    stat -f '%z' "$file_path"
  else
    stat -c '%s' "$file_path"
  fi
}

OUTPUT_PATH="$DEFAULT_OUTPUT_PATH"
ED_SIGNATURE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      option_name="$1"
      shift
      [[ $# -gt 0 ]] || die "Missing value for $option_name."
      OUTPUT_PATH="$1"
      ;;
    --ed-signature)
      shift
      [[ $# -gt 0 ]] || die "Missing value for --ed-signature."
      ED_SIGNATURE="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
  shift
done

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  usage >&2
  die "Expected arguments: <dmg_path> <short_version> <build_version> <download_url> [output_path]"
fi

DMG_PATH="$1"
SHORT_VERSION="$2"
BUILD_VERSION="$3"
DOWNLOAD_URL="$4"

if [ "$#" -eq 5 ]; then
  if [ "$OUTPUT_PATH" != "$DEFAULT_OUTPUT_PATH" ]; then
    die "Output path was provided twice. Use either --output or [output_path]."
  fi
  OUTPUT_PATH="$5"
fi

[ -f "$DMG_PATH" ] || die "DMG file not found: $DMG_PATH"
[ -n "$SHORT_VERSION" ] || die "short_version must not be empty."
[ -n "$BUILD_VERSION" ] || die "build_version must not be empty."
[[ "$DOWNLOAD_URL" =~ ^https?:// ]] || die "download_url must start with http:// or https://"

FILE_SIZE="$(file_size_bytes "$DMG_PATH")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

CHANNEL_TITLE="${APPCAST_CHANNEL_TITLE:-$DEFAULT_CHANNEL_TITLE}"
CHANNEL_LINK="${APPCAST_CHANNEL_LINK:-$DEFAULT_CHANNEL_LINK}"
CHANNEL_DESCRIPTION="${APPCAST_CHANNEL_DESCRIPTION:-$DEFAULT_CHANNEL_DESCRIPTION}"

mkdir -p "$(dirname "$OUTPUT_PATH")"

ESCAPED_CHANNEL_TITLE="$(xml_escape "$CHANNEL_TITLE")"
ESCAPED_CHANNEL_LINK="$(xml_escape "$CHANNEL_LINK")"
ESCAPED_CHANNEL_DESCRIPTION="$(xml_escape "$CHANNEL_DESCRIPTION")"
ESCAPED_SHORT_VERSION="$(xml_escape "$SHORT_VERSION")"
ESCAPED_BUILD_VERSION="$(xml_escape "$BUILD_VERSION")"
ESCAPED_DOWNLOAD_URL="$(xml_escape "$DOWNLOAD_URL")"
ESCAPED_PUB_DATE="$(xml_escape "$PUB_DATE")"
ESCAPED_ED_SIGNATURE="$(xml_escape "$ED_SIGNATURE")"

if [ -n "$ESCAPED_ED_SIGNATURE" ]; then
  ED_SIGNATURE_ATTRIBUTE=" sparkle:edSignature=\"$ESCAPED_ED_SIGNATURE\""
else
  ED_SIGNATURE_ATTRIBUTE=""
fi

cat > "$OUTPUT_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>$ESCAPED_CHANNEL_TITLE</title>
    <link>$ESCAPED_CHANNEL_LINK</link>
    <description>$ESCAPED_CHANNEL_DESCRIPTION</description>
    <language>en</language>
    <item>
      <title>Version $ESCAPED_SHORT_VERSION</title>
      <link>$ESCAPED_CHANNEL_LINK</link>
      <guid isPermaLink="false">revclip-$ESCAPED_BUILD_VERSION</guid>
      <pubDate>$ESCAPED_PUB_DATE</pubDate>
      <sparkle:version>$ESCAPED_BUILD_VERSION</sparkle:version>
      <sparkle:shortVersionString>$ESCAPED_SHORT_VERSION</sparkle:shortVersionString>
      <enclosure url="$ESCAPED_DOWNLOAD_URL" type="application/x-apple-diskimage" length="$FILE_SIZE" sparkle:version="$ESCAPED_BUILD_VERSION" sparkle:shortVersionString="$ESCAPED_SHORT_VERSION"$ED_SIGNATURE_ATTRIBUTE />
    </item>
  </channel>
</rss>
EOF

log "Generated appcast: $OUTPUT_PATH"
