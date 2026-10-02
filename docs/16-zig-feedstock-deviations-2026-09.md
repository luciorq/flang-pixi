# 16 — What conda-forge's zig-feedstock changes versus upstream zig, and what that does to hermeticity here and in R projects

*Measured 2026-09-30 against `zig 0.16.0` build **19** (`zig_impl_linux-64
h0addc32_19`, `zig_impl_osx-arm64 h0cab596_19`, `zig_impl_win-64
h66d57dd_19`) on gamma (linux-64), omicron (osx-arm64, macOS 26.4.1) and
kappa (win-64, no Visual Studio installed), plus the feedstock sources at
`d24562f` (2026-09-24): `recipe.yaml`, `NOTES.md`, `PATCH_MANIFEST.yaml`,
`building/zig-cc-unix.c`, `flag_rules.py`, the patches. Every claim below
was either read in those sources or produced by a compile on one of the
hosts; nothing is assumed from upstream zig's documentation. Companion
documents: [13](13-zig-feedstock-coupling.md) (the glibc floor story, still
accurate), [11](11-r-zig-integration.md) (consumer contract), and
r-zig-pixi's `FLANG_PIXI_HANDOFF.md`.*

The one-paragraph version: the feedstock's zig is **not** upstream zig
with a conda wrapper around it. It is a patched compiler whose linker
**prefers a shared libc++ from the conda env over the bundled static one**
(unconditionally, on every platform, with no opt-out flag), whose plain
`zig` binary still targets the *host* (glibc 2.34+, macOS 26.4) unless
told otherwise, and whose triplet-prefixed wrappers bake in a target
(glibc 2.17, macOS 11.0/10.13, **MSVC** on Windows), a baseline CPU and a
list of silently dropped flags (`-stdlib=`, `-march=`, `-static-libstdc++`
is ignored). Static libc++ — the property this project and r-zig-pixi
rely on for "one toolchain, no shared runtimes" — is therefore an
*accident of the environment* on Linux (no `libcxx` package present) and
**does not exist on macOS at all** (`zig_impl_osx-*` run-depends on
`libcxx`). Both projects are correct today on Linux and Windows and
already carry the shared libc++ on macOS, mostly without having chosen to.

## 1. The deviations, one table

