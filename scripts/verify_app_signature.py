#!/usr/bin/env python3
"""Fail closed unless the distribution app and its embedded code have release signatures."""
import argparse
import plistlib
from pathlib import Path
import subprocess


def validate_details(details, team):
    if (f'TeamIdentifier={team}\n' not in details or
            'Authority=Developer ID Application:' not in details or
            'runtime' not in next((line for line in details.splitlines() if 'flags=' in line), '') or
            not any(line.startswith('Timestamp=') for line in details.splitlines())):
        raise ValueError('Expected Developer ID, matching team, hardened runtime and secure timestamp')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--team', required=True)
    args = parser.parse_args()
    app = args.app
    sparkle = app / 'Contents/Frameworks/Sparkle.framework'
    components = [app, app / 'Contents/Helpers/revclip', sparkle,
                  sparkle / 'Versions/B/Autoupdate', sparkle / 'Versions/B/Updater.app',
                  sparkle / 'Versions/B/XPCServices/Downloader.xpc',
                  sparkle / 'Versions/B/XPCServices/Installer.xpc']
    for component in components:
        if not component.exists():
            raise ValueError(f'Missing signed component: {component.name}')
        subprocess.run(['codesign', '--verify', '--strict', str(component)], check=True)
        result = subprocess.run(['codesign', '--display', '--verbose=4', str(component)],
                                check=True, capture_output=True, text=True)
        validate_details(result.stderr, args.team)
    result = subprocess.run(['codesign', '--display', '--entitlements', '-', '--xml', str(app)],
                            check=True, capture_output=True)
    if result.stdout.strip() and plistlib.loads(result.stdout):
        raise ValueError('Unexpected main-app entitlements; review the least-privilege policy')
    print('Distribution signatures and empty main-app entitlements verified')


if __name__ == '__main__':
    main()
