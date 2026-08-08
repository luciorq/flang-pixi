# 05 — Platform matrix

## The cross-compilation ceiling

conda-forge publishes each `zig_<target>` package only into the subdirs of
machines that can *host* it. Verified against the anaconda.org file listing for
`zig 0.16.0`:

| package | published in subdirs | ⇒ can be hosted on |
|---|---|---|
| `zig_linux-64` | linux-64, linux-aarch64 | linux-64, linux-aarch64 |
| `zig_linux-aarch64` | linux-64, linux-aarch64 | linux-64, linux-aarch64 |
| `zig_osx-64` | osx-64, osx-arm64 | osx-64, osx-arm64 |
| `zig_osx-arm64` | osx-64, osx-arm64 | osx-64, osx-arm64 |
| `zig_win-64` | win-64 | win-64 |
| **`zig_win-arm64`** | **win-64 only** | **win-64 only** |
| `zig_win-32` | win-64 only | win-64 only |

Two conclusions:

1. **Cross-OS building is impossible.** Linux→macOS, Linux→Windows and
   macOS→Windows all lack a published toolchain. Each OS needs its own runner.
   (zig the language cross-compiles far more widely; the conda packaging simply
   does not expose it, and macOS additionally needs an SDK that conda-forge only
   ships on macOS runners.)
2. **win-arm64 is cross-only.** There is no `zig_win-arm64` in the win-arm64
   subdir, so a win-arm64 machine cannot build for itself even natively. It must
   be cross-built from win-64. This holds even though GitHub now offers
   `windows-11-arm` runners.

## The matrix

Ordered by value to [r-zig-pixi](11-r-zig-integration.md), not by ease.

| target | build machine | mode | r-zig-pixi today | status here |
|---|---|---|---|---|
| **linux-64** | linux-64 | native | conda-forge `flang` ✅ | stage 0 probe **passes** — this is the **parity harness**, not a deliverable |
| **osx-arm64** | osx-arm64 (`macos-14`+) | native | `gfortran`, **-O1 cap** for a miscompile | untested — **highest value** |
| **osx-64** | osx-64 (`macos-13`) | native | `gfortran` | untested |
| **win-64** | win-64 | native | MinGW `gfortran` | untested — must emit **MinGW ABI** |
| **linux-aarch64** | linux-aarch64 | native | `gfortran` | untested |
| **win-arm64** | win-64 | **cross** | n/a | untested; hardest leg |

macOS is deliberately built natively on both architectures rather than
cross-built from one. Cross osx-64↔osx-arm64 *is* available and would halve the
runner count, but native builds let the package tests actually execute the
binaries, which for a compiler is most of the value.

---

## linux-64 / linux-aarch64

The best-understood leg. `${{ stdlib('c') }}` pulls `sysroot_linux-64 2.28.*`,
which the zig wrapper auto-detects at
`$CONDA_PREFIX/x86_64-conda-linux-gnu/sysroot` and injects as `-isysroot`. That
is the entire glibc-floor mechanism — the `-target` triple carries no glibc
suffix in the native package.

Verified by the stage 0 probe on this machine: sysroot found, and the test
binary's highest glibc symbol reference was `GLIBC_2.2.5`.

**Watch for:** nothing specific yet. This is the leg to get working first.

---

## osx-arm64 / osx-64

**conda-forge does not build flang on macOS at all.** Both
`flang-feedstock` and `flang-rt-feedstock` carry `skip: true  # [osx]`, with the
comment "intentionally only windows (main target) & linux (debuggability)". So
there is no reference build to compare against, and no evidence that upstream
flang-rt has a working macOS story.

We do **not** skip macOS — proving or disproving it is a stated goal
([01](01-goals-and-scope.md)) — but expect stage 3 to be where it breaks.

Specifics:

- `MACOSX_DEPLOYMENT_TARGET` is honoured by the zig wrapper at runtime: it
  rewrites the triple, e.g. `aarch64-macos.11.0-none` → `aarch64-macos.14.0-none`.
  Setting it via `${{ stdlib('c') }}` / `c_stdlib_version` is sufficient; no
  extra flags needed.
- Stage 1 applies conda-forge's `AddLLVM.cmake` patch (`NOT APPLE AND ARG_SONAME`
  → `ARG_SONAME`) so shared-library naming matches Linux. Kept for install-layout
  consistency even though we build static.
- The runtime installs as `libflang_rt.runtime.dylib`, not `.so`; stage 3's
  `build.sh` symlinks whichever it finds.
- Apple's linker vs zig's LLD: the wrapper auto-promotes to `-fuse-ld=lld` when
  it sees Mach-O flags like `-exported_symbols_list` or `-force_load`. LLVM's
  build uses those, so the LLD MachO path will be exercised.

---

## win-64

The leg with the most at stake, because a MinGW-ABI flang **does not exist
anywhere** — not from conda-forge, not from LLVM's own releases.

### The ABI question is settled: `zig_win-64` defaults to MSVC

Read from `zig-feedstock/recipe/recipe.yaml`. `xc_w64` is defined as

```yaml
xc_w64: ${{ cross_target_platform_ == "win-64" }}
```

