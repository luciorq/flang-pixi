# 11 — What r-zig-pixi needs from this project

The consumer is [`r-zig-pixi`](../../r-zig-pixi) — R built from source with
`zig cc` / `zig c++` as the C/C++ toolchain, packaged as `r-zig-slim` and
shipping its toolchain so CRAN packages compile in the installed environment.

Zig has no Fortran frontend, so R's Fortran (LAPACK, BLAS, `fft`, and any CRAN
package with `.f`/`.f90`) needs a separate compiler. r-zig-pixi's goal is one
toolchain everywhere; today it cannot have that, and **this project exists to
close exactly that gap.**

---

## The gap, precisely

From `r-zig-pixi/pixi.toml` and `.github/devdocs/feat-initial-setup/TODO.md`:

| platform | Fortran today | why | what we must deliver |
|---|---|---|---|
| **linux-64** | conda-forge `flang` + `flang-rt_linux-64` | works | *nothing* — this is the **reference** |
| **osx-arm64** | `gfortran`, **`-O1` cap** | conda-forge ships no flang for osx | **flang** ← highest value |
| **osx-64** | `gfortran` | same | flang |
| **linux-aarch64** | `gfortran` | same | flang |
| **win-64** | MinGW `gfortran` (`gcc_impl_win-64`) | conda-forge's `flang_win-64` targets **MSVC**; R's gnuwin32 and `zig cc` are **MinGW** | **MinGW-ABI flang** |

Note what this does to priorities. **linux-64 is not a deliverable** — it
already works with conda-forge's flang. It is the parity harness: the one
platform where we can diff our flang against a known-good build of the same
LLVM version. Build it first for that reason, not because it ships anything.

### osx-arm64 is the highest-value target, and it is a correctness problem

r-zig-pixi's TODO records:

> **gfortran 15.2 miscompiles complex LAPACK at -O2 on arm64-darwin**: `zgesdd`
> returns wrong U/V with `info=0` (silent wrong numbers; caught by `make check`
> lapack.R). Isolated with a pure-Fortran driver — not a zig/ABI issue.
> Workaround: FFLAGS/FCFLAGS capped at **-O1** for gfortran-on-Darwin.

