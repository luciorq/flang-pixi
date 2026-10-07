# RESTART_PROMPT — state of flang-pixi as of 2026-10-07 (read first in a new session)

Authoritative detail lives in `docs/10-status-log.md` (newest entry first,
2026-10-07 at the top) and the numbered docs; this file is the map.

## Where things stand

- **Release in flight (2026-10-07): the first ALIGNED release — lld-zig 5 /
  flang-zig 6 / flang-rt-zig 10 on all six subdirs, zig 0.16.0 (zig_impl
  build 20), LLVM 23.1.1 — is BUILT and post-checked on linux-64,
  linux-aarch64, osx-arm64, osx-64, win-64 and win-arm64 (done 05:37 EDT;
  kappa needed a disk cleanup and a re-run of the arm chain). Upload waits for the
  user's go (commands in docs/14); then `prune-universe.py --apply`,
  `check-build-alignment.py`, `test.yml`. Until then universe holds the
  pre-rule spread below.** Build strings: docs/14 table; stage results and
  the two allowlist corrections the release build forced (sibling
  libraries; CRYPT32/WINHTTP): docs/10 2026-10-07.
- **Published and native-tested on all six subdirs** (prefix.dev
  `universe`, exactly 18 live files, docs/14): LLVM **23.1.1** chains built
  with conda-forge zig **0.16.0** (builds 17–19; the feedstock is at build
  20 since 2026-10-03, not yet used). Consumer set = `lld-zig`,
  `flang-zig`, `flang-rt-zig`; `llvm-zig` is build-time only, never
  published; the 22.x generation was never published.
- **Every published file is libc-only at load time** (measured 2026-10-06,
  docs/18 §6.1): Linux NEEDED = glibc + loader, macOS = `libSystem.B` with
  `minos 11.0`, Windows = OS DLLs + `api-ms-win-crt-*` (all 12 win-64
  executables resolve per symbol on kappa). No libc++/libstdc++/zlib/zstd/
  libxml2/VCRUNTIME anywhere. Finding: the three **linux-aarch64 packages
  declare no `__glibc` floor** (run export lost in the cross build; binaries
  are at GLIBC_2.17) — fix in the next rebuild (docs/18 §6.3).
- **Build path:** standalone rattler-build only via `scripts/rb-stage.sh`
  (`pixi run build-<stage>`) / `scripts/rb-stage.bat`; `recipe/variants.yaml`
  is the single source of floors (glibc 2.17, macOS 11.0); `pixi publish`
  retired (docs/06). Build hosts: gamma (= this machine; linux-64 native,
  linux-aarch64 cross; outputs under `/data/gamma/luciorq/workspaces/temp`),
  omicron (osx-arm64 native, osx-64 Rosetta via `RB_BUILD_PLATFORM=osx-64`),
  kappa (win-64 native, win-arm64 cross; SYSTEM scheduled tasks, scp'd
  `.ps1`, CRLF `.bat`). Tests: `.github/workflows/test.yml` on six hosted
  runners. Workspace lock refreshed 2026-10-06 (`pixi update`, all envs):
  rattler-build **stays 0.76.1**, python 3.14.8, cmake 4.4.4, zig 0.16.0
  build 20 in `zig-probe`; **no `zig_impl_*` 0.17.0 on conda-forge's main
  label** (only `conda-forge/label/zig_dev`).
- **Build numbers differ per subdir in the 23.1.1 generation** (docs/13 has
  why): lld `_1/_0/_4/_4/_0/_3`, flang `_2/_1/_5/_5/_1/_4`, flang-rt
  `_9/_9/_9/_9/_4/_7` for linux-64/linux-aarch64/osx-arm64/osx-64/win-64/
  win-arm64. `python3 scripts/check-build-alignment.py` verifies the channel
  against `scripts/build-alignment.json`.
