#!/usr/bin/env python3
"""Verify the vendored framework and license against a checksum-pinned official archive."""
import argparse
import hashlib
import json
from pathlib import Path
import stat
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
MAX_ARCHIVE_BYTES = 128 * 1024 * 1024


def manifest(root):
    result = {}
    for path in sorted(root.rglob('*')):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[name] = ('link', str(path.readlink()))
        elif path.is_file():
            result[name] = ('file', hashlib.sha256(path.read_bytes()).hexdigest(),
                            bool(path.stat().st_mode & stat.S_IXUSR))
    return result


def verify(vendor, official):
    if manifest(vendor / 'Sparkle.framework') != manifest(official / 'Sparkle.framework'):
        raise ValueError('Vendored Sparkle framework differs from the pinned official archive')
    if (vendor / 'LICENSE').read_bytes() != (official / 'LICENSE').read_bytes():
        raise ValueError('Vendored Sparkle license differs from the pinned official archive')


def main():
    if sys.version_info < (3, 12):
        raise SystemExit("Python 3.12 or newer is required for safe archive extraction; do not use macOS system Python 3.9")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools-dir', type=Path, help='Keep verified official tools here for release signing')
    args = parser.parse_args()
    pin = json.loads((ROOT / 'scripts/build-tools.json').read_text())['sparkle']
    with tempfile.TemporaryDirectory(prefix='revclip-sparkle-') as temporary:
        archive = Path(temporary) / 'sparkle.tar.xz'
        digest = hashlib.sha256()
        total = 0
        with urllib.request.urlopen(pin['url'], timeout=30) as response, archive.open('wb') as output:
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > MAX_ARCHIVE_BYTES:
                    raise ValueError('Sparkle archive exceeds size limit')
                digest.update(chunk)
                output.write(chunk)
        if digest.hexdigest() != pin['sha256']:
            raise ValueError('Sparkle archive checksum mismatch')
        extracted = args.tools_dir or Path(temporary) / 'official'
        extracted.mkdir(parents=True, exist_ok=False)
        with tarfile.open(archive) as bundle:
            bundle.extractall(extracted, filter='data')
        verify(ROOT / 'src/Revclip/Revclip/Vendor/Sparkle', extracted)
        print(f"Sparkle {pin['version']}: framework, symlinks, executable modes and license match")


if __name__ == '__main__':
    main()
