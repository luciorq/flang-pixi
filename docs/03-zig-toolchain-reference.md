# 03 — The conda-forge zig toolchain, as it actually behaves

Everything here was read out of `conda-forge/zig-feedstock` at `main`, or
observed directly in an installed `zig_linux-64 0.16.0` environment. Where a
claim is inferred rather than observed it says so.

## Package family

`zig-feedstock` emits four kinds of package:

| package | contains |
|---|---|
| `zig_impl_<target>` | the real zig binary and standard library, named `<conda-triplet>-zig` |
| `zig_<target>` | activation script + `cc`/`c++`/`ar`/`ranlib`/… wrapper scripts; depends on the impl |
| `zig` | unprefixed `zig` symlink, for using zig as a language |
| `zig-compiler` | metapackage: zig plus a C toolchain |

**For building C/C++ you want `zig_<target_platform>`, not `zig`.** `zig` gives
you the language driver; `zig_<target>` gives you the conda-integrated compiler
wrappers and — critically — the activation script.

## What activation sets (and what it does not)

Installing `zig_linux-64` and activating the environment yields:

```
CONDA_ZIG_BUILD=x86_64-conda-linux-gnu-zig
CONDA_ZIG_HOST=x86_64-conda-linux-gnu-zig
ZIG=$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-zig
ZIG_CC=$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-zig-cc
ZIG_CXX=$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-zig-cxx
ZIG_AR=…-zig-ar     ZIG_RANLIB=…-zig-ranlib   ZIG_ASM=…-zig-asm
ZIG_RC=…-zig-rc     ZIG_LLD=…-zig-lld
ZIG_FORCE_LOAD_CC=…  ZIG_FORCE_LOAD_CXX=…
ZIG_GLOBAL_CACHE_DIR=$HOME/.local/share/zig/zig-cache
```

> ### The single most important gotcha
>
> **`CC` and `CXX` are NOT set.** Unlike conda-forge's gcc/clang activation
> packages, the zig activation only exports `ZIG_*` variables. A CMake or
> autotools build that relies on `CC` being set will silently find the *system*
> compiler and produce a package built with the wrong toolchain that still
> appears to succeed.
>
> Every build script in this repo therefore starts by asserting `ZIG_CC` is set
> and passes it explicitly as `-DCMAKE_C_COMPILER=$ZIG_CC`.

On Windows the same variables are set by `zig_activate.bat`, pointing at `.exe`
wrappers in `%CONDA_PREFIX%\Library\bin`, plus `ZIG_RC_CMAKE` (the `zig-rc` path
with forward slashes, ready to hand to CMake).

## What the wrappers do to your flags

`zig-cc` / `zig-cxx` are bash (or `.exe`) shims around
`<triplet>-zig cc|c++`. Reading `_zig-cc-common.sh`, in order:

1. **Ensure `ZIG_GLOBAL_CACHE_DIR`.** zig aborts with `AppDataDirUnavailable` if
   it cannot resolve a cache directory and neither `XDG_DATA_HOME` nor `HOME` is
   set. Build sandboxes frequently have neither, so **set it explicitly in your
   build script** — all three of ours do.

2. **Sysroot injection (Linux).** Looks for
   `$CONDA_PREFIX/<arch>-conda-linux-gnu/sysroot`, falling back to
   `$CONDA_BUILD_SYSROOT`. If found, appends:
   ```
   -isysroot <sysroot> -L<sysroot>/usr/lib64 -L<sysroot>/usr/lib
                       -L<sysroot>/lib64     -L<sysroot>/lib
   ```
   This is how a conda glibc floor is achieved. **Without `sysroot_linux-64` in
   the environment, zig links against the build machine's glibc** and the
   package is not portable. That is why every recipe here lists
   `${{ stdlib('c') }}` in `requirements/build`.

3. **Auto-promote to LLD.** zig's self-hosted linker rejects many ordinary `ld`
   flags. The wrapper scans for `--version-script`, `--gc-sections`,
   `--build-id`, `-Bsymbolic*`, Mach-O `-exported_symbols_list`, `-force_load`
   and friends, and injects `-fuse-ld=lld` when it sees one. LLVM's build uses
   several of these, so expect the LLD path to be taken.
   (Blocked on ppc64le, where LLD lacks relocation support — not a target here.)

