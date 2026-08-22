# Source and derivation notes

The checked-in Lua calculator is generated from, and behaviorally follows, the
maintainer's active variant-specific C++ calculator. The C++ implementation and
its generated datasets are the upstream source of truth for the generated Lua
data:

- `zibomod/takeoff_perf/fcom_performance.inc`
- `zibomod/takeoff_perf/generated/takeoff_tables.inc`
- `zibomod/landing_perf/landing_perf.inc`
- `zibomod/landing_perf/generated/fcom_landing_tables.inc`
- the variant-specific VREF tables in `zibomod/calc.inc`

`tools/generate_lua_data.py` mechanically groups and encodes the generated C++
rows into `B738.tablet_perf_data.lua`. Set `ZIBO_MOD_SOURCE_ROOT` to the
maintainer source checkout when running it from this repository. The generator
records SHA-256 hashes of both input table files in the generated header;
`--check` verifies that the checked-in Lua copy is current. The common generated
dataset includes exact 737-700 24K/22K/20K
rating-specific speeds, trim, N1 and assumed-temperature rows. Its 22K/20K
field and climb limits retain the 737-700/7B24 airframe anchor and use the
generator's integrated rating-transfer surfaces. The public patch additionally emits the 900ER/SFP 24K and 22K rating
surfaces because those ratings are selectable in the LevelUp FMC but are not
yet consumed by the private C++ Tablet runtime.

The public Zibo plugin is not modified. The adapter replaces only the Tablet's
runtime calls to the external calculator and the rudimentary landing result
page after the stock Tablet script has defined its original functions.

For takeoff, a reported LevelUp 737-900 airframe with `laminar/B738/sfp`
enabled is resolved to the 737-900ER 27K/24K/22K performance family. The 24K
speed, trim, N1 and ATM rows come directly from the 900ER/7B27 FCOM section.
The 7B27 section has no separate 22K pages, so the matching 900ER/7B26 22K
rows supply that thrust-level surface. Field/climb limits retain the 900ER/27K
airframe anchor and apply the same integrated 24K/22K rating-transfer surfaces
used by the calculator's unified dataset. Landing uses the same resolved
airframe identity as takeoff.

When `zibomod/b737_variant` remains `-1`, the adapter resolves the legacy
shared-plugin selector `laminar/B738/73x` (`0` = 737-800, `1` = 737-900,
`2` = 737-700). Field/climb dispatch tables begin at sea level and end at a
finite runway length, so a lower pressure altitude or longer available runway
uses that nearest published boundary; the calculator still rejects pressure
altitude above the table, a runway below the minimum, and temperatures outside
the published domain.
