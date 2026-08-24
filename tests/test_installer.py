#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


PACKAGE = Path(__file__).resolve().parents[1]
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
        ["python3", "z_Install.py", *arguments], cwd=folder, capture_output=True, text=True, check=False
    )
    if completed.returncode != expect:
        raise AssertionError(
            f"installer returned {completed.returncode}, expected {expect}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed


def exercise(line_ending: bytes) -> None:
    original = BASELINE.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", line_ending)
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary)
        for name in PAYLOADS:
            shutil.copy2(PACKAGE / name, folder / name)
        target = folder / "B738.tablet.lua"
        target.write_bytes(original)

        first_run = run_installer(folder)
        assert "Package v0.1.5 payload verified; installation complete." in first_run.stdout
        installed = target.read_bytes()
        assert (folder / "B738.tablet.lua.backup").read_bytes() == original
        assert installed.count(b"BEGIN UPSTREAM_TABLET_PERF_CALC DOFILE") == 1
        assert installed.count(b"BEGIN UPSTREAM_TABLET_PERF_CALC HOOKS") == 1
        assert installed.find(b"BEGIN UPSTREAM_TABLET_PERF_CALC DOFILE") > installed.find(b"jit.off()")
        assert installed.find(b"BEGIN UPSTREAM_TABLET_PERF_CALC HOOKS") < installed.find(b"function page_app_rating()")
        if line_ending == b"\r\n":
            assert installed.count(b"\n") == installed.count(b"\r\n")

        first_hash = digest(installed)
        second_run = run_installer(folder)
        assert "Package v0.1.5 payload verified." in second_run.stdout
        assert "Tablet hooks already installed and current; installation complete." in second_run.stdout
        assert digest(target.read_bytes()) == first_hash
        assert (folder / "B738.tablet.lua.backup").read_bytes() == original

        run_installer(folder, "--uninstall")
        assert target.read_bytes() == original
        run_installer(folder, "--uninstall")
        assert target.read_bytes() == original


def exercise_missing_anchor() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary)
        for name in PAYLOADS:
            shutil.copy2(PACKAGE / name, folder / name)
        text = BASELINE.read_text(encoding="utf-8").replace("function page_app_rating()", "function renamed_page()")
        (folder / "B738.tablet.lua").write_text(text, encoding="utf-8", newline="\n")
        original_hash = digest((folder / "B738.tablet.lua").read_bytes())
        run_installer(folder, expect=1)
        assert digest((folder / "B738.tablet.lua").read_bytes()) == original_hash
        assert not (folder / "B738.tablet.lua.backup").exists()


def exercise_v010_upgrade() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary)
        for name in PAYLOADS:
            shutil.copy2(PACKAGE / name, folder / name)
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

        run_installer(folder)
        upgraded = target.read_text(encoding="utf-8")
        assert 'B738_upstream_perf_adapter = dofile(' not in upgraded
        assert upgraded.count('dofile("B738.tablet_perf_adapter.lua")') == 1
        assert (folder / "B738.tablet.lua.backup").read_bytes() == backup_marker


def exercise_mixed_package_refusal() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary)
        for name in PAYLOADS:
            shutil.copy2(PACKAGE / name, folder / name)
        target = folder / "B738.tablet.lua"
        target.write_bytes(BASELINE.read_bytes())
        original_hash = digest(target.read_bytes())
        with (folder / "B738.tablet_perf_core.lua").open("ab") as payload:
            payload.write(b"-- stale or damaged payload\n")

        completed = run_installer(folder, expect=2)
        assert "does not match package v0.1.5" in completed.stderr
        assert "extract the complete package again" in completed.stderr
        assert digest(target.read_bytes()) == original_hash
        assert not (folder / "B738.tablet.lua.backup").exists()


def exercise_other_loader_coexistence() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary)
        for name in PAYLOADS:
            shutil.copy2(PACKAGE / name, folder / name)
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


if not BASELINE.is_file():
    print(f"SKIP: set B738_TABLET_BASELINE to a stock Zibo 4.05.35/LevelUp tablet Lua: {BASELINE}")
    raise SystemExit(0)
exercise(b"\n")
exercise(b"\r\n")
exercise_missing_anchor()
exercise_v010_upgrade()
exercise_mixed_package_refusal()
exercise_other_loader_coexistence()
print("PASS: installer .35 baseline, LF/CRLF, idempotence, payload verification, v0.1.0 upgrade, uninstall and refusal")
