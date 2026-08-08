# 02 — Architecture decisions

This is the load-bearing document. Everything else follows from ADR-1.

---

## ADR-1 — We build LLVM/MLIR/Clang ourselves rather than using conda-forge's

**Status:** decided, backed by a reproducible experiment.

### The tempting alternative

conda-forge already ships everything a standalone flang build needs:

| package | latest | platforms |
|---|---|---|
| `llvmdev` | 22.1.8 | linux-64, linux-aarch64, linux-ppc64le, osx-64, osx-arm64, win-64, win-arm64 |
| `clangdev` | 22.1.8 | same |
| `mlir` | 22.1.8 | linux-64, linux-aarch64, linux-ppc64le, osx-64, osx-arm64, win-64 |

`conda-forge/flang-feedstock` builds flang out-of-tree against exactly these, in
about a hundred lines. Copying that recipe and swapping the compiler for zig
would be an afternoon's work — if it worked.

### Why it does not work

`zig c++` links **its own bundled libc++, statically**, and the conda-forge zig
wrapper **strips any `-stdlib=` flag** you pass it, so you cannot ask for
libstdc++ instead. The strip is explicit, at
`conda-forge/zig-feedstock:recipe/scripts/_zig-cc-common.sh`:

```bash
_final_args=()
for _fa in "${_tr_out_args[@]}"; do
    case "$_fa" in
        -march=*|-mtune=*|-ftree-vectorize) ;;
        -fstack-protector-strong|-fstack-protector|-fno-plt) ;;
        -fno-partial-inlining|-fno-ipa-cp-clone) ;;
        -fdebug-prefix-map=*) ;;
        -stdlib=*) ;;                 # <-- here
        -lgcc_eh|-lgcc_s) ;;
        ...
```

conda-forge's `llvmdev` / `clangdev` / `mlir` are built with gcc on Linux
(against libstdc++) and MSVC on Windows (against the MSVC STL). libc++ and
libstdc++ disagree on the layout of `std::string`, on `std::list` node
structure, and on name mangling (`std::__1::` vs `std::__cxx11::`). Every LLVM
public header is full of `std::string`, `llvm::StringRef`, `std::vector`, and
`std::unique_ptr` crossing the boundary. Linking a zig-built flang against a
gcc-built libLLVM is not a "probably fine, watch for warnings" situation — it is
undefined behaviour at every call.

### The experiment

`scripts/probe-zig-toolchain.sh` step 4 settles it. On linux-64 with
`zig_linux-64 0.16.0`:

```
$ ldd tcxx          # a C++17 program using std::string, std::vector, exceptions
	linux-vdso.so.1
	libm.so.6 => /lib/x86_64-linux-gnu/libm.so.6
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6
	/lib64/ld-linux-x86-64.so.2
	libresolv.so.2 …  libpthread.so.0 …  libdl.so.2 …  librt.so.1 …  libutil.so.1
```

No `libstdc++.so.6`. No `libc++.so.1`. The C++ runtime is compiled in. The
compiler's own diagnostics confirm the source: warnings quote
`.pixi/envs/.../lib/zig/libcxx/include/string`.

CMake identifies the wrapper as **Clang 21.1.8** — zig 0.16.0 bundles LLVM 21.

### Decision

Build LLVM, MLIR, Clang and LLD from the same llvm-project source tree with the
same zig toolchain, as **stage 1**, and link flang against that. The C++ ABI is
then self-consistent by construction, and the libc++ never escapes: it lives
inside our own binaries.

### Consequences

- **Cost:** an LLVM release build, i.e. hours of CPU and a large intermediate
  tree, before flang work can even start. Mitigated by making stage 1 a separate
  cached package (ADR-3) so it is paid once.
- We publish **no shared LLVM library** (ADR-2).
- Package names carry a `-zig` suffix and build strings a `zig_` prefix, so
  these can never be silently substituted for conda-forge's.
