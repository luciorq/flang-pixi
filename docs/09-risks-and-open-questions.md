# 09 — Risks and open questions

Ordered roughly by expected pain. Each entry says what would happen, how you
would recognise it, and what to do.

---

## R1 — macOS may not work at all, and macOS is the whole point

**Likelihood: high. Impact: loses the highest-value target.**

conda-forge does not build flang on macOS. Both `flang-feedstock` and
`flang-rt-feedstock` carry `skip: true  # [osx]`, commented "intentionally only
windows (main target) & linux (debuggability)". So **no reference build exists**
and upstream flang-rt gets little macOS testing.

This is simultaneously the reason the project exists — r-zig-pixi is stuck on
gfortran with an `-O1` cap on osx-arm64 because of a real miscompile
([11](11-r-zig-integration.md)) — and the risk most likely to sink it.

*Recognise it:* stages 1 and 2 succeed; stage 3 fails to build, or produces a
runtime that cannot link a program.

*Mitigation:* build linux-64 first so you can tell "macOS problem" from "our
recipe problem" — that is the only reason linux-64 is priority 0 despite
shipping nothing. If stage 3 proves intractable on macOS, the **cheap path is
worth trying before giving up**: conda-forge ships `llvmdev`/`clangdev`/`mlir`
for osx-64 and osx-arm64, so a standalone flang built the conda-forge way
(their recipe minus the `skip:`) is hours rather than days, and would work fine
with a zig-built R because the flang↔R interface is C. See the cost observation
in [11](11-r-zig-integration.md).

---

## R2 — Out-of-memory during stage 2

**Likelihood: high on 16 GB machines. Impact: build dies late.**

Several flang translation units — `flang/lib/Evaluate/fold-*.cpp` and much of
`flang/lib/Lower/` — consume many gigabytes each. conda-forge builds flang at a
hard `-j2` on its CI, which is a strong signal.

*Recognise it:* the compiler is killed with signal 9, or ninja reports a
subprocess failure with no diagnostic. On Linux, `dmesg | grep -i oom`.

*Mitigation:* `flang_parallel_compile_jobs` in
`packages/flang-zig/recipe/variants.yaml` defaults to `2`. Lower it to `1`
before trying anything else. `llvm_parallel_link_jobs` (stage 1) is already `1`;
static linking makes link steps larger than usual, so do not raise it on a
small machine.

---

## R3 — win-arm64 cross-build

**Likelihood: high. Impact: loses one target.**

The only cross path in the project, and it stacks three hard problems: native
tblgen, a build-platform Fortran compiler that must emit arm64, and no ability
to test the result on the machine that built it. Details in
[05](05-platform-matrix.md).

*Recognise it:* stage 1 fails at configure with tblgen errors (the
`LLVM_NATIVE_TOOL_DIR` wiring is wrong), or stage 3 fails with "no available
targets are compatible with triple aarch64-pc-windows-msvc" (the win-64 stage 1
was built `Native`-only — see the AArch64 note in [05](05-platform-matrix.md)).

*Mitigation:* build and validate win-64 completely first. Treat win-arm64 as a
follow-on. The CI workflow already sequences it that way.

---

## R4 — Optional LLVM dependencies are disabled

**Likelihood: certain (by choice). Impact: reduced functionality.**

`LLVM_ENABLE_ZLIB/ZSTD/LIBXML2/TERMINFO/LIBEDIT/LIBPFM=OFF`
([ADR-4](02-architecture-decisions.md)). Consequences: no compressed debug
sections, no `zstd` in object handling, plainer diagnostics.

None of this affects compiling Fortran. Re-enable **one at a time** after the
first green build, checking each links through zig. C libraries are ABI-safe to
mix with zig-built code — this is purely about limiting simultaneous failure
modes during bring-up.

---

## R5 — Build flags CMake probes for but zig rejects

**Likelihood: medium. Impact: confusing configure-time failures.**

The zig wrapper silently drops `-march=`, `-mtune=`, `-fstack-protector*`,
`-fno-plt`, `-stdlib=`, `-lgcc_s` and more (full table in
[03](03-zig-toolchain-reference.md)). LLVM's CMake runs many `check_c_compiler_flag`
probes; a *dropped* flag makes a probe pass and the flag then have no effect,
which is worse than failing.