- **Consumer (r-zig-pixi, branch `feat-no-host-paths`)**: Phase 2 complete
  — R built with flang on every platform; linux-64 uses conda-forge's flang
  by decision, the other four use ours. We own only `§6` and `§7` of its
  `.github/devdocs/consolidation/FLANG_PIXI_HANDOFF.md`; never edit other
  files there unasked.

## Long-term vision: a static R channel (recorded 2026-10-06, docs/18)

A conda channel distributing a portable R and R packages whose compiled
code is statically linked: packages stay `.so`/`.dylib`/`.dll` (R dlopens
them) but carry their third-party libraries inside with hidden visibility,
and depend at run time only on R, libc, and a small set of single-instance
runtimes shipped with R (libomp, BLAS/LAPACK, libR, Tcl/Tk; JVM/Python/MPI
where used). Built with conda-forge tools, distributable without conda-forge
run-time dependencies — the CRAN macOS/Windows binary model extended to
Linux, zig as the toolchain, flang-pixi as the compiler layer. Design
points, costs (own static library tree, rebuild-on-CVE, LGPL relinking,
X11/fontconfig/Cairo stay system-dynamic, `ignore_run_exports` + hand-written
run sections) and sequencing (portable R with the runtimes → static library
tree → packages) are in docs/18 §2. flang-pixi's packages already meet the
run-time contract; what follows for us is §5 (libomp) and §6.6 (allowlist
tripwire) of docs/18, and handoff §7 for r-zig-pixi.

## Standalone Fortran toolchain (r-zig-pixi proposal, measured 2026-10-06, docs/19)

The minimal conda-free compile set = `flang-23` (+link) + the intrinsic/OpenMP
`.mod` files + `libflang_rt.runtime.a` (+ a one-line cfg on macOS only): 24
files on unix, 40 on Windows, 30.5–43.9 MB as zstd; compiles with nothing
else on PATH and zig links it on all three platforms (no lld-zig, sysroot,
SDK or CRT snapshot). The flang *driver* link needs lld + sysroot (Linux),
`SDKROOT` (macOS), lld + the CRT snapshot (Windows). Recommendation: no
second artifact; `scripts/carve-fortran-standalone.py` carves it from the
published `.conda` (tested on all six subdirs). `flang-compile.cfg.in`
ships as `bin/flang-compile.cfg` from flang-zig build 6. Upstream-zig
switch = principle decision, estimated in docs/19 §6 (identical code, fewer
NEEDED, no conda-forge wait). flang-rt 10: add `llvm-openmp >=23` on unix.

## Decisions in force, and why

1. Never publish llvm-zig; never publish 22.x (prefix.dev storage).
2. Standalone rattler-build only: pixi-build derives `c_stdlib_version`
   from the build machine and ignores `variants.yaml` (shipped `__glibc
   >=2.28` once). Tripwire `scripts/check-stdlib-floor.py` in rb-stage.
3. Builds on our hosts, tests on hosted runners (osx-arm64 runners too
   small for stage 1; 6 h cap). Staging via GitHub pre-releases possible
   (`scripts/stage-release.sh`, `test.yml` `release:<tag>` + promote).
4. OpenMP: never build libomp; conda-forge `llvm-openmp` is the single
   runtime; flang-rt-zig ships `omp_lib.mod` (+ `libomp.dll.a`, empty
   `libatomic.a` on Windows). **Under review, unchanged (2026-10-06):**
   docs/18 §5 assesses a channel-owned `llvm-openmp-zig` drop-in (same
   names/soname/exports/symbol versions, `run_constraints: llvm-openmp
   <0.0a0`, scheduled with the 0.17 wave, r-zig-pixi switches in the same
   wave) and lists eight checks to do first; measured: conda-forge's libomp
   is libc-only on Linux/macOS (GLIBC 2.17, libSystem) and MSVC-built on
   Windows (`VCRUNTIME140`, `vc14_runtime`/`ucrt`); r-zig-pixi's lock pulls
   `llvm-openmp` through flang-rt-zig, its own `23.*` pin, and on macOS the
   `openmp_*` openblas builds + `_openmp_mutex *_kmp_llvm` (by name). The
   decision flips only when the user confirms.
