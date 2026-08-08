# 04 — The three build stages

All three stages compile from the same `llvm-project` tarball
(`llvmorg-22.1.8`), just different subdirectories of it.

```
                    llvm-project-22.1.8.tar.gz
                              │
   ┌──────────────────────────┼──────────────────────────┐
   │                          │                          │
 stage 1                   stage 2                    stage 3
 -S llvm                   -S flang                   -S runtimes
 PROJECTS=clang;lld;mlir   out-of-tree                RUNTIMES=flang-rt
   │                          │                          │
   ▼                          ▼                          ▼
 llvm-zig  ───host───►     flang-zig  ───build───►   flang-rt-zig
                                          (as CMAKE_Fortran_COMPILER)
```

The arrow from stage 2 to stage 3 is the bootstrap: flang-rt contains Fortran
source, so building it needs a Fortran compiler, which is what stage 2 produced.

---

## Stage 1 — `llvm-zig`

`packages/llvm-zig/recipe/` · `pixi run build-llvm`

Builds LLVM core plus three projects into `$PREFIX`.

**Why each project:**

- `mlir` — flang's entire lowering pipeline is MLIR-based. Mandatory.
- `clang` — flang links `clangBasic`, `clangDriver` and `clangFrontend`, and
  reuses clang's driver machinery for argument parsing and toolchain
  detection. Mandatory.
- `lld` — not required to *build* flang, but the produced flang must be able to
  link Fortran programs. Shipping lld makes the toolchain self-contained
  instead of depending on whatever `ld` the user's machine has.

**The CMake flags that matter:**

| flag | value | reason |
|---|---|---|
| `CMAKE_C_COMPILER` / `CMAKE_CXX_COMPILER` | `$ZIG_CC` / `$ZIG_CXX` | activation does not set `CC`/`CXX`; without this CMake finds system gcc |
| `CMAKE_AR` / `CMAKE_RANLIB` | `$ZIG_AR` / `$ZIG_RANLIB` | keeps archive creation inside the zig toolchain |
| `LLVM_ENABLE_RTTI` | `ON` | matches conda-forge; required by MLIR consumers |
| `LLVM_ENABLE_ASSERTIONS` | `OFF` | release build; assertions roughly double compile time and slow the compiler |
| `LLVM_BUILD_LLVM_DYLIB` / `LLVM_LINK_LLVM_DYLIB` | `OFF` | [ADR-2](02-architecture-decisions.md) — do not export libc++ ABI |
| `CMAKE_POSITION_INDEPENDENT_CODE` | `ON` | stages 2 and 3 link these archives into shared objects |
| `LLVM_ENABLE_ZLIB/ZSTD/LIBXML2/TERMINFO/LIBEDIT/LIBPFM` | `OFF` | [ADR-4](02-architecture-decisions.md) |
| `LLVM_TARGETS_TO_BUILD` | `Native` (variant) | shortest path to a working build; widen later |
| `LLVM_PARALLEL_LINK_JOBS` | `1` (variant) | link steps are the memory bottleneck |
| `LLVM_INSTALL_UTILS` | `ON` | stage 2 wants the installed tblgen/utility binaries |
| `LLVM_HOST_TRIPLE` / `LLVM_DEFAULT_TARGET_TRIPLE` | `$CONDA_TOOLCHAIN_HOST` | so flang reports the conda triple, consistent with the rest of the ecosystem |

**`LLVM_ENABLE_LIBCXX` is deliberately left unset.** It would add
`-stdlib=libc++`, which the zig wrapper strips ([03](03-zig-toolchain-reference.md),
flag filtering). zig already defaults to its bundled libc++, so the flag is at
best a no-op and at worst confuses the CMake feature probes.

**The tblgen safety net.** After `cmake --install`, the script copies
`llvm-tblgen`, `mlir-tblgen`, `clang-tblgen` (and the MLIR ODS generators) from
`build/bin` into `$PREFIX/bin` if the install did not already place them there.
Which tblgens get installed has varied across LLVM releases and interacts with
`LLVM_UTILS_INSTALL_DIR`; discovering a missing one an hour into stage 2 is
avoidable.

**`$PREFIX/share/llvm-zig/build-info.txt`** records the version, zig version,
project list, target list, host triple and C++ runtime. Stage 2 prints it. Future
sessions can read how a cached stage 1 was configured without re-deriving it.

---

## Stage 2 — `flang-zig`

`packages/flang-zig/recipe/` · `pixi run build-flang`

An out-of-tree flang build, structurally the same as
`conda-forge/flang-feedstock`: `cmake -S flang` with `LLVM_DIR`, `CLANG_DIR` and
`MLIR_DIR` pointed at the installed stage-1 CMake packages.

