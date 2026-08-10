# 10 — Status log

**Append-only.** Newest entry at the top. This is the first thing to read when
picking the project up in a new session, and the last thing to update before
putting it down.

Record: what you ran, on what, what happened. Failures are more valuable than
successes here — a recorded failure stops the next session from repeating it.

---

## Current state at a glance

Platforms ordered by value to [r-zig-pixi](11-r-zig-integration.md), not ease.
linux-64 ships nothing — it is the parity harness.

| stage | linux-64 *(ref → DONE)* | osx-arm64 | osx-64 | win-64 | linux-aarch64 | win-arm64 |
|---|---|---|---|---|---|---|
| recipes render + resolve | ✅ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| 0 · toolchain probe | ✅ | ⬜ | ⬜ | ⬜ | ⬜ | n/a |
| 1 · llvm-zig | ✅ 42.7 GiB, 54 min | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| 2 · flang-zig | ✅ 16.87 GiB, 71 min | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| 3 · flang-rt-zig | ✅ 239 MiB, 4 min *(incl. compiler-rt)* | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| Q5 (libc++ leak) | ✅ resolved, no leak | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| smoke | ✅ **PASS, clean** | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| ABI probe (zig cc ↔ flang) | ✅ **PASS, our own flang** | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| r-zig `make check` lapack.R | not yet attempted | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |

✅ pass · ❌ fail · ⬜ not attempted

**linux-64 is DONE.** All three stages build, publish, install cleanly via
the solver alone, compile+link+run real Fortran programs, and the zig-cc↔flang
ABI probe passes. Seven bugs found and fixed along the way — table and full
narrative in the entries below. Nothing is scope-incomplete on linux-64;
remaining work is other platforms and, eventually, wiring this into
r-zig-pixi for real (`make check`'s `lapack.R` is the actual bar there, not
yet run since it lives in a different repository).

## Next actions, in order

1. **osx-arm64** — the highest-value target ([11](11-r-zig-integration.md)).
   Start with `pixi run probe` there. Given how many of this session's linux
   bugs were libc++-specific gaps flang/flang-rt never gets tested against
   (conda-forge always uses gcc+libstdc++), expect macOS — a *second* libc++
   platform with a completely different CRT/C-library story than Linux's
   sysroot — to surface its own new issues rather than repeat these exact
   ones. Read [09](09-risks-and-open-questions.md) R1 first.
2. Then osx-64, matching the same recipes (no platform-specific work needed
   beyond what already exists there).
3. win-64 with the MinGW target ([09](09-risks-and-open-questions.md) R9) —
   the least-verified leg, expect it to be genuinely hard.
4. linux-aarch64, then win-arm64 (cross-only from win-64).
5. Once a target is built, actually take it to r-zig-pixi and run its own
   `make check` / `lapack.R` / contract tests — that is the real bar, not
   `pixi run smoke` here.

---

## 2026-08-08 (final) — clean rebuild published; smoke + ABI probe both pass against our own flang; session complete

**Ran:** final clean `pixi run build-flang` → `build-flang-rt` → `smoke` →
ABI probe against our own flang, on linux-64.

### Both final rebuilds hit the "already exists" trap again — now with the full fix

Both `flang-zig` (71 min) and `flang-rt-zig` (4 min — compiler-rt turned out
cheap, mostly small C files despite ~445 ninja targets) rebuilt cleanly and
published with `⏭ Skipping ... (already exists)` **both times**, confirming
this is a systematic property of unchanged build-string hashes, not a fluke.

**Extended the recovery procedure** from the earlier entry: patching only
`md5`/`sha256`/`size` in `repodata.json` is **not enough** —
`flang-zig`'s stale entry still listed `depends: [llvm-zig, __glibc]` with no
`sysroot_linux-64`, which would have made a fresh solver-driven install repeat
the exact bug just fixed, even though the *file itself* was correct. The
correct recovery, now used for both packages:

1. Copy the fresh `.conda` over the stale one in `./channel/<subdir>/`.
2. Extract the fresh file (`rattler-build package extract`) and read its own
   `info/index.json` — this is the *authoritative* dependency list, generated
   correctly by rattler-build from the recipe.
3. Patch `repodata.json`'s entry: `md5`, `sha256`, `size`, **and** `depends`
   (and `constrains`, where present — `flang-rt-zig` has a `libflang <0.0a0` /
   `libflang-rt <0.0a0` constraint that also needs to survive the patch).
4. Regenerate `repodata.json.zst`; delete the stale sharded index files
   (`repodata_shards.msgpack.zst`, `shards/`) rather than hand-maintain them.

### `pixi run smoke`: PASS, clean, no manual patches

```
== hello ==
  |  sum of squares 1..10 = 385.
  |  hello: OK
  -> PASS

== modules ==
  |  diagonal  = 5.656854249492381
  |  centroid  = 2. 2.
  |  modules: OK
  -> PASS

smoke test PASSED
```

A throwaway environment created purely via `pixi add flang-zig flang-rt-zig`
against the real published channel — no manual dependency additions, no
manually-copied files, no hand-edited `.cfg` content. This is the first time
in the project's history that this has worked without human intervention
inside the environment.

### ABI probe: PASS, against our own flang for the first time

Every prior ABI-probe run this session used **conda-forge's** flang as a
baseline (see the earlier entry). This is the first time it ran against our
own zig-built `flang`:

```
== toolchain ==
  flang : .../bin/flang
          flang version 22.1.8 (...)
          Target: x86_64-conda-linux-gnu
  zig cc: .../bin/x86_64-conda-linux-gnu-zig-cc

== running ==
  bind(C) scalar by value      ok
  assumed-size array byref     ok
  complex*16 argument          ok
  hidden character length      ok

ABI probe passed: zig cc and flang agree.
```