4. **Flag filtering.** These are dropped outright:

   | dropped | why |
   |---|---|
   | `-march=*`, `-mtune=*`, `-ftree-vectorize` | gcc spellings Clang rejects |
   | `-fstack-protector`, `-fstack-protector-strong` | |
   | `-fno-plt`, `-fno-partial-inlining`, `-fno-ipa-cp-clone` | gcc-specific |
   | `-fdebug-prefix-map=*` | |
   | **`-stdlib=*`** | **you cannot select libstdc++ — see [ADR-1](02-architecture-decisions.md)** |
   | `-lgcc_eh`, `-lgcc_s` | zig has its own unwinder/runtime |
   | `-l:libpthread.a`, `-l:libpthread.so*` | GNU `-l:` syntax panics zig's linker |

   Because conda's stock `CFLAGS`/`CXXFLAGS` are largely made of these, passing
   them through is mostly a no-op. Our build scripts `unset` them and set a
   minimal `-O2 -fPIC` instead, so what reaches the compiler is what we wrote.

5. **`MACOSX_DEPLOYMENT_TARGET`** is folded into the target triple at runtime:
   `aarch64-macos.11.0-none` becomes `aarch64-macos.14.0-none` if the variable
   says 14.0.

6. **`-target` injection.** Unless you passed your own `-target`, the wrapper
   appends the one baked in at install time.

## Target triples

From `zig-feedstock/recipe/recipe.yaml`:

| conda platform | conda triplet (binary prefix) | zig `-target` |
|---|---|---|
| linux-64 | `x86_64-conda-linux-gnu` | `x86_64-linux-gnu[.<glibc>]` |
| linux-aarch64 | `aarch64-conda-linux-gnu` | `aarch64-linux-gnu[.<glibc>]` |
| osx-64 | `x86_64-apple-darwin13.4.0` | `x86_64-macos.<ver>-none` |
| osx-arm64 | `arm64-apple-darwin20.0.0` | `aarch64-macos.<ver>-none` |
| win-64 | `x86_64-w64-mingw32` | `x86_64-windows-msvc` |

Note the Windows row: the **binary-name prefix says `mingw32` but the compile
target is `-windows-msvc`.** The `mingw32` string is only used by the feedstock
to decide whether to install `.sh` or `.bat` wrappers
(`install_zig_activation.py`: `is_nonunix = "mingw32" in target_triplet`). This
was read from the recipe, **not observed on a Windows machine** — confirming it
is open question W1 in [09](09-risks-and-open-questions.md), and
`scripts/probe-zig-toolchain.ps1` exists to answer it.

Observed on linux-64: the wrapper contains `-target x86_64-linux-gnu` with **no
glibc suffix**, because `c_stdlib_version` was empty in that variant. The glibc
floor therefore comes entirely from the sysroot (step 2), not from the triple.
A probe run confirms the result is fine: the test binary's highest glibc
reference was `GLIBC_2.2.5`.

## Version facts

- conda-forge `zig` / `zig_*`: **0.16.0** current, 0.17.0 also published.
- zig 0.16.0 bundles **Clang 21.1.8** — CMake reports
  `CMAKE_CXX_COMPILER_ID=Clang`, `CMAKE_CXX_COMPILER_VERSION=21.1.8`.
- `${{ compiler('zig') }}` in a rattler-build recipe expands using the variant
  keys `zig_compiler` and `zig_compiler_version`. rattler-build has **no
  built-in default for the "zig" language**, so every recipe here ships a
  `variants.yaml` declaring them. Without it, rendering fails.

## Cross-compilation reach

`zig_<target>` packages are published only into subdirs of the *same OS family*:

| package | available in subdirs |
|---|---|
| `zig_linux-64` | linux-64, linux-aarch64 |
| `zig_linux-aarch64` | linux-64, linux-aarch64 |
| `zig_osx-64` | osx-64, osx-arm64 |
| `zig_osx-arm64` | osx-64, osx-arm64 |
| `zig_win-64` | win-64 |

So Linux↔Linux and macOS↔macOS cross-builds are available; **Linux→macOS,
Linux→Windows and anything→Windows are not.** zig the language can of course
cross-compile far more widely, but the conda packaging does not expose it, and
macOS additionally needs an SDK that conda-forge only ships for macOS runners.
See [05](05-platform-matrix.md).
