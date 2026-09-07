#!/usr/bin/env python3
"""Offline packaging tests; only a harmless pause fixture is ever executed."""
import hashlib
import importlib.util
import json
import plistlib
import os
import shutil
import time
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


class ArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = ROOT / 'scripts/verify-artifact.py'
        if not path.exists():
            return
        spec = importlib.util.spec_from_file_location('artifact', path)
        assert spec is not None and spec.loader is not None
        cls.checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.checker)

    def setUp(self):
        self.assertTrue((ROOT / 'scripts/verify-artifact.py').exists(), 'artifact verifier not implemented')
        self.temp = tempfile.TemporaryDirectory(prefix='nesn-artifact-', dir=ROOT / 'build')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.meta = self.checker.load_metadata(ROOT / 'release.json')
        self.app = self.root / 'NESN Player.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Resources').mkdir()
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.checker.bundle_info(self.meta)))
        (self.app / 'Contents/Resources/LICENSE').write_bytes((ROOT / 'LICENSE').read_bytes())
        subprocess.run(['xcrun', 'clang', '-arch', 'arm64', '-mmacosx-version-min=14.0', '-x', 'c', '-', '-o', str(self.app / 'Contents/MacOS/NESNPlayer')], input=b'int main(void) { return 0; }\n', check=True, capture_output=True)
        self.sign()
        self.archive()

    def sign(self):
        subprocess.run(['codesign', '--force', '--sign', '-', str(self.app)], check=True, capture_output=True)

    def archive(self):
        self.zip = self.root / self.checker.archive_name(self.meta)
        with zipfile.ZipFile(self.zip, 'w', zipfile.ZIP_DEFLATED) as z:
            for p in sorted(self.app.rglob('*')):
                if p.is_file():
                    z.write(p, p.relative_to(self.root))
        self.hash = self.zip.with_suffix('.zip.sha256')
        self.hash.write_text(hashlib.sha256(self.zip.read_bytes()).hexdigest() + '  ' + self.zip.name + '\n')

    def verify(self):
        self.checker.verify(self.root, ROOT / 'release.json', ROOT / 'LICENSE')

    def test_valid_signed_archive(self):
        self.verify()

    def test_wrong_hash(self):
        self.hash.write_text('0' * 64 + '  ' + self.zip.name + '\n')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.verify()

    def test_missing_license(self):
        (self.app / 'Contents/Resources/LICENSE').unlink()
        self.sign()
        self.archive()
        with self.assertRaisesRegex(ValueError, 'LICENSE'):
            self.verify()

    def test_wrong_version(self):
        p = self.app / 'Contents/Info.plist'
        info = plistlib.loads(p.read_bytes())
        info['CFBundleVersion'] = '8'
        p.write_bytes(plistlib.dumps(info))
        self.sign()
        self.archive()
        with self.assertRaisesRegex(ValueError, 'CFBundleVersion'):
            self.verify()

    def test_invalid_signature(self):
        (self.app / 'Contents/MacOS/NESNPlayer').write_bytes(b'not executable')
        self.archive()
        with self.assertRaisesRegex(ValueError, 'codesign'):
            self.verify()

    def test_archive_does_not_match_bundle(self):
        (self.app / 'Contents/Resources/extra.txt').write_text('changed')
        self.sign()
        with self.assertRaisesRegex(ValueError, 'differ'):
            self.verify()

    def test_path_traversal(self):
        with zipfile.ZipFile(self.zip, 'a') as z:
            z.writestr('../escape', 'no')
        self.hash.write_text(hashlib.sha256(self.zip.read_bytes()).hexdigest() + '  ' + self.zip.name + '\n')
        with self.assertRaisesRegex(ValueError, 'unsafe'):
            self.verify()

    def test_wrong_binary_architecture(self):
        binary = self.app / 'Contents/MacOS/NESNPlayer'
        subprocess.run(['xcrun', 'clang', '-arch', 'x86_64', '-mmacosx-version-min=14.0', '-x', 'c', '-', '-o', str(binary)], input=b'int main(void) { return 0; }\n', check=True, capture_output=True)
        self.sign()
        self.archive()
        with self.assertRaisesRegex(ValueError, 'architecture'):
            self.verify()

    def test_newer_binary_deployment_floor(self):
        binary = self.app / 'Contents/MacOS/NESNPlayer'
        subprocess.run(['xcrun', 'clang', '-arch', 'arm64', '-mmacosx-version-min=15.0', '-x', 'c', '-', '-o', str(binary)], input=b'int main(void) { return 0; }\n', check=True, capture_output=True)
        self.sign()
        self.archive()
        with self.assertRaisesRegex(ValueError, 'deployment target'):
            self.verify()

    def test_wrong_plist_deployment_floor(self):
        p = self.app / 'Contents/Info.plist'
        info = plistlib.loads(p.read_bytes())
        info['LSMinimumSystemVersion'] = '15.0'
        p.write_bytes(plistlib.dumps(info))
        self.sign()
        self.archive()
        with self.assertRaisesRegex(ValueError, 'LSMinimumSystemVersion'):
            self.verify()

    def test_symlink_archive_entry(self):
        entry = zipfile.ZipInfo('NESN Player.app/Contents/link')
        entry.create_system = 3
        entry.external_attr = 0o120777 << 16
        with zipfile.ZipFile(self.zip, 'a') as z:
            z.writestr(entry, '/tmp/escape')
        self.hash.write_text(hashlib.sha256(self.zip.read_bytes()).hexdigest() + '  ' + self.zip.name + '\n')
        with self.assertRaisesRegex(ValueError, 'unsafe'):
            self.verify()

    def test_tag_consistency(self):
        script = str(ROOT / 'scripts/verify-artifact.py')
        good = subprocess.run(['python3', script, '--check-tag', 'v' + self.meta['version']], capture_output=True)
        bad = subprocess.run(['python3', script, '--check-tag', 'v0.0.0'], capture_output=True)
        self.assertEqual(good.returncode, 0)
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn(b'tag does not match', bad.stderr)

    def test_invalid_metadata(self):
        p = self.root / 'bad.json'
        m = dict(self.meta, architecture='x86_64')
        p.write_text(json.dumps(m))
        with self.assertRaisesRegex(ValueError, 'architecture'):
            self.checker.load_metadata(p)


