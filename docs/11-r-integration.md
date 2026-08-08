# 11 — Replacing gfortran for the R conda package

The driving use case: build conda-forge's `r-base` (and the CRAN package
ecosystem on top of it) with `flang-zig` instead of `gfortran`.

This is a much stronger requirement than "produce a working flang". A
self-contained compiler only has to satisfy itself; a **gfortran replacement**
has to interoperate with an existing ecosystem — R's C code, OpenBLAS, LAPACK,
and every CRAN package containing Fortran.

---

## The headline constraint: R does not target MSVC

R on Windows is a **MinGW-w64 / UCRT** toolchain, not MSVC. That is true of
upstream R (Rtools43+ is UCRT64) and it is true of conda-forge's build.
`r-base 4.6.1 win-64` depends on:

```
gcc_impl_win-64 >=14    gxx_impl_win-64 >=14    gfortran_impl_win-64
libgcc >=14             libstdcxx >=14          libgfortran5 >=14.3.0
libwinpthread           ucrt >=10.0.20348.0
```

`libwinpthread` + `ucrt` + `libgfortran5` is the MinGW-w64/UCRT signature.

### This rules out conda-forge's own flang

conda-forge already ships `flang_win-64` (the gfortran-style activation
package). Its `conda_build_config.yaml` sets:

```yaml
CHOST:
  - x86_64-pc-windows-msvc      # [win]
```

and its `activate.bat` sets `FFLAGS=-fms-runtime-lib=dll`,
`FC_LD=lld-link.exe`, `AR=llvm-ar.exe`, and links
`clang_rt.builtins-x86_64.lib`. That is an **MSVC-ABI** Fortran compiler.

> **conda-forge's existing `flang_win-64` cannot be used as a gfortran
> replacement for R.** Not because it is broken, but because it targets the
> wrong ABI for R's world. This is a large part of why this project is worth
> doing rather than just consuming the existing package.

### And it rules out `zig_win-64`'s default target

Resolved from `zig-feedstock/recipe/recipe.yaml`. `xc_w64` is defined as
`cross_target_platform_ == "win-64"` — unconditionally, so it is true for the
plain native `zig_win-64` package too. That selects:

```
zig_triplet:   "x86_64-windows-msvc"   # → the wrapper's default -target
conda_triplet: "x86_64-w64-mingw32"    # → only the binary-name prefix
```

So **`zig_win-64`'s wrappers default to `-target x86_64-windows-msvc`.** This
closes open question W1, and it closes it the wrong way for us.

### The fix: override the target to `windows-gnu`

zig itself has no problem targeting MinGW — it is one of its headline features,
and the conda-forge package ships the CRT to prove it. `zig-feedstock`'s own
`recipe/testing/test_mingw_crt.py` asserts these archives exist in the installed
package:

```
libmingw32.a   libucrt.a   libmingwex.a   libwinpthread.a   (+ .lib each)
```

**`libucrt.a` and `libwinpthread.a`** — UCRT and winpthread, precisely what
conda-forge's `r-base` depends on.

The wrapper only injects its own `-target` if the caller did not supply one
(rule R5 in `_zig-cc-common.sh`). So passing `--target=x86_64-windows-gnu`
explicitly wins. Two distinct settings, and it is important not to conflate
them:

| setting | what it controls |
|---|---|
| `CMAKE_C/CXX_COMPILER_TARGET=x86_64-windows-gnu` | the ABI **flang.exe itself** is compiled to |
| `LLVM_DEFAULT_TARGET_TRIPLE=x86_64-w64-windows-gnu` | the ABI **flang emits code for** — the one R actually cares about |

Both are set in the Windows build scripts. The second is the load-bearing one:
it is what makes `flang foo.f90` produce MinGW-ABI objects that link against
R's gcc-built C code.

**Untested.** Flang on Windows is developed and tested against MSVC; the
`windows-gnu` target for Fortran codegen is not a well-trodden path. See
risk R9.

---

## What "replace gfortran" requires beyond a working compiler

### 1. A compiler activation package (added: stage 4)

conda recipes do not call `flang` directly — they write
`{{ compiler('fortran') }}`, which expands to
`<fortran_compiler>_<target_platform>`. To be a drop-in you must ship a package
matching that name that sets `FC`, `FFLAGS` and the right run-exports.

`packages/flang-zig-activation/` produces **`flang-zig_<target_platform>`**,
modelled directly on `conda-forge/flang-activation-feedstock`. Switching the R
recipe is then a one-line variant change:

