"""Native installer integration; all source/config/destination paths are temporary.

Run with REVCLIP_NATIVE_CLI set to the compiled revclip executable. No build,
app launch, installed payload execution, network request or real agent home use.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CLI = os.environ.get("REVCLIP_NATIVE_CLI")
MANIFEST = ".revclip-managed.json"
FILES = {"SKILL.md": 0o644, "scripts/revclip": 0o755, "agents/openai.yaml": 0o644}


@unittest.skipUnless(CLI, "Set REVCLIP_NATIVE_CLI to the compiled native executable")
class NativeAgentInstallTest(unittest.TestCase):
    def setUp(self):
        self.cli = Path(CLI).resolve(strict=True)
        self.temp = tempfile.TemporaryDirectory(prefix="revclip-native-test-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name).resolve()
        self.home = self.work / "home"
        self.home.mkdir(mode=0o700)
        self.source = self.work / "AgentSupport"
        self.bundle = self.source / "revclip"
        for sub in ("scripts", "agents"):
            (self.bundle / sub).mkdir(parents=True, mode=0o700)
        (self.bundle / "SKILL.md").write_text("---\nname: revclip\n---\nTemporary native test skill\n")
        (self.bundle / "scripts/revclip").write_text("#!/bin/sh\nexit 79\n")
        (self.bundle / "agents/openai.yaml").write_text('interface:\n  display_name: "Revclip"\n')
        shutil.copyfile(ROOT / "agents/AgentSupport/providers.json", self.source / "providers.json")
        # Do not inherit any real provider overrides, credentials, or HOME.
        self.env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin", "TMPDIR": str(self.work),
                    "LANG": "en_US.UTF-8"}

    def invoke(self, command="install", provider="claude", extra=(), env=None, home=None):
        args = [str(self.cli), "agent", command, "--home", str(home or self.home),
                "--source", str(self.source)]
        if provider:
            args += ["--provider", provider]
        result = subprocess.run(args + list(extra), env={**self.env, **(env or {})},
                                cwd=self.work, capture_output=True, text=True, timeout=20)
        self.assertIn(result.returncode, (0, 1, 2), result.stderr)
        try:
            report = json.loads(result.stdout)
        except ValueError:
            self.fail(f"Expected JSON report; exit={result.returncode}, stdout={result.stdout!r}")
        return report, result.returncode

    def base(self, name=".claude", home=None):
        path = (home or self.home) / name
        path.mkdir(parents=True, mode=0o700)
        return path

    def leaf(self):
        return self.home / ".claude/skills/revclip"

    def success(self, command="install", **options):
        report, code = self.invoke(command, **options)
        self.assertEqual(code, 0, report)
        self.assertTrue(report["ok"], report)
        return report

    def row(self, report, ident="claude"):
        return next(row for row in report["providers"] if row["id"] == ident)

    def snapshot(self, root):
        return {str(p.relative_to(root)): (p.read_bytes(), stat.S_IMODE(p.stat().st_mode))
                for p in root.rglob("*") if p.is_file() and not p.is_symlink()}

    def verify_manifest(self, leaf):
        record = json.loads((leaf / MANIFEST).read_text())
        expected = {"schema_version": 1, "managed_by": "revclip-agent-support", "files": {
            name: {"sha256": hashlib.sha256((leaf / name).read_bytes()).hexdigest(), "mode": mode}
            for name, mode in FILES.items()}}
        self.assertEqual(record, expected)
        self.assertEqual((leaf / "scripts/revclip").read_bytes(), self.cli.read_bytes())
        for name, mode in FILES.items():
            self.assertEqual(stat.S_IMODE((leaf / name).stat().st_mode), mode)
        return record

    def conflict(self, **options):
        report, code = self.invoke(**options)
        self.assertEqual(code, 1, report)
        self.assertFalse(report["ok"], report)
        return report

    def test_absent_products_create_nothing(self):
        for command in ("inspect", "install"):
            report = self.success(command, provider=None)
            self.assertTrue(all(not row["detected"] for row in report["providers"]))
            self.assertEqual(list(self.home.iterdir()), [])

    def test_inspect_existing_base_is_read_only(self):
        base = self.base()
        row = self.row(self.success("inspect"))
        self.assertTrue(row["detected"])
        self.assertEqual(row["state"], "missing")
        self.assertEqual(list(base.iterdir()), [])

    def test_install_idempotent_manifest_and_native_payload(self):
        self.base()
        self.assertEqual(self.row(self.success())["action"], "installed")
        self.verify_manifest(self.leaf())
        before = self.snapshot(self.leaf())
        inode = self.leaf().stat().st_ino
        self.assertEqual(self.row(self.success())["action"], "unchanged")
        self.assertEqual(self.snapshot(self.leaf()), before)
        self.assertEqual(self.leaf().stat().st_ino, inode)
        self.assertEqual(self.row(self.success("inspect"))["state"], "current")

    def test_source_update_changes_hash_and_cleans_backup(self):
        self.base()
        self.success()
        old = self.verify_manifest(self.leaf())
        for name in ("SKILL.md", "agents/openai.yaml"):
            with self.subTest(name=name):
                with (self.bundle / name).open("a") as stream:
                    stream.write("\n# updated source\n")
                self.assertTrue(self.row(self.success("inspect"))["update_available"])
                self.assertEqual(self.row(self.success())["action"], "updated")
                new = self.verify_manifest(self.leaf())
                self.assertNotEqual(old["files"][name]["sha256"], new["files"][name]["sha256"])
                old = new
                self.assertEqual(sorted(p.name for p in self.leaf().parent.iterdir()), ["revclip"])

    def test_user_edit_preserved(self):
        self.base()
        self.success()
        (self.leaf() / "SKILL.md").write_text("user edit\n")
        before = self.snapshot(self.leaf())
        self.conflict()
        self.assertEqual(self.snapshot(self.leaf()), before)

    def test_unknown_extra_preserved(self):
        self.base()
        self.success()
        (self.leaf() / "personal.txt").write_text("do not delete")
        before = self.snapshot(self.leaf())
        self.conflict()
        self.assertEqual(self.snapshot(self.leaf()), before)

    def test_unmanaged_leaf_preserved(self):
        self.leaf().mkdir(parents=True)
        (self.leaf() / "SKILL.md").write_text("mine")
        before = self.snapshot(self.leaf())
        self.conflict()
        self.assertEqual(self.snapshot(self.leaf()), before)

    def test_symlink_leaf_preserved(self):
        base = self.base()
        (base / "skills").mkdir()
        outside = self.work / "outside"
        outside.mkdir()
        (outside / "keep").write_text("safe")
        self.leaf().symlink_to(outside, target_is_directory=True)
        self.conflict()
        self.assertTrue(self.leaf().is_symlink())
        self.assertEqual((outside / "keep").read_text(), "safe")

    def test_symlink_parent_preserved(self):
        base = self.base()
        outside = self.work / "outside"
        outside.mkdir()
        (base / "skills").symlink_to(outside, target_is_directory=True)
        self.conflict()
        self.assertEqual(list(outside.iterdir()), [])

    def test_hardlinked_managed_file_preserved(self):
        self.base()
        self.success()
        alias = self.work / "alias"
        os.link(self.leaf() / "SKILL.md", alias)
        before = alias.read_bytes()
        self.conflict()
        self.assertEqual(alias.read_bytes(), before)
        self.assertEqual(alias.stat().st_nlink, 2)

    def test_source_symlink_rejected(self):
        self.base()
        original = self.bundle / "SKILL.md"
        outside = self.work / "source-skill"
        original.rename(outside)
        original.symlink_to(outside)
        self.conflict()
        self.assertFalse(self.leaf().exists())

    def test_source_hardlink_rejected(self):
        self.base()
        os.link(self.bundle / "SKILL.md", self.work / "source-alias")
        self.conflict()
        self.assertFalse(self.leaf().exists())

    def test_env_root_exact_and_missing_override_no_fallback(self):
        self.base()
        override = self.work / "claude-override"
        self.success(env={"CLAUDE_CONFIG_DIR": str(override)})
        self.assertFalse(override.exists())
        self.assertFalse(self.leaf().exists())
        override.mkdir()
        self.success(env={"CLAUDE_CONFIG_DIR": str(override)})
        self.verify_manifest(override / "skills/revclip")
        self.assertFalse(self.leaf().exists())

    def test_explicit_home_takes_precedence_over_environment_home(self):
        selected = self.work / "selected-home"
        selected.mkdir()
        self.base(home=selected)
        self.success(home=selected)
        self.verify_manifest(selected / ".claude/skills/revclip")
        self.assertEqual(list(self.home.iterdir()), [])

    def test_codex_override_and_canonical_root(self):
        self.base(".codex")
        self.success(provider="codex")
        self.verify_manifest(self.home / ".agents/skills/revclip")
        isolated = self.work / "isolated-codex"
        isolated.mkdir()
        self.success(provider="codex", env={"CODEX_HOME": str(isolated)})
        self.verify_manifest(isolated / "skills/revclip")
        self.assertFalse((self.home / ".codex/skills").exists())

    def test_gemini_env_is_home_parent(self):
        override = self.work / "gemini-parent"
        (override / ".gemini").mkdir(parents=True)
        self.success(provider="gemini", env={"GEMINI_CLI_HOME": str(override)})
        self.verify_manifest(override / ".gemini/skills/revclip")
        self.assertFalse((override / "skills").exists())

    def test_python_manifest_migrates_to_native_payload(self):
        # Write the exact schema/modes used by the Python installer, including
        # both its old two-file and current three-file self-contained layouts.
        for include_metadata in (False, True):
            with self.subTest(include_metadata=include_metadata):
                if self.leaf().exists():
                    shutil.rmtree(self.leaf())
                self.leaf().mkdir(parents=True, mode=0o700)
                names = dict(FILES)
                if not include_metadata:
                    names.pop("agents/openai.yaml")
                for name, mode in names.items():
                    dest = self.leaf() / name
                    dest.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    shutil.copyfile(self.bundle / name, dest)
                    dest.chmod(mode)
                record = {"schema_version": 1, "managed_by": "revclip-agent-support", "files": {
                    name: {"sha256": hashlib.sha256((self.leaf() / name).read_bytes()).hexdigest(), "mode": mode}
                    for name, mode in names.items()}}
                manifest = self.leaf() / MANIFEST
                manifest.write_text(json.dumps(record, sort_keys=True) + "\n")
                manifest.chmod(0o644)
                self.assertEqual(self.row(self.success())["action"], "updated")
                self.verify_manifest(self.leaf())

    def test_malformed_manifest_preserved(self):
        self.base()
        self.success()
        manifest = self.leaf() / MANIFEST
        good = manifest.read_text()
        boolean_version = json.loads(good)
        boolean_version["schema_version"] = True
        for bad in ("{", json.dumps(boolean_version),
                    '{"schema_version":1,' + good[1:]):
            with self.subTest(manifest=bad[:40]):
                manifest.write_text(bad)
                self.conflict()
                self.assertEqual(manifest.read_text(), bad)


if __name__ == "__main__":
    unittest.main()
