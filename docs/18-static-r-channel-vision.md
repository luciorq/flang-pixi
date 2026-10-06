# 18 — Long-term vision: a static R channel (recorded 2026-10-06)

*Status: a direction, not a work item. Nothing in this document changes a
recipe or a published package. Two existing decisions are re-examined here
in its light (§5, §6); both stay as they are until the user confirms. The
one new rule it carries — one build number per package per release — is in
[docs/13](13-zig-feedstock-coupling.md#build-numbers-why-they-differ-per-subdir-today-and-the-rule-from-the-next-release-on).*

## 1. The vision

A conda channel that distributes a portable R and R packages whose compiled
code is **statically linked**: packages are still shared objects (R
`dlopen`s them) but carry their third-party libraries inside, with hidden
visibility, and depend at run time only on **R, libc, and a small set of
single-instance runtimes shipped with R itself**. Packages may be *built*
with conda-forge tools but must be distributable without conda-forge
run-time dependencies.

This is the CRAN macOS/Windows binary model — CRAN's `.tgz`/`.zip` packages
embed their libraries and assume only the OS and R — extended to Linux,
with zig as the toolchain and flang-pixi as the compiler layer.

flang-pixi's own consumer set is already the proof of concept: the
published `lld-zig`/`flang-zig` binaries need glibc (Linux), `libSystem`
(macOS) or the OS DLLs plus the UCRT api-sets (Windows) and nothing else
(§6.1 has the measured lists), and `flang-rt-zig` build 9 is a static,
hidden-visibility archive.

## 2. Design points, and why

- **Packages are `.so`/`.dylib`/`.dll`, never static executables.** R loads
  package code with `dlopen` (`RTLD_NOW | RTLD_LOCAL` by default) into its
  own process; there is no executable to make static. "Static" here means
  *the package's dependencies are inside the package's shared object*.
- **Hidden visibility plus an export tripwire is mandatory.** flang-rt
  build 9 is the template: compiled with `-fvisibility=hidden
  -fvisibility-inlines-hidden`, linked static-only, and the build fails if
  the probe symbol is not hidden (docs/16 §3d). Before build 9 a Fortran
  `.so` re-exported ~1,100 runtime symbols (1,238 exports on linux-64, 828
  on osx-arm64; 2 and 2–4 after). With default visibility, two packages
  embedding different versions of the same library can bind each other's
  symbols through `RTLD_GLOBAL` loads, `dlsym`, C++ RTTI/exception
  matching and vtable identity; hidden visibility makes a package's
  embedded copy private to it. Every package build gets the same
  "exports == its own entry points" check, and the check must run on all
  three object formats (zig's Mach-O linker ignores `-exported_symbols_list`,
  docs/16 §3d — so the hiding has to happen at compile time, as in build 9).
- **Single-instance-per-process runtimes must be SHARED, owned by the
  channel, and shipped with portable R:** `libomp` (one thread pool per
  process; two OpenMP runtimes in one process oversubscribe and can
  deadlock — the reason docs/11 item 7 exists), BLAS/LAPACK (R's `R_BLAS`
  model expects exactly one), `libR` itself, Tcl/Tk (one interpreter
  state), and where used JVM, Python and MPI (process-global state, cannot
  be duplicated). These are precisely the libraries a package must *not*
  embed; the channel ships them beside R, with their own export surface,
  and packages link them dynamically by install name/soname.
- **Floors stay at glibc 2.17 (the zig target) and macOS 11.0; libc is the
  floor that cannot be removed.** Every static package still binds to the
  system C library, so the floor is the oldest libc the channel promises:
  docs/13's `x86_64-linux-gnu.2.17` target with the ceiling tripwire, and
  `MACOSX_DEPLOYMENT_TARGET=11.0` with the Mach-O `minos` tripwire. On
  Windows the floor is the UCRT (Windows 10+), which zig's MinGW CRT
  imports through the `api-ms-win-crt-*` api-sets (measured in §6.1).
- **Costs, stated up front:**
  - *Our own zig-built static library tree.* conda-forge ships few `.a`
    files and its `.a` files are libstdc++/MSVC-built; a package that embeds
    zlib, libpng, cairo-free libs, Boost headers, etc. needs `.a` archives
    built with the same zig/libc++ and the same floors. That tree is a
    channel of its own (see sequencing).
  - *Security fixes mean rebuilding every package that embeds the library.*
    A CVE in zlib is one conda-forge upload today; under the vision it is a
    rebuild of every package whose `.so` contains zlib. The channel needs
    an inventory (which package embeds which library at which version) and
    a rebuild driver. This is the cost CRAN pays on macOS/Windows.
  - *LGPL relinking obligations.* A statically embedded LGPL library (e.g.
    libgfortran-class runtimes, some codec libraries) obliges the
    distributor to allow relinking. Prefer permissive libraries; keep LGPL
    libraries *shared inside R's tree* (where the user can replace them),
    never embedded.
  - *X11, fontconfig and Cairo stay system-dynamic exceptions.* They are
    tied to the host display stack and font database; embedding them is
    both impractical and wrong (fonts and displays are per host). Packages
    that need them link the system's, exactly as CRAN's Linux builds do.
  - *Every recipe uses `ignore_run_exports` and declares only R and the
    channel's runtimes.* Build-time conda-forge packages (headers, `.a`
    files, tools) must not leak run exports; the run section is written by
    hand: `r-base-zig`, and whichever of `libomp`/BLAS/Tcl-Tk the package
    uses. flang-pixi's recipes already do this for `llvm-zig` and the
    `vc`/`ucrt` chain.
