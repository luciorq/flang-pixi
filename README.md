# flang-pixi

Build **LLVM Flang** for Linux, macOS and Windows using the conda-forge
**`zig cc` / `zig c++`** toolchain, packaged as conda packages with
standalone **rattler-build**, driven by **Pixi** tasks.

**Why:** [`r-zig-pixi`](../r-zig-pixi) builds R from source with `zig cc` /
`zig c++`. Zig has no Fortran frontend, so R's Fortran (LAPACK, BLAS, CRAN
packages) needs a separate compiler. conda-forge ships flang only for linux-64
and win-64 — and its win-64 build targets the **MSVC** ABI, which R cannot use.
Before this project r-zig-pixi fell back to **gfortran on macOS, linux-aarch64
and Windows**, including an `-O1` cap on osx-arm64 to dodge a gfortran
miscompile that returns silently wrong LAPACK results. Since 2026-10-03 it
uses this project's flang on every platform it builds — see
[`docs/11-r-zig-integration.md`](docs/11-r-zig-integration.md).

> **Status (2026-11-12): LLVM 23.1.5 published on all six subdirs**
> (linux-64, linux-aarch64, osx-64, osx-arm64, win-64, win-arm64), built
> with conda-forge zig 0.17.0. On prefix.dev
> [`universe`](https://prefix.dev/channels/universe): `lld-zig` build 0,
> `flang-zig` build 0, `flang-rt-zig` build 1 and `llvm-openmp` build 1
> (`zig_*` build strings — the channel's own libomp, built by the
> flang-rt-zig recipe). `test.yml` run 43339367038 (smoke, Fortran OpenMP,
> and the zig-cc/flang ABI probe on the unix runners) is green on GitHub's
> six native runners. The 23.1.1 builds that published consumers pin stay
> on the channel (`retain` in `scripts/build-alignment.json`). Every binary
> links zig's **static** libc++, and build-time tripwires reject shared C++
> runtimes, glibc above 2.17 and macOS floors above 11.0.
> [`docs/10-status-log.md`](docs/10-status-log.md) is the authoritative
> record.

## Using the packages

flang-rt-zig requires `llvm-openmp ==23.1.5 zig_*`, a name conda-forge also
publishes. Under strict channel priority (pixi's default) a dependency comes
from the first channel that has the name, so **list universe before
conda-forge**; with conda-forge first, flang-rt-zig is unsolvable.

```bash
pixi workspace channel add --prepend https://prefix.dev/universe
pixi add flang-zig flang-rt-zig    # lld-zig and llvm-openmp come as dependencies
```

Every conda-forge package in that environment that depends on
`llvm-openmp` then shares the channel's libomp. Pin by version and build
number (`flang-zig ==23.1.5`, build number 0; flang-rt-zig build number 1);
flang-zig pins its lld-zig by build string itself. docs/14 lists the
published files.

## Quick start

```bash
pixi run probe        # stage 0 — verify the zig toolchain. ~10 s. Do not skip.
pixi run build-all    # stages 1-3 (llvm-zig, lld-zig, flang-zig, flang-rt-zig). Hours.
pixi run smoke        # compile and run tests/*.f90 with the result
pixi run abi-probe    # do `zig cc` and our flang agree on calling conventions?
```

Tools come from `pixi.lock`: rattler-build 0.80 (standalone, through
`scripts/rb-stage.sh` / `.bat`, not `pixi publish`), with pixi 0.84.2 (the
version CI pins). On a win-64 host use the `-winarm` task variants to
cross-build win-arm64 after `build-all`.

`abi-probe` is the gate before wiring the compiler into r-zig-pixi: it links a
`zig cc`-compiled C caller against flang-compiled Fortran and checks
`complex*16` returns, hidden `CHARACTER` lengths and by-reference arrays — the
conventions whose mismatch produces silently wrong numbers rather than a crash.

## How it works

```
                         llvm-project 23.1.5
                                  │
   ┌──────────────┬───────────────┼─────────────────────┐
   │              │               │                     │
 stage 1       stage 1.5        stage 2              stage 3
 -S llvm       -S lld           -S flang             -S runtimes
 clang;mlir                     out-of-tree          flang-rt;openmp
   │              │               │                     │
   ▼              ▼               ▼                     ▼
 llvm-zig ─host─► lld-zig ─run─► flang-zig ─build─► flang-rt-zig + llvm-openmp
 (build-only)                    (the Fortran compiler)
```

Four recipes, built in order, handed between stages through a local conda
channel at `./channel`. llvm-zig is a build-time input only and is never
published; the consumer set is lld-zig, flang-zig, flang-rt-zig and
llvm-openmp.

**Why we build LLVM ourselves instead of using conda-forge's `llvmdev`:**
`zig c++` statically links its own bundled libc++ and strips any `-stdlib=` flag,
so a zig-built flang cannot link against conda-forge's libstdc++-built LLVM. That
one fact drives the whole design — see
[`docs/02-architecture-decisions.md`](docs/02-architecture-decisions.md), which
includes the experiment that establishes it.

## Platform matrix

Ordered by value to r-zig-pixi, not by ease. The last column is what
r-zig-pixi used before this project; today it uses flang-zig on every
platform it builds (linux-64 since 2026-10-03; win-arm64 from its release
11).

| target | build machine | mode | r-zig-pixi before flang-pixi |
|---|---|---|---|
| linux-64 | linux-64 | native | conda-forge `flang` — the **parity harness** while the others were brought up |
| **osx-arm64** | osx-arm64 | native | `gfortran`, **`-O1` cap** for a miscompile ← highest value |
| **osx-64** | osx-64 (omicron under Rosetta) | native | `gfortran` |
| **win-64** | win-64 | native | MinGW `gfortran` — needs a **MinGW-ABI** flang |
| linux-aarch64 | **linux-64** | **cross** | `gfortran` |
| **win-arm64** | **win-64** | **cross only** | n/a |

Cross-*OS* building is impossible: conda-forge publishes each `zig_<target>`
package only into subdirs of the same OS family. And `zig_win-arm64` ships
**only** in the win-64 subdir, so win-arm64 cannot host its own build at all.
linux-aarch64 is cross-built on gamma (linux-64) and tested natively on
GitHub's arm runner. Details in
[`docs/05-platform-matrix.md`](docs/05-platform-matrix.md).

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
- [13 — zig-feedstock coupling](docs/13-zig-feedstock-coupling.md) — the glibc
  floor and the one-build-number-per-release rule
- [14 — Publishing runbook](docs/14-publishing-runbook.md) — the published files
  and the per-host upload commands

## Layout

```
pixi.toml              workspace root: dev tools + task graph
packages/              four recipes (llvm-zig, lld-zig, flang-zig, flang-rt-zig
                       with its llvm-openmp output), each with recipe/ and build scripts
scripts/               stage 0 probes, rb-stage build driver, smoke/ABI/OpenMP tests,
                       publishing helpers (prune, alignment check, staging)
tests/                 Fortran programs the smoke test compiles and runs
docs/                  design, reference and status
.github/workflows/     build.yml (GHA build matrix, unrun) and test.yml (six native runners)
```

## Relationship to conda-forge

These packages are deliberately **not** interchangeable with conda-forge's
`llvmdev` / `clangdev` / `mlir` / `flang`. The `-zig` package-name suffix and the
`zig_` build-string prefix are guard rails: co-installing them as substitutes
would produce C++ ABI mismatches. This is a parallel, self-contained toolchain.

One exception, by decision (2026-11-11): the OpenMP runtime is published
under conda-forge's name, `llvm-openmp`, with `zig_*` build strings, so
conda-forge packages that depend on `llvm-openmp` (fftw, openblas'
`openmp_*` builds, ...) share the same libomp in one environment. It is
ABI-compatible with conda-forge's and is chosen by channel order (universe
first). Background: docs/18 §5.4.

The recipes borrow their structure from `conda-forge/flang-feedstock` and
`conda-forge/flang-rt-feedstock`, which are the closest thing to a reference
build of standalone flang.

## Licence

The build scripts and documentation in this repository: see `LICENSE.txt`.
LLVM, Flang and MLIR are Apache-2.0 WITH LLVM-exception. Zig is MIT.
