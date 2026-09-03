# 12 — Upstream bug reports, ready to file

Four genuine upstream bugs were found while building this toolchain. Each
section below is a self-contained draft: title, repository, and body ready
to paste into an issue tracker. File them from a machine with GitHub access
(kappa is DNS-blocked for github.com). Where a workaround exists in this
repo, the draft links the mechanism so upstream can reproduce and compare.

---

## 1. pixi: `pixi publish` panics on any cross-platform publish

**Repo:** `prefix-dev/pixi`
**Title:** `pixi publish --target-platform <other> panics: pinned_source.rs "expected valid URL"`

> Publishing a pixi-build source package for a target platform different
> from the build platform panics deterministically:
>
> ```
> thread 'tokio-rt-worker' panicked at crates\pixi_record\src\pinned_source.rs:553:44:
> expected valid URL: ()
> thread 'main' panicked at crates\pixi\src\main.rs:49:10:
> Tokio executor failed, was there a panic?: Any { .. }
> ```
>
> Reproduced on Windows (win-64 host) with `pixi publish --path <pkg>
> --target-platform win-arm64 --to ./channel`, on pixi 0.76.0 and 0.77.1,
> with and without an explicit `--build-platform`, with relative and
> absolute `file://` channels, with and without a per-package lockfile.
> Native (same-platform) publishes of the identical package work.
> The panic occurs right after "Building 1 package(s):" is printed and the
> build string is computed.
>
> Workaround that works: bypass pixi and drive standalone `rattler-build
> build --recipe ... --target-platform win-arm64 --build-platform win-64`
> directly — the same recipe cross-builds fine, which localizes the bug to
> pixi's publish/source-pinning layer rather than rattler-build.
>
> Related observation: during cross builds through the pixi-build backend,
> both the `build_platform` script env var and the recipe selector context
> report the *target* platform (so `build_platform != target_platform`
> conditions never fire). Unclear if intended; it forced us to condition
> on concrete target names instead.

---

## 2. conda-forge zig-feedstock: `zig_win-arm64`'s zig binary crashes on the win-64 host

**Repo:** `conda-forge/zig-feedstock`
**Title:** `zig_win-arm64: bundled zig dies with "Illegal instruction" on the x64 host it is published for`

> `zig_win-arm64` (0.16.0) is published into the win-64 subdir, i.e. it is
> meant to run on x64 machines as a cross toolchain targeting win-arm64.
> Its wrapper `aarch64-w64-mingw32-zig-cc.exe` and the underlying
> `aarch64-w64-mingw32-zig.exe` are x86-64 PE files (verified: PE machine
> field 0x8664), but invoking the compiler on a trivial C file dies with
> `Illegal instruction` (CMake try-compile: exit 0xC000041D) on a Windows
> 11 Pro x64 machine that runs `zig_win-64`'s binaries without issue.
> Suspicion: the x64-hosted binary in this package was built with a higher
> ISA baseline than the plain win-64 package.
>
> Workaround: use `zig_win-64` with an explicit
> `--target=aarch64-windows-gnu` — zig cross-compiles natively, and we
> built the full LLVM/Flang stack for win-arm64 that way.

---

## 3. zig: aarch64-windows-gnu CRT lacks `wcstold`

**Repo:** `ziglang/zig`
**Title:** `aarch64-windows-gnu: linking fails with undefined symbol wcstold (present for x86_64-windows-gnu)`

> Cross-compiling LLVM for `aarch64-windows-gnu` with `zig cc` fails at
> every executable link with:
>
> ```
> lld-link: error: undefined symbol: wcstold
> ```
>
> (referenced from LLVM's Support library). The identical build for
> `x86_64-windows-gnu` links fine, so the symbol is present in the x64
> flavor of zig's MinGW CRT materialization but missing for aarch64.
>
> Note for anyone hitting this: on arm64-Windows `long double` has the
> same representation as `double`, so a forwarding shim is exactly
> correct, not an approximation:
>
> ```c
> #include <wchar.h>
> long double wcstold(const wchar_t *n, wchar_t **e) { return (long double)wcstod(n, e); }
> ```
>
> We compile this per-build and inject it via
> `CMAKE_EXE_LINKER_FLAGS`/`CMAKE_SHARED_LINKER_FLAGS`.

---

## 4. LLVM flang: `RTBuilder.h` getModel specialization is `_MSC_VER`-only, breaking MinGW builds

**Repo:** `llvm/llvm-project`
**Title:** `[flang] RTBuilder.h: getModel<void*(*)(void*, const void*, unsigned __int64)> guarded by _MSC_VER, undefined symbol under MinGW`

> `flang/include/flang/Optimizer/Builder/Runtime/RTBuilder.h` guards the
> memcpy-style function-pointer `getModel` specialization with
> `#ifdef _MSC_VER` (spelled `unsigned __int64`). Under a
> `*-windows-gnu` (MinGW) build, `_MSC_VER` is not defined but `size_t`
> is still `unsigned long long` (LLP64), so the specialization the
> FIRBuilder objects reference does not exist and the first executable
> link fails:
>
> ```
> lld-link: error: undefined symbol:
>   mlir::Type (*fir::runtime::getModel<void* (*)(void*, void const*, unsigned long long)>())(mlir::MLIRContext*)
> >>> referenced by libFIRBuilder.a(Allocatable.cpp.obj)
> ```
>
> Suggested fix: spell the type `unsigned long long` (identical type under
> MSVC) and widen the guard to `#if defined(_MSC_VER) || defined(_WIN64)`.
> We carry exactly that as a local patch
> (`packages/flang-zig/recipe/patch-rtbuilder.ps1`) and both win-64 and
> win-arm64 MinGW flang builds work with it.