- If someone later teaches the conda-forge zig wrapper to target libstdc++, this
  ADR should be revisited — the probe script prints a loud note if it ever sees
  a libstdc++ link.

---

## ADR-2 — No `libLLVM.so`; everything static

**Status:** decided.

`LLVM_BUILD_LLVM_DYLIB=OFF`, `LLVM_LINK_LLVM_DYLIB=OFF`, and stage 2 uses
`BUILD_SHARED_LIBS=OFF`.

A `libLLVM.so` exporting libc++-mangled C++ symbols into a conda prefix is a
trap: any conda package that links it with gcc gets silent ABI corruption. Static
archives keep the libc++ ABI sealed inside binaries we control (`flang`,
`clang`, `lld`).

**Cost:** larger binaries and slower link steps, and link steps are the memory
bottleneck of an LLVM build. Hence `LLVM_PARALLEL_LINK_JOBS=1`.

---

## ADR-3 — Three packages, not one multi-output recipe

**Status:** decided.

rattler-build supports a single recipe with a shared build cache and several
outputs, which is how conda-forge would normally express this. We use three
independent packages instead:

| stage | package | builds |
|---|---|---|
| 1 | `llvm-zig` | `llvm/` with `LLVM_ENABLE_PROJECTS=clang;lld;mlir` |
| 2 | `flang-zig` | `flang/` out-of-tree, `FLANG_INCLUDE_RUNTIME=OFF` |
| 3 | `flang-rt-zig` | `runtimes/` with `LLVM_ENABLE_RUNTIMES=flang-rt` |

Reasons:

1. **Iteration.** Stage 1 is the expensive one and the one least likely to need
   changes once it works. Making flang a separate package means a flang CMake
   tweak costs minutes, not hours. With a single recipe, any edit invalidates
   the whole cache.
2. **The bootstrap is real, not cosmetic.** flang-rt is partly written in
   Fortran; building it requires a working Fortran compiler, which is stage 2's
   output. Stage 3 lists `flang-zig` as a **build** dependency. This is the same
   split conda-forge uses (`flang-feedstock` and `flang-rt-feedstock` are
   separate repositories for the same reason).
3. **Failure isolation.** When macOS fails — and it probably will — we want to
   know which stage failed without reading a six-hour log.

**Cost:** stage 1's output has to be packaged and reinstalled before stage 2 can
use it, which adds a compress/decompress round trip of a multi-GB tree. Accepted.

**Hand-off mechanism:** `pixi publish --to ./channel` writes a properly indexed
local conda channel; stages 2 and 3 list `../../channel` as their first channel.
Note that `pixi build -o DIR` is *not* sufficient — it emits a bare `.conda`
file with no `repodata.json`, which the next stage cannot resolve against.

---

## ADR-4 — Optional LLVM dependencies are all off in the first bring-up

**Status:** decided, revisit after the first green build.

`LLVM_ENABLE_ZLIB`, `ZSTD`, `LIBXML2`, `TERMINFO`, `LIBEDIT`, `LIBPFM` are all
`OFF`. conda-forge sets several of these to `FORCE_ON`.

Each one is a conda C library that has to link correctly through zig on three
operating systems, and none of them is needed to compile Fortran. Turning them
on later is a one-line change per library; debugging six of them simultaneously
during a first bring-up is not.

C libraries are ABI-safe to mix with zig-built code (the C ABI is stable across
compilers) — this is purely about reducing the number of things that can fail at
once, not about a fundamental incompatibility.

---

## ADR-5 — Pin the LLVM version to 22.1.8

**Status:** decided.

Matches the newest conda-forge `llvmdev`/`clangdev`/`mlir`/`flang` at time of
writing, which means when something breaks we can compare against a known-good
conda-forge build of the same source. The tarball SHA-256
(`ad18b70e…d7aace`) is cross-checked against both `flang-feedstock` and
`flang-rt-feedstock`, which independently pin the same archive.

Building LLVM 22 with the Clang 21 inside zig 0.16 is well within LLVM's
supported host-compiler range.
