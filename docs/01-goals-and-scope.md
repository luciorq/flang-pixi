# 01 — Goals and scope

## Goal

Produce installable conda packages of **LLVM Flang** where every C and C++
translation unit is compiled by **`zig cc` / `zig c++` from conda-forge**, with
packaging driven by **Pixi** and the **`pixi-build-rattler-build`** backend.

**The consumer is [`r-zig-pixi`](../../r-zig-pixi)** — R built from source with
zig as the C/C++ toolchain. Zig has no Fortran frontend, so R's Fortran (LAPACK,
BLAS, `fft`, CRAN packages) needs a separate compiler. r-zig-pixi uses
conda-forge's flang on linux-64 and falls back to **gfortran everywhere else**,
because conda-forge ships no flang for macOS or linux-aarch64 and its
`flang_win-64` targets the MSVC ABI that R cannot use.

Closing that gap is the point of this project. See
[11 — r-zig-pixi integration](11-r-zig-integration.md) for the full picture;
it is the document that should drive prioritisation.

## Priority order

Driven by where r-zig-pixi actually hurts, not by what is easiest:

| # | platform | why |
|---|---|---|
| 0 | **linux-64** | *not a deliverable* — conda-forge's flang already works there. It is the **parity harness**: the only platform where we can diff our flang against a known-good build of the same LLVM version |
| 1 | **osx-arm64** | gfortran 15.2 **silently miscompiles complex LAPACK at -O2**; r-zig-pixi caps Fortran at `-O1` to dodge it. Correctness *and* performance |
| 2 | **osx-64** | same absence of any conda-forge flang |
| 3 | **win-64** | needs a **MinGW-ABI** flang, which exists nowhere. Only route to "one ABI everywhere" on Windows |
| 4 | **linux-aarch64** | gfortran; unverified whether it shares the arm64 miscompile |
| 5 | win-arm64 | completeness; cross-only |

## Definition of done

A build is done for a platform when all of the following hold on that platform:

1. `pixi run build-all` completes and leaves three packages in `./channel/`:
   `llvm-zig`, `flang-zig`, `flang-rt-zig`.
2. `pixi run smoke` installs them into a fresh prefix and compiles, links and
   runs every program in `tests/` with correct output.
3. `flang --version` reports the expected LLVM version.
4. On Linux, the produced binaries have a glibc floor no higher than the conda
   sysroot's (2.28) — verifiable with
   `objdump -T flang | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1`.

**But the real bar is r-zig-pixi's own suite**, which is what catches the bugs
that matter: `make check`'s `lapack.R` (silent wrong numerics) and
`scripts/contract-test.sh` (the mixed zig-C/C++ + Fortran path through R's
package build), both at the `-O2` we intend to ship. A flang that passes
`pixi run smoke` here but fails `lapack.R` there has delivered nothing.

Stage 0 (`pixi run probe`) is the gate that must pass before any of this is
attempted. It already passes on linux-64 — see
[the status log](10-status-log.md).

## Why zig at all

`zig cc` is a self-contained Clang plus a bundled libc/libc++/compiler-rt and a
set of prebuilt sysroot headers. Compared with conda-forge's stock gcc
toolchain it offers:

- **One compiler binary per build machine** rather than a per-target gcc
  cross-toolchain package set.
- **A hermetic C++ runtime.** zig statically links its own libc++, so the output
  has no libstdc++ / libc++.so runtime dependency at all (verified — see
  [02](02-architecture-decisions.md)).
- **A single flag dialect across all three OSes**, since it is Clang everywhere,
  rather than gcc on Linux / AppleClang on macOS / MSVC on Windows.

The same property that makes it attractive — the hermetic libc++ — is also the
main source of difficulty, because it makes zig-built C++ artifacts unable to
link against conda-forge's C++ artifacts. That trade is the subject of
[document 02](02-architecture-decisions.md).

## In scope

- linux-64, osx-arm64, win-64 as first-class targets.
- linux-aarch64 and osx-64 as best-effort (the recipes are written for them; no
  CI runner is guaranteed).
- Packaging LLVM/MLIR/Clang/LLD as an internal build substrate (`llvm-zig`),
  not as a general-purpose replacement for conda-forge's LLVM.
- A local file-based conda channel (`./channel`) as the hand-off between build
  stages. Publishing anywhere else is a later concern.

## Out of scope (for now)

- **Cross-OS compilation.** Not possible with these packages; see
  [05](05-platform-matrix.md). Each OS needs its own runner.
- **Submitting anything to conda-forge.** The `-zig` package names are
  deliberately distinct precisely so these can never be mistaken for, or
  co-solved with, the official `flang` / `llvmdev` packages.
- **OpenMP, OpenACC, CUDA/AMDGPU offload.** `LLVM_TARGETS_TO_BUILD` is set to
  `Native` to keep the first build tractable. Widening it is a variant change,
  not a redesign.
- **Matching conda-forge's `flang` package layout or ABI.** Ours is a parallel,
  self-contained toolchain.
- **32-bit, ppc64le, s390x, riscv64.** conda-forge ships zig for some of these;
  we are not chasing them.

## Non-goal worth stating explicitly

`llvm-zig` is **not** a drop-in `llvmdev` replacement and must never be used as
one. Installing it alongside conda-forge C++ packages that expect libstdc++ will
produce link-time or, worse, run-time failures. The `zig_` build-string prefix
and the distinct package name are the guard rails.