class RunningTargetTests(unittest.TestCase):
    """Run only a harmless pause fixture, never the player or another viewer."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nesn-guard-', dir=ROOT / 'build')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts/build-app.sh', self.root / 'scripts/build-app.sh')
        self.binary = self.root / 'dist/NESN Player.app/Contents/MacOS/NESNPlayer'
        self.binary.parent.mkdir(parents=True)
        subprocess.run(['xcrun', 'clang', '-x', 'c', '-', '-o', str(self.binary)],
                       input=b'#include <unistd.h>\nint main(void) { write(1,"R",1); for (;;) pause(); }\n',
                       check=True, capture_output=True)
        self.marker = self.root / 'build-attempted'
        tools = self.root / 'tools'
        tools.mkdir()
        swift = tools / 'swift'
        swift.write_text('#!/bin/sh\ntouch "$PWD/build-attempted"\nexit 73\n')
        swift.chmod(0o755)
        self.env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'])

    def start_fixture(self, binary, *args):
        child = subprocess.Popen([str(binary), *args], stdout=subprocess.PIPE)
        assert child.stdout is not None
        stdout = child.stdout
        def cleanup():
            if child.poll() is None:
                child.terminate()  # Only the exact process handle created by this test.
            child.wait(timeout=5)
            stdout.close()
        self.addCleanup(cleanup)
        self.assertEqual(stdout.read(1), b'R')
        return child

    def package(self):
        return subprocess.run(['/bin/zsh', str(self.root / 'scripts/build-app.sh')],
                              env=self.env, capture_output=True, text=True, timeout=20)

    def test_running_exact_target_refuses_before_build(self):
        before = self.binary.read_bytes()
        child = self.start_fixture(self.binary)
        result = self.package()
        self.assertIn('Refusing to replace running target', result.stderr)
        self.assertIn(str(child.pid), result.stderr)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists(), 'build must not start while target runs')
        self.assertEqual(self.binary.read_bytes(), before)
        self.assertIsNone(child.poll(), 'guard must not stop the running process')

    def test_target_started_during_build_refuses_before_delete(self):
        swift = self.root / 'tools/swift'
        swift.write_text('#!/bin/sh\ntouch "$PWD/build-attempted"\n'
                         'while [ ! -f "$PWD/continue" ]; do sleep 0.02; done\n'
                         'printf "%s\\n" "$PWD/bin"\n')
        package = subprocess.Popen(['/bin/zsh', str(self.root / 'scripts/build-app.sh')],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True)
        def cleanup():
            if package.poll() is None:
                package.terminate()
            package.communicate(timeout=5)
        self.addCleanup(cleanup)
        deadline = time.monotonic() + 10
        while not self.marker.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(self.marker.exists())
        before = self.binary.read_bytes()
        child = self.start_fixture(self.binary)
        (self.root / 'continue').touch()
        _, stderr = package.communicate(timeout=20)
        self.assertIn('Refusing to replace running target', stderr)
        self.assertIn(str(child.pid), stderr)
        self.assertEqual(self.binary.read_bytes(), before)
        self.assertIsNone(child.poll())

    def test_other_path_same_name_and_target_argument_do_not_block(self):
        other = self.root / 'other/NESNPlayer'
        other.parent.mkdir()
        shutil.copy2(self.binary, other)
        child = self.start_fixture(other, str(self.binary))
        result = self.package()
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertTrue(self.marker.exists())
        self.assertIsNone(child.poll())


if __name__ == '__main__':
    (ROOT / 'build').mkdir(exist_ok=True)
    unittest.main(verbosity=2)