*Recognise it:* a feature that CMake reports as enabled behaves as if it is not.

*Mitigation:* the build scripts `unset` conda's stock `CFLAGS`/`CXXFLAGS` and
set a minimal `-O2 -fPIC`, so what reaches the compiler is what we wrote and
nothing arrives by accident. If a specific probe misbehaves, force the CMake
variable directly rather than relying on detection.

---

## R6 — Disk and time

**Likelihood: certain. Impact: schedule.**

An LLVM release build tree plus three package payloads plus a local channel is
tens of GB. Budget 60 GB. Stage 1 is hours; a full matrix in CI is most of a day.

*Mitigation:* the three-stage split means you rarely pay stage 1 twice. In CI,
cache the stage-1 *package* keyed on `hashFiles('packages/llvm-zig/recipe/**')`
— see [08](08-ci.md).

---

## R7 — flang-rt's install path is target-triple dependent

**Likelihood: medium. Impact: a one-line fix, if you know where to look.**

flang-rt installs to
`$PREFIX/lib/clang/<major>/lib/<llvm-triple>/libflang_rt.runtime.*`, where
`<llvm-triple>` is LLVM's *normalised* triple (`x86_64-unknown-linux-gnu`), not
the conda one (`x86_64-conda-linux-gnu`). conda-forge hard-codes the path; we
`find` it instead, precisely because it moves when `LLVM_DEFAULT_TARGET_TRIPLE`
changes.

*Recognise it:* stage 3's `find` fails with "could not locate
libflang_rt.runtime.a", or the driver cannot find the runtime at link time.

---

## R8 — The driver config file may be wrong or insufficient

**Likelihood: medium. Impact: `flang hello.f90` fails for users even though the
package tests pass.**

Stage 2 writes `<triple>-flang.cfg` and `flang.cfg` with `-L`, `-rpath` and (on
Linux) `--sysroot`, copying what conda-forge's clangdev does. Whether flang
looks for `flang.cfg` under exactly that name, and whether `<CFGDIR>` expands as
expected, is **assumed, not verified**.

*Recognise it:* `flang hello.f90` fails to find `crt1.o` or `libflang_rt`, while
`flang -S -emit-llvm hello.f90` works.

*Mitigation:* stage 3's second package test compiles *and links and runs*, so
this gets caught inside the build rather than by a user. If it fails, check
`flang -### hello.f90` to see the real link line.

---

## ~~OPEN QUESTION W1~~ — RESOLVED: `zig_win-64` targets MSVC by default

**Answer: `x86_64-windows-msvc`.** From `zig-feedstock/recipe/recipe.yaml`,
`xc_w64` is `cross_target_platform_ == "win-64"` — unconditional, so it is true
for the plain native package too, selecting
`zig_triplet: "x86_64-windows-msvc"`. The `x86_64-w64-mingw32` conda triplet is
only a binary-name prefix (`install_zig_activation.py` tests for `mingw32`
solely to pick `.bat` vs `.sh` wrappers).

**This is the wrong ABI for R**, which is MinGW-w64/UCRT everywhere.

