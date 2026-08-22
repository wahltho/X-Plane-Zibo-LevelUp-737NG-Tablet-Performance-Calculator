#!/usr/bin/env python3
"""Generate the compact Lua performance dataset from the active C++ tables.

The generated Lua file is a mechanically encoded copy of the immutable runtime
rows consumed by the private C++ takeoff and landing calculators.  It groups
rows by their lookup key and stores only the numeric payload in delimited
strings so XLua does not have to construct roughly 120,000 row tables at load
time.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import itertools
import os
import re
import sys
from collections import defaultdict
from pathlib import Path


ROOT = Path(
    os.environ.get(
        "ZIBO_MOD_SOURCE_ROOT",
        Path(__file__).resolve().parents[2] / "Zibo Mod",
    )
).expanduser().resolve()
TAKEOFF_SOURCE = ROOT / "zibomod/takeoff_perf/generated/takeoff_tables.inc"
LANDING_SOURCE = ROOT / "zibomod/landing_perf/generated/fcom_landing_tables.inc"
OUTPUT = Path(__file__).resolve().parents[1] / "B738.tablet_perf_data.lua"
TAKEOFF_GENERATOR = ROOT / "tools/generate_takeoff_perf_tables.py"


ENUMS = {
    "kVariantZibo737800": 0,
    "kVariant737600": 1,
    "kVariant737700": 2,
    "kVariant737800": 3,
    "kVariant737900": 4,
    "kVariant737900ER": 5,
    "kConditionDry": 0,
    "kConditionGood": 1,
    "kConditionMedium": 2,
    "kConditionPoor": 3,
    "kBrakeMaxManual": 0,
    "kBrakeAutobrake1": 1,
    "kBrakeAutobrake2": 2,
    "kBrakeAutobrake3": 3,
    "kBrakeAutobrakeMax": 4,
    "true": 1,
    "false": 0,
}


# name: (number of key columns, expected total columns)
TAKEOFF_ARRAYS = {
    "kTakeoffFieldPoints": (4, 11),
    "kTakeoffClimbPoints": (4, 10),
    "kTakeoffSlopePoints": (2, 5),
    "kTakeoffWindPoints": (2, 5),
    "kTakeoffLimitCorrections": (4, 10),
    "kTakeoffSpeedPoints": (4, 8),
    "kTakeoffSpeedAdjustmentPoints": (5, 8),
    "kTakeoffV1AdjustmentPoints": (5, 8),
    "kTakeoffMcgPoints": (3, 6),
    "kTakeoffTrimPoints": (3, 6),
    "kTakeoffVrefPoints": (1, 3),
    "kTakeoffN1Points": (2, 5),
    "kTakeoffN1BleedPoints": (2, 4),
    "kTakeoffAssumedBleedPoints": (2, 4),
    "kTakeoffAtmMaximumPoints": (2, 5),
    "kTakeoffAtmN1Points": (2, 5),
    "kTakeoffAtmMinimumPoints": (2, 4),
    "kTakeoffAtmDeltaPoints": (2, 5),
}

LUA_NAMES = {
    "kTakeoffFieldPoints": "field",
    "kTakeoffClimbPoints": "climb",
    "kTakeoffSlopePoints": "slope",
    "kTakeoffWindPoints": "wind",
    "kTakeoffLimitCorrections": "limit_corrections",
    "kTakeoffSpeedPoints": "speeds",
    "kTakeoffSpeedAdjustmentPoints": "speed_adjustments",
    "kTakeoffV1AdjustmentPoints": "v1_adjustments",
    "kTakeoffMcgPoints": "mcg",
    "kTakeoffTrimPoints": "trim",
    "kTakeoffVrefPoints": "vref40",
    "kTakeoffN1Points": "n1",
    "kTakeoffN1BleedPoints": "n1_bleed",
    "kTakeoffAssumedBleedPoints": "assumed_bleed",
    "kTakeoffAtmMaximumPoints": "atm_maximum",
    "kTakeoffAtmN1Points": "atm_n1",
    "kTakeoffAtmMinimumPoints": "atm_minimum",
    "kTakeoffAtmDeltaPoints": "atm_delta",
}


def parse_token(token: str) -> str:
    token = token.strip()
    if token in ENUMS:
        return str(ENUMS[token])
    value = float(token)
    if value == 0:
        return "0"
    if value.is_integer():
        return str(int(value))
    return format(value, ".12g")


def format_value(value: object) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    return parse_token(str(value))


def parse_arrays(path: Path, specs: dict[str, tuple[int, int]]) -> dict[str, dict[str, list[list[str]]]]:
    current: str | None = None
    parsed: dict[str, dict[str, list[list[str]]]] = {
        name: defaultdict(list) for name in specs
    }
    declaration = re.compile(r"^static const \w+ (\w+)\[\] =")
    row = re.compile(r"^\s*\{\s*(.*?)\s*\},?\s*$")

    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = declaration.match(line)
        if match:
            current = match.group(1) if match.group(1) in specs else None
            continue
        if current is None:
            continue
        if line.strip() == "};":
            current = None
            continue
        match = row.match(line)
        if not match:
            continue
        tokens = [parse_token(token) for token in match.group(1).split(",")]
        key_columns, total_columns = specs[current]
        if len(tokens) != total_columns:
            raise ValueError(
                f"{path}:{line_number}: {current} has {len(tokens)} columns, expected {total_columns}"
            )
        key = ":".join(tokens[:key_columns])
        parsed[current][key].append(tokens[key_columns:])
    return parsed


def parse_landing(path: Path) -> dict[str, list[list[str]]]:
    # The landing enum starts at 0 while the takeoff enum reserves 0 for the
    # Zibo -800.  Normalize it to the takeoff data's 1..5 aircraft keys.
    rows: dict[str, list[list[str]]] = defaultdict(list)
    row = re.compile(r"^\s*\{\s*(.*?)\s*\},?\s*$")
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = row.match(line)
        if not match:
            continue
        raw = [token.strip() for token in match.group(1).split(",")]
        if len(raw) != 21:
            raise ValueError(f"{path}:{line_number}: landing row has {len(raw)} columns, expected 21")
        variant = ENUMS[raw[0]]
        key = ":".join((str(variant), parse_token(raw[1]), str(ENUMS[raw[2]])))
        brake = str(ENUMS[raw[3]])
        payload = [brake] + [parse_token(token) for token in raw[4:]]
        rows[key].append(payload)
    return rows


def load_takeoff_generator():
    spec = importlib.util.spec_from_file_location("upstream_perf_takeoff_generator", TAKEOFF_GENERATOR)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {TAKEOFF_GENERATOR}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def numeric_rows(groups: dict[str, list[list[str]]], group_key: str) -> list[tuple[float, ...]]:
    rows = groups.get(group_key)
    if not rows:
        raise ValueError(f"missing generated takeoff group {group_key}")
    return [tuple(float(value) for value in row) for row in rows]


def common_axis(first: list[tuple[float, ...]], second: list[tuple[float, ...]], column: int) -> list[float]:
    first_axis = [row[column] for row in first]
    second_axis = [row[column] for row in second]
    low = max(min(first_axis), min(second_axis))
    high = min(max(first_axis), max(second_axis))
    axis = sorted({value for value in first_axis + second_axis if low <= value <= high})
    if not axis:
        raise ValueError("supplemental takeoff surfaces do not overlap")
    return axis


def add_group_rows(
    groups: dict[str, list[list[str]]], group_key: str, rows: list[tuple[object, ...]]
) -> None:
    if group_key in groups:
        raise ValueError(f"duplicate supplemental takeoff group {group_key}")
    groups[group_key] = [[format_value(value) for value in row] for row in rows]


def add_900er_limit_surfaces(takeoff: dict[str, dict[str, list[list[str]]]], generator) -> None:
    for rating in (24, 22):
        for dry in (0, 1):
            source_field = numeric_rows(takeoff["kTakeoffFieldPoints"], f"5:27:{dry}:5")
            source_climb = numeric_rows(takeoff["kTakeoffClimbPoints"], f"5:27:{dry}:5")
            source_field_anchor = generator.make_interpolator(
                source_field, (0, 1, 2), 3, ((False, False), (False, False), (False, False))
            )
            source_climb_anchor = generator.make_interpolator(
                source_climb, (0, 1), 2, ((False, False), (False, False))
            )
            for flaps in (1, 5, 10, 15, 25):
                donor_field = numeric_rows(
                    takeoff["kTakeoffFieldPoints"], f"0:{rating}:{dry}:{flaps}"
                )
                donor_climb = numeric_rows(
                    takeoff["kTakeoffClimbPoints"], f"0:{rating}:{dry}:{flaps}"
                )
                donor_field_flap = generator.make_interpolator(
                    donor_field, (0, 1, 2), 4, ((False, False), (False, False), (False, False))
                )
                donor_field_basis = generator.make_interpolator(
                    donor_field, (0, 1, 2), 5, ((False, False), (False, False), (False, False))
                )
                donor_climb_flap = generator.make_interpolator(
                    donor_climb, (0, 1), 3, ((False, False), (False, False))
                )
                donor_climb_basis = generator.make_interpolator(
                    donor_climb, (0, 1), 4, ((False, False), (False, False))
                )

                field_rows = []
                field_axes = [common_axis(source_field, donor_field, column) for column in range(3)]
                for altitude, length, oat in itertools.product(*field_axes):
                    basis = donor_field_basis(altitude, length, oat)
                    if basis <= 0:
                        raise ValueError("invalid supplemental field-limit basis")
                    value = source_field_anchor(altitude, length, oat) * (
                        donor_field_flap(altitude, length, oat) / basis
                    )
                    field_rows.append((altitude, length, oat, value, 1, 1, 1))
                add_group_rows(
                    takeoff["kTakeoffFieldPoints"], f"5:{rating}:{dry}:{flaps}", field_rows
                )

                climb_rows = []
                climb_axes = [common_axis(source_climb, donor_climb, column) for column in range(2)]
                for altitude, oat in itertools.product(*climb_axes):
                    basis = donor_climb_basis(altitude, oat)
                    if basis <= 0:
                        raise ValueError("invalid supplemental climb-limit basis")
                    value = source_climb_anchor(altitude, oat) * (
                        donor_climb_flap(altitude, oat) / basis
                    )
                    climb_rows.append((altitude, oat, value, 1, 1, 1))
                add_group_rows(
                    takeoff["kTakeoffClimbPoints"], f"5:{rating}:{dry}:{flaps}", climb_rows
                )

                source_correction = numeric_rows(
                    takeoff["kTakeoffLimitCorrections"], f"5:27:{dry}:{flaps}"
                )[0]
                donor_correction = numeric_rows(
                    takeoff["kTakeoffLimitCorrections"], f"0:{rating}:{dry}:{flaps}"
                )[0]
                donor_basis = numeric_rows(
                    takeoff["kTakeoffLimitCorrections"], f"0:26:{dry}:{flaps}"
                )[0]
                correction = []
                for source_value, donor_value, basis_value in zip(
                    source_correction, donor_correction, donor_basis
                ):
                    if abs(basis_value) < 1.0e-9:
                        if abs(donor_value) >= 1.0e-9:
                            raise ValueError("invalid supplemental correction basis")
                        correction.append(source_value)
                    else:
                        correction.append(source_value * donor_value / basis_value)
                add_group_rows(
                    takeoff["kTakeoffLimitCorrections"],
                    f"5:{rating}:{dry}:{flaps}",
                    [tuple(correction)],
                )


def append_cpp_rows(
    takeoff: dict[str, dict[str, list[list[str]]]],
    cpp_name: str,
    rows: list[tuple[object, ...]],
) -> None:
    key_columns, total_columns = TAKEOFF_ARRAYS[cpp_name]
    for row in rows:
        if len(row) != total_columns:
            raise ValueError(f"supplemental {cpp_name} row has {len(row)} columns")
        tokens = [format_value(value) for value in row]
        group_key = ":".join(tokens[:key_columns])
        takeoff[cpp_name][group_key].append(tokens[key_columns:])


def add_900er_rating_tables(takeoff: dict[str, dict[str, list[list[str]]]], generator) -> None:
    packages = (
        generator.Package(
            "kVariant737900ER", 24, 0, (), 0, (),
            ((1863, generator.ALL_FLAPS),), ((1864, generator.ALL_FLAPS),),
            1865, 0, 1874, (1875, 1876),
        ),
        # The 7B27 FCOM has no separate 22K pages. The same 900ER airframe's
        # 7B26 section supplies the matching 22K thrust-level tables.
        generator.Package(
            "kVariant737900ER", 22, 0, (), 0, (),
            ((1705, generator.ALL_FLAPS),), ((1706, generator.ALL_FLAPS),),
            1707, 0, 1714, (1715, 1716),
        ),
    )
    for package in packages:
        for dry in (True, False):
            pages = package.speed_dry if dry else package.speed_wet
            for page, flaps in pages:
                speeds, speed_adjustments, v1_adjustments, mcg = generator.parse_speed_page(
                    generator.DEFAULT_PDF, package, page, flaps, dry
                )
                append_cpp_rows(takeoff, "kTakeoffSpeedPoints", speeds)
                append_cpp_rows(takeoff, "kTakeoffSpeedAdjustmentPoints", speed_adjustments)
                append_cpp_rows(takeoff, "kTakeoffV1AdjustmentPoints", v1_adjustments)
                append_cpp_rows(takeoff, "kTakeoffMcgPoints", mcg)
        append_cpp_rows(takeoff, "kTakeoffTrimPoints", generator.parse_trim_page(generator.DEFAULT_PDF, package))
        n1, n1_bleed = generator.parse_n1_page(generator.DEFAULT_PDF, package)
        append_cpp_rows(takeoff, "kTakeoffN1Points", n1)
        append_cpp_rows(takeoff, "kTakeoffN1BleedPoints", n1_bleed)
        append_cpp_rows(takeoff, "kTakeoffAssumedBleedPoints", n1_bleed)
        atm_maximum, atm_n1, atm_minimum, atm_delta = generator.parse_atm_pages(
            generator.DEFAULT_PDF, package
        )
        append_cpp_rows(takeoff, "kTakeoffAtmMaximumPoints", atm_maximum)
        append_cpp_rows(takeoff, "kTakeoffAtmN1Points", atm_n1)
        append_cpp_rows(takeoff, "kTakeoffAtmMinimumPoints", atm_minimum)
        append_cpp_rows(takeoff, "kTakeoffAtmDeltaPoints", atm_delta)


def add_900er_sfp_derates(takeoff: dict[str, dict[str, list[list[str]]]]) -> None:
    generator = load_takeoff_generator()
    add_900er_limit_surfaces(takeoff, generator)
    add_900er_rating_tables(takeoff, generator)


def encode_rows(rows: list[list[str]]) -> str:
    return ";".join(",".join(row) for row in rows)


def lua_long_string(value: str) -> str:
    # Generated numeric payload never contains a closing long-string token.
    return "[[" + value + "]]"


def render_table(name: str, groups: dict[str, list[list[str]]]) -> list[str]:
    lines = [f"data.{name} = {{"]
    for key in sorted(groups, key=lambda value: tuple(int(part) for part in value.split(":"))):
        lines.append(f"    [\"{key}\"] = {lua_long_string(encode_rows(groups[key]))},")
    lines.append("}")
    lines.append("")
    return lines


def generate() -> str:
    takeoff = parse_arrays(TAKEOFF_SOURCE, TAKEOFF_ARRAYS)
    add_900er_sfp_derates(takeoff)
    landing = parse_landing(LANDING_SOURCE)
    takeoff_sha = hashlib.sha256(TAKEOFF_SOURCE.read_bytes()).hexdigest()
    landing_sha = hashlib.sha256(LANDING_SOURCE.read_bytes()).hexdigest()
    lines = [
        "-- GENERATED FILE. DO NOT EDIT.",
        "-- Source: zibomod/takeoff_perf/generated/takeoff_tables.inc",
        "-- Source: zibomod/landing_perf/generated/fcom_landing_tables.inc",
        f"-- takeoff_sha256={takeoff_sha}",
        f"-- landing_sha256={landing_sha}",
        "-- Supplemental 900ER/SFP 24K and 22K tables: see SOURCE.md",
        "",
        "local data = {}",
        "",
    ]
    for cpp_name in TAKEOFF_ARRAYS:
        lines.extend(render_table(LUA_NAMES[cpp_name], takeoff[cpp_name]))
    lines.extend(render_table("landing", landing))
    lines.append("B738_upstream_perf_data = data")
    lines.append("return data")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail when the checked-in Lua data is stale")
    args = parser.parse_args()
    required = (TAKEOFF_SOURCE, LANDING_SOURCE, TAKEOFF_GENERATOR)
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        print(
            "Maintainer source input is unavailable. Set ZIBO_MOD_SOURCE_ROOT "
            "to the private Zibo Mod source checkout.\nMissing: " + "\n".join(missing),
            file=sys.stderr,
        )
        return 2
    generated = generate()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != generated:
            print(f"STALE: {OUTPUT}")
            return 1
        print(f"PASS: {OUTPUT} is current")
        return 0
    OUTPUT.write_text(generated, encoding="utf-8", newline="\n")
    print(f"Wrote {OUTPUT} ({OUTPUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