So macOS today is paying twice: silently-wrong numerics avoided only by an
optimisation cap, and every Fortran routine in R built at `-O1`. A working
flang on osx-arm64 removes both. The open TODO item *"Swap gfortran → flang
when conda-forge ships flang for osx-\*"* is the line this project is meant to
close — conda-forge is not going to ship it (`skip: true # [osx]` is
deliberate: *"intentionally only windows (main target) & linux
(debuggability)"*).

linux-aarch64 has an unresolved TODO asking whether it has the same miscompile.
Worth checking before assuming it is fine.

### win-64 needs an ABI nobody ships

r-zig-pixi already made and recorded this decision:

> ABI decision: dropped flang on win-64 (conda-forge's targets MSVC);
> conda-forge now ships MinGW gfortran (`gcc_impl_win-64`) — one GNU/MinGW ABI
> across the whole Windows toolchain.

That is the right call given what exists. To put flang back, we must produce a
flang that **emits MinGW-w64/UCRT objects**. Details and the mechanism are in
[05](05-platform-matrix.md#win-64); the short version:

- `zig_win-64`'s wrappers default to `-target x86_64-windows-msvc`
  (zig-feedstock's `zig_triplet`, selected by `xc_w64`, which is true for the
  native package too). **This closes open question W1.**
- The wrapper only injects its own `-target` when the caller supplies none, so
  passing `--target=x86_64-windows-gnu` explicitly wins.
- zig ships the MinGW CRT to back this: zig-feedstock's own
  `testing/test_mingw_crt.py` asserts `libucrt.a` and `libwinpthread.a` are
  installed — **UCRT + winpthread**, the same world `gcc_impl_win-64` lives in.
- The Windows build scripts set `LLVM_DEFAULT_TARGET_TRIPLE=x86_64-w64-windows-gnu`,
  which is what makes the *produced* flang emit MinGW objects.

#### Doesn't shared UCRT already make MSVC and MinGW compatible?

Only at the C-runtime level, which is not where the problem is. Since both
worlds link the same `ucrtbase.dll` (MSVC, Rtools42+, `gcc_impl_win-64`,
zig's MinGW CRT), they share one heap and one stdio/locale/math — so calling
an MSVC-built DLL through a **pure C API** from MinGW code genuinely works.
UCRT does *not* cover:

- **C++ ABI** — mangling (Itanium vs MSVC; symbols don't even resolve),
  STL object layout, exception model, RTTI. The windows-gnu/windows-msvc
  split lives entirely above the CRT. This is also why conda-forge's
  MSVC-built LLVM DLLs are unusable from zig's libc++ world — same class of
  incompatibility as libstdc++ vs libc++ on Linux (ADR-1).
- **`long double`** — a C-level hole: MinGW x86_64 is 80-bit x87, MSVC is
  64-bit. R uses `long double` accumulators, and it maps onto Fortran
  extended-precision kinds.
- **Object-level linking, which is how flang is actually consumed** — it
  emits `.o` files and `libflang_rt.runtime.a` into R packages' MinGW link,
  not calls across a DLL boundary. MSVC objects embed `/DEFAULTLIB`
  directives for `vcruntime.lib` and reference MSVC helper symbols
  (`__security_cookie`, `__chkstk`, MSVC EH personalities) the MinGW link
  world cannot satisfy; conda-forge's flang even passes
  `-fms-runtime-lib=dll` explicitly.

So UCRT lets the two worlds *coexist in one process* across C DLL
boundaries, but does not make an MSVC-targeted compiler's output linkable
into R's MinGW build — that is what forces `x86_64-windows-gnu`.

---

## The interface r-zig-pixi consumes

Match these exactly or the integration silently falls back to gfortran.

**1. The binary must be named `flang` on `PATH`.**
`scripts/env.sh` selects the compiler by probing:

```bash
if command -v flang     >/dev/null 2>&1; then echo flang
elif command -v flang-new …                 # legacy name
elif command -v gfortran …                  # ← silent fallback
```

Our stage 2 installs `$PREFIX/bin/flang`. ✅ Package *name* differs
(`flang-zig`), binary name does not.

**2. The runtime must sit in the clang resource directory.**
`zigbuild/tools/configure-only.sh` globs for it:

```bash
for f in "$CONDA"/lib/clang/*/lib/*/libflang_rt.runtime.a; do …
FLIBS_ARGS+=("FLIBS=-L$(dirname "$rt") -lflang_rt.runtime -lm")
```

So the canonical location is
`$PREFIX/lib/clang/<major>/lib/<llvm-triple>/libflang_rt.runtime.a` — *not*
`$PREFIX/lib`. Upstream installs it there and our stage 3 leaves it there,
adding `$PREFIX/lib` symlinks as a convenience only. **Do not "tidy" the
resource-dir copy away.** ✅

**3. `FLIBS` is passed explicitly, because R's configure mis-parses flang.**
r-zig-pixi already handles this (*"autoconf mis-parses flang's verbose link
output"* — it emits a bogus `-lflang_rt.runtime:` with a trailing colon). Not
our bug to fix, but do not expect `flang -###` output to be consumable.

**4. Package names must not collide with conda-forge's.**
r-zig-pixi depends on plain `flang` + `flang-rt_linux-64` on linux-64. Ours are
`flang-zig` / `flang-rt-zig` / `llvm-zig`, so both can coexist in one solve and
linux-64 can keep using conda-forge's while osx/win use ours. Wiring it up is a
per-target dependency swap in `r-zig-pixi/pixi.toml`:

```toml
[target.osx-arm64.dependencies]
flang-zig = "*"          # was: gfortran
flang-rt-zig = "*"
```

plus adding this project's channel.

Cost of that dependency pair (linux-64, measured 2026-08-25): **1.5 GiB**
installed — flang-zig 880 MiB + lld-zig (the linker split out of llvm-zig;
llvm-zig itself is build-time only and never enters the solve) + flang-rt +
sysroot. Before the lld-zig split the closure was 3.9 GiB because flang-zig
run-depended on all of llvm-zig for one binary, `ld.lld`.

---

## A cost observation worth making once

**For osx-64, osx-arm64 and linux-aarch64, the full zig-built LLVM stack
(stage 1) may not be necessary.**

conda-forge ships `llvmdev`, `clangdev` and `mlir` at 22.1.8 for all three of
those platforms. `conda-forge/flang-feedstock` builds a standalone flang against
them in about a hundred lines; the only reason there is no macOS flang is the
deliberate `skip: true # [osx]`, not a technical obstacle. Removing that skip
and building flang the conda-forge way would be **hours instead of days**, with
far less that can go wrong.

Would such a flang work with a zig-built R? **Yes** — and r-zig-pixi already
proves it on linux-64, where conda-forge's gcc-built flang drives a zig-built R
today. The reason it works is that flang is used as an *external program that
emits `.o` files*: the only linkage between flang's world and R's is
`libflang_rt.runtime`, whose public API is `extern "C"`. The libc++/libstdc++
split that [ADR-1](02-architecture-decisions.md) is built around never crosses
that boundary.

Where the zig stack **is** genuinely required:

- **win-64 and win-arm64.** conda-forge's `llvmdev` on Windows is MSVC-built, so
  a standalone flang against it is necessarily an MSVC flang — the exact thing
  that is unusable for R. A MinGW-ABI LLVM does not exist on conda-forge, and
  zig is the practical way to get one.

This is not an argument to abandon the zig approach — it was the stated
requirement, it gives one uniform toolchain story, and it is the only route on
Windows. It *is* worth knowing that a much cheaper path exists for the three
Unix platforms if stage 1 proves painful, and that the two approaches can be
mixed per platform without any change to how r-zig-pixi consumes the result.

---

## Validation: what "works" means here

Package-level tests are not enough. The bar is r-zig-pixi's own suite, which
already catches the class of bug that matters:

1. **`make check`'s `lapack.R`** — this is what caught the gfortran `zgesdd`
   miscompile. Silent wrong numbers are the failure mode; nothing else finds
   them.
2. **`scripts/contract-test.sh`** — builds `minqa` (Rcpp dependency *and*
   package Fortran), the full mixed-toolchain path: zig C/C++ plus our flang
   through R's package build.
3. **Numerics at `-O2`.** The entire point on macOS is removing the `-O1` cap,
   so validate at the optimisation level you intend to ship.

A flang that passes `pixi run smoke` here but fails `lapack.R` there has
delivered nothing.

---

## Open question Q5 — two C++ runtimes in one R process

`libflang_rt.runtime` is C++ source. conda-forge's `libflang-rt` depends on
`libstdcxx`; ours instead has zig's libc++ statically embedded. An R process
loading our runtime alongside libstdc++-based packages has two C++ runtimes in
one address space.

Usually fine — flang-rt's public API is `extern "C"`, so no C++ types cross —
**provided the embedded libc++ symbols do not have default visibility and
interpose on libstdc++'s.** Check as soon as stage 3 builds:

```bash
nm -D --defined-only $PREFIX/lib/libflang_rt.runtime.so \
  | grep -E '_Znwm|_ZdlPv|__cxa_throw|__cxa_begin_catch'
# expect: no output. Any hit means libc++ is exported and can interpose.
```

If symbols leak, add `-fvisibility=hidden -fvisibility-inlines-hidden` to the
flang-rt build, or a version script. Note conda-forge's flang does not have
this problem, which is another point in favour of the cheap path on Unix.
