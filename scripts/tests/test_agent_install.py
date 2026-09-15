"""Isolated installer acceptance tests; never inspect or install into real homes."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


# The installer directory is bundled as an app resource; imports must not add
# interpreter cache files to that source bundle.
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[2]
INSTALL = ROOT / "agents/AgentSupport/install.py"
spec = importlib.util.spec_from_file_location("agent_install", INSTALL)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
PROVIDERS = json.loads(INSTALL.with_name("providers.json").read_text())["providers"]


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name).resolve()
        self.home = self.work / "home"
        self.home.mkdir()
        self.source = self.work / "source"
        (self.source / "scripts").mkdir(parents=True)
        (self.source / "SKILL.md").write_text("---\nname: revclip\n---\nfixture\n")
        (self.source / "scripts/revclip").write_text("#!/bin/sh\nexit 0\n")
        (self.source / "agents").mkdir()
        (self.source / "agents/openai.yaml").write_text('interface:\n  display_name: "Revclip"\n')

    def invoke(self, command="install", env=None, app="Revclip", providers=None):
        return installer.run(command, app, home=self.home, env=env or {},
                             source=self.source, providers=providers or PROVIDERS)

    def row(self, report, ident):
        return next(row for row in report["providers"] if row["id"] == ident)

    def base(self, name):
        path = self.home / name
        path.mkdir(parents=True, exist_ok=True)
        return path

    def claude_leaf(self):
        return self.home / ".claude/skills/revclip"

    def test_absent_products_are_never_created(self):
        for command in ("inspect", "install"):
            report, code = self.invoke(command)
            self.assertEqual(code, 0)
            self.assertTrue(all(not row["detected"] for row in report["providers"]))
            self.assertEqual(list(self.home.iterdir()), [])

    def test_inspect_does_not_create_skills(self):
        base = self.base(".claude")
        report, code = self.invoke("inspect")
        self.assertEqual(code, 0)
        self.assertEqual(self.row(report, "claude")["state"], "missing")
        self.assertTrue(self.row(report, "claude")["detected"])
        self.assertEqual(list(base.iterdir()), [])

    def test_all_primary_roots_and_unsupported_cli(self):
        expected = {
            "codex": (".codex", ".agents/skills"),
            "claude": (".claude", ".claude/skills"),
            "cursor": (".cursor", ".cursor/skills"),
            "antigravity2": (".gemini/config", ".gemini/config/skills"),
            "antigravity-ide": (".gemini/antigravity", ".gemini/antigravity/skills"),
            "gemini": (".gemini", ".gemini/skills"),
            "grok": (".grok", ".grok/skills"),
            "kimi": (".kimi-code", ".kimi-code/skills"),
            "kimi-legacy": (".kimi", ".kimi/skills"),
            "hermes": (".hermes", ".hermes/skills"),
            "deepseek-harness": (".dsh", ".dsh/skills"),
        }
        for base, _ in expected.values():
            self.base(base)
        cli_base = self.base(".gemini/antigravity-cli")
        report, code = self.invoke()
        self.assertEqual(code, 0, report)
        for ident, (_, root) in expected.items():
            row = self.row(report, ident)
            self.assertEqual(row["path"], str(self.home / root / "revclip"))
            self.assertEqual(row["state"], "installed")
            self.assertEqual((Path(row["path"]) / "SKILL.md").read_bytes(),
                             (self.source / "SKILL.md").read_bytes())
            metadata = Path(row["path"]) / "agents/openai.yaml"
            self.assertEqual(metadata.read_bytes(), (self.source / "agents/openai.yaml").read_bytes())
            self.assertEqual(metadata.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.row(report, "antigravity-cli")["state"], "unsupported")
        self.assertEqual(list(cli_base.iterdir()), [])
        self.assertTrue(self.row(report, "deepseek-harness")["experimental"])

    def test_custom_env_roots_and_gemini_home_parent(self):
        env = {}
        selected = [p for p in PROVIDERS if p.get("env")]
        for p in selected:
            root = self.work / p["id"]
            base = root / ".gemini" if p["id"] == "gemini" else root
            base.mkdir(parents=True)
            env[p["env"]] = str(root)
        report, code = self.invoke(env=env)
        self.assertEqual(code, 0, report)
        for p in selected:
            base = Path(env[p["env"]])
            if p["id"] == "gemini":
                base /= ".gemini"
            self.assertEqual(self.row(report, p["id"])["path"], str(base / "skills/revclip"))
            self.assertTrue((base / "skills/revclip/SKILL.md").is_file())
        self.assertFalse((self.home / ".agents").exists())

    def test_missing_override_does_not_fall_back_or_create(self):
        self.base(".claude")
        self.base(".codex")
        env = {"CLAUDE_CONFIG_DIR": str(self.work / "absent-claude"),
               "CODEX_HOME": str(self.work / "absent-codex"),
               "GEMINI_CLI_HOME": str(self.work)}
        report, code = self.invoke(env=env)
        self.assertEqual(code, 0)
        for ident in ("claude", "codex", "gemini"):
            self.assertFalse(self.row(report, ident)["detected"])
        self.assertFalse((self.work / "absent-claude").exists())
        self.assertFalse((self.work / "absent-codex").exists())
        self.assertFalse((self.work / ".gemini").exists())
        self.assertFalse((self.home / ".agents").exists())

    def test_ignored_env_does_not_invent_targets(self):
        other = self.base("other")
        report, code = self.invoke(env={"KIMI_SHARE_DIR": str(other),
                                       "DSH_AGENTS_HOME": str(other),
                                       "ANTIGRAVITY_HOME": str(other)})
        self.assertEqual(code, 0)
        self.assertFalse(any(r["detected"] for r in report["providers"]))
        self.assertEqual(list(other.iterdir()), [])

    def test_idempotent_and_app_independent_then_managed_update(self):
        self.base(".claude")
        self.assertEqual(self.invoke()[1], 0)
        leaf = self.claude_leaf()
        inode = leaf.stat().st_ino
        manifest = (leaf / installer.MANIFEST).read_bytes()
        report, code = self.invoke(app="revclip-demo")
        self.assertEqual(code, 0)
        self.assertEqual(self.row(report, "claude")["action"], "unchanged")
        self.assertEqual(leaf.stat().st_ino, inode)
        self.assertEqual((leaf / installer.MANIFEST).read_bytes(), manifest)
        self.assertEqual((leaf / "scripts/revclip").stat().st_mode & 0o777, 0o755)
        (self.source / "SKILL.md").write_text("new version")
        inspection, _ = self.invoke("inspect")
        self.assertTrue(self.row(inspection, "claude")["update_available"])
        report, code = self.invoke()
        self.assertEqual(code, 0)
        self.assertEqual(self.row(report, "claude")["action"], "updated")
        self.assertEqual((leaf / "SKILL.md").read_text(), "new version")
        self.assertEqual(list(leaf.parent.iterdir()), [leaf])

    def test_unmanaged_tree_preserved_on_inspect_and_install(self):
        leaf = self.claude_leaf()
        leaf.mkdir(parents=True)
        (leaf / "notes.txt").write_text("mine")
        for command in ("inspect", "install"):
            report, code = self.invoke(command)
            self.assertEqual(code, 1)
            self.assertEqual(self.row(report, "claude")["state"], "conflict")
            self.assertEqual((leaf / "notes.txt").read_text(), "mine")

    def test_edited_managed_tree_preserved(self):
        self.base(".claude")
        self.invoke()
        (self.claude_leaf() / "SKILL.md").write_text("user changes")
        report, code = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(self.row(report, "claude")["state"], "conflict")
        self.assertEqual((self.claude_leaf() / "SKILL.md").read_text(), "user changes")

    def test_metadata_update_is_hashed_read_back_and_old_tree_removed(self):
        self.base(".claude")
        self.assertEqual(self.invoke()[1], 0)
        metadata = self.claude_leaf() / "agents/openai.yaml"
        marker = self.claude_leaf() / installer.MANIFEST
        old_hash = json.loads(marker.read_text())["files"]["agents/openai.yaml"]["sha256"]
        updated = 'interface:\n  display_name: "Updated Revclip"\n'
        (self.source / "agents/openai.yaml").write_text(updated)
        report, code = self.invoke()
        self.assertEqual(code, 0, report)
        self.assertEqual(self.row(report, "claude")["action"], "updated")
        self.assertEqual(metadata.read_text(), updated)
        self.assertNotEqual(json.loads(marker.read_text())["files"]["agents/openai.yaml"]["sha256"],
                            old_hash)
        report, code = self.invoke("inspect")
        self.assertEqual(code, 0, report)
        self.assertFalse(self.row(report, "claude")["update_available"])
        self.assertEqual(list(self.claude_leaf().parent.iterdir()), [self.claude_leaf()])

    def test_edited_or_missing_metadata_is_not_adopted(self):
        self.base(".claude")
        self.invoke()
        metadata = self.claude_leaf() / "agents/openai.yaml"
        metadata.write_text("user metadata")
        self.assertEqual(self.invoke()[1], 1)
        self.assertEqual(metadata.read_text(), "user metadata")
        metadata.unlink()
        metadata.parent.rmdir()
        report, code = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(self.row(report, "claude")["state"], "conflict")
        self.assertFalse(metadata.exists())

    def test_legacy_managed_copy_upgrades(self):
        self.base(".claude")
        self.invoke()
        leaf = self.claude_leaf()
        (leaf / "agents/openai.yaml").unlink()
        (leaf / "agents").rmdir()
        marker = leaf / installer.MANIFEST
        record = json.loads(marker.read_text())
        del record["files"]["agents/openai.yaml"]
        marker.write_text(json.dumps(record))
        report, code = self.invoke("inspect")
        self.assertEqual(code, 0, report)
        self.assertTrue(self.row(report, "claude")["update_available"])
        report, code = self.invoke()
        self.assertEqual(code, 0, report)
        self.assertEqual(self.row(report, "claude")["action"], "updated")
        self.assertEqual((leaf / "agents/openai.yaml").read_bytes(),
                         (self.source / "agents/openai.yaml").read_bytes())
        self.assertEqual(list(leaf.parent.iterdir()), [leaf])

    def test_metadata_directory_symlink_rejected(self):
        self.base(".claude")
        self.invoke()
        metadata_dir = self.claude_leaf() / "agents"
        target = self.work / "saved-metadata"
        metadata_dir.rename(target)
        metadata_dir.symlink_to(target, target_is_directory=True)
        self.assertEqual(self.invoke()[1], 1)
        self.assertTrue(metadata_dir.is_symlink())
        self.assertTrue((target / "openai.yaml").is_file())

    def test_metadata_staging_failure_cleans_partial_tree(self):
        self.base(".claude")
        self.invoke()
        old_metadata = (self.claude_leaf() / "agents/openai.yaml").read_bytes()
        (self.source / "agents/openai.yaml").write_text("new metadata")
        write = installer.write_file

        def fail_metadata(fd, name, *args):
            if name == "openai.yaml":
                raise OSError("injected metadata write failure")
            return write(fd, name, *args)

        with patch.object(installer, "write_file", side_effect=fail_metadata):
            report, code = self.invoke()
        self.assertEqual(code, 1, report)
        self.assertEqual((self.claude_leaf() / "agents/openai.yaml").read_bytes(), old_metadata)
        self.assertEqual(list(self.claude_leaf().parent.iterdir()), [self.claude_leaf()])

    def test_actual_bundle_inspect_and_install_in_temporary_home(self):
        self.base(".claude")
        source = INSTALL.parent / "revclip"
        for command in ("inspect", "install", "inspect"):
            report, code = installer.run(command, home=self.home, env={}, source=source)
            self.assertEqual(code, 0, report)
            self.assertIsNone(report["source_error"], report)
        for filename in installer.FILES:
            self.assertEqual((self.claude_leaf() / filename).read_bytes(),
                             (source / filename).read_bytes())

    def test_malformed_manifest_and_missing_manifest(self):
        self.base(".claude")
        self.invoke()
        marker = self.claude_leaf() / installer.MANIFEST
        for malformed in (b"{", b"[]", b'{"schema_version":1,"schema_version":1}'):
            marker.write_bytes(malformed)
            report, code = self.invoke()
            self.assertEqual(code, 1)
            self.assertEqual(marker.read_bytes(), malformed)
        marker.unlink()
        report, code = self.invoke("inspect")
        self.assertEqual(code, 1)
        self.assertEqual(self.row(report, "claude")["state"], "conflict")

    def test_symlink_leaf_rejected(self):
        skills = self.base(".claude/skills")
        victim = self.base("victim")
        (victim / "precious").write_text("safe")
        (skills / "revclip").symlink_to(victim, target_is_directory=True)
        self.assertEqual(self.invoke()[1], 1)
        self.assertTrue((skills / "revclip").is_symlink())
        self.assertEqual((victim / "precious").read_text(), "safe")

    def test_symlink_parents_and_base_rejected(self):
        victim = self.base("victim")
        claude = self.base(".claude")
        (claude / "skills").symlink_to(victim, target_is_directory=True)
        self.assertEqual(self.invoke()[1], 1)
        (self.home / ".cursor").symlink_to(victim, target_is_directory=True)
        report, code = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(self.row(report, "cursor")["state"], "conflict")
        self.assertEqual(list(victim.iterdir()), [])

    def test_world_writable_base_rejected(self):
        base = self.base(".claude")
        base.chmod(0o777)
        self.assertEqual(self.invoke()[1], 1)
        self.assertEqual(list(base.iterdir()), [])

    def test_unsafe_intermediate_parent_is_not_written(self):
        self.base(".codex")
        shared = self.base(".agents")
        shared.chmod(0o777)
        report, code = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(self.row(report, "codex")["state"], "conflict")
        self.assertEqual(list(shared.iterdir()), [])

    def test_duplicate_destination_is_idempotent(self):
        shared = self.work / "shared"
        shared.mkdir()
        report, code = self.invoke(env={"CLAUDE_CONFIG_DIR": str(shared),
                                       "GROK_HOME": str(shared)})
        self.assertEqual(code, 0, report)
        self.assertEqual(self.row(report, "claude")["action"], "installed")
        self.assertEqual(self.row(report, "grok")["action"], "unchanged")

    def test_payload_hardlink_is_rejected(self):
        self.base(".claude")
        self.invoke()
        file = self.claude_leaf() / "SKILL.md"
        os.link(file, self.work / "hardlink")
        self.assertEqual(self.invoke()[1], 1)
        self.assertEqual(file.read_bytes(), (self.work / "hardlink").read_bytes())

    def test_source_symlink_rejected_before_install(self):
        self.base(".claude")
        (self.source / "SKILL.md").unlink()
        (self.source / "SKILL.md").symlink_to(self.source / "scripts/revclip")
        report, code = self.invoke()
        self.assertEqual(code, 1)
        self.assertIsNotNone(report["source_error"])
        self.assertFalse(self.claude_leaf().exists())

    def test_partial_failure_continues_other_targets(self):
        self.base(".claude/skills/revclip")
        self.base(".cursor")
        report, code = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(self.row(report, "claude")["action"], "failed")
        self.assertEqual(self.row(report, "cursor")["action"], "installed")

    def test_failed_publish_rolls_back_old_tree(self):
        self.base(".claude")
        self.invoke()
        original = (self.claude_leaf() / "SKILL.md").read_bytes()
        (self.source / "SKILL.md").write_text("update")
        rename = os.rename

        def fail_publish(src, dst, **kwargs):
            if src.startswith(".revclip-stage-") and dst == "revclip":
                raise OSError("injected publish failure")
            return rename(src, dst, **kwargs)

        with patch.object(installer.os, "rename", side_effect=fail_publish):
            report, code = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(self.row(report, "claude")["action"], "failed")
        self.assertEqual(self.row(report, "claude")["state"], "installed")
        self.assertEqual((self.claude_leaf() / "SKILL.md").read_bytes(), original)
        self.assertEqual(list(self.claude_leaf().parent.iterdir()), [self.claude_leaf()])

    def test_failed_stage_cleans_up_and_preserves_existing(self):
        self.base(".claude")
        self.invoke()
        original = (self.claude_leaf() / "SKILL.md").read_bytes()
        (self.source / "SKILL.md").write_text("update")
        with patch.object(installer, "write_file", side_effect=OSError("disk full")):
            report, code = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual((self.claude_leaf() / "SKILL.md").read_bytes(), original)
        self.assertEqual(list(self.claude_leaf().parent.iterdir()), [self.claude_leaf()])

    def test_failed_rollback_keeps_recovery_copy_and_reports_it(self):
        self.base(".claude")
        self.invoke()
        original = (self.claude_leaf() / "SKILL.md").read_bytes()
        (self.source / "SKILL.md").write_text("update")
        rename = os.rename

        def fail_restore(src, dst, **kwargs):
            if dst == "revclip":
                raise OSError("injected rename failure")
            return rename(src, dst, **kwargs)

        with patch.object(installer.os, "rename", side_effect=fail_restore):
            report, code = self.invoke()
        self.assertEqual(code, 1)
        row = self.row(report, "claude")
        self.assertIn("recovery directory: .revclip-backup-", row["reason"])
        backup = next(self.claude_leaf().parent.glob(".revclip-backup-*"))
        self.assertEqual((backup / "SKILL.md").read_bytes(), original)

    def test_initial_readback_failure_rolls_back_to_missing(self):
        self.base(".claude")
        original = installer.existing
        calls = 0

        def fail_readback(parent):
            nonlocal calls
            calls += 1
            # install's initial check, pre-publication check, then readback.
            if calls == 3:
                raise installer.Conflict("injected readback failure")
            return original(parent)

        with patch.object(installer, "existing", side_effect=fail_readback):
            report, code = self.invoke()
        self.assertEqual(code, 1, report)
        self.assertFalse(self.claude_leaf().exists())
        self.assertEqual(list(self.claude_leaf().parent.iterdir()), [])

    def test_invalid_override_does_not_escape(self):
        for value in ("relative", str(self.home / ".." / "escape")):
            report, code = self.invoke(env={"CLAUDE_CONFIG_DIR": value})
            self.assertEqual(code, 1)
            self.assertEqual(self.row(report, "claude")["state"], "conflict")
        self.assertFalse((self.work / "escape").exists())

    def test_live_lock_preserved(self):
        root = self.base(".claude/skills/.revclip-install.lock")
        self.assertEqual(self.invoke()[1], 1)
        self.assertTrue(root.is_dir())

    def test_cli_json_and_app_validation_in_temp_home(self):
        # Invoke only our installer, with a clean synthetic environment.
        env = {"HOME": str(self.home), "PATH": os.environ.get("PATH", ""),
               "PYTHONDONTWRITEBYTECODE": "1"}
        result = subprocess.run([sys.executable, str(INSTALL), "inspect", "--app", "revclip-demo"],
                                env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertIsNone(report["source_error"], report)
        self.assertEqual(report["app"], "revclip-demo")
        self.assertFalse(any(row["detected"] for row in report["providers"]))
        result = subprocess.run([sys.executable, str(INSTALL), "install", "--app", "invalid"],
                                env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