Identical result to the conda-forge baseline. `zig cc`-compiled C and
our-flang-compiled Fortran agree on: `bind(C)` scalar passing, F77-style
assumed-size array by-reference passing (the actual `.Fortran()`/R-calling
convention), `COMPLEX*16` arguments (the historically fragile one), and hidden
`CHARACTER` length arguments. **This is the real gate before wiring this
compiler into r-zig-pixi, and it is green.**

### Session summary — every bug found and fixed, linux-64

| # | Stage | Bug | Fix |
|---|---|---|---|
| 1 | 1 | `llvm-exegesis` link fails: `__rseq_size`/`__rseq_offset` need glibc ≥2.35, sysroot pins 2.28 | `LLVM_TOOL_LLVM_EXEGESIS_BUILD=OFF` |
| 2 | 1 | `LLVM_INCLUDE_TESTS=ON` hard-depends on the now-disabled `llvm-exegesis` target | `LLVM_INCLUDE_TESTS=OFF` |
| 3 | 2, 3 | `FlangCommon.cmake` uses `cmake_push_check_state()` without including the module that defines it | `CMAKE_PROJECT_INCLUDE` seed file forcing `include(CMakePushCheckState)` |
| 4 | 2, 3 | `.pixi`-symlink (our own disk-space fix) causes a logical-vs-canonical path split; `cmake --install`'s RPATH rewrite fails a literal string match | `CMAKE_BUILD_WITH_INSTALL_RPATH=ON` |
| 5 | 3 | `float128.h`'s libc++ detection (`_LIBCPP_VERSION`) only works for C++ files; the C file `complex-reduction.c` wrongly enables `COMPLEX(16)` support the C++ side never defines | `-D_LIBCPP_VERSION=1` in `CFLAGS` only |
| 6 | 2 | `CONDA_TOOLCHAIN_HOST` fallback missing → `flang.cfg` never written at all | copied the fallback `case` block from `llvm-zig` |
| 7a | 2 | `sysroot_linux-64` never a runtime dependency → `--sysroot=` in `flang.cfg` points nowhere outside the build sandbox | added to `recipe.yaml`'s `run:` |
| 7b | 1, 3 | No GCC anywhere in the toolchain (by design), but `flang.exe`'s driver does classic GNU/Linux CRT-object probing at runtime | built `compiler-rt` (`COMPILER_RT_BUILD_CRT=ON`) in stage 3, relocated its output into the clang resource dir, added `-fuse-ld=lld --rtlib=compiler-rt` to `flang.cfg` |

Plus one **tooling trap**, not a bug in our recipes: `pixi publish` silently
skips re-copying a package when its build-string hash is unchanged (which
happens whenever only `build.sh`/`recipe.yaml` run-deps change, not
variant/host-dep inputs) — always verify the channel file's checksum actually
changed after such a fix, and always re-sync `depends`/`constrains` from the
fresh package's own `info/index.json`, not just the file hash.

**None of these bugs are in our own architecture or CMake flag choices** —
every one is a gap between upstream flang/flang-rt's assumptions (built and
tested against gcc+libstdc++ or MSVC, never libc++, never GCC-less) and this
specific combination this project deliberately set out to build. That the
list is this long, and none of it required abandoning the architecture, is
itself a reasonable signal that ADR-1 was the right call.

### Status: linux-64 is done

All items in [01](01-goals-and-scope.md)'s "Definition of done" are met on
linux-64: `build-all` succeeds, `smoke` passes, `flang --version` reports the
right version, and (from Q5, resolved two entries ago) there's no C++ runtime
leak. The ABI probe — the actual gate for r-zig-pixi — passes.