5. win-arm64: cross-only from win-64 (no native zig on 0.16);
   `libcompat_arm64.a` = wcstold shim + `__C_specific_handler` import
   redirect to `api-ms-win-crt-private` (zig 0.16's arm64 kernel32 import
   lib leaks an x64-only export → `0xC0000139`). Both retire on zig 0.17.
6. **Static libc++ everywhere (2026-09-30):** conda-forge's zig prefers a
   shared libc++ when one is in the env (no opt-out); every unix `build.sh`
   sets `ZIG_LIB_DIR` to a symlink mirror of `$BUILD_PREFIX/lib/zig` so the
   probe misses; `libcxx` removed from all recipes.
7. **flang-rt build 9 (2026-10-01): static-only, hidden visibility** — the
   shared runtime beside the archive made `-l` pick the dylib and made
   Apple's `ld` fail to link the archive through the flang driver
   (zig-built dylibs export `___dso_handle`); hidden visibility stops every
   Fortran `.so` re-exporting ~1,100 runtime symbols. Windows unchanged.
   This is the template for every package under the static-channel vision.
8. macOS floor through the conda wrapper: only a zig-form triple
   (`aarch64-macos.11.0-none`) carries the version; flang-rt's build.sh
   rewrites CMake's conda triple on the way to the wrapper (docs/16 D4).
9. zig 0.17 (released 2026-10-03): **wait for a main-label conda-forge
   package** (the `dev` branch publishes snapshots under
   `conda-forge/label/zig_dev` only, same version string), then one
   chain-wide wave on all six subdirs. docs/17 has the full impact
   assessment; LLVM 22.1.8, mingw-w64 15, macOS default floor 15.0,
   shared-libc++ patch still present (mirror still works), aarch64 shims
   retire, native win-arm64 zig becomes possible.
10. No upstream filing (drafts in docs/12); workarounds self-contained; the
    user commits and pushes; I never commit.
11. **One build number per package per release (2026-10-06, docs/13), first applied 2026-10-07:**
    from the next release on every published package is rebuilt on all six
    subdirs at one number, so a release is identifiable by its build number
    alone; per-subdir rebuilds between releases are hotfixes declared in
    docs/14 and `scripts/build-alignment.json`. The 0.17 wave is the first
    such release was pulled forward: **lld-zig 5, flang-zig 6, flang-rt-zig
    10, llvm-zig 4 are the zig 0.16 release built 2026-10-07** (r-zig-pixi's
    final 0.16 set); the 0.17 wave (or the upstream-zig switch, docs/19 §6)
    takes **lld 6 / flang 7 / flang-rt 11 / llvm-zig 5**
    (`build-alignment.json` `next_release`). No zig run constraint on any
    package: it cannot act on published builds and run metadata stays
    minimal; consumers pin build numbers and add upper bounds when 0.17
    packages appear.
