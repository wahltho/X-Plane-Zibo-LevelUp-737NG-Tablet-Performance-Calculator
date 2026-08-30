from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BASELINE = Path(
    "/Users/wahltho/dev/Zibo Mod/Original/737NG Series_V2.S1.50A/"
    "plugins/xlua/scripts/B738.tablet/B738.tablet.lua"
)
BASELINE = Path(os.environ.get("B738_TABLET_BASELINE", DEFAULT_BASELINE))
MODULE_ID = "tablet-performance-calculator"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def find_sequence(lines: list[str], sequence: list[str]) -> list[int]:
    return [
        index
        for index in range(len(lines) - len(sequence) + 1)
        if lines[index : index + len(sequence)] == sequence
    ]


def apply_exact_replacements(source: bytes, payload: dict[str, object]) -> bytes:
    eol = "\r\n" if source.count(b"\r\n") > source.count(b"\n") - source.count(b"\r\n") else "\n"
    final_eol = source.endswith((b"\r", b"\n"))
    lines = source.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n").split("\n")
    if final_eol and lines[-1] == "":
        lines.pop()
    for replacement in payload["replacements"]:
        old_lines = replacement["oldLines"]
        new_lines = replacement["newLines"]
        old_matches = find_sequence(lines, old_lines)
        new_matches = find_sequence(lines, new_lines)
        if len(old_matches) == 1 and not new_matches:
            index = old_matches[0]
            lines[index : index + len(old_lines)] = new_lines
        elif not old_matches and len(new_matches) == 1:
            continue
        else:
            raise AssertionError(
                f"{replacement['name']}: old={len(old_matches)}, installed={len(new_matches)}"
            )
    result = eol.join(lines)
    if final_eol:
        result += eol
    return result.encode("utf-8")


def apply_marked_insertion(source: bytes, payload: dict[str, object]) -> bytes:
    eol = "\r\n" if source.count(b"\r\n") > source.count(b"\n") - source.count(b"\r\n") else "\n"
    final_eol = source.endswith((b"\r", b"\n"))
    lines = source.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n").split("\n")
    if final_eol and lines[-1] == "":
        lines.pop()
    block = [payload["beginMarker"], *payload["contentLines"], payload["endMarker"]]
    block_matches = find_sequence(lines, block)
    if len(block_matches) == 1:
        return source
    if block_matches:
        raise AssertionError("marked loader block is duplicated")
    if payload["beginMarker"] in lines or payload["endMarker"] in lines:
        raise AssertionError("marked loader block is partial or modified")
    anchors = find_sequence(lines, payload["anchorLines"])
    if len(anchors) != 1:
        raise AssertionError(f"loader anchor matches={len(anchors)}")
    index = anchors[0]
    lines[index:index] = block
    result = eol.join(lines)
    if final_eol:
        result += eol
    return result.encode("utf-8")


class PackageTests(unittest.TestCase):
    def test_generated_package_files_are_current(self) -> None:
        completed = subprocess.run(
            [sys.executable, "tools/update_package.py", "--check"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)

    def test_schema3_manifest_and_payload_hashes(self) -> None:
        manifest = json.loads((ROOT / "package-manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(3, manifest["schemaVersion"])
        self.assertEqual("compatibilityPackage", manifest["packageType"])
        self.assertEqual(["levelup-737ng"], manifest["supportedProducts"])
        self.assertEqual(1, len(manifest["modules"]))
        module = manifest["modules"][0]
        self.assertEqual("optional", module["policy"])
        self.assertFalse(module["defaultEnabled"])
        payload_root = ROOT / "modules" / MODULE_ID
        for payload in module["payloads"]:
            data = (payload_root / payload["path"]).read_bytes()
            self.assertEqual(payload["size"], len(data))
            self.assertEqual(payload["sha256"], sha256(data))
        for name in (
            "B738.tablet_perf_data.lua",
            "B738.tablet_perf_core.lua",
            "B738.tablet_perf_adapter.lua",
        ):
            self.assertEqual((ROOT / name).read_bytes(), (payload_root / name).read_bytes())

    @unittest.skipUnless(BASELINE.is_file(), "set B738_TABLET_BASELINE to the stock tablet Lua")
    def test_structural_patch_handles_levelup_crlf_and_zibo_lf(self) -> None:
        loader = json.loads(
            (ROOT / "modules" / MODULE_ID / "B738.tablet.loader.json").read_text(encoding="utf-8")
        )
        hooks = json.loads(
            (ROOT / "modules" / MODULE_ID / "B738.tablet.hooks.json").read_text(encoding="utf-8")
        )
        crlf = BASELINE.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        for source in (crlf, crlf.replace(b"\r\n", b"\n")):
            installed = apply_exact_replacements(apply_marked_insertion(source, loader), hooks)
            self.assertEqual(1, installed.count(b"BEGIN UPSTREAM_TABLET_PERF_CALC DOFILE"))
            self.assertEqual(1, installed.count(b"BEGIN UPSTREAM_TABLET_PERF_CALC HOOKS"))
            self.assertEqual(
                installed,
                apply_exact_replacements(apply_marked_insertion(installed, loader), hooks),
            )
            if b"\r\n" in source:
                self.assertEqual(installed.count(b"\n"), installed.count(b"\r\n"))

    def test_release_archive_contains_manual_and_toolkit_contracts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "package.zip"
            completed = subprocess.run(
                [sys.executable, "tools/update_package.py", "--archive", str(archive)],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)
            self.assertTrue(archive.with_suffix(".zip.sha256").is_file())
            with zipfile.ZipFile(archive) as package:
                names = set(package.namelist())
                self.assertIn("z_Install.py", names)
                self.assertIn("package-manifest.txt", names)
                self.assertIn("package-manifest.json", names)
                self.assertIn(
                    f"modules/{MODULE_ID}/B738.tablet_perf_data.lua",
                    names,
                )
                manifest = json.loads(package.read("package-manifest.json"))
                self.assertEqual("0.1.6", manifest["packageVersion"])


if __name__ == "__main__":
    unittest.main()
