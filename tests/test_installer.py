#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


PACKAGE = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(PACKAGE))
INSTALLER_PATH = PACKAGE / "z_Install.py"
INSTALLER_SPEC = importlib.util.spec_from_file_location("tablet_perf_installer", INSTALLER_PATH)
assert INSTALLER_SPEC is not None and INSTALLER_SPEC.loader is not None
installer = importlib.util.module_from_spec(INSTALLER_SPEC)
INSTALLER_SPEC.loader.exec_module(installer)
DEFAULT_BASELINE = Path(
    "/Users/wahltho/dev/Zibo Mod/Original/Zibo Mod Original/"
    "B738X_XP12_4_05_35/plugins/xlua/scripts/B738.tablet/B738.tablet.lua"
)
BASELINE = Path(os.environ.get("B738_TABLET_BASELINE", DEFAULT_BASELINE))
PAYLOADS = (
    "B738.tablet_perf_data.lua",
    "B738.tablet_perf_core.lua",
    "B738.tablet_perf_adapter.lua",
    "Add_dofile.txt",
    "Add_perf_hooks.txt",
    "package-manifest.txt",
    "z_Install.py",
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run_installer(folder: Path, *arguments: str, expect: int = 0) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        ["python3", str(INSTALLER_PATH), "--aircraft-root", str(folder.parents[3].resolve()), *arguments], cwd=folder, capture_output=True, text=True, check=False
    )
    if completed.returncode != expect:
        raise AssertionError(
            f"installer returned {completed.returncode}, expected {expect}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed


def original_backup(folder: Path) -> Path:
    import json
    root = folder.parents[3]
    state = json.loads((root / ".patch-ownership/x-plane-zibo-40535-tablet-performance-calculator/receipt.json").read_text())
    return root / state["files"]["plugins/xlua/scripts/B738.tablet/B738.tablet.lua"]["backupRelativePath"]


def exercise(line_ending: bytes) -> None:
    original = BASELINE.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", line_ending)
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary) / "aircraft/plugins/xlua/scripts/B738.tablet"
        folder.mkdir(parents=True)
        target = folder / "B738.tablet.lua"
        target.write_bytes(original)

        first_run = run_installer(folder)
        assert "Tablet Performance installed." in first_run.stdout
        installed = target.read_bytes()
        assert original_backup(folder).read_bytes() == original
        assert installed.count(b"BEGIN UPSTREAM_TABLET_PERF_CALC DOFILE") == 1
        assert installed.count(b"BEGIN UPSTREAM_TABLET_PERF_CALC HOOKS") == 1
        assert installed.find(b"BEGIN UPSTREAM_TABLET_PERF_CALC DOFILE") > installed.find(b"jit.off()")
        assert installed.find(b"BEGIN UPSTREAM_TABLET_PERF_CALC HOOKS") < installed.find(b"function page_app_rating()")
        if line_ending == b"\r\n":
            assert installed.count(b"\n") == installed.count(b"\r\n")

        first_hash = digest(installed)
        second_run = run_installer(folder)
        assert "Tablet Performance installed." in second_run.stdout
        assert digest(target.read_bytes()) == first_hash
        assert original_backup(folder).read_bytes() == original

        run_installer(folder, "--uninstall")
        assert target.read_bytes() == original
        run_installer(folder, "--uninstall", expect=1)
        assert target.read_bytes() == original


def exercise_missing_anchor() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary) / "aircraft/plugins/xlua/scripts/B738.tablet"
        folder.mkdir(parents=True)
        text = BASELINE.read_text(encoding="utf-8").replace("function page_app_rating()", "function renamed_page()")
        (folder / "B738.tablet.lua").write_text(text, encoding="utf-8", newline="\n")
        original_hash = digest((folder / "B738.tablet.lua").read_bytes())
        run_installer(folder, expect=1)
        assert digest((folder / "B738.tablet.lua").read_bytes()) == original_hash
        assert not (folder / "B738.tablet.lua.backup").exists()


def exercise_v010_upgrade() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary) / "aircraft/plugins/xlua/scripts/B738.tablet"
        folder.mkdir(parents=True)
        original = BASELINE.read_text(encoding="utf-8")
        old_dofile = (
            '-- BEGIN UPSTREAM_TABLET_PERF_CALC DOFILE\n'
            'B738_upstream_perf_adapter = dofile("B738.tablet_perf_adapter.lua")\n'
            '-- END UPSTREAM_TABLET_PERF_CALC DOFILE'
        )
        hooks = (PACKAGE / "Add_perf_hooks.txt").read_text(encoding="utf-8").rstrip("\n")
        installed_v010 = original.replace("jit.off()", "jit.off()\n" + old_dofile, 1)
        installed_v010 = installed_v010.replace("function page_app_rating()", hooks + "\nfunction page_app_rating()", 1)
        target = folder / "B738.tablet.lua"
        target.write_text(installed_v010, encoding="utf-8", newline="\n")
        backup_marker = b"original v0.1.0 backup must remain untouched\n"
        (folder / "B738.tablet.lua.backup").write_bytes(backup_marker)

        before = target.read_bytes()
        blocked = run_installer(folder, expect=1)
        assert "no verified standalone owner" in blocked.stderr
        assert target.read_bytes() == before
        assert (folder / "B738.tablet.lua.backup").read_bytes() == backup_marker


