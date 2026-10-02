"""Exercise the production Swift 6 GCD termination callbacks in real processes."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Requires the macOS Swift toolchain')
class OCRWorkerLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='revclip-ocr-watchdog-')
        cls.addClassCleanup(cls.temporary.cleanup)
        root = pathlib.Path(__file__).resolve().parents[2]
        directory = pathlib.Path(cls.temporary.name)
        # Top-level Swift code must have this filename when compiled with others.
        shutil.copyfile(root / 'scripts/tests/fixtures/ocr_watchdog_probe.swift', directory / 'main.swift')
        cls.executable = directory / 'watchdog'
        subprocess.run(['swiftc', '-swift-version', '6', '-O',
                        str(root / 'src/Revclip/RevclipOCRWorker/RCOCRWorkerLifetime.swift'),
                        str(directory / 'main.swift'), '-o', str(cls.executable)],
                       check=True, capture_output=True, timeout=60)

    def test_timer_exits_with_124_instead_of_actor_isolation_trap(self):
        result = subprocess.run([str(self.executable), 'timer'], capture_output=True, timeout=8)
        self.assertEqual(result.returncode, 124, result.stderr.decode())

    def test_process_exit_callback_exits_with_1_instead_of_actor_isolation_trap(self):
        result = subprocess.run([str(self.executable), 'parent'], capture_output=True, timeout=8)
        self.assertEqual(result.returncode, 1, result.stderr.decode())


if __name__ == '__main__':
    unittest.main()