| # | deviation from upstream zig | where | measured effect |
|---|---|---|---|
| D1 | **Shared libc++ preferred over bundled static** (`Lld.zig-prefer-shared-libcxx.patch`, "unconditional across all platforms, by deliberate design", NOTES 1.9). Probe: `<zig lib dir>/../../lib/libc++.so.1` / `libc++.1.dylib` / `libc++.dll.a`. Only for native-arch links (cross builds keep static). No env var, no flag turns it off; `-static-libstdc++` is "unused", `-stdlib=` is stripped by the wrapper. | patch + wrapper | linux-64: env without `libcxx` → static libc++ (9.1 MB hello, 1193 `std::__1` symbols). Same env **plus `libcxx`** → `NEEDED libc++.so.1`, 5.4 MB, **no RUNPATH** → the binary does not even start (`cannot open shared object file`). osx-arm64: `libcxx 21.*` is a run dep of `zig_impl_osx-arm64`, so **every** C++ link produces `@rpath/libc++.1.dylib` with no rpath → `dyld: Library not loaded` until the consumer adds one. Windows: no `libc++.dll.a` in conda envs → static (1.47 MB hello, imports only KERNEL32/ntdll/UCRT api sets). Note the mix: `libc++abi.a` and `libunwind.a` stay *static* next to the *shared* libc++. |
| D2 | **Plain `zig` targets the host.** The unprefixed `zig` symlink is the patched compiler with upstream's native-target default. | packaging | `zig cc h.c` on gamma: `crt1.o` from `/usr/lib/gcc/x86_64-linux-gnu/13/…`, GLIBC_2.34 (C) / 2.38 (C++). `zig cc` on omicron: `minos 26.4.1`. Nothing conda-ish is applied unless you go through the wrappers or pass `-target` yourself. |
| D3 | **Triplet wrappers bake a target and a CPU**: `x86_64-conda-linux-gnu-zig-{cc,cxx,ar,ranlib,asm,rc,windres,lld,force-load-cc,force-load-cxx}` (C programs, `zig-cc-unix.c` / `zig-cc-nonunix.c`). Inject `-target <baked>` only if the caller passes none (R5), `-mcpu=baseline` only if absent (R6). Baked targets: `x86_64-linux-gnu.2.17` (from `c_stdlib_version`, default 2.17; riscv64 2.27), `aarch64-macos.11.0-none` / `x86_64-macos.10.13-none`, **`x86_64-windows-msvc`**, `aarch64-windows-msvc`. | recipe context + wrappers | gamma: wrapper C hello → GLIBC_2.2.5 ceiling, zig stubs, NEEDED `libm libc ld-linux libresolv libpthread libdl librt libutil` (the pre-2.34 split libs — expected for a 2.17 target). omicron: wrapper → `minos 11.0`; `MACOSX_DEPLOYMENT_TARGET=14.0` → 14.0 (folded into the triple). kappa: wrapper with no `-target` → **`error: failed to find libc installation: WindowsSdkNotFound`**; with `-target x86_64-windows-gnu` → works, identical bytes to plain zig. |
| D4 | **Conda-triple translation loses the version.** R5 rewrites `--target=arm64-apple-darwin20.0.0` to `aarch64-macos` *without* the baked version, so zig's own default applies (13.0 on 0.16, **15.0 on 0.17** — docs/17), and neither `-mmacosx-version-min=11.0` nor `MACOSX_DEPLOYMENT_TARGET` override it. `--target=aarch64-macos.11.0` (zig form) is honoured. | `flag_rules.py` R5 | omicron: `wrapper --target=arm64-apple-darwin20.0.0` → `minos 13.0`; `+ -mmacosx-version-min=11.0` → 13.0; `+ MACOSX_DEPLOYMENT_TARGET=11.0` → 13.0; `--target=aarch64-macos.11.0` → 11.0. **This is how flang-rt-zig ended up at 13.0 (§2.3).** |
| D5 | **Silently dropped flags** (`is_post_translate_drop`): `-march=*`, `-mtune=*`, `-ftree-vectorize`, `-fstack-protector[-strong]`, `-fno-plt`, `-fno-partial-inlining`, `-fno-ipa-cp-clone`, `-fdebug-prefix-map=*`, **`-stdlib=*`**, `-lgcc_eh`, `-lgcc_s`, `-l:libpthread.{a,so*}`. R7 drops `-Wl,-rpath-link*`, `-Wl,--color-diagnostics`. `-nostdlib++` downgrades the c++ wrapper to cc mode. `-Bsymbolic*` and `-Wl,-z,*` force lld. | wrapper | A `Makevars` that sets `-march=native` or `-stdlib=libc++` through the wrapper gets neither, with no warning. Plain `zig cc` honours all of them. |
| D6 | **Linux linker patches**: GNU ld scripts allowed and remapped through the sysroot (`link.zig-0{1,2,3}`), `--no-as-needed` honoured for bundled glibc libs (`dlsym(sin)` fix), libunwind forced for every glibc link, glibc version stripped from the LLVM triple string. | patches | Wrapper links use zig's **own** glibc stubs and headers regardless of a conda `sysroot_linux-64` in the env: with `sysroot_linux-64=2.28` installed, `__GLIBC_MINOR__` is still 17 and `crt1.o`/`libc.so.6` come from the zig cache. Good for us — the floor comes from the target, never from the sysroot — and it is why docs/13's defenses work. `dlsym(RTLD_DEFAULT,"sin")` resolves with and without `--no-as-needed`. |
| D7 | **macOS lld group**: `ld64.lld` support, `-fuse-ld=lld` honoured, lld never auto-selected for Mach-O. | patches | `zig-lld` wrapper exists; default macOS link is still zig's self-hosted Mach-O linker. |
| D8 | **Windows CRT patches**: `mingw-include-setjmp-s` (vendors mingw's `setjmp.S`, x86), `mingw-arm64-stubs`, `mingw-crtexe-no-atexit`, `ucrtbase-export-atexit-alias`, `gccmain-do-global-ctors-guard`; MSVC-side: dynamic CRT (`/MD`), `-IGNORE:importeddllmain`. The `Lld.zig-remove-ucrt` row is dead as of 2026-09-24 ("drop Lld.zig ucrt removal"). Not fixed: `libarm64/libkernel32.a` still lists `__C_specific_handler` (docs/10 2026-09-19). | patches | Plain `zig cc` on Windows defaults to `x86_64-windows-gnu` (UCRT api-set imports, 780 KB C hello). C++ for windows-gnu compiles zig's bundled libc++ from source on first use and prints a screenful of `_Nullable` notes that look like errors but are not (`b3.exe` runs). |
| D9 | **The compiler itself is not relocatable.** `zig_impl_linux-64` links conda's `libllvm21`, `libclang-cpp21.1`, `libxml2`, `zstd`, `libstdcxx`; `zig_impl_osx-arm64` the same plus `libcxx 21.*`; `zig_impl_win-64` needs `vc14_runtime` + `ucrt` (MSVC-built, dynamic CRT by patch). Upstream ships one static binary. | repodata | Fine inside an env; means "ship the zig toolchain with R" = ship conda LLVM 21 too (~100 MB) and, on macOS, `libcxx`. |
| D10 | **Packaging/activation**: four outputs (`zig_impl_<sub>`, `zig_<sub>` activation, `zig` symlinks, `zig-compiler` = zig + on macOS `lld 21.*` + `llvm-tools 21.*`). `zig` carries `run_exports: zig x.x.x`. Activation exports only `ZIG`, `ZIG_CC`, `ZIG_CXX`, `ZIG_AR`, `ZIG_RANLIB`, `ZIG_ASM`, `ZIG_RC`, `ZIG_LLD`, `ZIG_FORCE_LOAD_*`, `CONDA_ZIG_{BUILD,HOST}`, and `ZIG_GLOBAL_CACHE_DIR=~/.local/share/zig/zig-cache` — **no `CC`/`CXX`/`CFLAGS`/`LDFLAGS`**, unlike conda-forge's gcc/clang activation. | recipe + measured | Build systems that read `$CC` get nothing; CMake picks system `cc`. That is why every build.sh here sets `CMAKE_C_COMPILER="${ZIG_CC}"` explicitly. The global cache lands in `$HOME` by default (docs/13's "cache does not track the flang binary" applies to it). |
| D11 | **win-arm64 stays cross-only**: `zig_win-arm64` exists only in the win-64 subdir; native win-arm64 zig is "not planned" (feedstock issue #179). | recipe | Unchanged from docs/15. |

## 2. Impacts on flang-pixi

### 2.1 Linux: hermetic, but by omission — add a tripwire

Our linux-64 and linux-aarch64 binaries are exactly what the project wants:
static libc++/libc++abi/libunwind, glibc ceiling 2.17, `RUNPATH $ORIGIN/../lib`,
NEEDED = the 2.17-era glibc set only (measured on published `flang-23`,
`ld.lld`). That holds **only because no package in our Linux host envs brings
`libcxx`** — the recipes list `libcxx` under `if: osx` only. The moment a
future host dependency (an `llvm-openmp` rebuild, a `clang`-family tool, a
test dependency) pulls `libcxx` into a Linux build env, D1 flips every
executable to `NEEDED libc++.so.1` with no rpath, and nothing in our checks
would notice: `check-stdlib-floor.py` reads metadata, the glibc ceiling check
reads symbol versions. **Action:** extend the post-build check in the four
`build.sh` files to fail on `libc++.so`/`libstdc++.so` in `NEEDED` of any
installed ELF (one `readelf -d` loop next to the existing ceiling loop), and
say so in docs/13. Cross-built linux-aarch64 is immune (D1 is native-only),
which is one more reason to keep it cross.

### 2.2 macOS: we ship the shared libc++ and did not decide to

Published `flang-23` and `ld.lld` on osx-arm64 and osx-64 link
`@rpath/libc++.1.dylib` with `LC_RPATH @loader_path/../lib`, and the recipes
run-depend on `libcxx >=21` — so the packages are *consistent*, and the ABI
worry in docs/11 Q5 is moot in the direction we feared (there is no second
libc++ inside our binaries; libc++abi is static, libc++ is conda's). What
we lost is the property ADR-1 assumed: a flang that runs from a bare
directory. It cannot be recovered on macOS with this feedstock (D1 always
fires there; `zig_impl_osx-*` itself needs `libcxx`). Two consequences
worth writing down: (a) the runtime we hand to R programs,
`libflang_rt.runtime.a`, has no libc++ dependency of its own beyond what r-zig-pixi
already links (`link_libcpp` on macOS), so R's own libc++ policy decides, not
ours; (b) docs/13's table row "C++ runtime: macOS — conda-forge `libcxx`,
dynamic — the inverse of Linux" is now explained by D1 rather than by anything
we configured.

### 2.3 macOS floor bug found by this review: flang-rt-zig is built for 13.0, declared 11.0

`libflang_rt.runtime.{a,dylib}` on **both** osx subdirs carry `minos 13.0`
(every archive member too), while `flang-23`/`ld.lld` carry 11.0 and every
package declares `__osx >=11.0`. Root cause is D4: flang-rt-zig's `build.sh`
passes `-DCMAKE_{C,CXX}_COMPILER_TARGET=${CONDA_TOOLCHAIN_HOST}`
(`arm64-apple-darwin20.0.0`) on native macOS builds; the wrapper translates
that to a version-less zig triple and zig's default 13.0 wins over both the
baked 11.0 and `MACOSX_DEPLOYMENT_TARGET`. flang-zig/lld-zig do not pass an
explicit target on macOS, so the baked 11.0 applies. Practical exposure is
small (r-zig-pixi builds R for 13.0 anyway, and ld64 only warns when an
object's minos exceeds the link's), but the contract is wrong and the
tripwire docs/13 called "not wired up" is now known to be necessary.
**Actions:** in `flang-rt-zig/recipe/build.sh` pass the zig-form triple with
the floor (`aarch64-macos.${MACOSX_DEPLOYMENT_TARGET}` /
`x86_64-macos.${MACOSX_DEPLOYMENT_TARGET}`) or drop the explicit target on
macOS; add a Mach-O check (`otool -l … LC_BUILD_VERSION minos` ≤
`MACOSX_DEPLOYMENT_TARGET` for every installed Mach-O and one member of each
archive) beside the glibc ceiling check; rebuild flang-rt-zig on osx-arm64
(`_5`) and osx-64 (`_6`) and re-run `test.yml` for those two.

### 2.4 Windows: unaffected, with two things to know

Every Windows build here passes `--target=x86_64-windows-gnu` /
`aarch64-windows-gnu` explicitly, so the wrapper's MSVC default (D3) never
applies; our win-64 binaries are static-libc++, UCRT-api-set-only images
(docs/10). The setjmp patch the feedstock carries (D8) is the x86 twin of
the fix we wrongly tried on arm64, and the `__C_specific_handler` entry in
the arm64 kernel32 import library is still present in build 19 — our
`libcompat_arm64.a` remains necessary. On a machine without Visual Studio,
any consumer that calls the *wrapper* without a target fails with
`WindowsSdkNotFound` (kappa reproduces it); that is worth one sentence in
docs/11.

### 2.5 What did not change (re-verified on build 19)

Explicit `-target` beats every wrapper default (D3 R5), so
`ZIG_GLIBC_FLOOR` and the glibc ceiling tripwire from docs/13 still carry the
Linux floor; a conda sysroot in the env neither raises nor lowers it (D6).
`-stdlib=` is still stripped, so ADR-1 (build our own LLVM against zig's
libc++ instead of linking conda's libstdc++ LLVM) still stands. The feedstock
moved from build 17 to 19 between 2026-09-15 and 09-24 without touching any
of these; NOTES.md and PATCH_MANIFEST.yaml are the files to diff on the next
bump.

## 3. Impacts on R projects (r-zig-pixi and anything built the same way)

r-zig-pixi does not use the wrappers for R itself: `build.zig` resolves its
own targets (`gnu` + glibc 2.17 + baseline on Linux, `os_version_min 13.0` +
baseline on macOS, baseline elsewhere) and calls the plain `zig`. That makes
it immune to D3/D4/D5 for the R build. It is **not** immune to D1, D2 or
D9:

- **macOS: libR, libRblas, libRlapack and every package `.so` built with
  `zig c++` depend on conda's `@rpath/libc++.1.dylib`.** This is already the
  case (the osx-arm64 lockfile carries `libcxx 21.1.8` / `23.1.2`) and is
  handled implicitly: `stage.sh` adds `@loader_path` rpaths and
  `package-standalone.sh` vendors `@rpath/*` dependencies. Make it explicit:
  assert in `verify-bundle.sh` that `libc++.1.dylib` is either vendored or
  resolvable, and stop describing the macOS build as "zig's libc++ statically
  linked" anywhere (`link_libcpp = true` produces the *shared* conda libc++
  under this feedstock). Two versions of `libcxx` in one lockfile is a smell
  worth resolving.
- **Linux: static today, one dependency away from not.** No `libcxx` in the
  Linux lockfiles, so libR is self-contained. If any future dependency drags
  `libcxx` into the env, every C++ object in R and every user-built package
  silently gains `NEEDED libc++.so.1` with no rpath (D1) and R fails to start
  outside an activated env. Add the same `NEEDED` assertion to
  `verify-bundle.sh` (it already checks glibc ceilings) and to the
  contract suite's package build.
- **The R-package shims (`toolchain/zig-cc`, `zig-cxx`) pass `-target
  <arch>-linux-gnu.2.17` on Linux only.** On macOS they call plain zig, so a
  package compiled by a user inherits **D2: minos = the user's macOS
  version** (26.4 on omicron) while R itself is 13.0 — harmless locally,
  wrong for anyone redistributing package binaries. Pass `-target
  <arch>-macos.13.0` there too (zig form, so D4 cannot bite), and `-target
  x86_64-windows-gnu` on Windows so the MSVC default (D3) can never be
  reached if a conda wrapper is ever substituted for plain zig.
- **Flags users put in `Makevars` may vanish** only if the conda *wrapper* is
  the compiler; through the shims they reach plain zig intact. If r-zig-pixi
  ever switches the shims to `${ZIG_CC}` for conda-forge conformance, D5
  applies: `-march=native`, `-stdlib=`, `-fstack-protector` disappear
  without a warning. Prefer keeping plain zig behind the shims.
- **`-stdlib=libstdc++` and `-static-libstdc++` are dead flags** under
  this zig (stripped / "unused"). Package `Makevars` that expect them (a few
  CRAN packages set `-static-libstdc++` on Windows) get silently ignored,
  which is fine because libc++ is static there anyway.
- **Shipping the toolchain means shipping conda LLVM 21** (D9): the
  `r-zig-slim` run deps that carry `zig` pull `libllvm21`,
  `libclang-cpp21.1` on unix and `vc14_runtime`/`ucrt` on Windows, plus
  `libcxx` on macOS. Budget it; it is not a single-binary compiler. The
  `zig` package's `run_exports` pin `x.x.x`, so a recipe that lists `zig` in
  *host* would pin consumers to the exact zig version — keep it in `build`
  (as r-zig-pixi does) and add the run dep by hand.
- **`ZIG_GLOBAL_CACHE_DIR`** is set by activation to `~/.local/share/zig`;
  r-zig-pixi overrides it into `BUILD_DIR` (good) — user package builds
  through the shims use the activation default, which means a toolchain
  swap can reuse stale cached libc++/compiler-rt objects there; the
  `rm -rf` advice in the handoff doc applies to that directory too.
- **Windows** is the best case: plain zig defaults to `windows-gnu`, static
  libc++, UCRT api sets only; the only hazards are the wrapper's MSVC
  default and the arm64 `__C_specific_handler` entry (docs/10, handoff §3).

## 3b. Implemented 2026-09-30 (after the review)

Decision (user): make flang-zig use zig's static libc++ everywhere. Done in
the four unix `build.sh`: a `ZIG_LIB_DIR` mirror (real directory of symlinks
into `$BUILD_PREFIX/lib/zig`, no `lib/libc++` sibling) defeats D1 — measured
on gamma with `libcxx` deliberately present (static, GLIBC_2.17) and on
omicron (executable and dylib link only `libSystem`, exceptions work, minos
11.0). flang-rt-zig's macOS branch gets a shim that rewrites CMake's
`--target=arm64-apple-darwin20.0.0` into `aarch64-macos.11.0-none` for the
wrapper (D4 fix; CMake/compiler-rt still see the conda triple). Each script
ends with the two tripwires from §2.1/§2.3, validated against the old
osx-arm64 flang-rt package (rejected: minos 13.0) and a static test prefix
(accepted). `libcxx` removed from every recipe; build numbers llvm 3, lld 4,
flang 5, flang-rt 8; only the two macOS chains are rebuilt (Linux/Windows
packages were already static and need no rebuild). Results in docs/10.

## 3c. Reconciled with the consumer's measurements (2026-10-01)

r-zig-pixi acted on §3 the same day (its `feat-no-host-paths` branch,
record in its `.github/devdocs/feat-no-host-paths/PLAN.md`) and reported
back; the handoff's §6 now carries the reconciled text. What it adds to this
document:

- **D1, operational detail.** `zig build`'s local cache is not keyed on the
  probe's result: a warm cache hands back shared-libc++ link outputs after
  `ZIG_LIB_DIR` is switched on; a mirror build needs its own
  `ZIG_LOCAL_CACHE_DIR` or a cold cache. Plain `zig cc` follows
  `ZIG_LIB_DIR` on every call. The mirror's `lib/zig` must be a *real*
  directory: the probe `access()`es `<lib dir>/../../lib/<name>` and the
  kernel resolves `..` after following symlinks. Linux guard adopted there
  too (`NEEDED libc++.so*`/`libstdc++.so*` fails their contract suite).
- **D3, corrected scope.** The MSVC default and the flag drops belong to the
  `-cc`/`-cxx` *wrappers*; the real binary (`x86_64-w64-mingw32-zig.exe`,
  which `zig.bat` forwards to) defaults to the gnu ABI, and the host's
  Windows version reaches neither the PE header versions (6.0) nor
  `_WIN32_WINNT`.
- **D2/D4 for Fortran, measured here (omicron, flang-zig `_5`, flang-rt
  `_8`).** A flang-compiled object is stamped with the *host SDK's* version
  (26.0) unless `MACOSX_DEPLOYMENT_TARGET`, `-mmacos-version-min` or an
  `arm64-apple-macos<ver>` target says otherwise (each gives 13.0 when asked;
  the flag beats the env var, last flag wins). zig's Mach-O linker stamps
  the link target's floor over newer objects without a word; Apple's `ld`
  warns and does the same. So a Fortran object's floor must be set at
  compile time: `-mmacos-version-min=<floor>` in `FFLAGS`/`FCFLAGS`.
  flang's own macOS link uses Apple's `ld` and the SDK (`SDKROOT`; without
  it: `library 'System' not found`); `-fuse-ld=lld` works but still needs
  the SDK's `libSystem.tbd` — the Xcode CLT is a hard requirement for
  Fortran links on macOS, which this document's "hermetic" ambitions must
  state. Not adopted: a default `-mmacos-version-min` in `flang.cfg`, since
  the flag silently overrides a consumer's `MACOSX_DEPLOYMENT_TARGET`.
- **Runtime archive vs shared library.** `-L<resource dir> -lflang_rt.runtime`
  picks the shared library on macOS (zig and the flang driver alike; the
  driver adds an absolute rpath to the env), so packages linked that way
  load only inside the build env. r-zig-pixi now writes the archive path
  into `FLIBS`; docs/11 item 9 makes that the consumer rule. A static-only
  runtime layout is proposed (docs/10 2026-10-01), not decided.
- **Package targets on macOS.** `-target <arch>-macos.<min>` is not viable
  for R packages (loses SDK frameworks and headers); `-target
  <arch>-native.<min>` with explicit `-F`/`-L` into the SDK is under
  evaluation by r-zig-pixi. §3's bullet recommending a pinned target for
  the package shims is withdrawn until that report; flang-pixi's own CMake
  builds keep the zig-form triple because they need no frameworks.
- **rattler-build notes from the consumer** (not hit here: no staging
  outputs, no `path:` sources): the staging-output `build_cache` key does
  not hash `path:` sources; staging outputs get no `PKG_NAME`/`PKG_VERSION`.

## 3d. Follow-up from the consumer, and two new measurements (2026-10-01, later)

r-zig-pixi finished its omicron verification (macOS 26.4.1, CLT SDK 26.4;
conda-forge zig 0.16 `_15`/`_19` with the mirror, and upstream 0.16 from
PyPI; each probe rebuilt by a skeptic). Reconciled here:

- **`-target <arch>-native.13.0` is verified at the binary level** (no
  macOS 13 load test yet): the OS word must be the literal `native` plus
  `MAJOR.MINOR` (`aarch64-native.13` is rejected); result `minos 13.0`, no
  `LC_RPATH` for `-L` dirs, the installed SDK's headers and libSystem. Two
  SDK search dirs come back by hand at *link* time only:
  `-F$SDK/System/Library/Frameworks` and `-L$SDK/usr/lib` appended LAST —
  with the SDK `-L` first, `-lz`/`-liconv`/`-lcurl` silently bind the SDK's
  `.tbd` stubs against conda's headers on either zig. The conda-forge
  panic ("for loop over objects with non-equal lengths") and upstream's
  "unable to resolve dependency /usr/lib/libobjc.A.dylib" occur only when
  that SDK `-L` is missing; the `-fvisibility=hidden` + `-O3` linker crash
  reported earlier did not reproduce. `<arch>-macos.13.0` stays unusable
  (loses `usr/include`: `net/if_media.h` for ps, libDER via AppKit). D1
  still applies to the pinned form: conda-forge zig links the shared
  `@rpath/libc++.1.dylib` unless the mirror is on. Measured by me on the
  0.17 dev snapshot too: `aarch64-native.13.0` with `-F`/`-L` into the SDK
  links a CoreFoundation program at `minos 13.0`.
- **flang floor, confirmed from both sides:** objects default to the host
  version; `-mmacosx-version-min=13.0`, `-mmacos-version-min=13.0`,
  `--target=arm64-apple-macosx13.0` and `MACOSX_DEPLOYMENT_TARGET=13.0` all
  work; zig's link relabels silently. r-zig-pixi passes the flag in R's
  build and inside Makeconf's `FC` so it survives a user's `FFLAGS`. Their
  "88 archive members at 13.0" was the old flang-rt `_4`; `_8` (on universe
  since 2026-09-30) is 11.0 throughout — re-lock.
- **New: zig-built dylibs export `___dso_handle`, and that breaks the
  flang driver's link of the static runtime on macOS.** Apple-built dylibs
  do not export it; `libflang_rt.runtime.dylib` (zig-linked) does (1 of
  1932 exports). The flang driver always adds `-lflang_rt.runtime` and the
  resource dir to its link line, so a `flang -shared obj
  <dir>/libflang_rt.runtime.a` through Apple's `ld` sees both the archive
  and the dylib, binds the archive's static initializer
  (`__GLOBAL__sub_I_external_unit.cpp`) to the dylib's `___dso_handle` and
  dies with `ld: fixup error (kind=arm64_adrp_lo12) … target
  '___dso_handle'`. Same with `_4` and `_8`, with or without the version
  flag. It links fine when the dylib is not on the search path (an
  archive-only directory first on `-L`, or `-lflang_rt.runtime` resolving to
  the archive), with `-fuse-ld=lld`, and with zig's own linker. Apple's ld
  linking an Apple-compiled object against such a dylib is fine; the trap
  is exactly "archive static initializer + a `___dso_handle`-exporting
  dylib on the same line". This is the second bug the shared runtime in the
  resource dir causes (§3c: `-l` picks the dylib) — a **static-only
  runtime is now the recommendation, not a proposal** (docs/10).
- **Symbol re-export, measured:** a Fortran `.so` that links the archive
  statically re-exports the runtime: Linux 1,238 symbols (1,142 runtime:
  `_Fortran*`, `_ZN7Fortran*`, CFI_*, …), macOS 828 (808). Hiding them at
  link time: Linux — a version script works through zig + lld (`{ global:
  *; local: _Fortran*; _ZN7Fortran*; _ZNK7Fortran*; _ZT[VIS]N7Fortran*;
  };` leaves 25 exports; `--exclude-libs` is rejected by zig as an
  unsupported linker arg); macOS — zig's Mach-O linker *accepts and
  ignores* `-exported_symbols_list` (828 exports remain) and rejects
  `-unexported_symbols_list` and `-hidden-l`; Apple's ld honours
  `-hidden-lflang_rt.runtime` but only via `-l`, which hits the dylib trap.
  So on macOS the only reliable way is build-time: a runtime compiled with
  `-fvisibility=hidden -fvisibility-inlines-hidden`. flang-rt has no option
  for it (its `AddFlangRT.cmake` applies hidden visibility to CUDA offload
  objects only; `RT_API_ATTRS` carries no visibility), so it is a
  `CMAKE_CXX_FLAGS` decision in flang-rt-zig's build. **Done the same
  evening: flang-rt build 9** = static-only + hidden visibility on the four
  unix subdirs (Windows was static already), two new tripwires, consumer
  verification on linux-64 and osx-arm64 (docs/10 2026-10-01): a Fortran
  `.so` now exports its own symbols only, and the flang driver links through
  Apple's `ld` again.

## 4. Recommendations, in order

1. ~~flang-pixi: fix flang-rt-zig's macOS target (D4), add the tripwires, rebuild~~ — done, and extended to static libc++ everywhere (§3b).
2. flang-pixi docs: docs/13 gets D1/D6 (why Linux is static, why a sysroot
   does not matter), docs/11 gets the macOS libc++ statement and the
   `WindowsSdkNotFound` sentence. (docs/16 = this file; index updated.)
3. r-zig-pixi: done on its side 2026-09-30/10-01 except the macOS
   package target (under evaluation, §3c); `-mmacos-version-min=<floor>` for
   its Fortran compiles is the one new item (§3c).
4. Both: on every zig build-number bump, diff the feedstock's
   `PATCH_MANIFEST.yaml` + `NOTES.md` and re-run the three probes in §5;
   the interesting rows are the unconditional patches (D1, D7) and the
   `is_post_translate_drop` list (D5).
5. Upstream (draft only, per the no-filing rule; docs/12): the shared
   libc++ preference deserves an opt-out (an env var or honouring
   `-static-libstdc++`), and R5 should carry the baked OS version through
   conda-triple translation. Both are one-line changes in the feedstock.

## 5. How to re-measure (15 minutes)

```bash
# Linux — static vs shared libc++, floor, sysroot indifference
pixi exec -s zig=0.16.0            -- bash -c '$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-zig-cxx h.cpp -o a && readelf -d a | grep -E "NEEDED|RUNPATH"'
pixi exec -s zig=0.16.0 -s libcxx  -- bash -c '… same …'   # expect NEEDED libc++.so.1, no RUNPATH
pixi exec -s zig=0.16.0 -s sysroot_linux-64=2.28 -- bash -c 'printf "#include <features.h>\n__GLIBC_MINOR__\n" | $CONDA_PREFIX/bin/x86_64-conda-linux-gnu-zig-cc -E - | tail -1'   # 17
# macOS — always shared, and the D4 translation
pixi exec -s zig=0.16.0 -- bash -c 'W=$CONDA_PREFIX/bin/arm64-apple-darwin20.0.0-zig-cc; $W --target=arm64-apple-darwin20.0.0 h.c -o a; otool -l a | grep -A4 LC_BUILD_VERSION | grep minos'   # 13.0
# Windows — wrapper default needs an SDK; windows-gnu is self-contained
x86_64-w64-mingw32-zig-cxx.exe h.cpp -o a.exe                          # WindowsSdkNotFound without VS
x86_64-w64-mingw32-zig-cxx.exe -target x86_64-windows-gnu h.cpp -o a.exe   # KERNEL32 + api-ms-win-crt-* only
```
