# 19 — A standalone Fortran toolchain carved from flang-zig + flang-rt-zig (measured 2026-10-06)

*Answer to r-zig-pixi's proposal of a conda-free Fortran archive for
compiling R packages. Measured on gamma (linux-64), omicron (osx-arm64,
osx-64 under Rosetta) and kappa (win-64) against the published packages;
sizes for all six subdirs. Premises established earlier today are cited from
[docs/18](18-static-r-channel-vision.md) §6.1 and not re-derived. Nothing
published changes; the one recipe addition (a compile-only driver config)
ships with the next release.*

## 0. Summary

- **The minimal relocatable compile set works on all three platforms with
  nothing else on `PATH`**: `flang-23` (+`flang` link, `flang.exe` on
  Windows), the intrinsic + OpenMP `.mod` files, `libflang_rt.runtime.a`,
  and (macOS only) a one-line driver config. 24 files on unix, 40 on
  Windows. **zstd archives: 30.5 MB (osx-arm64) to 43.9 MB (linux-64)**;
  raw 144–210 MB, dominated by the 136–196 MB driver binary (§2).
- **Compile with flang, link with zig** (r-zig-pixi's model) needs neither
  lld-zig, nor a sysroot, nor an SDK path, nor the Windows CRT snapshot.
  The **flang driver link** needs, beyond the set: Linux `ld.lld` + a conda
  sysroot + compiler-rt's crt objects + `--rtlib=compiler-rt`; macOS
  `SDKROOT` (then either Apple's `ld` or `ld64.lld`); Windows `ld.lld` + the
  14 MB MinGW CRT snapshot directory (§3).
- **The config file question**: Linux and Windows need **no cfg at all** —
  flang-rt ships the intrinsic-module directory under the driver's own
  default triple name; macOS needs one line (`-fintrinsic-modules-path …`)
  because the driver's triple carries the host OS version. Passing that
  flag from zig-fc removes the cfg everywhere (§4). The compile-only cfg is
  now a recipe file, rendered as `bin/flang-compile.cfg` from build 6 on.
- **Windows**: lld-zig is unnecessary when zig links (measured); the
  `libomp.dll.a`/`libatomic.a` shims exist only for the *driver's*
  `-latomic -lomp`; a zig-linked Fortran DLL exports only its own symbols
  today (24, no runtime symbol) because lld's MinGW auto-export skips
  archive members, so flang-rt 10's hidden-visibility flags change nothing
  visible there (§5).
- **Upstream zig 0.16.0 vs conda's**: identical machine code for the same
  explicit flags; the bytes differ only in the embedded clang version
  string; linked programs differ in `NEEDED` (upstream: `libc` only;
  conda: the eight glibc split libraries, from the feedstock's
  `--no-as-needed` patch). Switching is a recipe refactor (own shims, no
  mirror), not a binary fix (§6).
- **OpenMP**: yes, require `llvm-openmp >=23` on every subdir in flang-rt
  10 (§7). The drop-in question stays where docs/18 §5 left it.
- **Recommendation (§8): document the file set and ship the carving
  script** (`scripts/carve-fortran-standalone.py`, tested on all six
  subdirs today) rather than publish a second per-platform artifact.

## 1. Channel state (2026-10-06)

`python3 scripts/check-build-alignment.py` → "build alignment OK" against
the declared legacy spread: lld-zig `_1/_0/_4/_4/_0/_3`, flang-zig
`_2/_1/_5/_5/_1/_4`, flang-rt-zig `_9/_9/_9/_9/_4/_7` (linux-64,
linux-aarch64, osx-arm64, osx-64, win-64, win-arm64), all version 23.1.1.
Full file lists per package and subdir, generated from each package's
`info/paths.json` (size, symlink/hardlink flag, path): [`19-file-lists/`](19-file-lists/).

| subdir | flang-zig (files / installed / download) | flang-rt-zig | lld-zig |
|---|---|---|---|
| linux-64 | 446 / 1,023 MB / 124.5 MB | 61 / 15 MB / 1.3 MB | 2 / 66 MB / 21.5 MB |
| linux-aarch64 | 446 / 989 MB / 120.1 MB | 61 / 14 MB / 1.1 MB | 2 / 60 MB / 20.5 MB |
| osx-arm64 | 446 / 814 MB / 98.7 MB | 55 / 8.3 MB / 1.0 MB | 2 / 52 MB / 17.1 MB |
| osx-64 | 446 / 850 MB / 106.4 MB | 55 / 11 MB / 1.2 MB | 2 / 58 MB / 19.2 MB |
| win-64 | 445 / 1.7 GB / 205.7 MB | 92 / 83 MB / 8.7 MB | 11 / 327 MB / 108.2 MB |
| win-arm64 | 445 / 1.5 GB / 181.6 MB | 93 / 67 MB / 6.4 MB | 11 / 288 MB / 98.4 MB |

What the bulk is: flang-zig's `lib/*.a` (libFortranSemantics 236 MB,
libFortranLower 178 MB, libFortranEvaluate 156 MB on linux-64; 387/316/248
MB on win-64) — flang's own static libraries, needed to *build* against
flang, not to compile Fortran — plus `bbc`, `fir-opt`, `fir-lsp-server`,
`tco`, `f18-parse-demo` (188 MB of developer tools on linux-64). The
driver `flang-23` is 196 MB (linux-64), 136 MB (osx-arm64), 175 MB
(win-64, where `flang-new.exe` is a hardlink to it). On Windows flang-rt
ships five 14.3 MB runtime archives of which `libflang_rt.runtime.a` and
`.static.a` are byte-identical and the `dynamic`/`_dbg` variants are the
same static build under CMake's other names — four of them can go in
build 10.

## 2. The minimal relocatable compile set

Carved from the published files by `scripts/carve-fortran-standalone.py`
(pairs a `flang-zig` and a `flang-rt-zig` `.conda` per subdir; `--archive
zst|xz|gz|none`), producing `<subdir>/flang-standalone/`:

```
bin/flang-23, bin/flang -> flang-23            (Library/bin/flang.exe on Windows)
bin/flang.cfg                                  one line, see §4 (Library/bin/flang.cfg)
lib/clang/23/finclude/flang/<conda triple>/    18 files: 15 intrinsic .mod + omp_lib.mod, omp_lib_kinds.mod, omp_lib.h
   + x86_64-unknown-linux-gnu -> <conda triple> (linux symlink, as shipped)
   + x86_64-w64-windows-gnu/ (Windows: the driver-triple copy, as shipped; 36 files total)
lib/clang/23/lib/<rt dir>/libflang_rt.runtime.a   rt dir = x86_64-unknown-linux-gnu | aarch64-unknown-linux-gnu | darwin | x86_64-w64-windows-gnu | aarch64-w64-windows-gnu
lib/libflang_rt.runtime.a -> …                 unix symlink, as shipped (lets -L<root>/lib -lflang_rt.runtime work)
STANDALONE-ORIGIN.txt                          provenance: source filenames + build numbers
```

| subdir | files | raw | gzip -9 | zstd -19 | xz -9 | full packages' download for comparison |
|---|---|---|---|---|---|---|
| linux-64 | 24 | 210.0 MB | 62.2 MB | **43.9 MB** | 39.3 MB | 125.8 MB (+21.5 lld) |
| linux-aarch64 | 24 | 195.9 MB | 58.9 MB | **41.3 MB** | 34.7 MB | 121.2 MB (+20.5) |
| osx-arm64 | 24 | 143.9 MB | 45.1 MB | **30.5 MB** | 25.9 MB | 99.7 MB (+17.1) |
| osx-64 | 24 | 157.3 MB | 50.3 MB | **35.0 MB** | 31.8 MB | 107.6 MB (+19.2) |
| win-64 | 40 | 190.1 MB | 58.0 MB | **40.1 MB** | 35.6 MB | 214.4 MB (+108.2) |
| win-arm64 | 40 | 166.7 MB | 52.1 MB | **35.7 MB** | 29.7 MB | 188.0 MB (+98.4) |

(raw = bytes on disk; compressed = one tar of the tree. Windows raw counts
one runtime archive, not five. r-zig-pixi's 279 MB / 63 MB-zstd linux-64
figure included lld: adding lld-zig's 66 MB `lld` binary gives 278.1 MB raw
and 62.9 MB zstd, measured here; on Windows the lld set adds 65 MB raw /
18.4 MB zstd.) `xz` is 10–20 % smaller than `zstd -19` but decompresses
several times slower; both are fine, `zstd` is what the `.conda` already
uses.

### 2a. Test (a): flang compiles, zig links the static archive — PASSES everywhere

With `env -i PATH=<set>/bin` (Windows: `PATH` set to the carved `bin` only),
`hello.f90`, `modules.f90` (derived types → needs `__fortran_type_info.mod`),
`omp_lib_use.f90 -fopenmp` (`use omp_lib`) and `omp_directives.f90
-fopenmp` compile on linux-64, osx-arm64 (and osx-64 under Rosetta) and
win-64. Then, with the plain conda zig binary (no wrapper, `env -i`):

| platform | link line that works | result |
|---|---|---|
| linux-64 | `zig cc -target x86_64-linux-gnu.2.17 x.o <root>/lib/libflang_rt.runtime.a -lm` (or `-L<root>/lib -lflang_rt.runtime`) | runs; NEEDED = glibc's split libs; OpenMP: add `-L<dir of libomp.so> -lomp` → `threads=2 max=2` |
| osx-arm64 | `zig cc -target aarch64-macos.11.0-none x.o <root>/lib/libflang_rt.runtime.a -lm` — **no SDK path given** | runs; `libSystem.B` only; `minos 11.0` when the objects were compiled with `-mmacos-version-min=11.0` (flang stamps the host SDK's 26.0 otherwise, docs/16 §3c); OpenMP with conda-forge's `libomp.dylib` → `threads=2` |
| win-64 | `zig cc -target x86_64-windows-gnu x.o <root>\Library\lib\clang\23\lib\x86_64-w64-windows-gnu\libflang_rt.runtime.a` — **no lld-zig, no CRT snapshot** (zig brings its own MinGW CRT) | runs; imports 10 OS DLLs, all resolve; OpenMP links against either the `libomp.dll.a` shim or conda-forge's MSVC `libomp.lib`, with `libomp.dll` beside the exe → `threads=2` |

The carved trees produced by the script were re-tested the same way on
each platform (relocated from the `.tar.zst` on linux-64): identical
results.

## 3. Test (b): what the flang DRIVER link needs beyond the set

| platform | step | result |
|---|---|---|
| linux-64 | set only | fails: no linker (`posix_spawn failed`) |
| | + `ld.lld` on `PATH`, `-fuse-ld=lld` | fails: `unable to find library -lflang_rt.runtime` — the driver searches `<resource>/lib/linux` and `<root>/lib`, not the per-triple runtime dir (its triple is `x86_64-conda-linux-gnu`, the dir is `x86_64-unknown-linux-gnu`); the shipped `lib/libflang_rt.runtime.a` symlink is what makes it work |
| | + symlink + `--sysroot=<conda sysroot_linux-64>` + flang-rt's `lib/clang/23/lib/linux/` (crtbegin/crtend/builtins, shipped) + `--rtlib=compiler-rt` | **works**: NEEDED `libm libc`, GLIBC_2.16 |
| | without `--rtlib=compiler-rt` | fails: wants `crtbeginS.o`, `-lgcc` (no GCC anywhere, by design) |
| | without `--sysroot` | links against the host's glibc → **GLIBC_2.34 ceiling on a 2.39 host**: the 2.17 floor is lost. The sysroot package is 265 MB installed |
| | `-fopenmp` | the driver adds `-lomp -lpthread` |
| osx-arm64 | set only | fails: no linker |
| | + `/usr/bin` on `PATH` (Apple `ld`), no `SDKROOT` | fails: `ld: library 'System' not found` |
| | + `SDKROOT` | **works** (Apple `ld -syslibroot`); the archive is found through the resource dir `lib/clang/23/lib/darwin` (no symlink needed); `minos` follows the objects |
| | + `SDKROOT` + `ld64.lld` from lld-zig, `/usr/bin` not on `PATH` | **works** too — lld-zig can replace Apple's `ld` for the driver link, the SDK cannot be replaced |
| win-64 | set only | fails: no linker |
| | + `ld.lld.exe` (lld-zig), `-fuse-ld=lld` | fails: `-lmingw32 -lgcc -lgcc_eh` not found |
| | + `-L<Library\x86_64-w64-mingw32\lib>` (flang-rt's 14 MB CRT snapshot: `crt2.o crtbegin.o crtend.o libmingw32 libmingwex libmsvcrt libgcc libgcc_eh libmoldname libkernel32 libuser32 libadvapi32 libshell32 libntdll libatomic libomp.dll.a`) | **works**; `-fopenmp` adds `-latomic -lomp` |

So the driver link is a different product: on Linux it needs a 265 MB
sysroot to keep the floor; on macOS the Xcode CLT; on Windows lld + the
CRT snapshot. r-zig-pixi's plan to send *every* link, configure probes
included, through zig is the right one for a conda-free archive.

## 4. The driver config outside conda

What the published `flang.cfg` carries and why each line belongs to the
link step: `$-Wl,-L,<CFGDIR>/../lib` and `$-Wl,-rpath,…` (link search path
and rpath to the env), `$-Wl,-rpath-link` + `--sysroot=<CFGDIR>/../<triple>/sysroot`
+ `-fuse-ld=lld` + `--rtlib=compiler-rt` (Linux link only; the Windows cfg
has `-fuse-ld=lld` and, on arm64, `-lcompat_arm64`), and
`-fintrinsic-modules-path <CFGDIR>/../lib/clang/23/finclude/flang/<triple>`
— the only compile-time line.

Measured without any cfg (`modules.f90`, which needs the intrinsic
`__fortran_type_info` module):

| platform | driver default lookup (`-###`) | no cfg, no flag | with `-fintrinsic-modules-path` on the command line |
|---|---|---|---|
| linux-64 | `…/finclude/flang/x86_64-conda-linux-gnu` — the LLVM default triple the binary was configured with (`LLVM_HOST_TRIPLE`), and the dir flang-rt ships (plus the `x86_64-unknown-linux-gnu` symlink) | **compiles** | compiles |
| win-64 | `x86_64-w64-windows-gnu`; flang-rt ships that copy beside the `x86_64-w64-mingw32` one | **compiles** when that dir is in the set (the first hand-carved set lacked it and failed with "runtime derived type info descriptor was not generated") | compiles |
| osx-arm64 | `arm64-apple-macosx26.0.0` on a macOS 26 host — the version is the host's, no shipped directory can match | fails ("runtime derived type info descriptor…") | compiles |

Therefore: **the minimal cfg is empty on Linux and Windows and one line on
macOS**, and passing `-fintrinsic-modules-path <root>/lib/clang/23/finclude/flang/<conda triple>`
from zig-fc makes a cfg unnecessary on every platform (verified for
`use omp_lib` too). The `<CFGDIR>` placeholder is expanded by the driver
relative to the cfg's directory, so the one-liner is relocatable.

Added to the recipe (ships with flang-zig build 6, no rebuild now):
`packages/flang-zig/recipe/flang-compile.cfg.in`, rendered by both build
scripts into `bin/flang-compile.cfg` (`Library/bin/` on Windows), exactly
one non-comment line; the driver accepts its `#` comments (verified with
`--config flang-compile.cfg` and renamed to `flang.cfg`); the recipe test
checks both. The carving script writes the same line as `flang.cfg`.

Exact minimal cfg per platform (the `<triple>` dir names flang-rt ships):

```
linux-64:      (none needed)   or: -fintrinsic-modules-path <CFGDIR>/../lib/clang/23/finclude/flang/x86_64-conda-linux-gnu
linux-aarch64: (none needed)   or: … /aarch64-conda-linux-gnu
osx-arm64:     -fintrinsic-modules-path <CFGDIR>/../lib/clang/23/finclude/flang/arm64-apple-darwin20.0.0
osx-64:        -fintrinsic-modules-path <CFGDIR>/../lib/clang/23/finclude/flang/x86_64-apple-darwin13.4.0
win-64:        (none needed with the x86_64-w64-windows-gnu dir)   or: … /x86_64-w64-mingw32
win-arm64:     (none needed with the aarch64-w64-windows-gnu dir)  or: … /aarch64-w64-mingw32
```

## 5. Windows parity

- **lld-zig is unnecessary when zig links** — measured: `zig cc -target
  x86_64-windows-gnu modules.o libflang_rt.runtime.a` with no lld-zig and
  no CRT snapshot on the machine produces a running `.exe` (zig's own
  MinGW CRT and lld-link). lld-zig matters only for the driver link (§3).
- **What the flang-rt build 4 shims are for, exactly** (from the driver's
  `-###` with `-fopenmp`: `… -lflang_rt.runtime -latomic -lomp -lmingw32
  -lgcc -lgcc_eh -lmoldname -lmingwex -lmsvcrt -ladvapi32 -lshell32
  -luser32 -lkernel32 …`):
  - `omp_lib.mod` / `omp_lib_kinds.mod` / `omp_lib.h`: **compile time
    only**; built by this flang from LLVM 23's `omp_lib.F90.var` with
    `LIBOMP_VERSION 5.0`; at link time the program needs a libomp that
    exports what it calls (§7).
  - `libomp.dll.a` (191 KB): a MinGW import library generated from
    conda-forge `libomp.dll`'s export table; needed only because the
    *driver* emits `-lomp` and MinGW lookup finds `lib<name>.dll.a`, not
    MSVC's `libomp.lib`. zig links either one directly (both measured);
    `libomp.dll` must be loadable at run time in both cases.
  - `libatomic.a` (8 bytes, an empty archive): satisfies the driver's
    `-latomic`; zig's CRT has no libatomic and never needs one (atomics
    come from compiler-rt builtins).
  None of the three is needed by a zig link.
- **Hidden visibility on win-64 (planned flang-rt 10)**: COFF has no ELF
  visibility; `-fvisibility=hidden` on MinGW only excludes symbols from
  lld's auto-export. Measured today with build 4 (no visibility flags): a
  Fortran DLL linked by zig with the static runtime exports **24 symbols,
  all its own** (`_QM…` module entities, `main`, `_QQmain`, `_CRT_INIT`,
  `__mingw_module_is_dll`) and **no `_FortranA*` runtime symbol**, because
  lld's MinGW auto-export rule skips members pulled from archives. So the
  flags are a parity change (same CFLAGS/CXXFLAGS on all six subdirs, one
  build number) with no expected change in exports; the existing unix
  tripwire (`.hidden` on `_FortranAioBeginExternalListOutput`) has no COFF
  equivalent — use a DLL export count on a test object instead if a
  Windows tripwire is wanted. win-64 flang-rt 10 is otherwise the number
  bump plus dropping the four duplicate archives (§1).

## 6. Building with upstream zig 0.16.0 instead of conda-forge's (estimate; nothing built)

Measured 2026-10-06 on gamma with the official `zig-x86_64-linux-0.16.0`
tarball (same bytes as the PyPI `ziglang` wheel's binary) against the
conda `zig_impl_linux-64 0.16.0` build 9 binary and its wrapper, one C
file, `-target x86_64-linux-gnu.2.17 -mcpu=baseline -O2`:

| | upstream `zig cc` | conda plain `zig cc` | conda wrapper `x86_64-conda-linux-gnu-zig-cc` |
|---|---|---|---|
| object code | reference | `objdump -d` identical | identical (explicit flags or none: the wrapper's own `-mcpu=baseline`/target give the same code) |
| object bytes | — | differ only in the embedded producer string: `clang version 21.1.0` vs `21.1.8 (conda-forge clangdev-feedstock …)` | same as conda plain |
| linked C program NEEDED | `libc.so.6` only | `libm libc ld-linux libresolv libpthread libdl librt libutil` | same as conda plain |
| linked C++ program NEEDED | `libc ld-linux libpthread libdl` | the same eight | — |
| glibc ceiling | GLIBC_2.2.5 | GLIBC_2.2.5 | GLIBC_2.2.5 |
| libc++ | static | static (no `libcxx` in env) | static |
| the compiler binary itself | static | needs conda `libLLVM.so.21.1`, `libclang-cpp.so.21.1`, `libz`, `libzstd`, `libstdc++` | script around the same binary |
| plain `zig cc` **without** `-mcpu=baseline` | native-CPU code (103 differing lines) | native-CPU code | n/a (wrapper injects baseline) |

What would change in the recipes: a second `source:` entry (the zig tarball
for the *build* platform, sha256-pinned; cross targets keep working because
zig is a cross compiler) or a `pip install ziglang`-style fetch; four tiny
shims of our own (`cc`/`c++`/`ar`/`ranlib`, plus `rc` on Windows: `exec
zig cc -mcpu=baseline --target=<explicit> "$@"`), an explicit
`ZIG_GLOBAL_CACHE_DIR`, and the removal of `${{ compiler('zig') }}` /
`zig_*` build deps, the `zig_compiler*` variant keys, the `ZIG_LIB_DIR`
mirror (upstream has no shared-libc++ preference), and the macOS conda-triple
rewrite in flang-rt's build.sh (there is no wrapper translation to work
around; the zig-form triple goes straight in). `zig-toolchain.txt` would
record the tarball's hash instead of a conda package. What would change in
the binaries: the producer string, and on Linux the `NEEDED` list shrinks
from eight to one–four glibc libraries (all still glibc; the allowlist
tripwire passes either way); nothing else, by the measurement above and by
docs/18 §6.4's reading of the wrapper. Side effects: docs/16's D1–D7 stop
applying, and **the 0.17 wave would no longer wait for conda-forge** (the
upstream 0.17.0 tarball exists; a main-label `zig_impl_*` does not). Cost: a
50–80 MB tarball per build host, our own shims to maintain, and losing the
conda-forge `run_exports`/pin convention for the compiler (replaced by the
sha256 in the recipe). It is a principle decision (r-zig-pixi's "upstream
zig is the reference"), not a correctness fix — docs/18 §6.4's "keep
`compiler('zig')` through the wave" stands until the user chooses.

## 7. OpenMP: pin `llvm-openmp >=23` on unix too

Today: win-64/win-arm64 `depends` carry `llvm-openmp >=23.1.1` (from the
host dependency's run export), the four unix subdirs carry an unbounded
`llvm-openmp`. The shipped `omp_lib.mod` (225 `omp_*` names) is generated
from LLVM 23's `omp_lib.F90.var` and declares 6.0-era entry points
(`omp_get_devices_memspace`, `omp_target_memset`, `omp_get_max_teams`,
`omp_in_explicit_task`, `omp_pause_resource`, `omp_display_env`, …) that
older libomp builds do not export — a program calling them links only
against a libomp of the same generation; conda-forge 23.1.2 exports them
(measured). Directive-only code (`__kmpc_*`) binds any libomp. The honest
contract is the module's generation: **`run: - llvm-openmp >=${{ major }}`
on every subdir in flang-rt 10** (no upper bound; a newer libomp runs code
built against an older `omp.h`/module), which also matches r-zig-pixi's
`23.*` pin. Recipe change only, at wave time. The channel-owned libomp
question is docs/18 §5 and is not reopened here.

## 8. Recommendation: a documented file set + a carving script, not a second artifact

**Recommend**: flang-pixi documents the minimal set (this file, §2) and
ships `scripts/carve-fortran-standalone.py`; r-zig-pixi carves its archive
from the published `.conda` files at its own build time (one `pixi exec
--spec "python>=3.14" python carve-fortran-standalone.py --out … a.conda
b.conda` per subdir, ~5 s each, tested on gamma/omicron/kappa today). The
carved tree's provenance file names the exact build numbers it came from.

Trade-offs, both ways:

- A second published artifact **doubles the publishing surface** (18 files
  → 24 per release, six more uploads on three hosts), needs its own
  storage (6 × 30–44 MB ≈ 225 MB per release on a prefix.dev plan that was
  pruned to 18 files for space), and **can drift from the build numbers**
  the alignment rule (docs/13) just made meaningful — an archive carved
  today would say "23.1.1" while containing flang-zig `_2`/`_5`/`_1` and
  flang-rt `_9`/`_4`/`_7` depending on subdir.
- A script run by the consumer keeps one source of truth (the `.conda`),
  costs the consumer a Python ≥ 3.14 (or `zstandard`) run, and gives
  non-conda users nothing to download by URL.
- **If a downloadable artifact is wanted later**: generate it from the
  published `.conda` files, never from a separate build, and host it as
  GitHub release assets (free, `scripts/stage-release.sh` and `test.yml`'s
  release path already exist) named with the build numbers —
  `flang-standalone-23.1.1-<subdir>-b<lld>.<flang>.<flang-rt>.tar.zst` —
  so it cannot drift; a `carve` job after the six native tests is the
  natural place. Not done now.

What r-zig-pixi must change to use the set (also in their handoff §8):
compile with `-fintrinsic-modules-path <root>/lib/clang/23/finclude/flang/<conda triple>`
(or keep the one-line `flang.cfg` the script writes), `-mmacos-version-min=<floor>`
on macOS; link `<root>/lib/libflang_rt.runtime.a` (or `-L<root>/lib
-lflang_rt.runtime`) `-lm`, plus `-lomp` against *their* libomp for
`-fopenmp`; on Windows link `Library\lib\clang\23\lib\x86_64-w64-windows-gnu\libflang_rt.runtime.a`
and their libomp import library, nothing from the CRT snapshot; pin one
flang-rt build number on every platform after the 0.17 wave (10).

## 8a. Shipped (release built 2026-10-07)

`bin/flang-compile.cfg` (flang-zig 6), `llvm-openmp >=23` on every subdir
and the single Windows runtime archive (flang-rt-zig 10) are in the first
aligned release (docs/10 2026-10-07, docs/14). The post-build checks on
each subdir were exactly §2a on the carved tree of the new packages.

## 9. How to re-verify

```bash
# channel state
python3 scripts/check-build-alignment.py
# carve + archive all six subdirs from the published files (linux files in ./channel, the others fetched from https://prefix.dev/universe/<subdir>/<file>)
pixi exec --spec "python>=3.14" python scripts/carve-fortran-standalone.py --out /tmp/carve --archive zst channel/linux-64/flang-zig-*.conda channel/linux-64/flang-rt-zig-*.conda …
# test (a) on the carved tree, nothing else on PATH (linux; omicron/kappa: the same with their zig binary)
R=/tmp/carve/linux-64/flang-standalone; env -i PATH=$R/bin flang -fopenmp -c packages/flang-rt-zig/recipe/omp_lib_use.f90 -o o.o && env -i PATH=$R/bin flang -c packages/flang-rt-zig/recipe/modules.f90 -o m.o
zig cc -target x86_64-linux-gnu.2.17 m.o $R/lib/libflang_rt.runtime.a -lm -o m && ./m
# cfg question: default lookup dir of the driver, and the no-cfg compile
mv $R/bin/flang.cfg /tmp/; env -i PATH=$R/bin flang -### -c m.f90 2>&1 | tr ' ' '\n' | grep -A1 intrinsic-modules-path; env -i PATH=$R/bin flang -c packages/flang-rt-zig/recipe/modules.f90 -o m0.o; mv /tmp/flang.cfg $R/bin/
# test (b): the driver link's extra needs (linux: lld + sysroot + crt objects + --rtlib)
env -i PATH=$R/bin:<lld-zig bin> flang -fuse-ld=lld --rtlib=compiler-rt --sysroot=<sysroot_linux-64 root> m.o -o m_b && readelf -V m_b | grep -oE 'GLIBC_[0-9.]+' | sort -V | tail -1   # 2.16
# upstream vs conda zig (one object): fetch https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz, then
#   for Z in <up>/zig <env>/bin/x86_64-conda-linux-gnu-zig; do $Z cc -target x86_64-linux-gnu.2.17 -mcpu=baseline -O2 -c h.c -o h-$$.o; done; diff <(objdump -d a.o) <(objdump -d b.o)
# omp_lib.mod generation: strings <finclude>/omp_lib.mod | grep -oE 'omp_[a-z_0-9]+' | sort -u | wc -l   # 225
# windows DLL exports (kappa): zig cc -target x86_64-windows-gnu -shared modules.o libflang_rt.runtime.a -o m.dll && python scripts/pe-exports.py m.dll
```