12. **Load-time dependency allowlist tripwire (patch written 2026-10-06,
    effective at the next rebuild):** the end-of-build check is now
    positive — Linux: glibc's `libc/libm/libdl/libpthread/librt/libresolv/
    libutil` + loader; macOS: `libSystem.B` only (+ `minos <= floor`);
    Windows: `KERNEL32/ntdll/ADVAPI32/SHELL32/ole32/VERSION` +
    `api-ms-win-crt-*` (`check-imports.ps1` in each recipe dir, via
    `llvm-objdump --private-headers`). flang-rt's Windows build asserts "no
    PE image" instead (its host env carries MSVC-built `libomp.dll`). The
    same predicates ran over the 18 extracted published packages: zero
    violations (`scripts/check-load-deps.sh`).
13. **Dependency trims evaluated, recipes unchanged (docs/18 §6.2–§6.5):**
    llvm-zig's optional libraries are all OFF (`LLVMConfig.cmake`: ZLIB 0,
    ZSTD OFF, LIBXML2 OFF, LIBEDIT 0, FFI OFF; TERMINFO no longer exists in
    LLVM ≥ 19). `stdlib('c')` → hand-declared `__glibc >=2.17,<3.0.a0` /
    `__osx >=11.0`: feasible (the sysroot changes nothing, docs/16 D6) and
    it fixes the linux-aarch64 gap; recommendation = declare the virtual
    floors by hand in `run:` in the 0.17 wave, make `check-stdlib-floor.py`
    fail on a missing floor, drop `stdlib('c')` only together with an
    explicit `MACOSX_DEPLOYMENT_TARGET` export in the three build.sh that
    rely on the wrapper's fold. `compiler('zig')` → `zig_impl_*` directly:
    no measured binary difference (the wrapper adds `-mcpu=baseline`, which
    we want, and an inert `-isysroot`); keep `compiler('zig')` through the
    wave. `python` is build-only (LLVM's build system; `pe-exports.py`).

## Files changed in this session (2026-10-06, uncommitted — the user commits)

New: `docs/18-static-r-channel-vision.md`, `scripts/check-build-alignment.py`,
`scripts/build-alignment.json`, `scripts/check-load-deps.sh`,
`packages/{llvm-zig,lld-zig,flang-zig,flang-rt-zig}/recipe/check-imports.ps1`.
Modified: `RESTART_PROMPT.md` (this file), `docs/10-status-log.md` (entry +
next actions), `docs/11-r-zig-integration.md` (items 7, 8 pointers),
`docs/13-zig-feedstock-coupling.md` (build-number section + rule),
`docs/14-publishing-runbook.md` (one-number-per-package table), `docs/README.md`
(index 18), `packages/*/recipe/build.sh` (allowlist tripwire), `packages/*/
recipe/build.bat` (Windows tripwire), `packages/*/recipe/recipe.yaml`
(NEXT build-number comments only; `number:` untouched), `pixi.lock`
(`pixi update`, all environments), `docs/19-standalone-fortran-toolchain.md` +
`docs/19-file-lists/` (new), `scripts/carve-fortran-standalone.py` (new),
`packages/flang-zig/recipe/flang-compile.cfg.in` (new) + its rendering in
flang-zig's `build.sh`/`build.bat`/`recipe.yaml` test, `.github/workflows/{build,test}.yml` +
`.github/actions/stage/action.yml` (actions bumped: checkout v7,
upload-artifact v7, download-artifact v8, setup-pixi v0.11.0). In r-zig-pixi: handoff `§7` appended
(their file, their push). Previous sessions' work is all pushed (tree was
clean at c2c061f plus the 10-03 RESTART_PROMPT/docs/10 edits).

## What remains (in order)

0. Finish the 2026-10-07 release: win-arm64 chain → static checks → user's
   go → upload per host (docs/14) → prune → alignment check → `test.yml`
   → finalize docs/14 and handoff §9 with the win-arm64 strings.
1. zig 0.17 wave when conda-forge's main label has `zig_impl_*` 0.17.0 (or
   the user chooses upstream zig, docs/19 §6): bump the four `variants.yaml`
   pins and the four `number:` fields to 6/7/11 (llvm-zig 5) in one change
   (floors, tripwires, flang-compile.cfg, OpenMP floor are already in);
   linux-64 first and read the tripwires;
   then the rest; `test.yml`; `check-build-alignment.py` (move
   `next_release` into `release` in `build-alignment.json`); drop
   `wcstold_compat.c` and `csh_arm64.def`/`-lcompat_arm64` after win-arm64
   is green on 0.17; consider a native win-arm64 lane. Pre-reads: docs/17
   §5–§8, docs/18 §6.
2. libomp decision (docs/18 §5): answer the eight checks, then the user
   decides; if yes, `packages/llvm-openmp-zig` joins the same wave and
   r-zig-pixi switches pins in it.
3. r-zig-pixi (their side): re-lock to flang-rt ≥ 9; linux-64 → flang-zig
   is the last platform not on flang-pixi (optional); build.zig on zig 0.17
   (docs/17 §4); vision items in handoff §7.
4. r-zig-pixi standalone archive (docs/19): their side carves with the
   script; flang-pixi side at wave time = `llvm-openmp >=23` in flang-rt's
   run, drop the four duplicate Windows runtime archives, and (if a
   downloadable artifact is ever wanted) a `carve` job producing GitHub
   release assets from the published `.conda`.
5. Optional hygiene: `docs/11-r-integration.md` is an old duplicate of
   `docs/11-r-zig-integration.md` (not in the index) — decide keep/delete.
6. GHA `build.yml` has never been run (census only).

## Credentials / infra

prefix.dev key with delete scope in `~/.rattler/credentials.json` on all
three hosts and as repo secret `PREFIX_API_KEY`. SSH: key
`~/.ssh/keys/id_cathouse` (passphrase from the user each session) loaded
into an agent at `/tmp/claude-1000/fp-agent.sock` (still loaded 2026-10-06;
`ssh omicron` / `ssh kappa` work from gamma). Omicron's network can
throttle GitHub/scp (2026-09-30); seed rattler-build's `src_cache` from a
gamma fetch if a stage cannot download (memory: kappa-transfer-constraints).
PowerShell 5.1 `Out-File` writes UTF-16: decode kappa result files as such.

## Commands to verify the work

```bash
# what is on universe (expect exactly 18 consumer files, newest build per subdir)
python3 scripts/prune-universe.py                      # dry run; "delete (0)" = clean
python3 scripts/check-build-alignment.py               # "build alignment OK" (legacy spread until the 0.17 wave)
# native validation of what is published, all six runners
gh workflow run test.yml && gh run list --workflow=test.yml --limit 1
# a package's floors/deps from its metadata
pixi exec --spec "python>=3.14" --spec pyyaml python scripts/check-stdlib-floor.py packages/flang-rt-zig/recipe/variants.yaml channel/linux-64/flang-rt-zig-23.1.1-*.conda
# load-time dependency allowlist (docs/18 §6.6) on any extracted package / installed prefix / consumer tree
bash scripts/check-load-deps.sh <dir> …                # "load-dep allowlist OK"; the 18 published files pass, conda-forge's win libomp fails (VCRUNTIME140)
#   per-file detail: linux readelf -d <bin> | grep NEEDED ; macOS otool -L <bin> (or llvm-objdump --macho --dylibs-used) ; windows python3 scripts/pe-resolve-imports.py <exe>
# the four patched tripwires parse: for p in llvm-zig lld-zig flang-zig flang-rt-zig; do bash -n packages/$p/recipe/build.sh; done
# lock state: rattler-build unchanged, no 0.17 on the main label
grep -o 'rattler-build-[0-9.]*' pixi.lock | sort -u ; pixi search zig_impl_linux-64 -c conda-forge | grep -E '^Version'
# standalone Fortran set (docs/19): carve, then compile with nothing else on PATH and link with zig
pixi exec --spec "python>=3.14" python scripts/carve-fortran-standalone.py --out /tmp/carve channel/linux-64/flang-zig-*.conda channel/linux-64/flang-rt-zig-*.conda
env -i PATH=/tmp/carve/linux-64/flang-standalone/bin flang -c packages/flang-rt-zig/recipe/modules.f90 -o m.o && zig cc -target x86_64-linux-gnu.2.17 m.o /tmp/carve/linux-64/flang-standalone/lib/libflang_rt.runtime.a -lm -o m && ./m
# zig 0.17 readiness (docs/17 §5): on the zig_dev snapshot or the official tarball
#   zig cc -target x86_64-linux-gnu.2.17 h.c && nm -D a.out | grep -o 'GLIBC_[0-9.]*' | sort -V | tail -1   # <= 2.17
#   zig cc -target aarch64-windows-gnu w.c (wcstold) and csh.c -lkernel32 -> private api set imports
```
