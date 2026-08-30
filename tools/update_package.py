#!/usr/bin/env python3
"""Generate and validate the manual and Maintenance Toolkit package metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.1.6"
RELEASE_TAG = f"v{VERSION}"
PACKAGE_ID = "x-plane-zibo-40535-tablet-performance-calculator"
REPOSITORY_URL = (
    "https://github.com/wahltho/"
    "X-Plane-Zibo-LevelUp-737NG-Tablet-Performance-Calculator"
)
MODULE_ID = "tablet-performance-calculator"
MODULE_ROOT = ROOT / "modules" / MODULE_ID
LOADER_PATCH_NAME = "B738.tablet.loader.json"
HOOKS_PATCH_NAME = "B738.tablet.hooks.json"
RUNTIME_FILES = (
    "B738.tablet_perf_data.lua",
    "B738.tablet_perf_core.lua",
    "B738.tablet_perf_adapter.lua",
)
RELEASE_ROOT_FILES = (
    *RUNTIME_FILES,
    "Add_dofile.txt",
    "Add_perf_hooks.txt",
    "package-manifest.txt",
    "z_Install.py",
    "README.md",
    "SOURCE.md",
    "LICENSE",
    "package-manifest.json",
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def fragment(name: str) -> list[str]:
    return (ROOT / name).read_text(encoding="utf-8").splitlines()


def make_tablet_loader_patch() -> dict[str, object]:
    fragment_lines = fragment("Add_dofile.txt")
    return {
        "format": "insert-marked-block-v1",
        "name": "Tablet performance calculator loader",
        "beginMarker": fragment_lines[0],
        "endMarker": fragment_lines[-1],
        "contentLines": fragment_lines[1:-1],
        "anchorLines": ["jit.off()"],
        "position": "after",
    }


def make_tablet_hooks_patch() -> dict[str, object]:
    return {
        "format": "exact-text-replacements-v1",
        "replacements": [
            {
                "name": "Tablet performance calculator hooks",
                "oldLines": ["end", "", "function page_app_rating()"],
                "newLines": [
                    "end",
                    "",
                    *fragment("Add_perf_hooks.txt"),
                    "function page_app_rating()",
                ],
            },
        ],
    }


def make_toolkit_files() -> dict[Path, bytes]:
    loader_relative = Path("modules") / MODULE_ID / LOADER_PATCH_NAME
    hooks_relative = Path("modules") / MODULE_ID / HOOKS_PATCH_NAME
    files: dict[Path, bytes] = {
        loader_relative: json_bytes(make_tablet_loader_patch()),
        hooks_relative: json_bytes(make_tablet_hooks_patch()),
    }
    for name in RUNTIME_FILES:
        files[Path("modules") / MODULE_ID / name] = (ROOT / name).read_bytes()

    payloads = []
    for relative in (
        loader_relative,
        hooks_relative,
        *(Path("modules") / MODULE_ID / name for name in RUNTIME_FILES),
    ):
        module_relative = relative.relative_to(Path("modules") / MODULE_ID)
        data = files[relative]
        payloads.append(
            {"path": module_relative.as_posix(), "sha256": sha256(data), "size": len(data)}
        )

    targets: list[dict[str, object]] = [
        {
            "operation": "insert-marked-block-v1",
            "payload": LOADER_PATCH_NAME,
            "relativePath": "plugins/xlua/scripts/B738.tablet/B738.tablet.lua",
            "sourceSha256": [],
        },
        {
            "operation": "exact-text-replacements-v1",
            "payload": HOOKS_PATCH_NAME,
            "relativePath": "plugins/xlua/scripts/B738.tablet/B738.tablet.lua",
            "sourceSha256": [],
        }
    ]
    for name in RUNTIME_FILES:
        payload = files[Path("modules") / MODULE_ID / name]
        targets.append(
            {
                "operation": "copy-file-v1",
                "payload": name,
                "relativePath": f"plugins/xlua/scripts/B738.tablet/{name}",
                "resultSha256": sha256(payload),
                "sourceSha256": [],
            }
        )

    manifest = {
        "aircraftFamily": "LevelUp 737NG Series v2 for X-Plane 12",
        "modules": [
            {
                "conflictsWith": [],
                "defaultEnabled": False,
                "description": (
                    "Variant-specific XLua takeoff and landing performance calculations "
                    "on the existing EFB pages."
                ),
                "displayName": "Tablet performance calculator",
                "installationOrder": 30,
                "moduleId": MODULE_ID,
                "payloads": payloads,
                "policy": "optional",
                "requires": [],
                "targets": targets,
            }
        ],
        "packageId": PACKAGE_ID,
        "packageType": "compatibilityPackage",
        "packageVersion": VERSION,
        "repositoryUrl": REPOSITORY_URL,
        "restartRequired": True,
        "schemaVersion": 3,
        "supportedProducts": ["levelup-737ng"],
        "supportedUpstreamReleases": [],
    }
    files[Path("package-manifest.json")] = json_bytes(manifest)
    return files


def legacy_payload_line(role: str, relative: str, data: bytes) -> str:
    return f"payload|{role}|{relative}|size|{len(data)}|sha256|{sha256(data)}"


def make_legacy_manifest(toolkit_files: dict[Path, bytes]) -> bytes:
    entries = [
        ("data", "B738.tablet_perf_data.lua"),
        ("core", "B738.tablet_perf_core.lua"),
        ("adapter", "B738.tablet_perf_adapter.lua"),
        ("dofile", "Add_dofile.txt"),
        ("hooks", "Add_perf_hooks.txt"),
        ("installer", "z_Install.py"),
        ("readme", "README.md"),
        ("source", "SOURCE.md"),
        ("license", "LICENSE"),
    ]
    lines = [
        "schema|package-manifest|1",
        f"package|id|{PACKAGE_ID}",
        f"package|version|{RELEASE_TAG}",
        f"package|release_tag|{RELEASE_TAG}",
        "aircraft|family|zibo_levelup_737ng",
        "target|relative_path|plugins/xlua/scripts/B738.tablet/B738.tablet.lua",
        "target|baseline|Zibo 4.05.35 / LevelUp V2.S1.50",
    ]
    for role, relative in entries:
        lines.append(legacy_payload_line(role, relative, (ROOT / relative).read_bytes()))
    lines.append(
        legacy_payload_line(
            "toolkit_manifest", "package-manifest.json", toolkit_files[Path("package-manifest.json")]
        )
    )
    for relative in sorted(path for path in toolkit_files if path != Path("package-manifest.json")):
        lines.append(legacy_payload_line("toolkit_payload", relative.as_posix(), toolkit_files[relative]))
    lines.extend(
        [
            "anchor|dofile|jit.off()",
            "anchor|hooks|function page_app_rating()",
            "marker|dofile|begin|-- BEGIN UPSTREAM_TABLET_PERF_CALC DOFILE",
            "marker|dofile|end|-- END UPSTREAM_TABLET_PERF_CALC DOFILE",
            "marker|hooks|begin|-- BEGIN UPSTREAM_TABLET_PERF_CALC HOOKS",
            "marker|hooks|end|-- END UPSTREAM_TABLET_PERF_CALC HOOKS",
            "source|takeoff_sha256|1337937106ebd4f5704887c8cba67c84332f9f0c6e1773490ff337ed1f4263d0",
            "source|landing_sha256|f64542a0e908b2745428a61180245370b447a88a01185fc0a616ba346d833d56",
            "dependency|external_jbriks_runtime|none",
            "dependency|public_zibomod_plugin_change|none",
            "runway|intersection_support|full_only",
            "hash_binding|upstream_b738_tablet_lua|none",
        ]
    )
    return ("\n".join(lines) + "\n").encode("utf-8")


def expected_files() -> dict[Path, bytes]:
    files = make_toolkit_files()
    files[Path("package-manifest.txt")] = make_legacy_manifest(files)
    return files


def write_files(files: dict[Path, bytes]) -> None:
    for relative, data in files.items():
        destination = ROOT / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists() or destination.read_bytes() != data:
            destination.write_bytes(data)
            print(f"Wrote {relative}")


def check_files(files: dict[Path, bytes]) -> bool:
    stale = []
    for relative, data in files.items():
        destination = ROOT / relative
        if not destination.is_file() or destination.read_bytes() != data:
            stale.append(relative.as_posix())
    if stale:
        print("STALE: " + ", ".join(stale), file=sys.stderr)
        return False
    print("PASS: package manifests and module payloads are current")
    return True


def build_archive(destination: Path, files: dict[Path, bytes]) -> None:
    if not check_files(files):
        raise RuntimeError("refusing to archive stale package metadata")
    destination.parent.mkdir(parents=True, exist_ok=True)
    entries = {Path(name): (ROOT / name).read_bytes() for name in RELEASE_ROOT_FILES}
    entries.update(
        {
            relative: data
            for relative, data in files.items()
            if relative.parts[0] == "modules"
        }
    )
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for relative in sorted(entries, key=lambda path: path.as_posix()):
            info = zipfile.ZipInfo(relative.as_posix(), date_time=(2026, 1, 1, 0, 0, 0))
            mode = 0o755 if relative.name == "z_Install.py" else 0o644
            info.external_attr = mode << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, entries[relative], compresslevel=9)
    checksum = sha256(destination.read_bytes())
    destination.with_suffix(destination.suffix + ".sha256").write_text(
        f"{checksum}  {destination.name}\n", encoding="utf-8", newline="\n"
    )
    print(f"Wrote {destination} ({destination.stat().st_size} bytes, sha256={checksum})")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="update generated manifests and module payloads")
    parser.add_argument("--check", action="store_true", help="fail if generated package files are stale")
    parser.add_argument("--archive", type=Path, help="write a deterministic release ZIP and checksum")
    args = parser.parse_args()
    if not (args.write or args.check or args.archive):
        parser.error("select --write, --check or --archive")

    files = expected_files()
    if args.write:
        write_files(files)
        files = expected_files()
    if args.check and not check_files(files):
        return 1
    if args.archive:
        build_archive(args.archive.expanduser().resolve(), files)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
