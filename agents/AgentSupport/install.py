#!/usr/bin/env python3
"""Install the bundled Revclip skill into existing agent homes (POSIX only)."""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import uuid


HERE = Path(__file__).absolute().parent
LEAF = "revclip"
MANIFEST = ".revclip-managed.json"
OWNER = "revclip-agent-support"
FILES = {"SKILL.md": 0o644, "scripts/revclip": 0o755, "agents/openai.yaml": 0o644}
SUBDIR_FILES = {"scripts": "revclip", "agents": "openai.yaml"}
MAX_BYTES = 8 * 1024 * 1024
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class Conflict(ValueError):
    """An existing path is not safe for this installer to modify."""


def absolute_path(value, home):
    if value == "~":
        value = str(home)
    elif value.startswith("~/"):
        value = str(home / value[2:])
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts or "\x00" in value:
        raise Conflict("root must be absolute, without parent traversal")
    return path


@contextmanager
def directory(path, create_from=None):
    """Walk exact components using directory descriptors; never follow symlinks."""
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise Conflict("unsafe directory path")
    fd = os.open(path.anchor, DIR_FLAGS)
    try:
        current = Path(path.anchor)
        for part in path.parts[1:]:
            current /= part
            if create_from is not None and Path(create_from) in current.parents:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
            info = os.fstat(fd)
            # System-owned ancestors are normal. Writable shared ancestors must
            # have sticky protection (e.g. the system temporary directory).
            if info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX:
                raise Conflict("unsafe writable parent directory")
        yield fd
    finally:
        os.close(fd)


def read_file(fd, name):
    handle = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    try:
        info = os.fstat(handle)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise Conflict("non-regular or hard-linked file")
        if info.st_size > MAX_BYTES:
            raise Conflict("file exceeds size limit")
        with os.fdopen(handle, "rb", closefd=False) as stream:
            data = stream.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise Conflict("file exceeds size limit")
        return data, stat.S_IMODE(info.st_mode)
    finally:
        os.close(handle)


def entries(fd, expected):
    # scandir is bounded even when an unmanaged directory contains many entries.
    found = set()
    with os.scandir(fd) as iterator:
        for item in iterator:
            found.add(item.name)
            if item.name not in expected or len(found) > len(expected):
                raise Conflict("unmanaged entries in skill tree")
    if found != expected:
        raise Conflict("incomplete skill tree")


def has_entry(fd, name):
    try:
        os.stat(name, dir_fd=fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def bundle(fd, managed=False):
    # Only previously managed copies may use the original two-file layout.
    # Their manifest must still match exactly before they can be upgraded.
    subdirs = dict(SUBDIR_FILES)
    if managed and not has_entry(fd, "agents"):
        del subdirs["agents"]
    entries(fd, {"SKILL.md", *subdirs} | ({MANIFEST} if managed else set()))
    payload = {"SKILL.md": read_file(fd, "SKILL.md")}
    for dirname, filename in subdirs.items():
        child = os.open(dirname, DIR_FLAGS, dir_fd=fd)
        try:
            if managed:
                require_private_owner(child)
            entries(child, {filename})
            payload[dirname + "/" + filename] = read_file(child, filename)
        finally:
            os.close(child)
    return payload


def manifest_for(payload):
    return {
        "schema_version": 1,
        "managed_by": OWNER,
        "files": {
            name: {"sha256": hashlib.sha256(data).hexdigest(), "mode": mode}
            for name, (data, mode) in payload.items()
        },
    }


def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Conflict("duplicate manifest key")
        result[key] = value
    return result


def existing(parent):
    try:
        fd = os.open(LEAF, DIR_FLAGS, dir_fd=parent)
    except FileNotFoundError:
        return None
    try:
        require_private_owner(fd)
        payload = bundle(fd, managed=True)
        raw, mode = read_file(fd, MANIFEST)
        if len(raw) > 4096:
            raise Conflict("management manifest exceeds size limit")
        try:
            record = json.loads(raw, object_pairs_hook=no_duplicate_keys)
        except (ValueError, UnicodeError, RecursionError) as exc:
            raise Conflict("malformed management manifest") from exc
        if mode != 0o644 or record != manifest_for(payload):
            raise Conflict("unmanaged or edited skill tree")
        # JSON booleans/floats must not masquerade as integer version/modes.
        if type(record.get("schema_version")) is not int or any(
            type(item.get("mode")) is not int for item in record["files"].values()
        ):
            raise Conflict("malformed management manifest")
        return record
    except FileNotFoundError as exc:
        raise Conflict("incomplete or unmanaged skill tree") from exc
    finally:
        os.close(fd)


def source_payload(source):
    with directory(source) as fd:
        raw = bundle(fd)
    return {name: (data, FILES[name]) for name, (data, _) in raw.items()}


def write_file(fd, name, data, mode):
    handle = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     mode, dir_fd=fd)
    try:
        os.fchmod(handle, mode)
        with os.fdopen(handle, "wb", closefd=False) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(handle)
    finally:
        os.close(handle)