— unconditionally, so it is **true for the plain native `zig_win-64` package**
too, not only for cross-compiler variants. That selects:

```
zig_triplet:   "x86_64-windows-msvc"    → the wrapper's default -target
conda_triplet: "x86_64-w64-mingw32"     → only the binary-name prefix
```

The `mingw32` string is cosmetic: `install_zig_activation.py` uses it solely to
choose `.bat` over `.sh` wrappers (`is_nonunix = "mingw32" in target_triplet`).

**This closes OPEN QUESTION W1, and it closes it the wrong way for R.**

### Why MSVC is unusable here

R on Windows is MinGW-w64/UCRT — upstream (Rtools43+) and in conda-forge, whose
`r-base win-64` depends on `gcc_impl_win-64`, `libgfortran5`, `libwinpthread`
and `ucrt`. r-zig-pixi drives R's gnuwin32 build with `zig cc`'s `-windows-gnu`
target and already recorded the consequence:

> ABI decision: dropped flang on win-64 (conda-forge's targets MSVC);
> conda-forge now ships MinGW gfortran — one GNU/MinGW ABI across the whole
> Windows toolchain.

### The fix: override the target

zig has no trouble targeting MinGW; the conda package ships the CRT to prove it.
`zig-feedstock/recipe/testing/test_mingw_crt.py` asserts these exist in the
installed package:

```
libmingw32.a   libucrt.a   libmingwex.a   libwinpthread.a
```

**UCRT and winpthread** — the same world `gcc_impl_win-64` lives in.

The wrapper only injects its own `-target` when the caller supplies none (rule
R5 in `_zig-cc-common.sh`), so ours wins. `build.bat` sets two *different*
things, and conflating them is the easy mistake:

| setting | controls |
|---|---|
| `CMAKE_{C,CXX,ASM}_COMPILER_TARGET=x86_64-windows-gnu` | the ABI **flang.exe itself** is built to |
| `LLVM_DEFAULT_TARGET_TRIPLE=x86_64-w64-windows-gnu` | the ABI **flang emits code for** ← the one R cares about |

Override either with `ZIG_WIN_ABI_TARGET` / `LLVM_WIN_TRIPLE` if needed.

**Untested, and the biggest unknown in the project.** Flang on Windows is
developed and tested against MSVC; `windows-gnu` Fortran codegen is not a
well-trodden path. See risk R9 in [09](09-risks-and-open-questions.md).

Other Windows specifics:

- `ninja <1.13` is pinned, copying conda-forge's flang recipe, which hit a path
  bug where `...\tools` was interpreted as a tab escape.
- The **shared** Fortran runtime is unsupported on Windows
  ([llvm-project#134186](https://github.com/llvm/llvm-project/issues/134186)).
  Stage 3 sets `FLANG_RT_ENABLE_SHARED=OFF` there.
- `${{ stdlib('c') }}` pulls `vs2022` on Windows. With a MinGW target that is
  now clearly questionable — **OPEN QUESTION W2**, see
  [09](09-risks-and-open-questions.md).

---

## win-arm64

**Cross-built from win-64. There is no other option** — see the table at the top.

Run on a win-64 machine, after a native win-64 `build-all`:

```
pixi run build-all-winarm
```

which is three `pixi publish --target-platform win-arm64 --build-platform win-64`
invocations.

### The three things that make this the hardest leg

**1. Native tblgen.** LLVM generates much of its own source with `tblgen`, which
must run on the *build* machine. Rather than let LLVM configure a nested native
sub-build (`CROSS_TOOLCHAIN_FLAGS_NATIVE`), the recipes take a build-platform
`llvm-zig` as a build dependency and point LLVM at it:

```
-DLLVM_NATIVE_TOOL_DIR=%BUILD_PREFIX%/Library/bin
-DLLVM_TABLEGEN=.../llvm-tblgen.exe
-DMLIR_TABLEGEN_EXE=.../mlir-tblgen.exe
-DCLANG_TABLEGEN=.../clang-tblgen.exe
```

This is why win-64 must be built **before** win-arm64.

**2. The win-64 stage 1 needs the AArch64 backend.** `llvm_targets_to_build`
defaults to `Native`, which on a win-64 machine means X86 only. Stage 3 uses the
*build-platform* `flang.exe` as `CMAKE_Fortran_COMPILER` to compile the arm64
runtime — an X86-only flang simply cannot emit arm64 code.

> **Before cross-building win-arm64, rebuild the win-64 stage 1 with**
> ```yaml
> llvm_targets_to_build:
>   - "X86;AArch64"
> ```
> in `packages/llvm-zig/recipe/variants.yaml`. Skipping this produces a
> confusing failure deep inside stage 3, not a clear error at stage 1.

**3. No test execution.** A win-arm64 binary cannot run on a win-64 host, so the
package tests that execute `flang.exe` cannot run as part of the build.
Validation requires a `windows-11-arm` runner (or real hardware) that installs
the published packages and runs `pixi run smoke`. The CI workflow has a separate
job for exactly this — see [08](08-ci.md).

Target triple used throughout: `aarch64-pc-windows-msvc`.
