#!/usr/bin/env python3
"""Validate local and archived ad-hoc bundles without executing the app."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
APP = 'NESN Player.app'


def load_metadata(path):
    m = json.loads(Path(path).read_text())
    if set(m) != {'version', 'build', 'architecture', 'minimum_macos'}:
        raise ValueError('unexpected release metadata fields')
    if not isinstance(m['version'], str) or not re.fullmatch(r'\d+\.\d+\.\d+(?:-[a-z0-9.-]+)?', m['version']):
        raise ValueError('invalid version')
    if not isinstance(m['build'], str) or not re.fullmatch(r'[1-9]\d*', m['build']):
        raise ValueError('invalid build')
    if m['architecture'] != 'arm64':
        raise ValueError('unsupported architecture')
    if m['minimum_macos'] != '14.0':
        raise ValueError('unsupported minimum macOS')
    return m


def archive_name(m):
    return f"NESN-Player-v{m['version']}-macOS-{m['architecture']}.zip"


def bundle_info(m):
    return {
        'CFBundleExecutable': 'NESNPlayer',
        'CFBundleIdentifier': 'io.github.pzzzy.nesn-player',
        'CFBundleName': 'NESN Player',
        'CFBundleDisplayName': 'NESN Player',
        'CFBundlePackageType': 'APPL',
        'CFBundleIconFile': 'AppIcon',
        'CFBundleShortVersionString': m['version'],
        'CFBundleVersion': m['build'],
        'LSMinimumSystemVersion': m['minimum_macos'],
        'LSArchitecturePriority': [m['architecture']],
        'NSHighResolutionCapable': True,
    }


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise ValueError(f'{args[0]} failed: {result.stderr.strip()}')
    return result.stdout + result.stderr


def verify_bundle(app, m, license_path):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    for key, value in bundle_info(m).items():
        if info.get(key) != value:
            raise ValueError(f'bundle metadata mismatch: {key}')
    notice = app / 'Contents/Resources/LICENSE'
    if not notice.is_file() or notice.read_bytes() != Path(license_path).read_bytes():
        raise ValueError('missing or changed LICENSE')
    run('codesign', '--verify', '--deep', '--strict', str(app))
    if 'Signature=adhoc' not in run('codesign', '-d', '--verbose=2', str(app)):
        raise ValueError('expected ad-hoc signature')
    binary = app / 'Contents/MacOS/NESNPlayer'
    if run('lipo', '-archs', str(binary)).strip() != m['architecture']:
        raise ValueError('binary architecture mismatch')
    commands = run('otool', '-l', str(binary))
    versions = re.findall(r'\bminos\s+(\d+(?:\.\d+)+)', commands)
    if not versions or any(tuple(map(int, v.split('.'))) > (14, 0, 0) for v in versions):
        raise ValueError('binary deployment target exceeds declared macOS minimum')


def inventory(app):
    result = {}
    for p in app.rglob('*'):
        if p.is_symlink():
            raise ValueError('unsafe bundle symlink')
        if p.is_file():
            result[str(p.relative_to(app))] = hashlib.sha256(p.read_bytes()).hexdigest()
    return result


def verify(dist, metadata_path=ROOT / 'release.json', license_path=ROOT / 'LICENSE'):
    dist = Path(dist)
    m = load_metadata(metadata_path)
    archive = dist / archive_name(m)
    expected = hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n'
    if archive.with_suffix('.zip.sha256').read_text() != expected:
        raise ValueError('checksum mismatch')
    with tempfile.TemporaryDirectory(prefix='verify-', dir=dist) as temp:
        with zipfile.ZipFile(archive) as z:
            seen = set()
            for item in z.infolist():
                p = PurePosixPath(item.filename)
                mode = item.external_attr >> 16
                if (p.is_absolute() or '..' in p.parts or not p.parts or p.parts[0] != APP
                        or item.filename in seen or stat.S_ISLNK(mode) or '\\' in item.filename):
                    raise ValueError('unsafe archive entry')
                seen.add(item.filename)
            if z.testzip() is not None:
                raise ValueError('archive CRC failure')
            z.extractall(temp)
            for item in z.infolist():
                mode = item.external_attr >> 16
                if not item.is_dir() and mode:
                    (Path(temp) / item.filename).chmod(mode & 0o777)
        extracted = Path(temp) / APP
        verify_bundle(extracted, m, license_path)
        verify_bundle(dist / APP, m, license_path)
        if inventory(extracted) != inventory(dist / APP):
            raise ValueError('archive and local bundle differ')
    print(f"Verified {archive.name}: version {m['version']} build {m['build']}, arm64/macOS 14, LICENSE, ad-hoc signature, ZIP and SHA-256")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dist', type=Path, default=ROOT / 'dist')
    parser.add_argument('--write-plist', type=Path)
    parser.add_argument('--archive-name', action='store_true')
    parser.add_argument('--check-tag')
    args = parser.parse_args()
    m = load_metadata(ROOT / 'release.json')
    if args.write_plist:
        args.write_plist.write_bytes(plistlib.dumps(bundle_info(m)))
    elif args.archive_name:
        print(archive_name(m))
    elif args.check_tag:
        if args.check_tag != 'v' + m['version']:
            parser.error('tag does not match release.json version')
    else:
        verify(args.dist)


if __name__ == '__main__':
    main()