def remove_owned(parent, name, partial=False):
    """Remove only a previously validated, fixed-shape private staging/backup tree."""
    fd = os.open(name, DIR_FLAGS, dir_fd=parent)
    try:
        if not partial:
            expected = {"SKILL.md", "scripts", MANIFEST}
            if has_entry(fd, "agents"):
                expected.add("agents")
            entries(fd, expected)
        for dirname, filename in SUBDIR_FILES.items():
            try:
                child = os.open(dirname, DIR_FLAGS, dir_fd=fd)
            except FileNotFoundError:
                if not partial and dirname != "agents":
                    raise
                continue
            try:
                if not partial:
                    entries(child, {filename})
                try:
                    os.unlink(filename, dir_fd=child)
                except FileNotFoundError:
                    if not partial:
                        raise
            finally:
                os.close(child)
            os.rmdir(dirname, dir_fd=fd)
        for filename in ("SKILL.md", MANIFEST):
            try:
                os.unlink(filename, dir_fd=fd)
            except FileNotFoundError:
                if not partial:
                    raise
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=parent)


def install_target(root, payload, create_from):
    desired = manifest_for(payload)
    with directory(root, create_from=create_from) as parent:
        require_private_owner(parent)
        # Fixed lock serializes our installers; never remove somebody else's lock.
        lock = ".revclip-install.lock"
        try:
            os.mkdir(lock, 0o700, dir_fd=parent)
        except FileExistsError as exc:
            raise Conflict("installer lock exists; concurrent or interrupted install") from exc
        stage = ".revclip-stage-" + uuid.uuid4().hex
        backup = ".revclip-backup-" + uuid.uuid4().hex
        staged = backed_up = published = committed = False
        try:
            before = existing(parent)
            if before == desired:
                return "unchanged"
            os.mkdir(stage, 0o700, dir_fd=parent)
            staged = True
            stage_fd = os.open(stage, DIR_FLAGS, dir_fd=parent)
            try:
                for dirname, filename in SUBDIR_FILES.items():
                    os.mkdir(dirname, 0o700, dir_fd=stage_fd)
                    child = os.open(dirname, DIR_FLAGS, dir_fd=stage_fd)
                    try:
                        write_file(child, filename, *payload[dirname + "/" + filename])
                    finally:
                        os.close(child)
                write_file(stage_fd, "SKILL.md", *payload["SKILL.md"])
                write_file(stage_fd, MANIFEST,
                           (json.dumps(desired, sort_keys=True) + "\n").encode(), 0o644)
                staged = True
            finally:
                os.close(stage_fd)
            if existing(parent) != before:
                raise Conflict("destination changed during staging")
            if before is not None:
                os.rename(LEAF, backup, src_dir_fd=parent, dst_dir_fd=parent)
                backed_up = True
            try:
                os.rename(stage, LEAF, src_dir_fd=parent, dst_dir_fd=parent)
                staged = False
                published = True
            except OSError:
                if backed_up:
                    try:
                        os.rename(backup, LEAF, src_dir_fd=parent, dst_dir_fd=parent)
                    except OSError as rollback:
                        raise Conflict("rollback failed; recovery directory: " + backup) from rollback
                    backed_up = False
                raise
            if existing(parent) != desired:
                raise Conflict("installed readback mismatch")
            committed = True
            if backed_up:
                remove_owned(parent, backup)
                backed_up = False
            return "updated" if before is not None else "installed"
        except Exception as exc:
            # Preserve a recovery copy if rollback itself fails. Never hide failure.
            if published and not committed and before is None:
                os.rename(LEAF, stage, src_dir_fd=parent, dst_dir_fd=parent)
                staged = True
            if backed_up and published and not committed:
                try:
                    os.rename(LEAF, stage, src_dir_fd=parent, dst_dir_fd=parent)
                    staged = True
                    os.rename(backup, LEAF, src_dir_fd=parent, dst_dir_fd=parent)
                    backed_up = False
                except OSError as rollback:
                    raise Conflict("rollback failed; recovery directory: " + backup) from rollback
            raise exc
        finally:
            if staged:
                remove_owned(parent, stage, partial=True)
            os.rmdir(lock, dir_fd=parent)