def exercise_mixed_package_refusal() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary) / "aircraft/plugins/xlua/scripts/B738.tablet"
        folder.mkdir(parents=True)
        target = folder / "B738.tablet.lua"
        target.write_bytes(BASELINE.read_bytes())
        original_hash = digest(target.read_bytes())
        (folder / "B738.tablet_perf_core.lua").write_bytes(b"-- unowned payload\n")
        completed = run_installer(folder, expect=1)
        assert "Unowned companion file" in completed.stderr
        assert digest(target.read_bytes()) == original_hash
        assert not (folder / "B738.tablet.lua.backup").exists()


def exercise_other_loader_coexistence() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary) / "aircraft/plugins/xlua/scripts/B738.tablet"
        folder.mkdir(parents=True)
        original = BASELINE.read_text(encoding="utf-8")
        other = (
            "-- BEGIN OTHER_PACKAGE DOFILE\n"
            'dofile("other_package.lua")\n'
            "-- END OTHER_PACKAGE DOFILE"
        )
        original = original.replace("jit.off()", "jit.off()\n" + other, 1)
        target = folder / "B738.tablet.lua"
        target.write_text(original, encoding="utf-8", newline="\n")

        run_installer(folder)
        installed = target.read_text(encoding="utf-8")
        assert installed.count("BEGIN OTHER_PACKAGE DOFILE") == 1
        assert installed.count("BEGIN UPSTREAM_TABLET_PERF_CALC DOFILE") == 1
        run_installer(folder, "--uninstall")
        assert target.read_text(encoding="utf-8") == original


def exercise_incompatible_luac_is_not_used() -> None:
    calls: list[list[str]] = []

    def run_luac(arguments: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        calls.append(arguments)
        assert arguments == ["/usr/bin/luac", "-v"]
        return subprocess.CompletedProcess(arguments, 0, "Lua 5.4.8", "")

    original_which = installer.shutil.which
    original_named_temporary_file = installer.tempfile.NamedTemporaryFile
    original_run = installer.subprocess.run
    try:
        installer.shutil.which = lambda command: "/usr/bin/luac" if command == "luac" else None
        installer.tempfile.NamedTemporaryFile = lambda **_: (_ for _ in ()).throw(
            AssertionError("Lua 5.4 must be rejected before creating a temporary file")
        )
        installer.subprocess.run = run_luac
        installer.validate_lua(b"this payload must not be passed to Lua 5.4")
        assert calls == [["/usr/bin/luac", "-v"]]
    finally:
        installer.shutil.which = original_which
        installer.tempfile.NamedTemporaryFile = original_named_temporary_file
        installer.subprocess.run = original_run


def exercise_windows_luac_temporary_file_contract() -> None:
    payload = b"function flight_start()\nend\n"
    fake_path = Path(tempfile.mkdtemp()) / "windows-locked.lua"

    class WindowsLockedTemporary:
        def __init__(self) -> None:
            self.name = str(fake_path)
            self.stream = fake_path.open("wb")
            self.closed = False

        def __enter__(self) -> "WindowsLockedTemporary":
            return self

        def write(self, data: bytes) -> int:
            return self.stream.write(data)

        def flush(self) -> None:
            self.stream.flush()

        def __exit__(self, *_: object) -> None:
            self.stream.close()
            self.closed = True

    temporary: WindowsLockedTemporary | None = None

    def named_temporary_file(*, suffix: str, delete: bool) -> WindowsLockedTemporary:
        nonlocal temporary
        assert suffix == ".lua"
        assert delete is False
        temporary = WindowsLockedTemporary()
        return temporary

    def run_luac(arguments: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        if arguments == ["C:/Lua/luac.exe", "-v"]:
            return subprocess.CompletedProcess(arguments, 0, "Lua 5.1.5", "")
        assert temporary is not None and temporary.closed
        assert arguments == ["C:/Lua/luac.exe", "-p", str(fake_path)]
        assert fake_path.read_bytes() == payload
        return subprocess.CompletedProcess(arguments, 0, "", "")

    original_which = installer.shutil.which
    original_named_temporary_file = installer.tempfile.NamedTemporaryFile
    original_run = installer.subprocess.run
    try:
        installer.shutil.which = lambda command: "C:/Lua/luac.exe" if command == "luac" else None
        installer.tempfile.NamedTemporaryFile = named_temporary_file
        installer.subprocess.run = run_luac
        installer.validate_lua(payload)
        assert not fake_path.exists()
    finally:
        installer.shutil.which = original_which
        installer.tempfile.NamedTemporaryFile = original_named_temporary_file
        installer.subprocess.run = original_run
        if fake_path.exists():
            fake_path.unlink()
        fake_path.parent.rmdir()


exercise_windows_luac_temporary_file_contract()
exercise_incompatible_luac_is_not_used()
if not BASELINE.is_file():
    print(f"SKIP: set B738_TABLET_BASELINE to a stock Zibo 4.05.35/LevelUp tablet Lua: {BASELINE}")
    raise SystemExit(0)
exercise(b"\n")
exercise(b"\r\n")
exercise_missing_anchor()
exercise_v010_upgrade()
exercise_mixed_package_refusal()
exercise_other_loader_coexistence()
print("PASS: Lua 5.1 compiler selection, installer .35 baseline, LF/CRLF, idempotence, unowned payload refusal, v0.1.0 refusal, uninstall and coexistence")