| flag | value | reason |
|---|---|---|
| `LLVM_DIR` / `CLANG_DIR` / `MLIR_DIR` | `$PREFIX/lib/cmake/{llvm,clang,mlir}` | find stage 1 |
| `BUILD_SHARED_LIBS` | `OFF` | stage 1 produced static archives; conda-forge uses `ON` because its llvmdev ships a dylib |
| `FLANG_INCLUDE_RUNTIME` | `OFF` | the runtime is stage 3 and cannot be built here |
| `FLANG_INCLUDE_TESTS` | `OFF` | avoids needing `lit`; also saves a lot of time |
| `FLANG_PARALLEL_COMPILE_JOBS` | `2` (variant) | see below |
| `LLVM_PARALLEL_LINK_JOBS` | `1` | see below |

**On `FLANG_PARALLEL_COMPILE_JOBS=2`.** This is the number most likely to bite
you. Several flang translation units — `flang/lib/Evaluate/fold-*.cpp` and much
of `flang/lib/Lower/` — are notorious for consuming many gigabytes of RAM each.
conda-forge builds flang with a hard `cmake --build . -j2` for precisely this
reason. Raising it is the fastest way to convert a slow build into an
OOM-killed one. If you must go faster, raise the outer `-j` (which governs
everything except the flang job pool) rather than this.

**Driver config file.** After install, the script writes
`$PREFIX/bin/<triple>-flang.cfg` (and a copy at `flang.cfg`) containing
`-L`/`-rpath` for `$PREFIX/lib` and, on Linux, `--sysroot`. Without it a bare
`flang hello.f90` in an activated environment will not find `libflang_rt` or the
sysroot's C runtime objects. conda-forge does the same thing, from its clangdev
recipe.

**Stage 2 does not produce a usable Fortran compiler yet** — it can parse,
analyse and emit LLVM IR, but not link a program. The recipe's test reflects
that: it runs `flang -S -emit-llvm hello.f90` and checks the IR, nothing more.

---

## Stage 3 — `flang-rt-zig`

`packages/flang-rt-zig/recipe/` · `pixi run build-flang-rt`

Configures `runtimes/` with `LLVM_ENABLE_RUNTIMES=flang-rt`, mirroring
`conda-forge/flang-rt-feedstock`.

| flag | value | reason |
|---|---|---|
| `CMAKE_Fortran_COMPILER` | `$BUILD_PREFIX/bin/flang` | the stage-2 compiler, from the **build** environment |
| `CMAKE_Fortran_COMPILER_WORKS` | `yes` | **not laziness** — CMake's Fortran probe tries to *link* a test program, which needs the runtime we are about to build. Without this the configure step deadlocks on itself |
| `FLANG_RT_ENABLE_SHARED` | `ON` (unix) / `OFF` (Windows) | the shared runtime is unsupported on Windows, [llvm-project#134186](https://github.com/llvm/llvm-project/issues/134186) |
| `FLANG_RT_INCLUDE_TESTS` | `OFF` | needs `lit` |

**Install layout.** flang-rt installs into the clang resource directory:

```
$PREFIX/lib/clang/22/lib/<llvm-triple>/libflang_rt.runtime.{a,so}
```

The `<llvm-triple>` there is LLVM's *normalised* triple
(`x86_64-unknown-linux-gnu`), **not** the conda triple
(`x86_64-conda-linux-gnu`). conda-forge hard-codes the path; our `build.sh`
globs for it with `find`, because the normalised triple depends on
`LLVM_DEFAULT_TARGET_TRIPLE` and is the line most likely to break when that
changes. The script then symlinks the result to `$PREFIX/lib/` so the driver
config file's `-L` finds it.

Stage 3's package test is the real one: `flang hello.f90 -o hello && ./hello`.

---

## Tuning knobs

All live in each package's `recipe/variants.yaml`.

| key | default | raise it when |
|---|---|---|
| `llvm_targets_to_build` | `Native` | you need cross-target codegen; `X86;AArch64` for a portable package |
| `llvm_parallel_link_jobs` | `1` | the machine has ≥ 32 GB and you want stage 1 faster |
| `flang_parallel_compile_jobs` | `2` | ≥ 64 GB RAM. Read the warning above first |
| `zig_compiler_version` | `0.16` | a newer zig is published and you want it |

## Rough cost expectations

Untested estimates, for planning only — replace with measurements in
[10-status-log.md](10-status-log.md) once you have them.

| stage | wall clock (16-core, 32 GB) | peak RAM | installed size |
|---|---|---|---|
| 1 | 1–3 h | driven by link jobs | multiple GB |
| 2 | 1–2 h (capped at `-j2` for flang TUs) | several GB per TU | hundreds of MB |
| 3 | 10–30 min | modest | small |