def resolve_provider(provider, home, env):
    override = env.get(provider.get("env", ""))
    base = absolute_path(override or provider["base"], home)
    if override and provider.get("env_is_home_parent"):
        base = base / ".gemini"
    if provider["id"] == "codex" and not override:
        root = home / ".agents/skills"
    else:
        root = base / provider.get("skills", "skills")
    return base, root


def require_private_owner(fd):
    info = os.fstat(fd)
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise Conflict("configuration directory must be owned by this user and not writable by others")


def run(command, app="Revclip", *, home=None, env=None, source=None, providers=None):
    home = Path(home if home is not None else Path.home()).absolute()
    env = os.environ if env is None else env
    if providers is None:
        providers = json.loads((HERE / "providers.json").read_text())["providers"]
    payload = None
    source_error = None
    try:
        payload = source_payload(source or HERE / LEAF)
    except (OSError, ValueError) as exc:
        source_error = str(exc)
    rows = []
    for provider in providers:
        row = {"id": provider["id"], "name": provider["name"], "detected": False,
               "path": None, "state": "missing", "action": "skipped",
               "experimental": provider.get("experimental", False),
               "sources": provider["sources"], "reload": provider["reload"]}
        rows.append(row)
        try:
            base, root = resolve_provider(provider, home, env)
            row["path"] = str(root / LEAF)
            try:
                with directory(base) as base_fd:
                    row["detected"] = True
                    require_private_owner(base_fd)
            except FileNotFoundError:
                row["reason"] = "configuration base absent"
                continue
            if not provider.get("supported", True):
                row.update(state="unsupported", reason="flat Markdown CLI; bundle support unverified")
                continue
            try:
                with directory(root) as parent:
                    require_private_owner(parent)
                    record = existing(parent)
            except FileNotFoundError:
                record = None
            row["state"] = "installed" if record is not None else "missing"
            row["update_available"] = record != manifest_for(payload) if payload else None
            row["action"] = "none"
            if command == "install":
                if source_error:
                    raise Conflict("source bundle invalid: " + source_error)
                # Recheck the detection gate immediately before any mkdir.
                with directory(base) as base_fd:
                    require_private_owner(base_fd)
                    boundary = base if base in root.parents else home
                    row["action"] = install_target(root, payload, boundary)
                row.update(state="installed", update_available=False)
        except (OSError, ValueError) as exc:
            row.update(state="conflict", action="failed", reason=str(exc))
            # A post-publication cleanup error is still a failure, but do not
            # claim the successfully published skill is missing or unmanaged.
            if command == "install" and row["detected"] and row["path"]:
                try:
                    with directory(Path(row["path"]).parent) as parent:
                        if existing(parent) is not None:
                            row["state"] = "installed"
                except (OSError, ValueError):
                    pass
    report = {"schema_version": 1, "command": command, "app": app,
              "skill": LEAF, "providers": rows, "source_error": source_error}
    failed = any(row["action"] == "failed" for row in rows)
    report["ok"] = not failed and not (command == "install" and source_error)
    return report, 0 if report["ok"] else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("inspect", "install"))
    parser.add_argument("--app", choices=("Revclip", "revclip-demo"), default="Revclip")
    args = parser.parse_args(argv)
    try:
        report, code = run(args.command, args.app)
    except (OSError, ValueError) as exc:
        report, code = {"schema_version": 1, "ok": False, "error": str(exc)}, 1
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main())
