# flang-pixi documentation

Build LLVM Flang for Linux, macOS and Windows using the conda-forge `zig cc` /
`zig c++` toolchain, packaged with Pixi and the `pixi-build-rattler-build`
backend.

**Nothing has been compiled yet.** The repository structure, recipes and this
documentation exist so that the first compile attempt starts from a reasoned
position rather than trial and error. [`10-status-log.md`](10-status-log.md) is
the single source of truth for what has actually been executed and what its
result was — read it first if you are picking this up in a new session.

## Read in this order

| # | Document | What it answers |
|---|----------|-----------------|
| 01 | [Goals and scope](01-goals-and-scope.md) | What we are building, what counts as done, what is out of scope |
| 02 | [Architecture decisions](02-architecture-decisions.md) | **Why we rebuild LLVM instead of using conda-forge's.** The load-bearing document |
| 03 | [Zig toolchain reference](03-zig-toolchain-reference.md) | How the conda-forge zig packages actually work: env vars, wrappers, flag filtering, sysroots |
| 04 | [Build stages](04-build-stages.md) | The three-stage bootstrap, every CMake flag and why |
| 05 | [Platform matrix](05-platform-matrix.md) | Per-OS specifics and the cross-compilation ceiling |
| 06 | [Recipe conventions](06-recipe-conventions.md) | How the pixi + rattler-build pieces fit together |
| 07 | [Local workflow](07-local-workflow.md) | Commands to run, in order, on a dev machine |
| 08 | [CI](08-ci.md) | The runner matrix and why it looks like that |
| 09 | [Risks and open questions](09-risks-and-open-questions.md) | Everything expected to go wrong, with mitigations |
| 10 | [Status log](10-status-log.md) | **Append-only record of what has been run.** Update this every session |
| 11 | [r-zig-pixi integration](11-r-zig-integration.md) | **Who this is for and what they need.** Drives prioritisation |

## The thirty-second version

```
conda-forge zig  ─┐
                  ├─►  stage 1: llvm-zig      (llvm + mlir + clang + lld, static)
                  ├─►  stage 2: flang-zig     (the flang driver, out-of-tree)
                  └─►  stage 3: flang-rt-zig  (Fortran runtime, built BY stage 2)
```

Three separate conda packages, built in order, handed between stages through a
local conda channel at `./channel`. We compile LLVM ourselves because `zig c++`
statically links its own libc++, which is ABI-incompatible with the libstdc++
that conda-forge's `llvmdev`/`clangdev`/`mlir` are built against. That single
fact drives the entire design; [document 02](02-architecture-decisions.md)
proves it.

## Getting started right now

```bash
pixi run probe          # stage 0: ~10 s, verifies the zig toolchain works
pixi run build-llvm     # stage 1: hours
```

## Who this is for

[`r-zig-pixi`](../../r-zig-pixi) — R built from source with zig cc/c++. It uses
conda-forge's flang on linux-64 and **gfortran everywhere else**, because
conda-forge ships no flang for macOS or linux-aarch64 and its `flang_win-64`
targets the MSVC ABI R cannot use. [Doc 11](11-r-zig-integration.md) explains
the gap, the interface to match, and why **osx-arm64 is the highest-value
target while linux-64 ships nothing**.
