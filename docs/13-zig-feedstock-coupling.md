# 13 — zig-feedstock coupling: how updates propagate, what broke, and the defenses

Everything in this toolchain is compiled by conda-forge's `zig` packages.
That makes the zig-feedstock a *load-bearing dependency in ways ordinary
compiler packages are not*: zig bundles its own clang, its own libc++ (linked
statically into every C++ binary on Linux), its own MinGW-w64 CRT (Windows),
and — the subject of this document — its own **generated glibc stub
libraries** whose contents depend on wrapper defaults that the feedstock can
change between *build numbers* of the same zig version.

This document exists because one such change broke the toolchain in
production (2026-09-03, docs/10). Read this before touching the zig
dependency, the wrapper-related build script logic, or when a link starts
failing with an undefined libc symbol.

## The coupling surfaces, per platform

| surface | Linux | macOS | Windows |
|---|---|---|---|
| C library at link time | **zig-generated glibc stubs** — version chosen by the `-target` triple (`x86_64-linux-gnu.2.17`), NOT by the conda sysroot | host libSystem via conda's `MACOSX_DEPLOYMENT_TARGET` (wrapper folds it into the triple) | **zig's bundled MinGW-w64 CRT**, statically materialized into every binary |
| C++ runtime | zig's bundled libc++, **static** (ADR-1) | conda-forge `libcxx`, dynamic — the inverse of Linux | zig's bundled libc++, static |
| what a feedstock rebuild can silently change | default glibc stub version, wrapper flag handling | wrapper flag handling | bundled CRT contents, wrapper flag handling |

Key subtlety that cost us a day: the conda `sysroot_linux-64` package in the
build env is **headers only** as far as zig links are concerned. The wrapper
passes it as `-isysroot`, which affects `#include` resolution; the *symbols
available at link time* come from zig's own stub libraries, generated from
zig's bundled abilists at the glibc version named in the `-target` triple.
A bare `x86_64-linux-gnu` triple means "whatever default the wrapper/zig
picks" — and that default belongs to the feedstock, not to us.

## The incident (2026-09-03): logf128

- zig-feedstock `zig_linux-64 0.16.0` went from build `he14ddc7_13` to
  `hbab2c52_15` between our Aug-28 and Sep-03 builds.
- Measured directly from the stub libraries each build generates
  (`nm -D` on the cached `libm.so.6` / `libc.so.6`):
  - build 13 stubs: symbol versions up to **GLIBC_2.31** (libm exports
    `logf128`, present since glibc 2.26)
  - build 15 stubs: symbol versions up to **GLIBC_2.17** (no `logf128`)
- Our llvm-zig build-4 archives had been *configured* under build 13:
  LLVM's `check_symbol_exists(logf128, math.h, HAS_LOGF128)` succeeded, so
  `libLLVMAnalysis.a` carried undefined `logf128` references.
- Every later link of those archives — lld, flang, anything — ran under
  build 15 and died: `ld.lld: error: undefined symbol: logf128`.
- Minimal repro (kept in the status log): a two-line C file declaring
  `__float128 logf128(__float128)` links under 13, fails under 15.

Neither feedstock build matched the **declared** floor: our recipes say
`c_stdlib_version 2.28` (sysroot 2.28, and flang-zig run-depends on
`sysroot_* >=2.28`), but the binaries actually required 2.31-era symbols
(build 13) or only 2.17-era ones (build 15). The declaration and the
artifact had never been connected.

## The defenses (all implemented 2026-09-03)

Layered, in order of importance:

