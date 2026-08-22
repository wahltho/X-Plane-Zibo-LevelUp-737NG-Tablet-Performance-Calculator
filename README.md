# Stand-alone takeoff and landing performance calculator patch for Zibo 4.05.35

This unofficial patch makes the existing Tablet performance pages calculate
takeoff and landing results locally in XLua. It targets the stock Zibo
4.05.35 `B738.tablet` script and also follows the LevelUp variant selector used
by the shared Zibo plugin.

Release `v0.1.3` resolves legacy `73x`/Ultimate aircraft IDs when the shared
plugin reports no modern variant ID, adds the 737-700 FMC rating family
`R24K`/`R22K`/`R20K`, and accepts below-sea-level pressure altitude and runways
longer than the last dispatch-table row by conservatively using the nearest
published boundary. It also applies the stock FMC whole-knot rounding contract
to V1/VR/V2. Release `v0.1.2` makes LevelUp's livery-controlled 737-900ER/SFP takeoff
configuration use the 900ER dataset and offer its FMC rating family
`R27K`/`R24K`/`R22K`. Release
`v0.1.1` fixed adapter registration under XLua 1.3. Users of an earlier release
can copy the new files over it and rerun `z_Install.py`;
the installer updates the marked loader block without overwriting the backup.

## What it provides

- Variant-specific takeoff calculations for the 737-600, -700, -800, -900 and
  -900ER, plus the stock Zibo -800 mode.
- Takeoff flaps 1, 5, 10, 15 and 25; dry/wet runway, wind, slope, altitude,
  temperature, bleed/anti-ice, rating, ATM, N1, V1/VR/V2, trim and VREF40.
- Variant-specific landing calculations for flaps 15, 30 and 40, dry/good/
  medium/poor braking action, all five brake selections and reverser credit.
- Automatic dynamic takeoff rating (`R-20K`, `R-22K`, `R-24K`, `R-26K` or `R-27K`)
  according to the selected aircraft/SFP configuration and the result actually
  used.
- Whole-hectopascal HPA display and calculation input. IN HG retains the stock
  hundredth-inch input/display contract.
- A Calculate action that requires runway, weight and a valid 6.0--36.0% CG.
  Calculate updates the result state; page 2 displays it when selected.

The external JBriks calculator is not used after the hooks are installed. The
public `zibomod` plugin binary remains unchanged.

## Deliberate `.35` runway limitation

The stock `.35` FMS runway interface supplies full-runway length and heading,
but no intersection takeoff geometry. Therefore this package offers `FULL`
runway only. It does not invent intersection distances. If `B738X_rnw.dat` is
available, threshold elevations are used to derive runway slope; otherwise the
existing departure slope/elevation datarefs and full-runway FMS list are used.

## Installation

Copy these files into the aircraft folder
`plugins/xlua/scripts/B738.tablet/`:

- `B738.tablet_perf_data.lua`
- `B738.tablet_perf_core.lua`
- `B738.tablet_perf_adapter.lua`
- `Add_dofile.txt`
- `Add_perf_hooks.txt`
- `package-manifest.txt`
- `z_Install.py`

Run the installer from that folder:

```bash
python3 z_Install.py
```

On Windows use `py z_Install.py` or `python z_Install.py` if necessary. The
installer preserves LF/CRLF line endings, syntax-checks the result when `luac`
is available, and creates `B738.tablet.lua.backup` once without overwriting it.
It also verifies the package version, sizes and SHA-256 hashes of all required
runtime files. Re-running it is safe and reports separately whether the
payload is verified and whether the marked hooks were already current.

Manual fallback: insert `Add_dofile.txt` directly after `jit.off()` and insert
`Add_perf_hooks.txt` directly before `function page_app_rating()`.

## Removal and aircraft updates

Remove only this package's hook blocks with:

```bash
python3 z_Install.py --uninstall
```

The three payload Lua files can then be deleted. Alternatively restore the
installer-created backup. After Zibo or LevelUp replaces `B738.tablet.lua`,
delete the stale backup and run the installer again against the new script;
the installer refuses an unknown script layout instead of guessing anchors.

## Verification included in the source package

- `python3 tools/generate_lua_data.py --check`
- `lua tests/test_core.lua`
- `lua tests/test_adapter.lua`
- `python3 tests/test_installer.py`
- `luac -p` over all package Lua files

The automated tests cover all six takeoff variant modes across dry/wet,
representative altitudes and all five takeoff flap settings; all five landing
variants across three flap settings, four runway conditions and five brake
settings; the recorded ESSB takeoff case; HPA normalization; the CG gate;
runtime replacement of the JBriks path; legacy `73x`/Ultimate variant resolution;
737-700 24K/22K/20K and 900ER/SFP 27K/24K/22K rating families; below-sea-level
pressure-altitude and long-runway boundary handling; and exact `.35` installer behavior for
LF and CRLF files. Simulator runtime remains a separate validation layer.

## Files

- `B738.tablet_perf_core.lua`: calculator without Tablet UI dependencies.
- `B738.tablet_perf_data.lua`: generated compact performance data.
- `B738.tablet_perf_adapter.lua`: `.35` Tablet state/UI integration.
- `tools/generate_lua_data.py`: deterministic data generator/freshness check.
- `SOURCE.md`: source-of-truth and derivation notes.
- `package-manifest.txt`: hashes, sizes, target and hook metadata.

This patch is unofficial and is not supported by Zibo or LevelUp.
