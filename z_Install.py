#!/usr/bin/env python3
"""Install or remove the stand-alone Tablet performance calculator hooks.

The target is edited as bytes so its existing LF or CRLF convention and final
newline are preserved.  A stock backup is created once and never overwritten.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


LUA_FILE = Path("B738.tablet.lua")
BACKUP_FILE = Path("B738.tablet.lua.backup")
MANIFEST_FILE = Path("package-manifest.txt")
PACKAGE_ID = "x-plane-zibo-40535-tablet-performance-calculator"
PAYLOADS = (
    Path("B738.tablet_perf_data.lua"),
    Path("B738.tablet_perf_core.lua"),
    Path("B738.tablet_perf_adapter.lua"),
)
DOFILE_FRAGMENT = Path("Add_dofile.txt")
HOOK_FRAGMENT = Path("Add_perf_hooks.txt")
DOFILE_ANCHOR = "jit.off()"
HOOK_ANCHOR = "function page_app_rating()"
DOFILE_BEGIN = "-- BEGIN UPSTREAM_TABLET_PERF_CALC DOFILE"
DOFILE_END = "-- END UPSTREAM_TABLET_PERF_CALC DOFILE"
HOOK_BEGIN = "-- BEGIN UPSTREAM_TABLET_PERF_CALC HOOKS"
HOOK_END = "-- END UPSTREAM_TABLET_PERF_CALC HOOKS"


def detect_eol(data: bytes) -> str:
    crlf_count = data.count(b"\r\n")
    lf_only_count = data.count(b"\n") - crlf_count
    return "\r\n" if crlf_count > lf_only_count else "\n"


def split_lines(data: bytes) -> tuple[list[str], str, bool]:
    eol = detect_eol(data)
    final_eol = data.endswith((b"\n", b"\r"))
    text = data.decode("utf-8", errors="strict")
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    if final_eol and lines and lines[-1] == "":
        lines.pop()
    return lines, eol, final_eol


def encode_lines(lines: list[str], eol: str, final_eol: bool) -> bytes:
    text = eol.join(lines)
    if final_eol:
        text += eol
    return text.encode("utf-8")


def read_fragment(path: Path) -> list[str]:
    lines, _, _ = split_lines(path.read_bytes())
    return lines


def require(path: Path) -> None:
    if not path.is_file():
        print(f"ERROR: {path} not found; run from the B738.tablet script folder.", file=sys.stderr)
        raise SystemExit(2)


def verify_package() -> str:
    require(MANIFEST_FILE)
    package_id = ""
    package_version = ""
    payloads: dict[str, tuple[int, str]] = {}
    for line in MANIFEST_FILE.read_text(encoding="utf-8").splitlines():
        fields = line.split("|")
        if len(fields) == 3 and fields[:2] == ["package", "id"]:
            package_id = fields[2]
        elif len(fields) == 3 and fields[:2] == ["package", "version"]:
            package_version = fields[2]
        elif (
            len(fields) == 7
            and fields[0] == "payload"
            and fields[3] == "size"
            and fields[5] == "sha256"
        ):
            try:
                payloads[fields[2]] = (int(fields[4]), fields[6])
            except ValueError:
                print(f"ERROR: invalid payload size in {MANIFEST_FILE}: {line}", file=sys.stderr)
                raise SystemExit(2)

    if package_id != PACKAGE_ID or not package_version:
        print(f"ERROR: invalid or incompatible {MANIFEST_FILE}.", file=sys.stderr)
        raise SystemExit(2)

    required_files = (*PAYLOADS, DOFILE_FRAGMENT, HOOK_FRAGMENT, Path("z_Install.py"))
    for path in required_files:
        require(path)
        expected = payloads.get(path.name)
        if expected is None:
            print(f"ERROR: {path.name} is not listed in {MANIFEST_FILE}.", file=sys.stderr)
            raise SystemExit(2)
        data = path.read_bytes()
        actual_size = len(data)
        actual_hash = hashlib.sha256(data).hexdigest()
        if actual_size != expected[0] or actual_hash != expected[1]:
            print(
                f"ERROR: {path.name} does not match package {package_version}; "
                "extract the complete package again and allow overwriting.",
                file=sys.stderr,
            )
            raise SystemExit(2)
    return package_version


def matches(lines: list[str], needle: str, *, active_only: bool = False) -> list[int]:
    result = []
    for index, line in enumerate(lines):
        if needle in line and (not active_only or not line.lstrip().startswith("--")):
            result.append(index)
    return result


def find_block(lines: list[str], begin: str, end: str) -> tuple[int, int] | None:
    starts = matches(lines, begin)
    ends = matches(lines, end)
    if not starts and not ends:
        return None
    if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
        print(f"ERROR: malformed or duplicate marked block {begin!r}.", file=sys.stderr)
        raise SystemExit(1)
    return starts[0], ends[0] + 1


def unique_anchor(lines: list[str], needle: str) -> int:
    found = matches(lines, needle, active_only=True)
    if len(found) != 1:
        print(f"ERROR: expected one active anchor {needle!r}, found {len(found)}.", file=sys.stderr)
        raise SystemExit(1)
    return found[0]


def install_block(
    lines: list[str], begin: str, end: str, fragment: list[str], anchor: str, *, before: bool
) -> bool:
    block = find_block(lines, begin, end)
    if block is not None:
        if lines[block[0]:block[1]] == fragment:
            return False
        lines[block[0]:block[1]] = fragment
        return True
    index = unique_anchor(lines, anchor)
    insertion = index if before else index + 1
    lines[insertion:insertion] = fragment
    return True


def remove_block(lines: list[str], begin: str, end: str) -> bool:
    block = find_block(lines, begin, end)
    if block is None:
        return False
    del lines[block[0]:block[1]]
    return True


def validate_lua(payload: bytes) -> None:
    compiler = shutil.which("luac")
    if compiler is None:
        print("Lua syntax check skipped: luac not found.")
        return
    with tempfile.NamedTemporaryFile(suffix=".lua") as temporary:
        temporary.write(payload)
        temporary.flush()
        completed = subprocess.run(
            [compiler, "-p", temporary.name], capture_output=True, text=True, check=False
        )
    if completed.returncode != 0:
        message = completed.stderr.strip() or completed.stdout.strip()
        print(f"ERROR: modified B738.tablet.lua failed luac: {message}", file=sys.stderr)
        raise SystemExit(1)
    print("Lua syntax check passed.")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--uninstall", action="store_true", help="remove only this package's marked hooks")
    args = parser.parse_args()

    require(LUA_FILE)
    package_version = ""
    if not args.uninstall:
        package_version = verify_package()

    original = LUA_FILE.read_bytes()
    lines, eol, final_eol = split_lines(original)
    changed = False
    if args.uninstall:
        changed |= remove_block(lines, DOFILE_BEGIN, DOFILE_END)
        changed |= remove_block(lines, HOOK_BEGIN, HOOK_END)
    else:
        changed |= install_block(
            lines, DOFILE_BEGIN, DOFILE_END, read_fragment(DOFILE_FRAGMENT), DOFILE_ANCHOR, before=False
        )
        changed |= install_block(
            lines, HOOK_BEGIN, HOOK_END, read_fragment(HOOK_FRAGMENT), HOOK_ANCHOR, before=True
        )

    if not changed:
        if args.uninstall:
            print("Tablet performance calculator hooks are already removed.")
        else:
            print(f"Package {package_version} payload verified.")
            print("Tablet hooks already installed and current; installation complete.")
        return 0

    modified = encode_lines(lines, eol, final_eol)
    validate_lua(modified)
    if not args.uninstall and not BACKUP_FILE.exists():
        shutil.copy2(LUA_FILE, BACKUP_FILE)
        print(f"Backup created: {BACKUP_FILE}")
    elif not args.uninstall:
        print(f"Backup already exists, not overwritten: {BACKUP_FILE}")
    LUA_FILE.write_bytes(modified)
    action = "Removed" if args.uninstall else "Installed or updated"
    print(f"{action} Tablet performance calculator hooks in {LUA_FILE}.")
    if not args.uninstall:
        print(f"Package {package_version} payload verified; installation complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