```yaml
fortran_compiler:
  - flang-zig        # was: gfortran
```

The deliberately distinct name (`flang-zig_linux-64`, not `flang_linux-64`)
avoids colliding with conda-forge's MSVC-targeting package.

### 2. `FLIBS` changes

R's `configure` probes the Fortran compiler and derives `FLIBS` — the libraries
C code must link to call Fortran. With gfortran that is roughly
`-lgfortran -lm -lquadmath`. With flang it becomes `-lflang_rt.runtime`.

Anything that hard-codes `-lgfortran` breaks. R itself derives it; some CRAN
packages do not.

### 3. Two Fortran runtimes in one process

This is unavoidable during any migration and worth stating plainly.
conda-forge's `libblas`/`liblapack` (OpenBLAS) are built with gfortran and pull
in `libgfortran5`. An R built with flang pulls in `libflang_rt`. Both end up
loaded in the same process.

That is generally survivable — the two runtimes export disjoint symbols, and
OpenBLAS does no Fortran I/O, which is where per-runtime state actually lives.
But it is not a configuration anyone tests, and it doubles the runtime surface.

### 4. Fortran ABI compatibility with gfortran

For flang-built R to call gfortran-built OpenBLAS, the calling conventions must
agree. Where they do and do not:

| aspect | compatible? | note |
|---|---|---|
| name mangling | ✅ | both lowercase + single trailing underscore |
| assumed-size arrays (`.Fortran()`) | ✅ | plain pointer passing |
| hidden character-length args | ✅ likely | both pass length as trailing `size_t` |
| `COMPLEX` return values | ⚠️ | historically the most common mismatch; verify explicitly |
| `real(kind=10)` (x87 80-bit) | ⚠️ | gfortran supports it; flang's support differs |
| `real(kind=16)` / `libquadmath` | ❌ likely | gfortran ships libquadmath; flang has no equivalent |
| assumed-shape / allocatable dummies | ❌ | descriptor layouts differ — but these never cross the R/C boundary |

The last row is the reassuring one: R's `.Fortran()` interface only ever passes
assumed-size arrays and scalars, so array descriptors never cross a compiler
boundary. The risky rows are complex returns and `kind=16`.

### 5. The C++ runtime question, now sharper

[ADR-1](02-architecture-decisions.md) argued that zig's statically linked libc++
is "sealed inside our own binaries". That was true when flang was self-contained.
It is less obviously true now.

`libflang_rt.runtime` is C++ source. conda-forge's `libflang-rt` depends on
`libstdcxx`; ours will instead have libc++ statically embedded. Load that into
an R process alongside libstdc++-based packages and there are two C++ runtimes
in one address space.

This is usually fine — flang-rt's public API is `extern "C"`, so no C++ types
cross the boundary — **provided the embedded libc++ symbols do not have default
visibility and interpose on libstdc++'s** (`operator new`, `operator delete`,
and the typeinfo/EH machinery are the ones to watch).

**Open question Q5.** Resolve empirically once stage 3 builds:

```bash
nm -D --defined-only $PREFIX/lib/libflang_rt.runtime.so | grep -E '_Znwm|_ZdlPv|__cxa_throw'
# expect: nothing. Any hit means libc++ is exported and can interpose.
```

If symbols do leak, the fix is `-fvisibility=hidden -fvisibility-inlines-hidden`
on the flang-rt build, or a version script.

---

## Suggested order of work

The R goal does not change the build stages; it adds a fourth and re-prioritises
the platforms.

1. **linux-64 end to end.** Same as before. R on Linux is the cleanest target
   and the fastest feedback loop.
2. **Stage 4 activation package**, then rebuild `r-base` locally with
   `fortran_compiler: flang-zig`. This is where the real problems surface.
3. **Resolve Q5** (libc++ symbol leakage) as soon as stage 3 exists — it is a
   two-minute check that could invalidate assumptions.
4. **Verify Fortran ABI against gfortran** with a targeted test: a C caller
   calling flang-built and gfortran-built routines that return `COMPLEX*16`
   and take `CHARACTER` arguments. Cheaper than discovering it via a CRAN
   package.
5. **Windows last**, and expect it to be hard: the `windows-gnu` flang target is
   uncharted (R9).

## Explicitly not decided

- Whether to also replace `libblas`/`liblapack` with flang-built versions, which
  would remove the two-runtime problem at the cost of rebuilding much more of
  the stack.
- Whether CRAN binary packages built against gfortran-R can be used with
  flang-R at all. Assume not, until measured.
