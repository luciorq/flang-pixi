# 12 — Upstream bug reports, ready to file

Five genuine upstream bugs were found while building this toolchain. Each
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

---

## 5. conda-forge zig-feedstock: glibc stub baseline changed between builds, breaking links against libraries built with earlier builds

**Repo:** `conda-forge/zig-feedstock`
**Title:** `linux-64 build 13 → 15 changed the glibc version zig's stub libraries target — new links against archives built under 13 fail (repro: logf128)`

> Between `zig_linux-64 0.16.0 he14ddc7_13` and `hbab2c52_15` the glibc
> version the wrapper targets changed. Measured from the stub libraries
> each build generates (`nm -D` on the cached stubs): build 13's stubs
> carry symbol versions up to **GLIBC_2.31** (libm exports `logf128`),
> build 15's only up to **GLIBC_2.17** (no `logf128`). Minimal repro:
>
> ```c
> extern __float128 logf128(__float128);
> int main(void){ volatile __float128 x = 2; return (int)(double)logf128(x); }
> ```
>
> `x86_64-conda-linux-gnu-zig-cxx repro.c` links under build 13 and fails
> under build 15 with `ld.lld: error: undefined symbol: logf128`.
>
> A lower baseline is a reasonable portability choice, but the silent flip
> breaks a real workflow: static libraries compiled under build 13 whose
> configure step *detected* logf128 (LLVM's `HAS_LOGF128` does exactly
> this) carry undefined references that no longer resolve when a
> downstream package links them under build 15. Request: document the
> targeted glibc version per build, keep it stable within a zig version,
> and consider exporting it (e.g. `ZIG_GLIBC_VERSION`) so downstream
> recipes can detect mismatches. Our full mitigation (may be useful to
> other consumers): pass an explicitly glibc-versioned target
> (`--target=x86_64-linux-gnu.2.28`) so the stub surface is chosen by the
> recipe rather than the wrapper default — the wrapper honors it — plus a
> post-build check that `llvm-objdump -T` shows no `GLIBC_*` requirement
> above the declared floor.

---

## 6. zig: bundled mingw-w64 `libarm64/libkernel32.a` lists `__C_specific_handler`, which arm64 kernel32.dll does not export

**Repo:** `ziglang/zig` (`lib/libc/mingw`, the bundled mingw-w64 import
libraries); upstream mingw-w64 already restricts the entry
(`lib-common/kernel32.def.in`: `F_X64(__C_specific_handler)` /
`F_ARM32(__C_specific_handler)`).
**Title:** `aarch64-windows-gnu: linking -lkernel32 ahead of the CRT imports __C_specific_handler from KERNEL32.dll → STATUS_ENTRYPOINT_NOT_FOUND on arm64 Windows`

> Cross-compiling LLVM 23 for `aarch64-windows-gnu` with `zig cc` links
> fine, but every resulting executable fails to start on arm64 Windows 11
> with exit code `0xC0000139` (STATUS_ENTRYPOINT_NOT_FOUND). Resolving each
> import with Microsoft's arm64 import libraries and the real arm64
> `ucrtbase.dll` export table leaves exactly one unsatisfiable entry:
> `__C_specific_handler` imported from `KERNEL32.dll`. On x64 kernel32
> exports it (forwarder to ntdll); on arm64 neither kernel32 nor ntdll
> does — it comes from the UCRT (`api-ms-win-crt-private-l1-1-0.dll`) or
> vcruntime140. zig's `libarm64/libkernel32.a` still carries the x64
> entry, while upstream mingw-w64 limits it to x64/arm32. A plain
> `zig cc -target aarch64-windows-gnu t.c` resolves the symbol from the
> private api set (correct), but `zig cc t.c -lkernel32` — what CMake's
> MinGW platform module emits on every link line — resolves it from
> KERNEL32 because lld keeps the first definition it sees.
> Workaround: a one-symbol import library for
> `api-ms-win-crt-private-l1-1-0.dll` (`zig dlltool -m arm64 -d csh.def`)
> placed anywhere on the link line. Fix: drop the entry from the arm64
> kernel32 import library (sync with mingw-w64 master).

