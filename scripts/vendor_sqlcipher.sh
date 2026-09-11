#!/bin/sh
set -eu

# This script vendors SQLCipher's amalgamation from a hash-pinned release
# archive. The generated C is compiled with Apple's CommonCrypto provider;
# no OpenSSL headers or libraries are used.

SQLCIPHER_VERSION=4.19.0
SQLCIPHER_ARCHIVE_SHA256=7075f96cbabe45b4ecfc2e6b1745a625f856f695b0827a5506ce9ed85b906aa0
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ARCHIVE_PATH=${SQLCIPHER_SOURCE_ARCHIVE:-$ROOT_DIR/.local/sqlcipher-source/v4.19.0.tar.gz}
VENDOR_DIR=$ROOT_DIR/src/Revclip/Revclip/Vendor/SQLCipher
MAKE_JOBS=${SQLCIPHER_MAKE_JOBS:-2}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "vendor_sqlcipher: shasum or sha256sum is required" >&2
    exit 1
  fi
}

if [ ! -f "$ARCHIVE_PATH" ]; then
  echo "vendor_sqlcipher: source archive not found: $ARCHIVE_PATH" >&2
  echo "Download v$SQLCIPHER_VERSION to .local/sqlcipher-source/v4.19.0.tar.gz first." >&2
  exit 1
fi

actual_sha256=$(sha256_file "$ARCHIVE_PATH")
if [ "$actual_sha256" != "$SQLCIPHER_ARCHIVE_SHA256" ]; then
  echo "vendor_sqlcipher: source hash mismatch" >&2
  echo "expected: $SQLCIPHER_ARCHIVE_SHA256" >&2
  echo "actual:   $actual_sha256" >&2
  exit 1
fi

if ! command -v make >/dev/null 2>&1 || ! command -v cc >/dev/null 2>&1; then
  echo "vendor_sqlcipher: make and cc are required" >&2
  exit 1
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/revclip-sqlcipher.XXXXXX")
cleanup() {
  find "$WORK_DIR" -type f -exec unlink {} \; 2>/dev/null || true
  find "$WORK_DIR" -depth -type d -exec rmdir {} + 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

tar -xzf "$ARCHIVE_PATH" -C "$WORK_DIR"
SOURCE_DIR=$WORK_DIR/sqlcipher-$SQLCIPHER_VERSION
if [ ! -d "$SOURCE_DIR" ]; then
  echo "vendor_sqlcipher: archive did not contain sqlcipher-$SQLCIPHER_VERSION/" >&2
  exit 1
fi

# These flags are required by SQLCipher's build contract. Keep the crypto
# provider explicit so a future source/configure change cannot silently pick
# OpenSSL as a fallback.
SQLCIPHER_CFLAGS='-O2 -DSQLITE_HAS_CODEC -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown -DSQLCIPHER_CRYPTO_CC -DSQLITE_THREADSAFE=2 -DSQLITE_TEMP_STORE=2'
SQLCIPHER_LDFLAGS='-framework Security -framework CoreFoundation'

(
  cd "$SOURCE_DIR"
  ./configure \
    --disable-tcl \
    --disable-readline \
    --disable-shared \
    --enable-static \
    --with-tempstore=yes \
    CFLAGS="$SQLCIPHER_CFLAGS" \
    LDFLAGS="$SQLCIPHER_LDFLAGS"
  # The upstream fts5 rule removes this generated header before Lemon writes
  # it. A placeholder keeps the command portable to macOS environments that
  # route `rm -f` through a trash command which rejects missing paths.
  : > fts5parse.h
  # The target_source rule also removes and recreates tsrc; seed the empty
  # directory so the same trash-backed command has an existing target.
  mkdir -p tsrc
  make -j"$MAKE_JOBS" AMALGAMATION_GEN_FLAGS='--linemacros=0' sqlite3.c
)

for generated in sqlite3.c sqlite3.h sqlite3ext.h; do
  if [ ! -s "$SOURCE_DIR/$generated" ]; then
    echo "vendor_sqlcipher: missing generated $generated" >&2
    exit 1
  fi
done
if ! grep -q 'sqlite3_key' "$SOURCE_DIR/sqlite3.h"; then
  echo "vendor_sqlcipher: generated header has no sqlite3_key declaration" >&2
  exit 1
fi
if ! grep -q 'crypto_cc.c' "$SOURCE_DIR/sqlite3.c"; then
  echo "vendor_sqlcipher: amalgamation has no CommonCrypto provider" >&2
  exit 1
fi

mkdir -p "$VENDOR_DIR"
cp "$SOURCE_DIR/sqlite3.c" "$VENDOR_DIR/sqlite3.c"
cp "$SOURCE_DIR/sqlite3.h" "$VENDOR_DIR/sqlite3.h"
cp "$SOURCE_DIR/sqlite3ext.h" "$VENDOR_DIR/sqlite3ext.h"
cp "$SOURCE_DIR/LICENSE.md" "$VENDOR_DIR/LICENSE.md"
cp "$SOURCE_DIR/SQLITE_LICENSE.md" "$VENDOR_DIR/SQLITE_LICENSE.md"

echo "SQLCipher $SQLCIPHER_VERSION vendored"
echo "archive_sha256=$actual_sha256"
echo "amalgamation_sha256=$(sha256_file "$VENDOR_DIR/sqlite3.c")"
echo "header_sha256=$(sha256_file "$VENDOR_DIR/sqlite3.h")"
echo "flags=$SQLCIPHER_CFLAGS"
echo "linker_flags=$SQLCIPHER_LDFLAGS"
