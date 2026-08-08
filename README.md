# flang-pixi

Build **LLVM Flang** for Linux, macOS and Windows using the conda-forge
**`zig cc` / `zig c++`** toolchain, packaged with **Pixi** and the
**`pixi-build-rattler-build`** backend.

**Why:** [`r-zig-pixi`](../r-zig-pixi) builds R from source with `zig cc` /
`zig c++`. Zig has no Fortran frontend, so R's Fortran (LAPACK, BLAS, CRAN
packages) needs a separate compiler. conda-forge ships flang only for linux-64
and win-64 — and its win-64 build targets the **MSVC** ABI, which R cannot use.
So r-zig-pixi falls back to **gfortran on macOS, linux-aarch64 and Windows**,
including an `-O1` cap on osx-arm64 to dodge a gfortran miscompile that returns
silently wrong LAPACK results. Closing that gap is what this project is for —
see [`docs/11-r-zig-integration.md`](docs/11-r-zig-integration.md).

> **Status: scaffolding + design complete. No LLVM or flang compilation has been
> attempted yet.** Stage 0 (toolchain probe) and the mixed `zig cc` ↔ flang ABI
> probe both pass on linux-64.
> [`docs/10-status-log.md`](docs/10-status-log.md) is the authoritative record of
> what has actually been run.

## Quick start

```bash
pixi run probe        # stage 0 — verify the zig toolchain. ~10 s. Do not skip.
pixi run build-all    # stages 1-3. Hours.
pixi run smoke        # compile and run tests/*.f90 with the result
pixi run abi-probe    # do `zig cc` and our flang agree on calling conventions?
```

`abi-probe` is the gate before wiring the compiler into r-zig-pixi: it links a
`zig cc`-compiled C caller against flang-compiled Fortran and checks
`complex*16` returns, hidden `CHARACTER` lengths and by-reference arrays — the
conventions whose mismatch produces silently wrong numbers rather than a crash.

## How it works

```
                    llvm-project 22.1.8
                              │
   ┌──────────────────────────┼──────────────────────────┐
   │                          │                          │
 stage 1                   stage 2                    stage 3
 -S llvm                   -S flang                   -S runtimes
 clang;lld;mlir            out-of-tree                flang-rt
   │                          │                          │
   ▼                          ▼                          ▼
 llvm-zig  ───host───►     flang-zig  ───build───►   flang-rt-zig
                                          (as the Fortran compiler)
```

Three conda packages, built in order, handed between stages through a local
conda channel at `./channel`.

**Why we build LLVM ourselves instead of using conda-forge's `llvmdev`:**
`zig c++` statically links its own bundled libc++ and strips any `-stdlib=` flag,
so a zig-built flang cannot link against conda-forge's libstdc++-built LLVM. That
one fact drives the whole design — see
[`docs/02-architecture-decisions.md`](docs/02-architecture-decisions.md), which
includes the experiment that establishes it.

## Platform matrix

Ordered by value to r-zig-pixi, not by ease.

| target | build machine | mode | r-zig-pixi today |
|---|---|---|---|
| linux-64 | linux-64 | native | conda-forge `flang` ✅ — **parity harness, not a deliverable** |
| **osx-arm64** | osx-arm64 | native | `gfortran`, **`-O1` cap** for a miscompile ← highest value |
| **osx-64** | osx-64 | native | `gfortran` |
| **win-64** | win-64 | native | MinGW `gfortran` — needs a **MinGW-ABI** flang |
| linux-aarch64 | linux-aarch64 | native | `gfortran` |
| **win-arm64** | **win-64** | **cross only** | n/a |

Cross-*OS* building is impossible: conda-forge publishes each `zig_<target>`
package only into subdirs of the same OS family. And `zig_win-arm64` ships
**only** in the win-64 subdir, so win-arm64 cannot host its own build at all.
Details in [`docs/05-platform-matrix.md`](docs/05-platform-matrix.md).

On Windows the build deliberately targets **MinGW-w64/UCRT**
(`x86_64-w64-windows-gnu`), not the `x86_64-windows-msvc` that `zig_win-64`
defaults to, because R's gnuwin32 build and `zig cc`'s `-windows-gnu` target are
both MinGW. Zig ships `libucrt.a` and `libwinpthread.a` to make this work.

## Documentation

Start at [`docs/README.md`](docs/README.md). The documents that matter most:

- [02 — Architecture decisions](docs/02-architecture-decisions.md) — why this is
  shaped the way it is
- [03 — Zig toolchain reference](docs/03-zig-toolchain-reference.md) — how the
  conda-forge zig packages actually behave
- [09 — Risks and open questions](docs/09-risks-and-open-questions.md) — what is
  expected to break, and what is still unresolved
- [10 — Status log](docs/10-status-log.md) — what has been run
- [11 — r-zig-pixi integration](docs/11-r-zig-integration.md) — **who this is
  for, the interface they consume, and the priority order**

## Layout

```
pixi.toml              workspace root: dev tools + task graph
packages/              three pixi packages, each with recipe/ and build scripts
scripts/               stage 0 probes and the end-to-end smoke test
tests/                 Fortran programs the smoke test compiles and runs
docs/                  design, reference and status
.github/workflows/     CI matrix
```

## Relationship to conda-forge

These packages are deliberately **not** interchangeable with conda-forge's
`llvmdev` / `clangdev` / `mlir` / `flang`. The `-zig` package-name suffix and the
`zig_` build-string prefix are guard rails: co-installing them as substitutes
would produce C++ ABI mismatches. This is a parallel, self-contained toolchain.

The recipes borrow their structure from `conda-forge/flang-feedstock` and
`conda-forge/flang-rt-feedstock`, which are the closest thing to a reference
build of standalone flang.

## Licence

The build scripts and documentation in this repository: see `LICENSE.txt`.
LLVM, Flang and MLIR are Apache-2.0 WITH LLVM-exception. Zig is MIT.