(Earlier draft blamed a missing aarch64 `setjmp` implementation; the arm64
UCRT does export `__intrinsic_setjmpex`, so that report was wrong and has
been withdrawn — docs/10 2026-09-19.)

## 7. zig (windows-gnu): `zig cc -shared` without a .def auto-exports mingw CRT symbols (`atexit`), so an exe linking the import library fails with `duplicate symbol: atexit`

*Draft received from r-zig-pixi 2026-10-07 (they build every R package DLL
with `zig cc -shared` on win-64); re-run here the same day. **Not filed**
(standing rule; the user decides). r-zig-pixi's existing search found no
Codeberg report; related but different: GitHub ziglang/zig #14892 (stage3 +
MSVC, closed) and #23642 (pass `-exclude-all-symbols` through `zig cc`).*

**Repro** (any host, target `x86_64-windows-gnu`):

```c
// lib.c
int answer(void) { return 42; }
// main.c
#include <stdlib.h>
int answer(void);
static void bye(void) {}
int main(void) { atexit(bye); return answer() == 42 ? 0 : 1; }
```
```
zig cc -target x86_64-windows-gnu -shared -o lib.dll lib.c -Wl,--out-implib,lib.lib
zig cc -target x86_64-windows-gnu -o main.exe main.c lib.lib
lld-link: error: duplicate symbol: atexit
>>> defined at .../lib/libc/mingw/crt/crtexe.c:328 (crt2.obj)
>>> defined at lib.lib(lib.dll)
```

`lib.dll` exports `_CRT_INIT __mingw_module_is_dll answer atexit`
(`llvm-readobj --coff-exports`). LLD's MinGW auto-export (no .def, no
`dllexport`) exports every global except the C runtime's, which it
recognises by the GNU object file names (`crt2.o`, `dllcrt2.o`, …). zig
materialises its CRT as `crt2.obj` / `dllcrt2.obj` (seen in the zig cache),
so `crtdll.c`'s `atexit` and the other CRT globals are exported as the DLL's
own; mingw-w64's own CRT objects are skipped.

**Re-run 2026-10-07 on gamma (cross from linux-64):**

| zig | `lib.dll` exports | `main.exe` link | with the workaround object |
|---|---|---|---|
| upstream 0.16.0 (ziglang.org tarball) | `… answer atexit` | **fails** (duplicate `atexit`) | exports `… answer`; link OK |
| upstream **0.17.0** (ziglang.org tarball) | same | **fails** | OK |
| conda-forge `zig_impl_linux-64 0.16.0` build 20 | same | **fails** | — |

So the 0.17.0 release does not fix it; conda-forge's *win-64* zig hides it
only through its `mingw-crtexe-no-atexit` / `ucrtbase-export-atexit-alias`
patches (docs/16 D8), which is why the problem was invisible to r-zig-pixi
until it cross-compiled with the Linux zig. Expected upstream behaviour: the
CRT objects zig links should be excluded from auto-export like mingw-w64's
(either by emitting the GNU object names or by an explicit
`-exclude-symbols` drectve in zig's `crtdll.c` / `crtexe.c`).

**Workaround** (r-zig-pixi `build.zig`, `addSharedLib` on Windows; keep it
through the 0.17 wave and the upstream-zig switch): an object in each DLL
holding

```c
__asm__(".section .drectve,\"yni\"\n\t.ascii \" -exclude-symbols:atexit\"\n\t.text");
```

(the same mechanism the hidden-visibility flang-rt archive now uses for its
own symbols, docs/19 §5).

**flang-pixi exposure:** none in the published set — lld-zig and flang-zig
ship executables only, flang-rt-zig ships archives. llvm-zig's MLIR runner
DLLs are built with `zig cc -shared` and carry the same stray exports, but
llvm-zig is never published and nothing links their import libraries.