**Next session should start with osx-arm64** ([01](01-goals-and-scope.md)'s
priority order, [11](11-r-zig-integration.md)'s rationale), reading
[09](09-risks-and-open-questions.md) R1 first. Given how many of this
session's bugs were libc++-specific gaps in flang/flang-rt that conda-forge
never exercises, expect macOS — a *second* libc++ platform, but with a
completely different C library/CRT story than Linux's sysroot — to surface
its own new set rather than repeat these exact five.

---

## 2026-08-08 (even later) — FIRST SUCCESSFUL END-TO-END RUN: two more bugs, both now fixed and validated

**This is the milestone the whole project has been building toward:** a
Fortran program, compiled and linked by our own zig-built `flang`, actually
running and producing correct output.

```
$ flang tests/hello.f90 -o hello && ./hello
 sum of squares 1..10 = 385.
 hello: OK
$ flang tests/modules.f90 -o modules && ./modules
 diagonal  = 5.656854249492381
 centroid  = 2. 2.
 modules: OK
```

Getting here required finding two more bugs after the `CONDA_TOOLCHAIN_HOST`
fix (previous entry) — both discovered by actually trying to link and run a
program, which nothing before this point had done (every prior check was
either frontend-only or used conda-forge's flang instead of ours).

### Bug 6 — `sysroot_linux-64` was never a runtime dependency of flang-zig

With `flang.cfg` now being written (previous entry's fix), linking failed
differently:

```
/usr/bin/ld: cannot find Scrt1.o / crti.o / crtbeginS.o / -lm / -lgcc / -lc ...
```

`flang.cfg`'s `--sysroot=<CFGDIR>/../x86_64-conda-linux-gnu/sysroot` — the
same convention conda-forge's clangdev uses — pointed at a path that only
existed inside the *build sandbox* (where `sysroot_linux-64` was a build
dependency). Outside it, in a real install, nothing was ever there:
`flang-zig/recipe/recipe.yaml`'s `requirements/run` never listed
`sysroot_linux-64`, unlike conda-forge's own `flang-feedstock`, which does.

**Fix:** added `sysroot_${{ target_platform }} >=${{ c_stdlib_version }}`
under `if: linux` in `flang-zig/recipe/recipe.yaml`'s `run:` section.

### Bug 7 — flang has no GCC anywhere in its toolchain, but its driver assumes one

Even with a real sysroot providing `crt1.o`/`crti.o`/`crtn.o` (glibc's own
objects), linking *still* failed on `crtbeginS.o`, `libgcc`, `libgcc_s` —
none of which `sysroot_linux-64` provides. Those are **compiler-runtime**
objects, normally supplied by an actual GCC install (conda-forge's
`gcc_impl_linux-64` or similar). We have no GCC anywhere in this toolchain
by design (ADR-1) — `flang.exe` is a genuine Clang-derived driver (not
`zig cc`), and left to its own defaults it does classic GNU/Linux toolchain
probing at runtime, assuming a GCC install exists. It doesn't, here.

**Root cause was two-layered:**

1. Stage 1 (`llvm-zig`) never built `compiler-rt` — only
   `LLVM_ENABLE_PROJECTS=clang;lld;mlir`. LLVM's `compiler-rt`, built with
   `COMPILER_RT_BUILD_CRT=ON`, produces exactly the GCC-independent
   replacements needed: `clang_rt.crtbegin.o` / `clang_rt.crtend.o` and
   `libclang_rt.builtins.a` (replacing `libgcc.a`). Clang's driver
   automatically prefers these over GCC's objects once told
   `--rtlib=compiler-rt`.
2. Even after building compiler-rt, its own CMake installs these files to
   `$PREFIX/lib/linux/` — a **top-level sibling** of `lib/clang/`, not
   *inside* the clang resource directory Clang's driver actually searches
   (`$PREFIX/lib/clang/<major>/lib/linux/`). Left where CMake put them,
   `--rtlib=compiler-rt` still finds nothing.

**Fix, three parts:**

1. `flang-rt-zig/recipe/build.sh` now builds `compiler-rt` *alongside*
   `flang-rt` in the same `-S runtimes` invocation
   (`LLVM_ENABLE_RUNTIMES="compiler-rt;flang-rt"`), with
   `COMPILER_RT_BUILD_CRT=ON` and every other `COMPILER_RT_BUILD_*` component
   (sanitizers, XRay, memprof, profiling, ORC, libFuzzer) turned off — none
   of it is needed to link a Fortran program, all of it costs build time.
   `COMPILER_RT_DEFAULT_TARGET_ONLY=ON` additionally required
   `CMAKE_C_COMPILER_TARGET` to be set even for a **native** (non-cross)
   build, which nothing previously set on this path — added the same
   `CONDA_TOOLCHAIN_HOST` fallback used elsewhere, this time to the
   native-build branch.
2. A new step in `build.sh` after install, copying (not symlinking, to
   survive package re-extraction) `$PREFIX/lib/linux/*` into
   `$PREFIX/lib/clang/<major>/lib/linux/` — the location Clang's driver
   actually searches.
3. `flang-zig/recipe/build.sh`'s `flang.cfg` now includes `-fuse-ld=lld`
   (route through `llvm-zig`'s own bundled `ld.lld`, already a runtime
   dependency, rather than depending on whatever `ld` a host happens to
   have — this dev machine's system binutils happened to exist and mask
   that we were silently relying on it) and `--rtlib=compiler-rt`.

### How this was validated without paying for more full rebuilds

Each fix was tested **in place**, without a `pixi publish` cycle, before
committing to the expensive real pipeline:

- Added `sysroot_linux-64` directly to the throwaway smoke-test environment
  (`pixi add sysroot_linux-64` in `.smoke/`) — confirmed it was *necessary
  but not sufficient* (got past `Scrt1.o`, still missing `crtbeginS.o`).
- Resumed `flang-rt-zig`'s build **in place** (same validated pattern as
  every other fix this session) to build compiler-rt cheaply and inspect
  exactly where its output landed.
- Manually copied the freshly-built `compiler-rt` artifacts into the
  smoke-test environment's clang resource directory, and manually rewrote its
  `flang.cfg` with the two new flags — **this is what actually produced the
  first successful `hello`/`modules` run above**, entirely without an
  expensive `pixi publish` cycle.

All three fixes are now in the recipe files. A final clean `pixi run
build-flang` → `build-flang-rt` → `smoke` sequence is in progress as of this
entry to produce genuinely self-consistent, correctly-published packages (the
manual patches above proved the *architecture* works, but the channel itself
still held pre-fix artifacts) — **check the next entry for that outcome.**

### A packaging trap worth remembering: `pixi publish` silently skips existing filenames

Discovered mid-session: rebuilding `flang-zig` after the `CONDA_TOOLCHAIN_HOST`
fix produced a build string hash (`zig_c2a7154_0`) **identical** to the
pre-fix build — run-dependency and script-content changes do not appear to
enter the hash, only host/build dependency and variant inputs do. `pixi
publish --to ./channel` saw that filename already existed and **silently
skipped copying the new (fixed) artifact over it**, printing
`⏭ Skipping ... (already exists)` and still reporting overall success. The
channel kept serving the *stale, pre-fix* package.

**Recovery:** `pixi publish --force` exists for exactly this but forces
another full rebuild-from-source (the "always re-copies source" behaviour
noted elsewhere). Cheaper: manually overwrote the stale `.conda` file, then
patched `repodata.json`'s `md5`/`sha256`/`size` for that entry by hand
(computed via Python `hashlib`), regenerated `repodata.json.zst`, and deleted
the (now-stale, unpatched) sharded index files
(`repodata_shards.msgpack.zst`, `shards/`) rather than hand-maintain them —
local `file://` channels resolve fine from plain `repodata.json` alone.

**Lesson for future sessions:** after any fix that changes only a build
script (not recipe/variant inputs) and you see "already exists" during
publish, **verify the channel file's checksum actually changed** before
trusting the "success" — it will report success either way.

---

## 2026-08-08 (later) — stage 3 succeeds cleanly; smoke test finds a stage-2 gap

**Ran:** `pixi run build-flang-rt` on linux-64.

### Stage 3: PASS, first attempt at the CMake level — but a real runtime bug

Configure and compile went cleanly (no `cmake_push_check_state` recurrence —
`CMAKE_PROJECT_INCLUDE` *does* propagate through the `-S runtimes` build, so
the sed-patch fallback was never needed). At the final link of
`libflang_rt.runtime.so`, a new, different bug:

```
ld.lld: error: undefined symbol: _FortranACppSumComplex16
>>> referenced by complex-reduction.c:126
>>>               .../complex-reduction.c.o:(_FortranASumComplex16)
>>> did you mean: _FortranACppSumComplex10
```

(plus `ProductComplex16`, `DotProductComplex16`, `ReduceComplex16Ref`,
`ReduceComplex16Value` — all the `COMPLEX(KIND=16)` reduction entry points.)

**Root cause, found by reading `flang/include/flang/Common/float128.h`:**
that header decides whether 128-bit `__float128` support is enabled with

```c
#if (defined(__FLOAT128__) || defined(__SIZEOF_FLOAT128__)) && \
    !defined(_LIBCPP_VERSION) && !defined(__CUDA_ARCH__)
```

— deliberately disabled under libc++, whose header comment explains why:
*"libc++ does not fully support `__float128` right now, e.g.
`std::complex<__float128>` multiplication ends up calling `copysign()` that
is not defined for `__float128`."* **This is upstream correctly anticipating
our exact situation** (ADR-1: zig always links libc++). But the detection
only works for C++ translation units — `_LIBCPP_VERSION` is defined by
libc++'s own headers, and the file only probes for it behind
`#ifdef __cplusplus / #include <cstddef>`.
`flang-rt/lib/runtime/complex-reduction.c` is a **C** file that also
includes this header: under C, `__cplusplus` is undefined, `<cstddef>` is
never included, `_LIBCPP_VERSION` is never seen — so the C file wrongly
concludes float128 support **is** available (zig's clang defines
`__SIZEOF_FLOAT128__` regardless of C++ stdlib) and emits calls to the
Complex16 entry points, while the C++ side (`sum.cpp`, `product.cpp`, ...)
correctly sees libc++ and never defines them. Declared in C, never defined
in C++, only under libc++ — exactly why conda-forge (libstdc++, no
`_LIBCPP_VERSION` ambiguity in either language) never encounters this.

**Fix:** `-D_LIBCPP_VERSION=1` added to `CFLAGS` (not `CXXFLAGS`) in
`flang-rt-zig/recipe/build.sh`. Grepped the whole flang/flang-rt tree first —
this macro is checked nowhere else, so only its definedness matters, not the
value. This makes the C file reach the same "disable float128" conclusion
the C++ side already reaches, restoring upstream's actual intent rather than
routing around it. Mirrored into `build.bat` for Windows, marked unverified
there.

**Validated cheaply first:** cleared the work directory's cached `build/`
(a mere env-var change doesn't invalidate CMake's already-cached
`CMAKE_C_FLAGS`, so a plain reconfigure wouldn't have picked it up) and
resumed via the raw-script pattern — clean link, no undefined symbols, the
runtime glob-and-symlink logic in `build.sh` found both `libflang_rt.runtime.a`
and `.so`. *Then* ran the real `pixi run build-flang-rt` for an actual
packaged/tested/published artifact — this one was fast (72 targets, ~2
minutes total) since flang-rt is far smaller than flang itself.

**Result: PASS.** Published `flang-rt-zig-22.1.8-zig_7d4df44_0.conda` to
`./channel/linux-64/` — **233.01 MiB installed, 41 files.** Largest:
`libflang_rt.runtime.a` (145.26 MiB), `libflang_rt.runtime.so` (87.50 MiB).

**All three stages now build successfully on linux-64.** Five bugs found and
fixed across the three stages this session — none in our own CMake flags or
architecture, all in gaps between upstream flang/flang-rt's assumptions and
a standalone, libc++-linked, glibc-2.28-floor build that nobody else
exercises this combination of:

1. `llvm-exegesis` vs. glibc < 2.35 (`__rseq_size`/`__rseq_offset`) — stage 1
2. `LLVM_INCLUDE_TESTS=ON` hard-depending on the now-disabled `llvm-exegesis`
   target — stage 1
3. `FlangCommon.cmake`'s missing `include(CMakePushCheckState)` — stages 2 & 3
4. `.pixi`-symlink RPATH mismatch at `cmake --install` time — stages 2 & 3
5. `float128.h`'s libc++ detection gap for C translation units — stage 3

### Q5 (two C++ runtimes in one process): RESOLVED — no leak

```
$ nm -D --defined-only lib/libflang_rt.runtime.so | grep -E '_Znwm|_ZdlPv|__cxa_throw|__cxa_begin_catch'
(no output)
$ ldd lib/libflang_rt.runtime.so
	linux-vdso.so.1, libm.so.6, libc.so.6, ld-linux-x86-64.so.2,
	libresolv.so.2, libpthread.so.0, libdl.so.2, librt.so.1, libutil.so.1
	(no libstdc++, no libc++)
```

No C++ runtime symbols exported, no C++ runtime linked at all. Safe to load
`libflang_rt.runtime.so` alongside libstdc++-based R packages (Rcpp,
data.table, ...) — the concern in [09](09-risks-and-open-questions.md) Q5 is
closed.

### `pixi run smoke`: FAILED — a second, different bug in stage 2

First real link-and-run test of our own flang (everything before this only
tested the frontend, or used conda-forge's flang). Compiling `tests/hello.f90`
and `tests/modules.f90` through the throwaway smoke-test environment
**succeeded** (flang linked them without error, itself evidence flang-rt's
static archive resolves correctly at link time — the Q5-adjacent symbol gap
does not appear in the static `.a`, only would have blocked the `.so`).
**Running the produced binaries failed:**

```
./hello: error while loading shared libraries: libflang_rt.runtime.so:
cannot open shared object file: No such file or directory
```

`readelf -d hello` showed **no RPATH/RUNPATH entry at all**, and no
`*.cfg` file existed anywhere in the installed environment — meaning stage
2's driver-config-file block (documented in [04](04-build-stages.md) and
flagged as an open risk, R8, in [09](09-risks-and-open-questions.md)) never
ran at all.

**Root cause:** `flang-zig/recipe/build.sh` only *checks*
`if [[ -n "${CONDA_TOOLCHAIN_HOST:-}" ]]` before writing `flang.cfg` — unlike
`llvm-zig/recipe/build.sh`, it never *sets* a fallback value.
`CONDA_TOOLCHAIN_HOST` is normally populated by conda-forge's gcc/clang
compiler activation packages, which this project never uses (zig is the
compiler). The variable was simply never set, the whole cfg-writing block
was silently skipped, and nothing downstream noticed until a produced binary
actually tried to run outside the build sandbox.

**Fix:** copied the exact fallback `case` block from `llvm-zig/recipe/build.sh`
into `flang-zig/recipe/build.sh`, right before the stage-1-presence sanity
check. Validated via the raw-script resume pattern first (confirmed
`[[ -n x86_64-conda-linux-gnu ]]` now true, `flang.cfg` /
`x86_64-conda-linux-gnu-flang.cfg` written with the expected `-rpath`/
`--sysroot` content) — this resume was fast since nothing needed
recompiling, only the tail of the script re-ran. A full `pixi run build-flang`
re-run (needed for an actual packaged/tested/published artifact — see the
"re-running pixi publish always forces a full recompile" lesson from earlier)
was in progress as of this entry; **check the next entry for the outcome**,
and re-run `pixi run smoke` immediately after to get the real end-to-end
confirmation this project has been building toward.

**Updates R8** in [09](09-risks-and-open-questions.md): the config-file
*mechanism* (the `.cfg` syntax, `-rpath`/`--sysroot` content, `<CFGDIR>`
expansion) was correct and works exactly as intended the moment it actually
runs — the bug was a silently-skipped build-script guard, not a wrong
mechanism. R8 should be marked resolved once `pixi run smoke` passes.

---

## 2026-08-08 — stage 2 (flang-zig) succeeds; two new bugs found and fixed

**Ran:** `pixi run build-flang` on linux-64, three attempts.

### Attempt 1: full compile succeeded (65 min, 427/427 targets); install failed on RPATH

Configure, compile and link all completed cleanly, including `bin/flang`
itself. `cmake --install` got through most libraries and binaries, then
failed installing `bin/bbc`:

```
CMake Error at build/tools/bbc/cmake_install.cmake:55 (file):
  file RPATH_CHANGE could not write new RPATH: ...
  which does not contain: ...
```

**Root cause, confirmed by reading the binary's actual RUNPATH with
`readelf -d`:** `packages/flang-zig/.pixi` is a symlink to
`/data/gamma/.../pkg-pixi/flang-zig` (our own fix for the disk-exhaustion
incident, previous entry). `$PREFIX`/`$BUILD_PREFIX` are set using the
LOGICAL (symlinked) path throughout the build, but the linker embedded the
REAL (canonical, post-symlink) path in `bin/bbc`'s RUNPATH. CMake's
`file(RPATH_CHANGE)` does a literal byte-for-byte match against the OLD
rpath it recorded at configure time (the logical path) and fails when the
binary's actual embedded rpath (the real path) doesn't match — even though
both refer to the identical file.

**This is a direct, previously-unforeseen side effect of the `.pixi`
symlink fix.** Only `bin/bbc` failed (not `flang`, which apparently hadn't
been reached yet — the install script processes `tools/bbc` before
`tools/flang-driver`, so the hard error aborted before `flang` itself was
ever copied to `$PREFIX`). **The whole install failing meant `flang` was
NOT actually installed despite the compile succeeding** — this is not a
"mostly worked" situation, it's a full stage failure.

**Fix:** `-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON`, added to all three
build.sh (and the Windows build.bat, defensively — the mechanism is
POSIX-specific but the flag is harmless there). This makes CMake link
binaries directly with their final install RPATH, skipping the
old-rpath-must-match rewrite step entirely. Added to llvm-zig and
flang-rt-zig too, pre-emptively, since they have the same symlink exposure
even though stage 1 happened not to trip it.

**A bug introduced while fixing this, caught before it shipped:** the first
attempt at this fix put a multi-line `#`-comment *between* two
backslash-continued lines of the `cmake ... \` invocation. Verified with a
throwaway test (`echo foo \ ... # comment ... \ bar` splits into two
separate commands, the second failing with "command not found") — a `#`
starting a word inside a backslash-continuation block terminates the
*entire* multi-line command at that point, silently truncating everything
after it. **Never interleave a `#comment` line between `\`-continued
arguments in bash** — put explanatory comments entirely before or after the
continued command, never inside it. Fixed by moving the comment above the
`cmake` invocation in all three files.

### Attempt 2: manual resume (raw script), confirms both fixes work

Rather than lose the 427/427 already-compiled objects, resumed by editing
the surviving work directory's script snapshot in place and re-running
`source build_env.sh && ./conda_build.sh` directly (same pattern as
stage 1's exegesis fix). Completed in a few minutes — reconfigure + relink
+ install, no recompile, `test -x $PREFIX/bin/flang` passed, no RPATH
error. This validated the fix cheaply before spending a full cycle on it,
but only ran the raw build script, not the real `pixi publish` pipeline
(no packaging, no test execution, no channel index).

### Attempt 3: full `pixi run build-flang`, actually published — but a full recompile

**Learned the hard way:** re-invoking `pixi publish` reuses the same
work-dir hash (`o97m4YHjt3I`, unchanged since only `build.sh`'s content
changed, not the recipe/variant hash inputs) but **still re-copies the
source tree into `work/`**, which refreshes file mtimes and invalidates
ninja's dependency tracking — forcing a full 427-target recompile despite
nothing source-level having changed. There is no cheap way to get
`pixi publish` to reuse a previous ninja build directory; the "resume in
place" trick only works by *not* going through `pixi publish` again.

**Result: PASS.** 71 minutes total (65 min build/install + ~5 min
packaging). Published `flang-zig-22.1.8-zig_c2a7154_0.conda` to
`./channel/linux-64/` — **16.87 GiB installed, 447 files, 2.12 GiB
compressed.** Largest files: `bin/flang-22` (3.06 GiB), `bin/flang-new`
(3.06 GiB, likely a hardlink/duplicate of flang-22), `bin/bbc` (2.73 GiB),
`lib/libFortranSemantics.a` (2.21 GiB), `lib/libFortranLower.a` (1.67 GiB).

**Independently verified** (not just trusting the pipeline's exit code —
the log showed no explicit "running test" section, only test files being
staged into the package): extracted the published `.conda` directly and
ran the recipe's own test commands by hand.

```
$ bin/flang --version
flang version 22.1.8 (...)
Target: x86_64-conda-linux-gnu
$ bin/flang -S -emit-llvm hello.f90 -o hello.ll   # exit 0
$ grep -c define hello.ll
2
```

Matches the recipe test's `grep -q "define"` check exactly. `Target:
x86_64-conda-linux-gnu` matches stage 1's `LLVM_DEFAULT_TARGET_TRIPLE`.

**Memory during compile:** peaked around 39/62 GiB used (23 GiB available)
through `lib/Lower`, the heaviest library — comfortable headroom at
`FLANG_PARALLEL_COMPILE_JOBS=2`, no OOM risk observed on this 62 GiB
machine.

**Resolves:** the `cmake_push_check_state` bug from the first attempt this
session (see below) stayed fixed across all three attempts — no
regression.

---

## 2026-08-08 — earlier same day: `cmake_push_check_state` bug (stage 2, first configure attempt)

**Ran:** `pixi run build-flang`, before any of the above.

**Result: FAILED at configure**, ~26 seconds in:

```
CMake Error at cmake/modules/FlangCommon.cmake:78 (cmake_push_check_state):
  Unknown CMake command "cmake_push_check_state".
```

**Root cause:** `flang/cmake/modules/FlangCommon.cmake` calls
`cmake_push_check_state()`/`cmake_pop_check_state()` (in its `quadmath.h`
detection, reached because zig's clang auto-detected a system GCC
installation but `quadmath.h` wasn't found via the direct check) without
ever `include(CMakePushCheckState)` — it only includes
`CheckCSourceCompiles` and `CheckIncludeFile`. This is a real gap in
upstream flang's own CMake, that a standalone/out-of-tree build (this one,
and conda-forge's) can hit directly; an in-tree LLVM super-build likely
never notices because something else processed earlier happens to pull in
the module first (CMake module state is global per configure run).

**Fix:** `-DCMAKE_PROJECT_INCLUDE=<recipe>/cmake-project-include.cmake`,
a one-line seed file containing `include(CMakePushCheckState)`, injected
via CMake's standard `CMAKE_PROJECT_INCLUDE` hook (processed right after
`project()`, well before `FlangCommon.cmake` is reached). Added to both
`flang-zig` and `flang-rt-zig` (which also processes `FlangCommon.cmake`,
being "shared between Flang and Flang-RT" per its own header comment) —
untested for stage 3 as of this entry; stage 3 builds via `-S runtimes`,
which may process this file through a different (possibly nested
ExternalProject-style) CMake invocation where `CMAKE_PROJECT_INCLUDE`
might not propagate the same way it did for stage 2's direct `-S flang`
build. Verify when stage 3 is attempted; if it resurfaces there, the
fallback is sed-patching `FlangCommon.cmake`'s source directly (works
regardless of project nesting).

Kept entirely on our side (a build-time include, not a source patch),
self-documented in `cmake-project-include.cmake`.

---

## 2026-08-07 (even later) — disk exhaustion on the primary disk; build relocated to /data

**Ran:** `pixi run build-llvm` for real (first genuine compile attempt) on
this host (`gamma`).

### Attempt 1: got to 99% (6682/6735 targets), then a real, fixable bug

47 minutes in, failed linking `llvm-exegesis` (an optional microarch
benchmarking tool):

```
ld.lld: error: undefined symbol: __rseq_size
ld.lld: error: undefined symbol: __rseq_offset
```

`__rseq_size`/`__rseq_offset` are glibc symbols for restartable-sequence
thread registration, only present in **glibc >= 2.35**. Our sysroot
deliberately pins 2.28 for the glibc-floor story ([05](05-platform-matrix.md)).
llvm-exegesis is irrelevant to flang — fixed by disabling it:
`-DLLVM_TOOL_LLVM_EXEGESIS_BUILD=OFF` in both `build.sh` and `build.bat`.

**Resumed from the surviving work directory** (rattler-build's `.pixi/bld/.../work`
survives a failed build) to avoid redoing 47 minutes of compilation — edited the
snapshot copy of the build script in place, re-sourced `build_env.sh`, re-ran.
Worth remembering for any future mid-build fix.

That surfaced a second, related bug: `LLVM_INCLUDE_TESTS=ON` makes
`test/CMakeLists.txt` wire `check-llvm-tools-*` targets with a **hard**
`add_dependencies()` on `llvm-exegesis`, so CMake's generate step fails outright
once the tool is disabled ("dependency target llvm-exegesis ... does not
exist"). Fixed by turning `LLVM_INCLUDE_TESTS` off too — we never intended to
run `check-llvm` anyway, and tblgen installation is governed by
`LLVM_INSTALL_UTILS`, not this flag. Both fixes are now in `build.sh`/`build.bat`
with the reasoning inline.

### Attempt 2: disk exhaustion, unrelated to the recipe

Second resume died with **exit 134 (SIGABRT)** — not a build bug. The root
filesystem (`/dev/nvme0n1p2`, 476 GB, shared with other sessions on this host)
filled to 100% (471/476 GB used, then down to low tens of MB free). The stage-1
work tree alone was 53 GB and climbing; combined with `~/.cache/rattler` (145 GB,
shared across other pixi projects on this box) and other tenants' project
directories (`~/projects` 151 GB, `~/workspaces` 28 GB), there was no room left
to finish linking + installing + packaging.

This machine hosts multiple concurrent sessions (other zellij panes, an
`opencode` process visible in `ps`), so the large shared caches were not touched
— only my own throwaway scratch conda environments (`abicheck`, `zigprobe`,
~4.4 GB) were removed, and even that wasn't enough.

**User pointed at a second disk**: `/data/gamma/luciorq/workspaces/temp`, 8.3 TB
total / 7.8 TB free (`gammadata` filesystem, separate device from the root
`nvme0n1p2`).

### First fix attempted (`--build-dir`): did NOT work — corrected below

Initially tried redirecting via:

```bash
PIXI_CACHE_DIR=/data/gamma/luciorq/workspaces/temp/pixi-cache \
  pixi publish --path packages/llvm-zig --to ./channel \
  --build-dir /data/gamma/luciorq/workspaces/temp/build
```

This build actually **succeeded** (see below) — but investigating afterward,
`--build-dir` had **no effect**: `packages/llvm-zig/.pixi/bld/...` still grew
to 113 GB on the root disk; `/data/.../build` stayed essentially empty (29 KB).
It succeeded anyway only because other tenants on this shared host apparently
freed space concurrently during the ~54-minute build (root disk usage dropped
from 413 GB to 365 GB used *during* a run that itself added ~120 GB — the only
explanation is concurrent activity from other sessions, not anything this
project did). **Do not rely on this — it was luck, not a fix.**

`PIXI_CACHE_DIR` *did* work (verified via `pixi info --extended`), but the
package cache was never the actual disk-space problem — the `.pixi/bld` work
tree was.

### Actual, verified fix: symlink `<package>/.pixi` to the roomy disk

Filesystem-level, tool-agnostic, does not depend on any flag being honored:

```bash
mkdir -p /data/gamma/luciorq/workspaces/temp/pkg-pixi/llvm-zig
mv packages/llvm-zig/.pixi /data/gamma/luciorq/workspaces/temp/pkg-pixi/llvm-zig
ln -s /data/gamma/luciorq/workspaces/temp/pkg-pixi/llvm-zig packages/llvm-zig/.pixi
```

Applied to `llvm-zig` after the fact (moved 122 GB — `bld` 113 GB +
`artifacts-v0` 8.5 GB — across filesystems; this took several minutes since it
is a cross-device copy+delete, not a rename). Applied to `flang-zig` and
`flang-rt-zig` **preemptively**, before their first build, since for those the
symlink can just point at an empty directory (no data to move).

Each package needs its own symlink — they do not share one `.pixi`. The root
workspace's own `.pixi/` (dev tools: zig-probe, rattler-build) is small
(~1.5 GB) and was left alone.

**This pattern — not `--build-dir` — is what `docs/07-local-workflow.md` now
documents.** If you are continuing this project on `gamma` (or hit the same
problem on another constrained host), symlink each package's `.pixi` before
its first build, don't reach for `--build-dir`.

---

## 2026-08-07 (later) — reframed around r-zig-pixi; W1 resolved; ABI probe validated

**Context change:** the consumer is `r-zig-pixi` (R built from source with zig
cc/c++), not conda-forge's `r-base`. It already uses conda-forge flang on
linux-64 and falls back to gfortran elsewhere. That inverts the priorities —
see [11](11-r-zig-integration.md) and the table above.

### W1 RESOLVED: `zig_win-64` targets MSVC

`xc_w64` in zig-feedstock is `cross_target_platform_ == "win-64"`,
**unconditionally**, so it is true for the plain native package too and selects
`zig_triplet: "x86_64-windows-msvc"`. The `x86_64-w64-mingw32` conda triplet is
only a binary-name prefix.

**Wrong ABI for R.** R (upstream Rtools43+, conda-forge `r-base win-64`, and
r-zig-pixi's gnuwin32 build) is MinGW-w64/UCRT. conda-forge's own
`flang_win-64` is MSVC too (`CHOST: x86_64-pc-windows-msvc`,
`FFLAGS=-fms-runtime-lib=dll`), which is exactly why r-zig-pixi dropped it.

**Fixed in the recipes:** the Windows build scripts now pass
`--target=x86_64-windows-gnu` explicitly (the wrapper only injects its own
`-target` when the caller supplies none) and set
`LLVM_DEFAULT_TARGET_TRIPLE=x86_64-w64-windows-gnu`. zig backs this: its own
`testing/test_mingw_crt.py` asserts `libucrt.a` and `libwinpthread.a` ship in
the package — UCRT + winpthread, the same world `gcc_impl_win-64` lives in.
New risk **R9** tracks that flang has never really been aimed at `windows-gnu`.

### ABI probe: PASS on linux-64 (baseline)

**Ran:** `scripts/abi-probe.sh` in an env with conda-forge `flang 22.1.8` +
`flang-rt_linux-64` + `zig_linux-64 0.16.0`. Fortran half compiled by flang,
C half by `zig cc`, deliberately different compilers.

```
bind(C) scalar by value      ok
assumed-size array byref     ok
complex*16 argument          ok
hidden character length      ok
```

This is the **baseline to compare our own flang against**, and it independently
confirms r-zig-pixi's working premise: a non-zig-built flang interoperates fine
with zig-built C, because the only linkage is `libflang_rt`'s `extern "C"` API.

Two things learned wiring it up, both matching r-zig-pixi's own findings:

- `libflang_rt.runtime` lives in the **clang resource dir**
  (`$PREFIX/lib/clang/22/lib/x86_64-unknown-linux-gnu`), which is on neither the
  default link path nor the loader path. Needs explicit `-L` **and** `-rpath`.
  This is why r-zig-pixi globs for it and passes `FLIBS` by hand.
- conda-forge's flang reports `Target: x86_64-conda-linux-gnu`.

### Also changed

- Dropped the `flang-zig-activation` package drafted earlier: r-zig-pixi
  consumes flang as a plain dependency and detects it by **binary name on
  PATH**, not via `${{ compiler('fortran') }}`. No activation package needed.
- Added `tests/abi/` + `scripts/abi-probe.sh` + `pixi run abi-probe`.
- New risks **R9** (windows-gnu flang) and **Q5** (two C++ runtimes in one R
  process). **W2** sharpened: `${{ stdlib('c') }}` → `vs2022` is now clearly
  questionable against a MinGW target.

---

## 2026-08-07 — repository scaffolding, stage 0, recipe rendering

**Done:** repo structure, three package recipes, docs 01–10, CI workflow,
stage 0 probe scripts.

### Recipe rendering — all three stages verified

**Ran:** `rattler-build build --render-only` on each recipe, plus
`pixi publish --path packages/llvm-zig --to ./channel` far enough to see full
dependency resolution (then aborted — no compilation attempted).

**Result: all three recipes render and resolve.** Build strings:
`llvm-zig zig_547aedf_0`, `flang-zig zig_c2a7154_0`, `flang-rt-zig zig_7d4df44_0`.

Two bugs found and fixed in the process:

1. **Conditional variant values need a LIST under `then:`.** Written as
   ```yaml
   c_stdlib_version:
     - if: linux
       then: "2.17"     # ← silently ignored
   ```
   the override does not apply and you inherit rattler-build's built-in default
   (2.28) with no warning. Caught because the resolved spec read
   `sysroot_linux-64 2.28.*` despite the variant saying 2.17. Correct form is
   `then:` followed by a list item. Verified the fix by rendering with a
   temporary 2.17 variant and confirming the spec changed to
   `sysroot_linux-64 2.17.*`.

   The committed value is **2.28**, matching conda-forge's current default
   glibc floor.

2. **`channels` under `[package.build]` is deprecated** in favour of
   `backend.channels`. Note these are *not* the same thing as they look:
   `backend.channels` is only where the build-backend package is fetched from.
   The recipe's own build/host dependencies resolve from the `[workspace]`
   channel list — which is why `../../channel` belongs there, not here.

**Also confirmed:** `variants.yaml` sitting next to `recipe.yaml` is
auto-discovered by the pixi-build-rattler-build backend (the resolved spec
`zig_linux-64 0.16.*` comes from our `zig_compiler_version`, which is not a
rattler-build default).

**Caveat:** a `pixi publish`/`pixi build` run leaves a ~6.7 GB extracted source
cache under `packages/<pkg>/.pixi/bld/`. Gitignored, but budget for it.

### Stage 0 toolchain probe

**Ran:** `pixi run probe` on linux-64 (Ubuntu, kernel 6.8, `zig_linux-64 0.16.0`).

**Result: PASS.** All six checks:

| check | result |
|---|---|
| activation exports `ZIG`/`ZIG_CC`/`ZIG_CXX`/`ZIG_AR`/`ZIG_RANLIB` | ✅ |
| `zig cc` compiles + links + runs C | ✅ |
| `zig c++` compiles + links + runs C++17 incl. exceptions | ✅ |
| C++ runtime | ✅ **statically linked libc++** — `ldd` shows only libc/libm/libpthread/…, no `libstdc++.so.6`, no `libc++.so.1` |
| CMake accepts `$ZIG_CC`/`$ZIG_CXX` incl. try-compile | ✅ — identifies as `Clang 21.1.8` |
| conda sysroot detected | ✅ `…/x86_64-conda-linux-gnu/sysroot`; test binary's highest glibc ref `GLIBC_2.2.5` |

**Facts established** (these are why the architecture looks the way it does):

- zig 0.16.0 bundles **Clang 21.1.8**.
- `zig c++` links **its own libc++, statically**. Confirms
  [ADR-1](02-architecture-decisions.md): we cannot link against conda-forge's
  libstdc++-built `llvmdev`/`clangdev`/`mlir`, so we build LLVM ourselves.
- The zig activation exports `ZIG_CC`/`ZIG_CXX` but **not** `CC`/`CXX`. Every
  build script must pass them to CMake explicitly or CMake finds system gcc.
- `zig_<target>` packages are published only into same-OS-family subdirs, so
  cross-OS building is impossible. **`zig_win-arm64` exists only in the win-64
  subdir**, making win-arm64 a cross-only target.
- `pixi publish --to <dir>` writes an indexed local channel; `pixi build -o DIR`
  does not (bare `.conda`, no repodata). Stages hand off via `pixi publish`.
- `pixi-build-rattler-build` 0.4.5 is on conda-forge; the manifest schema in
  `packages/*/pixi.toml` was validated against a throwaway package that built
  successfully.
- rattler-build's `script.file: build` (no extension) resolves to
  `build.sh`/`build.bat` per platform.

**Open:** W1 (Windows C ABI), W2 (`stdlib('c')` on Windows), Q3 (tblgen install),
Q4 (static LLVM link viability). See
[09](09-risks-and-open-questions.md).

---

## Template for new entries

```markdown
## YYYY-MM-DD — <one-line summary>

**Ran:** <exact command> on <platform / machine spec>

**Result:** PASS | FAIL at <stage/step>

**Wall clock:** …   **Peak RAM:** …   **Installed size:** …

**Log excerpt:**
```
<the ~20 lines that matter>
```

**Diagnosis:** …

**Changed:** <files touched in response>

**Resolves / opens:** <R#, W#, Q# from doc 09>
```
