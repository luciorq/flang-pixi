# RESTART_PROMPT — state of flang-pixi as of 2026-11-12 (read first in a new session)

Authoritative detail lives in `docs/10-status-log.md` ("Current state at a
glance" and "Next actions" at the top, then entries newest first) and the
numbered docs; this file is the map.

## Where things stand

- **Published and native-tested on all six subdirs** (prefix.dev
  `universe`, docs/14): the **third aligned release, LLVM 23.1.5
  (2026-11-12) — lld-zig `_0`, flang-zig `_0`, flang-rt-zig `_1`,
  llvm-openmp `zig_*_1`** on every subdir, conda-forge zig 0.17.0;
  `test.yml` run 43339367038 green on all six runners; alignment OK
  (`release` 0/0/1/1); prune keeps 24, retains 36, deletes 0.
  `llvm-zig` (`_0`) is build-only, never published.
- **llvm-openmp is new in this release:** the channel's own libomp, built
  with zig in flang-rt-zig's runtimes build (`openmp` in
  `LLVM_ENABLE_RUNTIMES`), a second output of the flang-rt-zig recipe,
  published under conda-forge's name with `zig_*` build strings (decision
  2026-11-11, docs/18 §5.4; cause: conda-forge's win-arm64 libomp breaks
  parallel regions with more than six shared variables, docs/10
  2026-11-11). flang-rt-zig build 1 requires `llvm-openmp ==23.1.5 zig_*`.
- **Channel order is part of the contract:** strict channel priority
  filters dependencies by the first channel that has the name, so
  **consumers list universe before conda-forge** (`pixi workspace channel
  add --prepend https://prefix.dev/universe`); with conda-forge first,
  flang-rt-zig is unsolvable. universe has **no base or override channel**
  on prefix.dev since 2026-11-12 (the base relation to conda-forge ranked
  conda-forge above universe and hid our llvm-openmp in every order;
  docs/10 2026-11-12). Keep universe's Base and Overrides empty.
- **Retained** beside it (`retain` in `scripts/build-alignment.json`, keyed
  by version): the 36 23.1.1 files of the first (lld `_5` / flang `_6` /
  flang-rt `_10`, zig 0.16.0; r-zig-toolchain pins them) and second (lld
  `_6` / flang `_7` / flang-rt `_11`, zig 0.17.0; r-zig-pixi's lock before
  its release 11) aligned releases. `next_release`: lld-zig 1, flang-zig 1,
  flang-rt-zig 2, llvm-openmp 2, llvm-zig 1.
- **Every published file is libc-only at load time** (docs/18 §6.1; the
  allowlist tripwire runs at the end of every build): Linux NEEDED = glibc +
  loader (GLIBC ≤ 2.17), macOS = `libSystem.B` with `minos 11.0`, Windows =
  OS DLLs + `api-ms-win-crt-*`. The run sections declare `__glibc >=2.17` /
  `__osx >=11.0` by hand on every subdir (the linux-aarch64 gap of
  2026-10-06 is closed). `check-stdlib-floor.py` also rejects any C++/GCC/
  MSVC runtime dependency (conda-forge's zig 0.17.0 build 6 run-exports
  them; all four recipes ignore them by name).
