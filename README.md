# Tablet takeoff and landing performance calculator for Zibo and LevelUp

This unofficial patch makes the existing Tablet performance pages calculate
takeoff and landing results locally in XLua. It targets the stock Zibo
4.05.35 `B738.tablet` script and also follows the LevelUp variant selector used
by the shared Zibo plugin.

Release `v0.1.7` makes the existing Toolkit package available for compatible
Zibo installations as well as LevelUp installations. The calculator runtime
and hooks are unchanged. Release `v0.1.6` prevents false stand-alone installer
failures by restricting the optional whole-file syntax check to a Lua
5.1-compatible compiler, matching
X-Plane XLua/LuaJIT semantics. Lua 5.2 through 5.4 system compilers are skipped;
the temporary source is also closed before invoking `luac.exe` on Windows. The
installer still validates package hashes and structural anchors normally. No
calculator runtime or hook changed. Release `v0.1.5` added an interoperable
manifest-driven package for the X-Plane 737NG
Maintenance Toolkit without changing the calculation runtime. The same release
archive continues to support the stand-alone `z_Install.py` workflow. Release
`v0.1.3` resolves legacy `73x`/Ultimate aircraft IDs when the shared
plugin reports no modern variant ID, adds the 737-700 FMC rating family
`R24K`/`R22K`/`R20K`, and accepts below-sea-level pressure altitude and runways
longer than the last dispatch-table row by conservatively using the nearest
published boundary. It also applies the stock FMC whole-knot rounding contract
to V1/VR/V2. Release `v0.1.2` makes LevelUp's livery-controlled 737-900ER/SFP takeoff
configuration use the 900ER dataset and offer its FMC rating family
`R27K`/`R24K`/`R22K`. Release
`v0.1.1` fixed adapter registration under XLua 1.3. Existing installations made by the receipt-based installer can be updated
by running it from the complete extracted package. Older installs without a
receipt must first be removed using their original installer and backups.

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

## Maintenance Toolkit

The release archive includes a schema-3 `package-manifest.json` with one
optional `tablet-performance-calculator` module. The Toolkit applies both hook
blocks structurally, installs the three Lua payloads in the same transaction
and owns the corresponding backups for safe update or removal. The Toolkit
contract supports detected Zibo and LevelUp installations when their tablet
scripts match the declared structural anchors. The stand-alone installer
remains available for the documented stock Zibo 4.05.35 script.

Before switching installation methods, remove the patch through its current
owner. For an older standalone installation without a receipt, use the original
installer and backups. The new installer and MTK cannot treat already patched
files as originals merely because their hashes are known.

## Deliberate `.35` runway limitation

The stock `.35` FMS runway interface supplies full-runway length and heading,
but no intersection takeoff geometry. Therefore this package offers `FULL`
runway only. It does not invent intersection distances. If `B738X_rnw.dat` is
available, threshold elevations are used to derive runway slope; otherwise the
existing departure slope/elevation datarefs and full-runway FMS list are used.

## Installation

Close X-Plane. Extract the complete package outside the aircraft folder; do
not copy its Lua files into the aircraft first. From that package folder, run:

```text
python3 z_Install.py --aircraft-root "/path/to/Zibo or LevelUp aircraft"
```

On Windows use `py -3`. Python 3.10 or newer is required. The installer checks
package hashes, preserves the script's LF/CRLF convention and checks Lua syntax
when a Lua 5.1-compatible compiler is available. It saves the original script
and payload files under its own receipt before making changes.

Use the same command for repeat installs and updates. A payload or marked block
that has changed since the recorded install blocks the operation.

## Removal and aircraft updates

Close X-Plane and run from the extracted package:

```text
python3 z_Install.py --aircraft-root "/path/to/Zibo or LevelUp aircraft" --uninstall
```

This removes this package's hooks and restores its three payload files to their
recorded original state. Other patches in the shared Lua file are retained.
Uninstall before an aircraft update replaces that script, then install again.
If the script has already been replaced, keep the receipt and backups and ask
for help; deleting them would discard the original restore record.

## Verification included in the source package

- `python3 tools/update_package.py --check`
- `python3 -m unittest discover -s tests -p 'test_*.py'`
- `lua tests/test_core.lua`
- `lua tests/test_adapter.lua`
- `python3 tests/test_installer.py`
- `luac -p` over all package Lua files

The performance-data regeneration step is maintainer-only because its inputs
belong to the private C++ source checkout. Set `ZIBO_MOD_SOURCE_ROOT` to that
checkout before running `python3 tools/generate_lua_data.py --check`.

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
- `tools/update_package.py`: deterministic Toolkit metadata and release-archive
  generator.
- `SOURCE.md`: source-of-truth and derivation notes.
- `package-manifest.txt`: hashes, sizes, target and hook metadata.
- `package-manifest.json`: Maintenance Toolkit schema-3 package contract.
- `modules/tablet-performance-calculator/`: Toolkit patch and raw Lua payloads.

This patch is unofficial and is not supported by Zibo or LevelUp.

## Installation ownership

MTK and the standalone installer remain separate supported installation methods.
Use the same owner for updates and removal. To switch, uninstall through the
current owner first, then install through the other. Neither installer adopts
already patched files on the strength of matching hashes alone.

Keep the complete extracted package, including `standalone_guard.py` and
`standalone-ownership.json`. The standalone installer checks its recorded
original backups and stops if MTK owns this patch or a shared target file.
Unknown, duplicate or incomplete patch blocks and unowned companion files also
block the operation. Other correctly installed patches are preserved.

A failed operation restores the bytes it changed. If the process is interrupted,
keep the `.patch-ownership` receipt, transaction journal and lock, together with
any older patch backup/state directory. Do not delete them to retry. Ask for
support before changing those files.

Older standalone installs without a complete receipt are not automatically
migrated. Remove them using the installer and original backups that created
them. This source change affects installation checks only; runtime payloads and
patch versions are unchanged. Installer and recovery tests cover these checks.