- **Sequencing:** (1) portable R bundling the single-instance runtimes
  (libR, libomp, BLAS/LAPACK, Tcl/Tk) — r-zig-pixi is most of the way
  there; (2) the static library tree (zig-built `.a` files with hidden
  visibility, one floor, one libc++); (3) packages, starting with the ones
  r-zig-pixi's contract suite already builds (Rcpp, data.table, minqa …),
  each with the export tripwire.

## 3. What this asks of flang-pixi

Nothing new in the compiler layer: flang-zig, lld-zig and flang-rt-zig
already meet the vision's run-time contract (§6.1). Two things follow:

1. The OpenMP decision (docs/11 item 7, RESTART_PROMPT decision 4) is the
   one place flang-pixi depends on a conda-forge *run-time* library. §5
   assesses a channel-owned drop-in. **Decision unchanged until confirmed.**
2. The tripwires should state the contract positively (an allowlist of
   libc-only dependencies) rather than as "no libc++". §6.6 proposes it and
   the patch is written; it takes effect with the next rebuild (the zig 0.17
   wave).

## 4. What this asks of r-zig-pixi

Recorded in their handoff §7 (`.github/devdocs/consolidation/
FLANG_PIXI_HANDOFF.md`): portable R ships libomp/BLAS/Tcl-Tk as the
channel's shared runtimes; package builds embed everything else with hidden
visibility and an export check; recipes declare only R and the channel's
runtimes; and the new one-build-number-per-release rule lets their lock pin
a single flang-rt build number on every platform after the next release.

## 5. Revisit (a): "never build libomp" vs a channel-owned `llvm-openmp-zig`

**Today (docs/11 item 7):** flang-rt-zig run-depends on conda-forge
`llvm-openmp` on every subdir and ships `omp_lib.mod` (+ `libomp.dll.a` and
an empty `libatomic.a` on Windows). The reason was single-instance: R's C
code (zig cc, `-fopenmp`) and Fortran code must share one runtime.