- **Build path:** standalone rattler-build only via `scripts/rb-stage.sh`
  (`pixi run build-<stage>`) / `scripts/rb-stage.bat`; `recipe/variants.yaml`
  is the single source of floors (glibc 2.17, macOS 11.0) and of the zig
  pin (0.17.0); `pixi publish` retired (docs/06). Build hosts: gamma (=
  this machine; linux-64 native, linux-aarch64 cross), omicron (osx-arm64
  native, osx-64 Rosetta via `RB_BUILD_PLATFORM=osx-64`), kappa (win-64
  native, win-arm64 cross; SYSTEM scheduled tasks, scp'd `.ps1`, CRLF
  `.bat`). The 23.1.5 builds ran in scratch copies (gamma `RB_OUT` under
  `/data/gamma/luciorq/workspaces/temp/r-zig-pixi/fp-rb`, omicron
  `~/rz-fp-2315/`, kappa `C:\Users\admin\rz-fp-2315\`). Tests:
  `.github/workflows/test.yml` on six hosted runners. Tools (lock refreshed
  2026-11-11): **rattler-build 0.80.0**, pixi **0.84.2** (the version CI
  pins), `prefix-dev/setup-pixi` **v0.11.3**, cmake 4.4.5, python 3.15.2,
  conda-forge `zig_impl_*` 0.17.0 (build 6). omicron's firewall (LuLu)
  keys rules by program path: a new environment's rattler-build needs a
  rule (docs/10 2026-11-11).
- **One build number per package on all six subdirs** (docs/13 rule since
  2026-10-07). `python3 scripts/check-build-alignment.py` verifies the
  channel against `scripts/build-alignment.json`.
- **Consumer (r-zig-pixi):** uses flang-zig on every platform it builds
  (linux-64 since 2026-10-03). Its release 11 (PR #48, build 11, not yet
  published) switches to 23.1.5 (flang-zig 0, flang-rt-zig 1, `llvm-openmp
  zig_*_1`), lists universe first and adds win-arm64. We own only `§6`
  and `§7` of its `.github/devdocs/consolidation/FLANG_PIXI_HANDOFF.md`;
  never edit other files there unasked.

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
run-time contract; docs/18 §5 (libomp) is done as of 23.1.5 (§5.4) and
§6.6 (allowlist tripwire) runs in every build; handoff §7 is r-zig-pixi's.

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
NEEDED, no conda-forge wait). The `llvm-openmp` requirement it asked for
is in flang-rt-zig on every subdir since 23.1.5 (`==23.1.5 zig_*` from
build 1).

## Decisions in force, and why

1. Never publish llvm-zig; never publish 22.x (prefix.dev storage).
2. Standalone rattler-build only: pixi-build derives `c_stdlib_version`
   from the build machine and ignores `variants.yaml` (shipped `__glibc
   >=2.28` once). Tripwire `scripts/check-stdlib-floor.py` in rb-stage.
3. Builds on our hosts, tests on hosted runners (osx-arm64 runners too
   small for stage 1; 6 h cap). Staging via GitHub pre-releases possible
   (`scripts/stage-release.sh`, `test.yml` `release:<tag>` + promote).
4. OpenMP: **since 23.1.5 (decision 2026-11-11, docs/18 §5.4) the channel
   builds libomp** — `llvm-openmp` `zig_*`, an output of the flang-rt-zig
   recipe; `omp_lib.mod` / `omp_lib.h` come from openmp's own runtimes
   build; flang-rt-zig requires `llvm-openmp ==23.1.5 zig_*` (build 1);
   consumers list universe first; the channel follows conda-forge's libomp
   majors. History below (superseded). Until 23.1.1: never build libomp;
   conda-forge `llvm-openmp` was the single
   runtime; flang-rt-zig shipped `omp_lib.mod` (+ `libomp.dll.a`, empty
   `libatomic.a` on Windows). **Under review, unchanged (2026-10-06):**
   docs/18 §5 assesses a channel-owned `llvm-openmp-zig` drop-in (same
   names/soname/exports/symbol versions, `run_constraints: llvm-openmp
   <0.0a0`, scheduled with the 0.17 wave, r-zig-pixi switches in the same
   wave) and lists eight checks to do first; measured: conda-forge's libomp
   is libc-only on Linux/macOS (GLIBC 2.17, libSystem) and MSVC-built on
   Windows (`VCRUNTIME140`, `vc14_runtime`/`ucrt`); r-zig-pixi's lock pulls
   `llvm-openmp` through flang-rt-zig, its own `23.*` pin, and on macOS the
   `openmp_*` openblas builds + `_openmp_mutex *_kmp_llvm` (by name). The
   decision flips only when the user confirms (it did, 2026-11-11).
5. win-arm64: cross-only from win-64 (no native zig on 0.16);
   `libcompat_arm64.a` = wcstold shim + `__C_specific_handler` import
   redirect to `api-ms-win-crt-private` (zig 0.16's arm64 kernel32 import
   lib leaks an x64-only export → `0xC0000139`). Both retired with zig 0.17
   (2026-10-11; win-arm64 green without them). Still cross-only on 0.17:
   the zig-probe env has no win-arm64 platform (pixi.toml).
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
9. zig 0.17: landed on conda-forge's main label 2026-10-10 and adopted the
   same day (user decision 2026-10-10: conda-forge zig, the build scripts
   keep every workaround either zig source needs; docs/10 2026-10-10/11).
   History: **wait for a main-label conda-forge
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
    (`build-alignment.json` `next_release`). (2026-11-12: applied —
    0.17 wave = 6/7/11; LLVM 23.1.5 reset the numbers: 0/0/1/1, llvm-zig 0.) No zig run constraint on any
    package: it cannot act on published builds and run metadata stays
    minimal; consumers pin build numbers and add upper bounds when 0.17
    packages appear.
12. **Load-time dependency allowlist tripwire (patch written 2026-10-06,
    in every build since 2026-10-07):** the end-of-build check is now
    positive — Linux: glibc's `libc/libm/libdl/libpthread/librt/libresolv/
    libutil` + loader; macOS: `libSystem.B` only (+ `minos <= floor`);
    Windows: `KERNEL32/ntdll/ADVAPI32/SHELL32/ole32/VERSION` +
    `api-ms-win-crt-*` (`check-imports.ps1` in each recipe dir, via
    `llvm-objdump --private-headers`). flang-rt's Windows build asserts "no
    PE image" for flang-rt itself and, since 23.1.5, runs the allowlist on
    its own `libomp.dll`. The
    same predicates ran over the 18 extracted published packages: zero
    violations (`scripts/check-load-deps.sh`).
14. **Consumer contract (2026-10-07):** build strings end in `_<N>`;
    release builds a published consumer pins (`retain` in
    `build-alignment.json`, keyed by version since 23.1.5: 23.1.1 lld 5/6,
    flang 6/7, flang-rt 10/11) are never pruned;
    flang-zig pins its lld-zig by build string from build 7 (`lld_build`
    recipe context, bump with each release; 23.1.5: `lld_build` 0). r-zig-pixi's `atexit`
    auto-export report: reproduced on upstream 0.16.0 and 0.17.0, parked as
    docs/12 #7, not filed (rule 10).
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
    wave. `python` is build-only (LLVM's build system; `pe-exports.py` until
    23.1.1, no recipe calls it since 23.1.5).
15. **Channel order (2026-11-12):** universe before conda-forge for every
    consumer, and universe keeps no base or override channel on prefix.dev.
    Strict priority filters a dependency (flang-rt-zig's `llvm-openmp
    zig_*`) by the first channel that has the name; a base relation ranks
    the base above universe. docs/10 2026-11-12, docs/18 §5.4.

## Working tree

Everything up to `77e7460` is pushed (2026-11-12: the 23.1.5 release, the
build-1 pin, the base-channel finding). The user commits and pushes; I
never commit.

## What remains (in order)

1. **r-zig-pixi release 11** (their track, PR #48): pins 23.1.5 (flang-zig
   0, flang-rt-zig 1, `llvm-openmp zig_*_1`), universe first, win-arm64
   added. Nothing to do here unless it reports a toolchain problem.
2. **Retained 23.1.1 builds:** drop a `retain` entry only when no
   published consumer pins it any more (r-zig-toolchain 5/6/10; the 6/7/11
   set once r-zig-pixi's 23.1.1-based builds are gone).
3. **Next release** at `next_release` (lld 1 / flang 1 / flang-rt 2 /
   llvm-openmp 2, llvm-zig 1; bump flang-zig's `lld_build`). Candidate: the
   upstream-zig switch (docs/19 §6): sha-pinned tarball per build host, own
   cc/c++/ar/ranlib/rc shims (`-mcpu=baseline` is already explicit),
   explicit `ZIG_GLOBAL_CACHE_DIR`, drop `compiler('zig')` and the
   `zig_compiler*` variant keys, drop the mirror and the macOS
   conda-triple rewrite; consider a native win-arm64 lane. Follow
   conda-forge's libomp majors (docs/18 §5.4). Pre-reads: docs/17 §5–§8,
   docs/18 §6.
4. osx-arm64 parity vs CRAN's experimental flang 23 (never done).
5. Optional hygiene: `docs/11-r-integration.md` is an old duplicate of
   `docs/11-r-zig-integration.md` (not in the index) — decide keep/delete;
   `test.yml`'s OpenMP step name still says "against conda-forge libomp";
   `stage-release.sh` reads the hosts' `projects/flang-pixi` checkouts,
   not the scratch copies the 23.1.5 builds used.
6. GHA `build.yml` (rewritten 2026-09-17) has never been run (census only).

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
# what is on universe (expect 24 release files + 36 retained 23.1.1 files)
python3 scripts/prune-universe.py                      # dry run; "delete (0)" = clean
python3 scripts/check-build-alignment.py               # "build alignment OK" (release 0/0/1/1)
# native validation of what is published, all six runners
gh workflow run test.yml && gh run list --workflow=test.yml --limit 1
# a package's floors/deps from its metadata
pixi exec --spec "python>=3.14" --spec pyyaml python scripts/check-stdlib-floor.py packages/flang-rt-zig/recipe/variants.yaml channel/linux-64/flang-rt-zig-23.1.5-*.conda
# load-time dependency allowlist (docs/18 §6.6) on any extracted package / installed prefix / consumer tree
bash scripts/check-load-deps.sh <dir> …                # "load-dep allowlist OK"; conda-forge's win libomp fails (VCRUNTIME140)
#   per-file detail: linux readelf -d <bin> | grep NEEDED ; macOS otool -L <bin> (or llvm-objdump --macho --dylibs-used) ; windows python3 scripts/pe-resolve-imports.py <exe>
# the four patched tripwires parse: for p in llvm-zig lld-zig flang-zig flang-rt-zig; do bash -n packages/$p/recipe/build.sh; done
# lock state: rattler-build 0.80.0; newest conda-forge zig
grep -o 'rattler-build-[0-9.]*' pixi.lock | sort -u ; pixi search zig_impl_linux-64 -c conda-forge | grep -E '^Version'
# standalone Fortran set (docs/19): carve, then compile with nothing else on PATH and link with zig
pixi exec --spec "python>=3.14" python scripts/carve-fortran-standalone.py --out /tmp/carve channel/linux-64/flang-zig-*.conda channel/linux-64/flang-rt-zig-*.conda
env -i PATH=/tmp/carve/linux-64/flang-standalone/bin flang -c packages/flang-rt-zig/recipe/modules.f90 -o m.o && zig cc -target x86_64-linux-gnu.2.17 m.o /tmp/carve/linux-64/flang-standalone/lib/libflang_rt.runtime.a -lm -o m && ./m
# zig 0.17 readiness (docs/17 §5; done 2026-10, kept for the upstream-zig switch): on the official tarball
#   zig cc -target x86_64-linux-gnu.2.17 h.c && nm -D a.out | grep -o 'GLIBC_[0-9.]*' | sort -V | tail -1   # <= 2.17
#   zig cc -target aarch64-windows-gnu w.c (wcstold) and csh.c -lkernel32 -> private api set imports
```