1. **Explicit glibc floor in the zig target** — the load-bearing fix.
   All four `build.sh` files pass
   `--target=<arch>-linux-gnu.${ZIG_GLIBC_FLOOR}` via
   `CMAKE_{C,CXX,ASM}_COMPILER_TARGET`. The wrapper honors an explicit
   `--target` and skips its own baked-in one (verified against the build-15
   compiled dispatcher). Consequence: configure-time symbol detection,
   archive contents, and final links all see **exactly the declared glibc
   surface, forever**, regardless of which feedstock build is installed.

   **The floor is `2.17` (CentOS 7 era) — a stated project goal**: these
   toolchains must run on old Linux servers. It was briefly 2.28 (matching
   the sysroot present in the build envs) before the goal was made explicit
   (2026-09-03). `c_stdlib_version` in variants.yaml and `ZIG_GLIBC_FLOOR`
   in the build scripts always move together. At 2.17, newer-glibc symbols
   (logf128@2.26, copy_file_range@2.27, ...) are simply not detected at
   configure time, so LLVM uses its portable fallbacks — the same
   combination the whole chain was proven with when feedstock build 15
   implicitly targeted 2.17.

2. **`-DLLVM_HAS_LOGF128=OFF`** (llvm-zig, both build scripts). Belt over
   the braces for the one detection that already burned us; also drops any
   fp128-folding dependency from consumers. Kept even though defense 1
   makes the detection deterministic.

3. **Build-time ceiling tripwire.** Each `build.sh` ends with
   `check_glibc_ceiling`: `llvm-objdump -T` on the shipped binaries
   (`clang`/`llvm-tblgen`, `lld`, `flang`, `libflang_rt*.so`), extract the
   maximum `GLIBC_x.y` requirement, **fail the build** if it exceeds
   `ZIG_GLIBC_FLOOR`. A future baseline flip (or a stray flag) now breaks
   loudly in our build, not in a consumer's link months later.

4. **Exact zig version pin** (`0.16.0`, variants.yaml, all four packages).
   A zig *version* bump swaps clang, libc++ and the MinGW CRT wholesale and
   must be a deliberate chain-wide rebuild. The feedstock *build number* is
   deliberately NOT pinned: build pins go stale, block fixes, and defense
   1+3 already neutralize the class of drift a build pin would guard
   against.

5. **Audit trail in every package**: `share/<pkg>/zig-toolchain.txt` (and
   llvm-zig's existing `build-info.txt`) record the exact zig conda package
   (name-version-build) and the ABI target used. When something smells like
   toolchain skew, `cat` these from the installed packages instead of
   archaeology through build logs.

## Rules of thumb going forward

- **Never mix link-time producers and consumers across zig feedstock
  builds without the explicit floor.** With defenses 1–3 in place this is
  automatic; if you ever remove them, you reintroduce the incident class.
- **A zig version bump (0.16 → 0.17) = rebuild the entire chain on all
  platforms, then re-run smokes + the r-zig validation.** Update the pin in
  all four variants.yaml files in the same change.
- **Changing the glibc floor** = change `c_stdlib_version` AND
  `ZIG_GLIBC_FLOOR`'s default in the four build.sh files together, bump all
  build numbers, rebuild the linux chain. Raising it above 2.17 would
  abandon the old-server goal — that is a product decision, not a build
  detail.
- **Windows analog to keep in mind**: flang-rt-zig ships a *snapshot* of
  zig's MinGW CRT (extracted at build time). Consumers link our CRT
  snapshot against headers from *their* zig. A zig version bump can skew
  these — that's covered by the version pin, and is the reason flang-rt-zig
  must be rebuilt in the same wave as any zig bump.
- **macOS analog**: the floor is `MACOSX_DEPLOYMENT_TARGET` (11.0 via
  `c_stdlib_version`), which the wrapper already folds into the triple.
  Stable so far; the ceiling check has no Mach-O equivalent wired up — if
  macOS ever shows load-time symbol errors after a feedstock bump, start
  there.

## Diagnostic recipes

Which glibc a zig build's stubs actually provide (uses the zig cache from
any compile):

```sh
nm -D "$ZIG_GLOBAL_CACHE_DIR"/o/*/libm.so.6 | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1
```

What a shipped binary actually requires:

```sh
llvm-objdump -T <binary> | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1
```

What zig toolchain built an installed package:

```sh
cat $PREFIX/share/<pkg>/zig-toolchain.txt   # or share/llvm-zig/build-info.txt
```

The upstream report asking the feedstock to document/stabilize the baseline
is draft 5 in [12](12-upstream-reports.md).