*Mitigation, already implemented:* the Windows build scripts pass
`--target=x86_64-windows-gnu` explicitly (the wrapper only injects its own
`-target` when the caller supplies none) and set
`LLVM_DEFAULT_TARGET_TRIPLE=x86_64-w64-windows-gnu`. zig ships the MinGW CRT —
zig-feedstock's own `test_mingw_crt.py` asserts `libucrt.a` and
`libwinpthread.a` are present. See [05](05-platform-matrix.md#win-64) and
[11](11-r-zig-integration.md).

---

## R9 — flang has never really been targeted at `windows-gnu`

**Likelihood: high. Impact: loses the Windows leg.**

Upstream flang on Windows is developed and tested against MSVC. conda-forge's
`flang_win-64` is MSVC. LLVM's own binaries are MSVC. Asking flang to emit
MinGW-ABI Fortran objects is off the tested path, and this project is the only
thing that needs it.

*Recognise it:* stage 2 builds but `flang hello.f90` produces objects that will
not link against `zig cc -target x86_64-windows-gnu` output; or flang-rt fails
to build for the gnu target; or symbol decoration / `long double` mismatches
appear at link time.

*Mitigation:* validate the ABI in isolation **before** wiring R — compile a
trivial Fortran routine with our flang and a C caller with `zig cc
-target x86_64-windows-gnu`, link, run. r-zig-pixi did exactly this for
zig+gfortran before committing (*"validated by a mixed zig+gfortran ABI test
before wiring the build"*); do the same here. If it proves intractable, MinGW
gfortran on Windows remains a perfectly good status quo — Windows is priority 3,
not 1.

---

## OPEN QUESTION W2 — is `${{ stdlib('c') }}` right on Windows now?

Sharper than before, now that W1 is answered. `${{ stdlib('c') }}` pulls
`vs2022_win-64` on Windows. With an **MSVC** target that was defensible — it
supplies UCRT run-export metadata. With our **MinGW/UCRT** target it is at best
irrelevant and at worst pulls in the wrong CRT metadata, making the package
declare a dependency on the MSVC runtime it does not use.

The MinGW world's equivalents are `ucrt` and `libwinpthread`, which is what
conda-forge's `gcc_impl_win-64` / `r-base` depend on.

*Resolve by:* building stage 1 on Windows and inspecting the resulting
package's `depends` and the DLL imports of `flang.exe`
(`llvm-objdump -p flang.exe | findstr DLL`). If it imports `ucrtbase.dll` +
`libwinpthread-1.dll` and not `vcruntime140.dll`, drop `${{ stdlib('c') }}` on
Windows and depend on `ucrt` explicitly.

---

## Q5 — two C++ runtimes in one R process

**Likelihood: medium. Impact: subtle, hard-to-debug crashes in R.**

`libflang_rt.runtime` is C++ source. conda-forge's `libflang-rt` depends on
`libstdcxx`; ours has zig's libc++ statically embedded. An R process loading our
runtime alongside libstdc++-based packages (Rcpp, data.table, …) has two C++
runtimes in one address space.

Usually fine, since flang-rt's public API is `extern "C"` — **provided the
embedded libc++ does not export symbols that interpose on libstdc++'s**.

*Resolve by* (two minutes, as soon as stage 3 builds):

```bash
nm -D --defined-only $PREFIX/lib/libflang_rt.runtime.so \
  | grep -E '_Znwm|_ZdlPv|__cxa_throw|__cxa_begin_catch'
# expect no output
```

*Mitigation if symbols leak:* `-fvisibility=hidden
-fvisibility-inlines-hidden` on the flang-rt build, or a version script.

---

## OPEN QUESTION Q3 — does stage 1 install every tblgen stage 2 needs?

Stage 1's `build.sh` copies `llvm-tblgen`, `mlir-tblgen`, `clang-tblgen` and the
MLIR ODS generators from `build/bin` into `$PREFIX/bin` if the install did not
place them there. Whether that safety net is necessary, or sufficient, is
unverified — which tblgens get installed has varied across LLVM releases and
interacts with `LLVM_UTILS_INSTALL_DIR`.

*Resolve by:* after stage 1, `ls $PREFIX/bin/*tblgen*` and record it. If the
safety net fired, note which binaries it had to copy.

---

## OPEN QUESTION Q4 — is a static-LLVM flang link actually viable?

We build stage 1 static and stage 2 with `BUILD_SHARED_LIBS=OFF`, while
conda-forge uses `BUILD_SHARED_LIBS=ON` against a dylib-shipping llvmdev. Static
linking makes flang's link step much larger and is the most likely place to hit
a linker limit or an OOM.

*Resolve by:* getting through stage 2 once. If the link step is the blocker,
the fallback is `LLVM_BUILD_LLVM_DYLIB=ON` in stage 1 plus `BUILD_SHARED_LIBS=ON`
in stage 2 — accepting that the resulting `libLLVM.so` exports libc++-mangled
symbols and must therefore be treated as private to these packages ([ADR-2](02-architecture-decisions.md)
explains why we avoided it).