**Under the vision** the channel owns libomp, so the runtime would be a
flang-pixi output — `llvm-openmp-zig`, built from the same LLVM tarball
(`openmp/` runtime, standalone build: it needs a C/C++ compiler only, not
llvm-zig's libraries), as a **drop-in** for conda-forge's package: same
library names, same soname/install name, same export set and symbol
versions, same import-library names on Windows; a `run_constraints:
llvm-openmp <0.0a0` mutual exclusion so no environment carries both;
scheduled with the zig 0.17 wave; and r-zig-pixi switches its pins in the
same wave (its R and packages link `-lomp` and would otherwise keep
conda-forge's).

### 5.1 What conda-forge's libomp links and ships (measured 2026-10-06, `llvm-openmp 23.1.2` build 0, current on all six subdirs)

| subdir | files | load-time deps | floor / notes | exports |
|---|---|---|---|---|
| linux-64 `h7148c6a_0` | `lib/libomp.so` (SONAME `libomp.so`, unversioned), `lib/libompd.so`, `lib/libarcher_static.a`, `lib/libarcher.so.bak` | `libpthread.so.0 librt.so.1 libdl.so.2 libc.so.6 ld-linux-x86-64.so.2` — **no libstdc++, no libgcc_s** (only a weak `__cxa_finalize@GLIBC_2.2.5`) | GLIBC ceiling 2.17; depends `__glibc >=2.17,<3.0.a0`; version nodes `OMP_1.0 … OMP_6.0`, `GOMP_1.0 … GOMP_5.0` (GOMP compatibility layer on) | 1,385 |
| linux-aarch64 `hde6636f_0` | same set | same (`ld-linux-aarch64.so.1`) | GLIBC ceiling 2.17; **depends `[]`** (no `__glibc` floor declared) | 1,173 |
| osx-arm64 `hdb3d66b_0` | `lib/libomp.dylib` | `/usr/lib/libSystem.B.dylib` only | install name `@rpath/libomp.dylib` (compat 5.0.0, current 5.0.0); `minos 11.0`; depends `__osx >=11.0` | 1,648 |
| osx-64 `h8c1e6b9_0` | same | same | same | 1,767 |
| win-64 `h49e36cd_0` | `Library/bin/libomp.dll`, `Library/bin/libiomp5md.dll` (Intel-name alias), `Library/lib/libomp.lib`, `Library/lib/libiomp5md.lib` (MSVC import libs) | `KERNEL32.dll PSAPI.DLL VCRUNTIME140.dll` + `api-ms-win-crt-{convert,environment,heap,runtime,stdio,string,utility}` — **MSVC-built** | depends `ucrt >=10.0.20348.0, vc >=14.3,<15, vc14_runtime >=14.44.35208` | 788 |
| win-arm64 `hef4af3d_0` | same | same (arm64) | depends `vc, vc14_runtime` (no `ucrt` in that subdir) | 676 |

All six constrain `intel-openmp <0.0a0` and `openmp 23.1.2|23.1.2.*`.
Consequence for a drop-in: on Linux and macOS the conda-forge runtime is
already libc-only — the vision gains nothing in *run-time dependencies*
there, only ownership (rebuild cadence, floor control, no MSVC runtime on
Windows). On Windows the drop-in removes `vc14_runtime`/`ucrt` from the
closure (zig's MinGW CRT imports the api-sets directly), which is the one
real hermeticity gain.

### 5.2 What pulls `llvm-openmp` into r-zig-pixi's lock (branch `feat-no-host-paths`, read-only, 2026-10-06)

- **By name, besides flang-rt-zig:** r-zig-pixi's own `pixi.toml`
  (`llvm-openmp = "23.*"` in `[dependencies]`) and its `recipe/recipe.yaml`
  (`llvm-openmp 23.*` in host; unpinned in run via the run export).
- **macOS openblas feature only:** `libopenblas 0.3.34 openmp_*` builds
  (`llvm-openmp >=19.1.7`) and `_openmp_mutex 4.5 7_kmp_llvm`
  (`llvm-openmp >=9.0.1`) in the `openblas`/`full-openblas` environments on
  osx-arm64/osx-64. On linux and win-64 those environments use the
  `pthreads_*` openblas builds (no OpenMP dependency).
- **Linux and win-64 environments also carry `libgomp` + `_openmp_mutex
  4.5 20_gnu`** through `libgcc` — a second OpenMP runtime already present
  (r-zig links `libomp`, never `libgomp`, by its own rule; the vision's
  portable R removes `libgcc` from the run-time picture entirely).

So a *differently named* drop-in with mutual exclusion breaks the macOS
`openblas` environments as locked today (their openblas binds `llvm-openmp`
by name). Under the vision the channel ships its own BLAS, which resolves
it; until then the openblas feature would have to move to `pthreads` builds
on macOS, or the drop-in keeps the conda-forge name and wins by channel
priority (which docs/11 item 4 deliberately avoids for the compiler
packages).

### 5.3 Checks before deciding (none done beyond §5.1–§5.2)

1. **Export and symbol-version parity.** Build from `openmp/runtime` with
   the same `exports_so.txt` version script (OMP_*/GOMP_* nodes) and
   `LIBOMP_GOMP_COMPAT`/`LIBOMP_OMPT_SUPPORT` as conda-forge; compare
   `nm -D --defined-only` / exports-trie / PE export counts against
   1,385 / 1,173 / 1,648 / 1,767 / 788 / 676. Binaries linked against
   conda-forge's libomp carry versioned references (`omp_get_num_threads@OMP_1.0`);
   a replacement without the version nodes fails at load.
2. **No C++ runtime surface.** zig builds libomp with its static libc++;
   the export tripwire must show no `std::`/`__cxa` exports and hidden
   visibility for everything but the OpenMP API (conda-forge's exports no
   libstdc++ symbol at all — measured).
3. **Windows import libraries.** conda-forge ships MSVC-style `libomp.lib`
   (+ `libiomp5md.lib`); a MinGW build produces `libomp.dll.a`. Decide
   whether to also generate the `.lib` (lld-link `/def` can) for MSVC-built
   consumers, and whether the `libiomp5md.dll` alias is needed (Intel
   compatibility; nothing in r-zig-pixi uses it).
4. **File-list parity on Linux:** `libompd.so`, `libarcher*` — ship or
   document the omission (R needs neither).
5. **`_openmp_mutex`.** conda-forge's `*_llvm` mutex depends on
   `llvm-openmp` by name; decide whether the channel ships its own mutex
   variant or drops the mutex convention (its purpose is exactly the
   single-runtime guarantee the vision enforces by construction).
6. **r-zig-pixi's switch in the same wave:** `pixi.toml` and recipe pins,
   `omp.h` location (`$PREFIX/include/omp.h`), `-lomp` resolution on all
   subdirs, and the macOS openblas question above.
7. **Build mechanics:** a fifth recipe (`packages/llvm-openmp-zig`), built
   from the same tarball (`openmp/` with `-DOPENMP_STANDALONE_BUILD=ON`),
   no llvm-zig dependency, minutes per subdir; cross builds (linux-aarch64,
   win-arm64) need the usual explicit target; the runtime's tests need a
   compiler with `-fopenmp` (zig cc has the codegen).
8. **The 0.17 coupling.** Adding a runtime to the wave widens the first
   same-number release (§docs/13 rule); the alternative is a release of its
   own right after.

**Decision: unchanged** — flang-rt-zig keeps `llvm-openmp` (conda-forge) as
its run dependency and no libomp is built, until the user confirms the
drop-in after items 1–8 are answered.

## 6. Revisit (b): dependency trims for flang-pixi — verified with the published files

Fetched from `universe` (the 12 macOS/Windows files) and `./channel` (the 6
Linux files, byte-identical names to universe), extracted, and inspected:
`readelf -d` (Linux), `llvm-objdump --macho --dylibs-used` /
`--private-headers` (macOS; same load commands `otool -L`/`otool -l` print),
`scripts/pe-resolve-imports.py` (Windows, import listing here; **per-symbol
resolution on kappa**: the published win-64 set installed from universe with
`pixi exec`, all 12 executables — `flang.exe`, `flang-new.exe`, `bbc.exe`,
`fir-opt.exe`, `fir-lsp-server.exe`, `tco.exe`, `f18-parse-demo.exe`,
`lld.exe`, `ld.lld.exe`, `ld64.lld.exe`, `lld-link.exe`, `wasm-ld.exe` —
report "all imports resolve").

### 6.1 Load-time dependencies of every published file (2026-10-06)

| subdir | package (build) | binaries | load-time dependencies (union) | declared `depends` |
|---|---|---|---|---|
| linux-64 | lld-zig `_1` | 1 ELF (`bin/lld` + 4 symlinks) | `libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libresolv.so.2 libutil.so.1 ld-linux-x86-64.so.2` | `__glibc >=2.17,<3.0.a0` |
| linux-64 | flang-zig `_2` | 6 ELF (`flang-23`, `bbc`, `fir-opt`, `fir-lsp-server`, `tco`, `f18-parse-demo`) | same eight (glibc 2.17-era split libraries; all glibc) | `lld-zig ==23.1.1`, `sysroot_linux-64 >=2.17`, `__glibc >=2.17,<3.0.a0` |
| linux-64 | flang-rt-zig `_9` | 0 shared objects (archives + 4 relocatable crt `.o`) | none (static only) | `llvm-openmp`, `__glibc >=2.17,<3.0.a0` |
| linux-aarch64 | lld-zig `_0` | 1 ELF | same set with `ld-linux-aarch64.so.1` | **`[]`** |
| linux-aarch64 | flang-zig `_1` | 6 ELF | same | `lld-zig ==23.1.1`, `sysroot_linux-aarch64 >=2.17` — **no `__glibc`** |
| linux-aarch64 | flang-rt-zig `_9` | 0 shared objects | none | `llvm-openmp` — **no `__glibc`** |
| osx-arm64 | lld-zig `_4` | 1 Mach-O | `/usr/lib/libSystem.B.dylib` only; `minos 11.0` | `__osx >=11.0` |
| osx-arm64 | flang-zig `_5` | 6 Mach-O | `libSystem.B` only; `minos 11.0` | `lld-zig ==23.1.1`, `__osx >=11.0` |
| osx-arm64 | flang-rt-zig `_9` | 0 Mach-O executables/dylibs (archives only) | none | `llvm-openmp`, `__osx >=11.0` |
| osx-64 | lld `_4` / flang `_5` / flang-rt `_9` | 1 / 6 / 0 | identical to osx-arm64 | identical |
| win-64 | lld-zig `_0` | 5 PE (one image hardlinked) | `KERNEL32 ntdll ADVAPI32 SHELL32 ole32` + `api-ms-win-crt-{convert,environment,heap,locale,math,multibyte,private,runtime,stdio,string,time,utility}-l1-1-0` | `[]` |
| win-64 | flang-zig `_1` | 7 PE | same + `VERSION.dll` (`flang.exe`/`flang-new.exe`) | `lld-zig ==23.1.1` |
| win-64 | flang-rt-zig `_4` | 0 PE (archives: runtime, CRT snapshot, `libomp.dll.a`, `libatomic.a`) | none | `llvm-openmp`, `llvm-openmp >=23.1.1` |
| win-arm64 | lld `_3` / flang `_4` / flang-rt `_7` | 5 / 7 / 0, machine `0xaa64` | identical DLL set to win-64 | `[]` / `lld-zig ==23.1.1` / `llvm-openmp, llvm-openmp >=23.1.1` |

No file on any subdir needs `libc++`, `libstdc++`, `libgcc_s`, `libunwind`,
`zlib`, `zstd`, `libxml2`, `libedit`, `libffi`, `ncurses`/terminfo,
`VCRUNTIME140`, `MSVCP140`, `libwinpthread` or `libomp`. The contract the
vision wants (libc only) already holds for every published file.

**Two findings beyond the question asked:**
- The three **linux-aarch64** packages declare **no `__glibc` floor** (the
  `__glibc >=2.17` run export reached the linux-64 packages but not the
  cross-built ones; `check-stdlib-floor.py` only rejects a floor that is
  *too high*, so a missing one passes). The binaries themselves are fine
  (ceiling tripwire: GLIBC_2.17). Fix in the next rebuild: hand-declare the
  floor (§6.3) and make the checker fail on a missing floor.
- flang-zig's glibc "split" NEEDED list (`librt`, `libresolv`, `libutil`
  besides `libc/libm/libdl/libpthread`) is what a 2.17 target produces
  (pre-2.34 glibc had them as separate libraries). They are all glibc; the
  allowlist in §6.6 includes them. On a 2.34+ host they are stubs that
  forward to `libc.so.6`.

### 6.2 llvm-zig's optional LLVM libraries

rb-stage.sh wipes the work tree before each stage, so no `CMakeCache.txt`
of the llvm-zig build survives on gamma. The package's own
`lib/cmake/llvm/LLVMConfig.cmake` (linux-64 `llvm-zig-23.1.1-zig_f1366af_0`
in `./channel`; built with `zig_impl_linux-64 0.16.0 h0addc32_17`, target
`x86_64-linux-gnu.2.17`, per its `share/llvm-zig/build-info.txt`) records
the configured values, and both build scripts pass them unconditionally on
every subdir (`build.sh` lines 347–352, `build.bat` lines 211–214):

| option | LLVMConfig.cmake | set by the build scripts |
|---|---|---|
| `LLVM_ENABLE_ZLIB` | `0` | `OFF` |
| `LLVM_ENABLE_ZSTD` | `OFF` | `OFF` |
| `LLVM_ENABLE_LIBXML2` | `OFF` | `OFF` |
| `LLVM_ENABLE_LIBEDIT` | `0` | `OFF` (build.sh; build.bat relies on the default = not found) |
| `LLVM_ENABLE_FFI` | `OFF` | default (not requested) |
| `LLVM_ENABLE_TERMINFO` | not recorded (LLVM ≥ 19 removed the option; no terminfo dependency exists) | `OFF` (harmless no-op) |
| `LLVM_ENABLE_HTTPLIB` / `LLVM_WITH_Z3` / `LLVM_ENABLE_LIBPFM` | `OFF` / empty / `OFF` (build.sh) | |
| `LLVM_ENABLE_THREADS` / `RTTI` / `EH` / `PIC` | `ON` / `ON` / `OFF` / `ON` | |

Consistent with §6.1: the NEEDED/import lists contain none of these
libraries on any subdir. Nothing to trim here; the flags stay (they make
the result independent of what the build env happens to contain).

### 6.3 Dropping `${{ stdlib('c') }}` for hand-declared `__glibc >=2.17` / `__osx >=11.0`

What `stdlib('c')` contributes today (variants: `sysroot 2.17` / `macosx_deployment_target 11.0` / `vs 2022.14`):

| platform | build env | run exports it injects | measured effect on the binaries |
|---|---|---|---|
| linux | `sysroot_linux-<arch> 2.17` (headers; the wrapper passes `-isysroot`) | `__glibc >=2.17,<3.0.a0` — landed on linux-64 only (§6.1) | **none**: the explicit `--target=<arch>-linux-gnu.2.17` makes zig use its own glibc headers and stubs; `__GLIBC_MINOR__` is 17 with or without a conda sysroot (docs/16 D6) |
| osx | `MACOSX_DEPLOYMENT_TARGET=11.0` in the env | `__osx >=11.0` (all four macOS packages have it) | the wrapper folds the env var into the triple; flang-rt's build.sh passes the zig-form triple explicitly, the other three rely on the fold |
| win | `vs2022_win-64` chain | `vc`, `vc14_runtime`, `ucrt` — all in `ignore_run_exports.by_name` | none (MinGW target; `vs2022_*` is never invoked) |

Evaluation: **feasible, and it fixes the linux-aarch64 gap**, under two
conditions — (1) every unix `build.sh` exports `MACOSX_DEPLOYMENT_TARGET`
itself (today the macOS floor reaches the wrapper only through the variable
the stdlib activation sets; rattler-build also sets a default, but the
value must be ours), and (2) `check-stdlib-floor.py` keeps a source of
truth for the expected floors (it reads `c_stdlib_version` from
`variants.yaml`; that key can stay in variants.yaml as plain data, or the
script reads a new `floors:` key). The hand-declared lines would be, in each
recipe's `run:`: `__glibc >=2.17,<3.0.a0` (linux), `__osx >=11.0` (osx),
nothing on win. Hash impact: the `c_stdlib` variant keys leave the hash
input — a rebuild anyway in the 0.17 wave.

Recommendation: **declare the virtual floors by hand in `run:` in the 0.17
wave regardless** (so the floor is explicit and uniform on all six subdirs,
independent of run-export propagation through cross builds), extend
`check-stdlib-floor.py` to fail on a *missing* floor, and drop
`stdlib('c')` at the same time only if the `MACOSX_DEPLOYMENT_TARGET`
export is added to the three build.sh files that rely on the fold. The
package contents do not change either way (§6.1).

### 6.4 Depending on `zig_impl_<platform>` directly instead of `${{ compiler('zig') }}`

`compiler('zig')` resolves to `zig_<platform> 0.16.0` (28 files: the
`<triple>-zig-{cc,cxx,ar,ranlib,asm,rc,windres,lld,force-load-*}` wrappers
and `etc/conda/activate.d/zig_activate.sh`), which pins the exact
`zig_impl_<platform>` build (22,068 files, the compiler). The build scripts
use the wrappers through `ZIG_CC`/`ZIG_CXX`/`ZIG_AR`/`ZIG_RANLIB` and the
activation's `ZIG_GLOBAL_CACHE_DIR`; `build.bat` additionally `%ZIG_RC%`.
Because every script passes an explicit `--target`, the wrapper's remaining
contributions to our builds are: `-mcpu=baseline` (wanted — plain `zig cc`
targets the *build host's* CPU for native builds), `-isysroot <conda
sysroot>` (no effect, §6.3), and the `is_post_translate_drop` filter
(docs/16 D5) — and none of the four build scripts passes a dropped flag
(`-march`, `-mtune`, `-fstack-protector*`, `-fno-plt`,
`-fdebug-prefix-map`, `-stdlib=`; checked 2026-10-06; flang's `flang.cfg`
`-Wl,-rpath-link` goes to `ld.lld` directly, not through the wrapper).

Switching to `zig_impl_<platform>` directly means our own shims (`zig cc
-mcpu=baseline --target=…`), our own `ZIG_GLOBAL_CACHE_DIR`, and on Windows
our own `rc`. The shared-libc++ preference lives in the zig *binary*
(`Lld.zig` patch), so the `ZIG_LIB_DIR` mirror stays needed either way.
Gain: no dependence on the wrapper's flag filter or its MSVC default
(already neutralised by the explicit targets); cost: a hash-changing,
retest-everything change with **no measured difference in the binaries**.
Recommendation: **keep `compiler('zig')`** through the 0.17 wave; revisit
only if a 0.17 wrapper change bites (docs/17 §8 found none in the wrappers'
argument handling). The cross builds already name `zig_linux-64` /
`zig_win-64` explicitly and would follow the same rule.

### 6.5 The `python` build dependency

Build-only in all four recipes; it never reaches `depends` (§6.1). Use:
llvm-zig needs Python for LLVM's own build system (`Python3_EXECUTABLE` is
passed; tablegen helpers and `llvm/utils` scripts), flang-rt-zig's
`build.bat` runs `pe-exports.py` to turn `libomp.dll`'s export table into
`libomp.dll.a`, lld-zig and flang-zig do not reference it (flang's CMake
probes for it). Nothing to trim; it is not a run-time cost.

### 6.6 Allowlist tripwire (patch written 2026-10-06; takes effect at the next rebuild)

The current end-of-build tripwire is a denylist ("no `libc++`/`libstdc++`/
`libunwind` NEEDED; no shared libc++ on macOS"). The vision's contract is
positive — *only libc* — so the check becomes an allowlist, failing on
anything else:

| platform | allowed load-time dependencies | measured deviation from the list proposed in the request |
|---|---|---|
| Linux | `libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libresolv.so.2 libutil.so.1` and the loader `ld-linux-*.so.*` | `librt`, `libresolv`, `libutil` added: the 2.17 target links the pre-2.34 split libraries (§6.1); all are glibc |
| macOS | `/usr/lib/libSystem.B.dylib` only (plus the existing `minos <= floor` check) | none |
| Windows | `KERNEL32.dll`, `ntdll.dll`, `ADVAPI32.dll`, `SHELL32.dll`, `ole32.dll`, `VERSION.dll` and `api-ms-win-crt-*-l1-1-0.dll` | `ADVAPI32`, `SHELL32`, `ole32`, `VERSION` added: LLVM Support uses them (known folders, registry/crypto, file version info); they are OS DLLs present on every Windows, not runtimes |

Implementation: `packages/*/recipe/build.sh` — the Linux loop now prints
every `NEEDED` entry and fails on one outside the allowlist; the macOS loop
lists `LC_LOAD_DYLIB`/`LC_LOAD_WEAK_DYLIB`/`LC_REEXPORT_DYLIB` names
(`otool -l`, so a dylib's own `LC_ID_DYLIB` is not counted) and fails on
anything but `libSystem.B`. `packages/*/recipe/build.bat` — a new
`check-imports.ps1` (same file in the four recipe dirs) runs
`llvm-readobj --coff-imports` over `Library\bin\*.exe|*.dll` and fails on a
DLL outside the allowlist; cross builds use the native `llvm-readobj` from
`BUILD_PREFIX` like the strip pass. flang-rt-zig's Windows build skips the
scan (it ships no PE image, and its host env carries conda-forge's
MSVC-built `libomp.dll`, which would trip the list) and instead asserts no
`*flang_rt*.dll` exists. The new predicates were run over the 18 extracted
published packages before the patch was written: **zero violations**, so
the first rebuild under the allowlist (the 0.17 wave) starts green.

## 7. Build numbers

The per-subdir spread, why it exists, and the one-number-per-release rule
from the next release on: docs/13 (rule), docs/14 (live list in the new
format), `scripts/check-build-alignment.py` + `scripts/build-alignment.json`
(the check).

## 8. How to re-verify

```bash
# 1. load-time deps of every published file (this document's §6.1); downloads ~0.9 GB
S=$(mktemp -d); for u in <subdir>/<filename from the docs/14 table> …; do curl -sSLo $S/$(basename $u) https://prefix.dev/universe/$u; done
#   extract (.conda = zip of .tar.zst): python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' f.conda d && zstd -dc d/pkg-*.tar.zst | tar -x -C d
#   linux: readelf -d <elf> | grep NEEDED           macOS: llvm-objdump --macho --dylibs-used <macho> (or otool -L)
#   windows: python3 scripts/pe-resolve-imports.py <exe>   (on Windows it also resolves every symbol)
# 2. conda-forge libomp per subdir (§5.1): same extraction on
#    https://conda.anaconda.org/conda-forge/<subdir>/llvm-openmp-23.1.2-<build>.conda ; readelf -V lib/libomp.so | grep -oE '(OMP|GOMP)_[0-9.]+' | sort -u
# 3. llvm-zig's optional libraries (§6.2): from the package, no build tree needed
zstd -dc <(python3 -c 'import zipfile,sys;z=zipfile.ZipFile(sys.argv[1]);sys.stdout.buffer.write(z.read([n for n in z.namelist() if n.startswith("pkg-")][0]))' channel/linux-64/llvm-zig-23.1.1-*.conda) | tar -xO lib/cmake/llvm/LLVMConfig.cmake | grep -E 'LLVM_ENABLE_(ZLIB|ZSTD|LIBXML2|LIBEDIT|FFI|HTTPLIB)'
# 4. what pulls llvm-openmp in r-zig-pixi (§5.2): read-only on their lock
python3 -c 'import yaml;d=yaml.safe_load(open("../r-zig-pixi/pixi.lock"));print([p["conda"].rsplit("/",1)[-1] for p in d["packages"] if any(x.split()[0]=="llvm-openmp" for x in p.get("depends",[]))])'
# 5. allowlist predicates against extracted packages (what the patch will enforce at build time)
bash scripts/check-load-deps.sh <extracted-package-dir> …    # exit 0 = allowlist-clean
```
