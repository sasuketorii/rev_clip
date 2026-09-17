#!/usr/bin/env python3
"""Verify public release delivery; local builds alone cannot satisfy this check.

Uses only the Python standard library. Does not launch apps or access user data.
Signature presence is checked here; cryptographic and Apple checks remain separate.
"""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

REPO = 'sasuketorii/rev_clip'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def fetch(url, limit=1024 * 1024):
    with urllib.request.urlopen(url, timeout=30) as response:
        data = response.read(limit + 1)
    require(len(data) <= limit, 'Response exceeds size limit')
    return data


def api_token():
    """Optional token for GitHub API metadata only; never for the feed or the artifact."""
    token = os.environ.get('GITHUB_TOKEN', '').strip()
    require(not token or bool(re.fullmatch(r'[A-Za-z0-9_.\-]{1,255}', token)), 'GITHUB_TOKEN has an unexpected form')
    return token


def api_request(url, token):
    """Request for exactly https://api.github.com. The token is an unredirected header:
    urllib does not copy it to a redirect target, whatever that target is."""
    parts = urllib.parse.urlsplit(url)
    require(parts.scheme == 'https' and parts.netloc == 'api.github.com', 'Not a GitHub API URL')
    request = urllib.request.Request(url, headers={'Accept': 'application/vnd.github+json'})
    if token:
        request.add_unredirected_header('Authorization', 'Bearer ' + token)
    return request


def fetch_api(url, limit=1024 * 1024):
    """Release and tag metadata. Anonymous without GITHUB_TOKEN; what is compared is the same."""
    try:
        return fetch(api_request(url, api_token()), limit)
    except urllib.error.HTTPError as error:
        if error.code in (403, 429):
            raise ValueError(f'GitHub API refused the metadata request (HTTP {error.code}, usually the anonymous '
                             'rate limit of a shared address); set GITHUB_TOKEN for the API lookups') from None
        raise


def verify_feed(data, tag, build, release):
    require(release['tag_name'] == tag, 'Latest public release does not match requested tag')
    require(not release.get('draft') and not release.get('prerelease'), 'Release is not stable/public')
    items = ET.fromstring(data).findall('./channel/item')
    require(bool(items), 'Update feed is empty')
    newest = max(items, key=lambda item: int(item.findtext(NS + 'version', '0')))
    require(newest.findtext(NS + 'version') == build, 'Update feed build does not match')
    require(newest.findtext(NS + 'shortVersionString') == tag[1:], 'Update feed version does not match')
    enclosure = newest.find('enclosure')
    require(enclosure is not None, 'Missing update enclosure')
    expected_url = f'https://github.com/{REPO}/releases/download/{tag}/Revclip-{tag}.dmg'
    require(enclosure.get('url') == expected_url, 'Update URL points to a different artifact')
    require(bool(enclosure.get(NS + 'edSignature')), 'Missing Sparkle signature')
    size = int(enclosure.get('length', '0'))
    require(0 < size <= 512 * 1024 * 1024, 'Invalid update size')
    assets = {asset['name']: asset for asset in release['assets']}
    require('appcast.xml' in assets, 'Release has no appcast asset')
    asset = assets.get(f'Revclip-{tag}.dmg')
    require(asset is not None and asset['size'] == size and asset['browser_download_url'] == expected_url,
            'Release artifact and update feed differ')
    return expected_url, size, asset.get('digest')


def verify_app(path, tag, build, demo=False):
    with (path / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    require(info.get('CFBundleShortVersionString') == tag[1:] and info.get('CFBundleVersion') == build,
            f'{path.name}: installed version/build does not match release')
    expected_id = 'com.revclip.revclip-demo' if demo else 'com.revclip.Revclip'
    require(info.get('CFBundleIdentifier') == expected_id, f'{path.name}: wrong bundle identity')
    expected_feed = '' if demo else f'https://github.com/{REPO}/releases/latest/download/appcast.xml'
    require(info.get('SUFeedURL', '') == expected_feed, f'{path.name}: wrong update feed')
    binary = path / 'Contents/MacOS' / info['CFBundleExecutable']
    with binary.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {'name': path.name, 'version': tag[1:], 'build': build, 'binary_sha256': digest}


def public_tag_sha(tag):
    url = f'https://api.github.com/repos/{REPO}/git/ref/tags/{urllib.parse.quote(tag, safe="")}'
    obj = json.loads(fetch_api(url))['object']
    for _ in range(5):
        if obj['type'] == 'commit':
            return obj['sha']
        require(obj['type'] == 'tag', 'Tag does not resolve to a commit')
        obj = json.loads(fetch_api(f'https://api.github.com/repos/{REPO}/git/tags/{obj["sha"]}'))['object']
    raise ValueError('Excessive tag nesting')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--sha', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--demo-app', type=Path)
    args = parser.parse_args()
    require(bool(re.fullmatch(r'v\d+\.\d+\.\d+', args.tag)), 'Invalid release tag')
    require(bool(re.fullmatch(r'[1-9]\d*', args.build)), 'Invalid build')
    require(bool(re.fullmatch(r'[0-9a-f]{40}', args.sha)), 'Full commit SHA required')
    require(bool(args.app) == bool(args.demo_app), 'Verify both installed apps together, or neither')
    # Remove only our requested receipt so a failed check cannot leave a stale PASS.
    args.output.unlink(missing_ok=True)
    require(public_tag_sha(args.tag) == args.sha, 'Public tag points to a different commit')
    release = json.loads(fetch_api(f'https://api.github.com/repos/{REPO}/releases/latest'))
    # The feed and the artifact are always fetched as an anonymous user would get them.
    feed = fetch(f'https://github.com/{REPO}/releases/latest/download/appcast.xml')
    url, expected_size, expected_digest = verify_feed(feed, args.tag, args.build, release)
    digest = hashlib.sha256()
    count = 0
    deadline = time.monotonic() + 180
    with urllib.request.urlopen(url, timeout=30) as response:
        while True:
            require(time.monotonic() < deadline, 'Artifact download deadline exceeded')
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            count += len(chunk)
            require(count <= expected_size, 'Downloaded artifact exceeds declared size')
            digest.update(chunk)
    require(count == expected_size, 'Downloaded artifact is truncated')
    digest_hex = digest.hexdigest()
    if expected_digest:
        require(expected_digest == 'sha256:' + digest_hex, 'GitHub asset digest mismatch')
    apps = []
    if args.app:
        apps = [verify_app(args.app, args.tag, args.build), verify_app(args.demo_app, args.tag, args.build, True)]
    result = {'status': 'passed', 'scope': 'public-delivery-and-installed-versions' if apps else 'public-delivery',
              'tag': args.tag, 'source_sha': args.sha, 'build': args.build, 'release_url': release['html_url'],
              'dmg_sha256': digest_hex, 'dmg_bytes': count, 'apps': apps,
              'not_verified_here': ['Apple notarization', 'cryptographic Sparkle signature',
                                    'installed binary provenance', 'actual updater installation', 'real UI acceptance']}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=args.output.parent, delete=False) as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
        temporary = Path(stream.name)
    temporary.replace(args.output)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        message = str(error)
        secret = os.environ.get('GITHUB_TOKEN', '').strip()
        if secret:
            message = message.replace(secret, '***')
        print(f'Release delivery FAILED: {message}', file=sys.stderr)
        sys.exit(1)
