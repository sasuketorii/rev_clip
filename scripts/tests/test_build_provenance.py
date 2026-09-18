import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ProvenanceTests(unittest.TestCase):
    def test_vendor_byte_symlink_and_executable_drift_is_rejected(self):
        verifier = load('verify_sparkle')
        with tempfile.TemporaryDirectory() as root:
            roots = [Path(root) / name for name in ('vendor', 'official')]
            for folder in roots:
                (folder / 'Sparkle.framework').mkdir(parents=True)
                (folder / 'LICENSE').write_text('fixture license')
                (folder / 'Sparkle.framework/binary').write_bytes(b'fixture')
                (folder / 'Sparkle.framework/current').symlink_to('binary')
            verifier.verify(*roots)
            binary = roots[0] / 'Sparkle.framework/binary'
            binary.write_bytes(b'tampered')
            with self.assertRaises(ValueError): verifier.verify(*roots)
            binary.write_bytes(b'fixture')
            binary.chmod(0o755)
            with self.assertRaises(ValueError): verifier.verify(*roots)
            binary.chmod(0o644)
            link = roots[0] / 'Sparkle.framework/current'
            link.unlink(); link.symlink_to('different')
            with self.assertRaises(ValueError): verifier.verify(*roots)

    def test_distribution_signature_rejects_missing_guards(self):
        verifier = load('verify_app_signature')
        details = 'Authority=Developer ID Application: Fixture\nTeamIdentifier=TESTTEAM\nCodeDirectory flags=0x10000(runtime)\nTimestamp=fixture\n'
        verifier.validate_details(details, 'TESTTEAM')
        for line in details.splitlines(keepends=True):
            with self.assertRaises(ValueError): verifier.validate_details(details.replace(line, ''), 'TESTTEAM')
        with self.assertRaises(ValueError): verifier.validate_details(details, 'OTHERTEAM')
