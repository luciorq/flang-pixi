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
| recipes render + resolve | ✅ | ✅ | ⬜ | ✅ | ⬜ | ✅ |
| 0 · toolchain probe | ✅ | ✅ *(after Darwin rpath fix)* | ⬜ | ✅ *(windows-gnu target; MSVC default unusable w/o VS)* | ⬜ | n/a |
| 1 · llvm-zig | ✅ 3.18 GiB *(build 4, lld-less)* | ✅ 2.47 GiB | ⬜ | ✅ | ⬜ | ✅ 3.70 GiB *(cross, unstripped)* |
| 1.5 · lld-zig | ✅ 63 MiB *(slim, build 3)* | ✅ 49 MiB | ⬜ | ✅ | ⬜ | ✅ *(cross)* |
| 2 · flang-zig | ✅ *(build 2)* | ✅ | ⬜ | ✅ 1.43 GiB *(MinGW ABI!)* | ⬜ | ✅ 1.26 GiB *(cross)* |
| 3 · flang-rt-zig | ✅ *(build 2)* | ✅ | ⬜ | ✅ *(+ extracted zig MinGW CRT)* | ⬜ | ✅ 97.6 MiB *(+ aarch64 CRT + wcstold shim)* |
| Q5 (libc++ leak) | ✅ resolved, no leak | n/a *(same libcxx as all of conda-forge osx)* | ⬜ | ⬜ | ⬜ | ⬜ |
| smoke | ✅ **PASS** *(closure 1.3 GiB)* | ✅ **PASS** *(783 MB)* | ⬜ | ✅ **PASS, self-contained** | ⬜ | ⚠ **built, UNVALIDATED** *(no arm64 hardware)* |
| ABI probe (zig cc ↔ flang) | ✅ **PASS, our own flang** | ✅ **PASS** | ⬜ | ⬜ next | ⬜ | ⬜ |
| r-zig `make check` lapack.R | ✅ **PASS** *(+ contract test, via flang-zig-validation worktree)* | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |

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

## 2026-08-25 (later) — lld-zig implemented (one packaging trap); osx-arm64 stage 1 in progress: four more zig-on-macOS bugs found and fixed

### lld-zig package: implemented, one new trap found

New `packages/lld-zig`: standalone `-S lld` build against llvm-zig, with
llvm-zig as a **build** dep (host stays empty → no same-path clobbering with
llvm-zig's own bundled lld; trade-off: no cross-compilation for this recipe,
acceptable since only win-arm64 would care and it is last in priority).

**Trap: the first build published a package with ZERO content files** (15.9
KiB, metadata only) — and its test still passed. Root cause: llvm-zig's
STRONG `run_exports` means that even as a *build* dep it injects itself into
the HOST env (that is what strong exports do). lld's `cmake --install` then
overwrote llvm-zig-owned paths (`bin/lld`, `liblld*.a`, `include/lld`),
rattler-build attributed every file to the host package and packaged
nothing; the test passed because the same export had put llvm-zig's own
`bin/lld` into the test env. **Fix:** `ignore_run_exports: from_package:
[llvm-zig]` in lld-zig's recipe. The empty `.conda` + its repodata entry
were purged from the channel before republishing (same-hash "already
exists" trap would otherwise have kept the empty one). Second build:
31 content files, 289.64 MiB installed, 97 MB compressed. (Follow-up,
not blocking: ~230 MiB of that is `liblld*.a` + headers nobody consumes
at runtime — bin/ alone would do.)

flang-zig's recipe now has `run: lld-zig ==version` (was `llvm-zig ==`) +
`ignore_run_exports` on llvm-zig; flang-rt-zig's run deps emptied the same
way. Both rebuilds get NEW build hashes (host/run-dep changes) — the one
time the "already exists" trap does not fire.

### osx-arm64 stage 1 (omicron): four zig-on-macOS bugs, all found by building

All four fixed in `llvm-zig/recipe/build.sh`'s osx block; validated by
resume-in-place on the surviving work dir (the established pattern):

1. **`-Wl,-exported_symbols_list,<file>` breaks zig's driver** — the parse
   failure disables zig's own libSystem/-syslibroot injection and the link
   dies with "library not found for -lSystem" + undefined `_malloc`/`_atoi`.
   Minimal-repro bisect confirmed the flag, alone, flips a working
   `-dynamiclib` link to broken. Only three targets use export files (libLTO,
   libRemarks, libclang), all via one AddLLVM.cmake line. **Fix:** sed to the
   `=` spelling, which zig parses cleanly — measured consequence: the export
   list is then silently NOT applied (verified with `nm`: the dylib
   over-exports). Benign here: nothing consumes these dylibs from our
   packages (ADR-2, static linking).
2. **zig hard-rejects ld64's `-sectcreate`** ("unsupported linker arg"),
   used by clang/tools/driver to embed an Info.plist metadata section in
   `bin/clang`. Cosmetic; **fix:** sed the flag out of
   `clang/tools/driver/CMakeLists.txt` — careful, in LLVM 22 the flag is a
   `target_link_libraries(... PRIVATE "...")` item whose line carries the
   closing paren, and an EMPTY-STRING item is invalid CMake — the
   replacement must leave a bare `)`.
3. **macOS's default `ulimit -n` 256 vs ~2000-object dylib links** —
   `libclang-cpp.dylib` fails with zig's `ProcessFdQuotaExceeded`.
   **Fix:** `ulimit -n 65536` in the osx block.
4. **dsymutil requires Apple's CoreFoundation framework headers**, and
   zig's clang adds no SDK framework search paths. dsymutil is irrelevant
   to flang; **fix:** `LLVM_TOOL_DSYMUTIL_BUILD=OFF` (same
   disable-the-irrelevant-tool pattern as llvm-exegesis on Linux).

Meta-observation: bugs 1, 2 and 4 are all one family — zig's driver is not
a complete ld64 driver; Apple-specific link features (symbol-export files,
section creation, frameworks) are where it diverges from real clang. Expect
stage 2/3 on macOS to hit the same family (flang.cfg content, compiler-rt's
CRT being ELF-only).

### 2026-08-29 — win-arm64 DELIVERED: all four packages cross-built and published

`channel/win-arm64/` now holds the complete chain, cross-built from kappa:
llvm-zig (3.70 GiB, unstripped), lld-zig, flang-zig (1.26 GiB) and
flang-rt-zig (97.6 MiB incl. the extracted **aarch64** MinGW CRT with the
wcstold shim baked in). This is, to our knowledge, the first MinGW-ABI
arm64-Windows flang anywhere. **Built but UNVALIDATED** — no arm64 Windows
hardware available; validation procedure when one exists: pixi env from
this channel with flang-zig + flang-rt-zig, compile and run
`tests/hello.f90` and `tests/modules.f90`.

Getting there required abandoning `pixi publish` for cross targets and a
run of seven distinct discoveries:

a. **`pixi publish` panics on any cross-target publish**
   (`pinned_source.rs:553: expected valid URL`, deterministic on 0.76 and
   0.77, all flag combinations) — worth filing upstream. Bypass: drive
   **standalone rattler-build** directly (`rb-arm.bat` wrapper; conda-forge
   rattler-build 0.74 via pixi global), which also indexes its output dir,
   making manual channel publishing a plain file copy.
b. **conda-forge `zig_win-arm64`'s zig binary dies with "Illegal
   instruction" on the x64 build host** — report to zig-feedstock. Since
   zig is natively a cross-compiler, the recipes now use `zig_win-64` for
   the win-arm64 target with `--target=aarch64-windows-gnu`.
c. **zig's aarch64-windows-gnu CRT lacks `wcstold`** (the x64 flavor has
   it), sinking every executable link via LLVM's Support code. On
   arm64-Windows `long double` *is* `double`, so a forwarding shim to
   `wcstod` is exactly correct — compiled per-build and injected via
   `CMAKE_EXE/SHARED_LINKER_FLAGS` in all cross branches, AND baked into
   the extracted end-user `libmsvcrt.a`. Report to zig.
d. MLIR's ExecutionEngine runner DLLs (`libmlir_float16_utils.dll` et al.)
   need more CRT than the arm flavor offers and flang never uses them —
   `-DMLIR_ENABLE_EXECUTION_ENGINE=OFF` on the cross leg.
e. **Foreign-arch `llvm-strip` poisons the script's exit code**: the
   per-file `2>nul` tolerance hides output but the final ERRORLEVEL fails
   the whole script *after* a successful build — `ver >nul` reset at
   script end. ARM binaries ship unstripped for now (cross-strip via the
   native BUILD_PREFIX llvm-strip is a queued improvement).
f. **pixi-build reports `build_platform == target_platform` even for
   cross builds** — both in script env vars and recipe selectors — so
   `build_platform != target_platform` conditions silently never fire.
   Recipes and scripts now condition on the concrete target
   (`target_platform == "win-arm64"`). Also: cmd delayed expansion is
   unreliable in packaged build scripts — all cross blocks are goto-style
   straight-line code.
g. Operational: `schtasks /tr` has a 261-char limit (wrapper .bat);
   kappa's disk filled mid-build (447 MB free!) from accumulated work
   trees — periodic purges keeping one src_cache seed are now part of the
   playbook.

### 2026-08-28 — Option A: llvm-zig sheds lld, lld-zig goes host-dep + slim; the four-round stale-state saga

User decisions: implement Option A (make lld-zig cross-buildable so win-arm64
— a stated project goal, R on win-arm64 — becomes possible) plus the lld-zig
size slimming. Final state:

- **llvm-zig build 4**: lld project dropped entirely (`LLVM_ENABLE_PROJECTS
  = clang;mlir`); 3.18 GiB linux / 2.47 GiB osx installed, no lld anywhere.
- **lld-zig build 3**: llvm-zig moved build→host (host deps resolve for the
  TARGET platform — the thing that makes cross builds produce a target-arch
  linker), a cross branch (native tblgen from build deps), and a
  binary-only payload with the driver aliases deduplicated to symlinks:
  **63 MiB linux / 49 MiB osx** (was 378 MiB as accidental full copies; the
  earlier 289 MiB shipped liblld*.a + headers nobody links at runtime).
  Windows keeps separate PE copies (~300 MiB) — no safe dedup there yet.
- Runtime closures: **783 MB osx-arm64, 1.3 GiB linux-64** (was 1.5 GiB).
- flang-zig/flang-rt-zig at build 2, rebuilt against the lld-less llvm.
- Unix smokes PASS on the new generation.

**The saga worth remembering — it took FOUR llvm rebuilds to actually drop
lld, because reused build dirs preserve three layers of stale state:**

1. *CMake cache*: passing a new `-DLLVM_ENABLE_PROJECTS` does not reset the
   cached per-tool enables; lld kept configuring. (Fix attempt: explicit
   `-DLLVM_TOOL_LLD_BUILD=OFF`.)
2. *Build tree*: even with the flag, stale generated state can resurrect
   components. (Fix attempt: `rm -rf build` pre-configure — free, since
   pixi's source re-copy forces full recompiles anyway.)
3. **Host prefix — the insidious one**: `$PREFIX` persists across runs in
   the same build dir, so files installed by PREVIOUS generations remain
   and get PACKAGED even when the current build never produces them.
   bin/lld survived the projects change, the tool flag, AND the build-tree
   deletion this way — ninja built 6,673 targets without lld while the
   package still listed a 63 MiB bin/lld. The tell: package listings that
   contain files the build log never mentions building. (Fix: explicitly
   purge the dropped component's files from `$PREFIX` pre-configure.)

All three defenses now live in llvm-zig's build scripts. General lesson
for this backend: **a reused build dir is never clean — treat CMake cache,
build tree, and host prefix as all potentially poisoned** when a component
is removed from a recipe.

kappa win-64 chain and the first win-arm64 cross chain in flight — results
in the next entry.

### 2026-08-27 — Windows LINKS AND RUNS (zig-CRT extraction); backends flipped to X86;AArch64; build-number bump ends the "already exists" era

**Windows smoke passes.** The MinGW-CRT frontier is closed, per the user's
decision to stay self-contained (no `gcc_impl_win-64` dependency):

- `packages/flang-rt-zig/recipe/extract-zig-crt.ps1` runs one verbose
  `zig cc --target=x86_64-windows-gnu` link and harvests every CRT artifact
  zig materializes into its cache (parsed off the printed `lld-link` line),
  into `Library\x86_64-w64-mingw32\lib` with the GNU names flang's driver
  emits: `crt2.obj→crt2.o`, `libmingw32.lib→libmingw32.a`,
  `compiler_rt.lib→libgcc.a` (zig's libgcc replacement), zigc + the UCRT
  `api-ms-win-crt-*` import libs merged into `libmsvcrt.a` (llvm-ar MRI
  ADDLIB), system import libs as `lib<name>.a`, empty archives for
  `libgcc_eh/libmoldname/libmingwex` (SEH needs no gcc_eh; modern mingw-w64
  merged the other two), empty objects for `crtbegin.o/crtend.o` (zig links
  without them; validated).
- `flang-zig`'s build.bat now writes `Library\bin\flang.cfg` with
  `-fuse-ld=lld` (the driver otherwise invokes bare `ld`); `ld.lld.exe`
  comes from lld-zig, already flang's run dep.
- flang-rt's Windows multi-flavor `libflang_rt.runtime.static.a` is aliased
  to the plain `libflang_rt.runtime.a` the driver links.

All three pieces were validated **by hand first** in a clean solver env
(`hello.f90` AND `modules.f90` compile, link, run — correct output), then
baked into the recipes. PowerShell extraction gotchas, for the record:
`$ErrorActionPreference=Stop` turns native stderr into fatal errors;
Set-Content sneaks BOMs that break llvm-ar's MRI parser (use
`[IO.File]::WriteAllLines` with BOM-free UTF8 + cmd stdin redirect); and
`Out-String` wraps long native output at console width, destroying
parseable link lines (capture to a file via cmd redirect instead).

**Backends flipped** (user request): `llvm_targets_to_build` is now
`"X86;AArch64"` on every platform — each flang can emit code for both
arches, unlocking the cross paths (win-arm64 mandatory-cross first;
linux-aarch64 / osx-64 hardware-optional). Gamma's llvm went from 6659 to
6805 ninja targets; rebuild chains ran on all three machines.

**The "already exists" class is now solved properly**: rattler's
build-string hash inputs are variant values + dependency *specs* — not
resolved packages, not script content. So content-only rebuilds (new llvm
behind the same spec) collide with old filenames and get silently skipped.
The fix used all session — manual channel recovery — is replaced by the
boring correct one: **bump `build.number`** (lld/flang/flang-rt now build
1). New filenames, clean publishes, and the solver automatically prefers
the higher build number over any stale build 0.

Two more environment lessons: Windows scheduled tasks created without
`/ru` run on the interactive token and **die with CONTROL_C_EXIT when that
user's session ends** (two mysterious mid-build deaths on shared kappa) —
`/ru SYSTEM /rl HIGHEST` with an explicit PATH in the command (SYSTEM lacks
pixi) is the durable pattern. And superseded same-version packages left in
a channel make build-env solves ambiguous — remove them promptly.

**Validation state after the flip**: gamma and omicron chains fully
republished as build 1, smokes PASS on both; the r-zig-pixi regression
gate re-run on gamma against the new flang — **R rebuilds, `make check`
passes, `lapack.R` OK**.

**Kappa chain completed too** (evening): llvm 4.53 GiB cross-capable,
then lld/flang/flang-rt as build 1. One last extraction bug found by the
packaged build: with `ZIG_GLOBAL_CACHE_DIR` under the CWD (as build.bat
sets it), zig prints **relative** artifact paths
(`.zig-global-cache\o\...`) and the absolute-only path regex harvested
nothing — the first packaged flang-rt shipped empty stubs while the
interactive validation (different CWD → absolute paths) had worked.
Fixed with tokenize-and-resolve parsing. Also: SYSTEM-context tasks need
`C:\Windows\System32\WindowsPowerShell\v1.0` in PATH explicitly, or
every `powershell` step in a build.bat silently no-ops (this resurrected
the llvm-config bug once before it was caught; llvm-zig's build.bat now
hard-fails if the filter can't run).

**Final validation: a completely clean Windows env solved from the
channel — `pixi add flang-zig flang-rt-zig`, zero hand patches — compiles,
links and runs both test programs.** The win-64 toolchain is
self-contained end to end.

### win-64 COMPLETE (packages): full chain published; smoke blocked on the known MinGW-CRT frontier (2026-08-26)

All four packages now exist for win-64 in `channel/win-64/` — **a MinGW-ABI
flang.exe exists**, which was this leg's reason to exist:

| package | size | note |
|---|---|---|
| llvm-zig | 4.18 GiB installed, 6369 files | 6659/6659 targets clean |
| lld-zig | 276 MiB, 31 files | |
| flang-zig | 1.41 GiB, 439 files | flang.exe --version + -emit-llvm test passed |
| flang-rt-zig | 93.76 MiB, 35 files | static-only (upstream: no shared flang-rt on Windows) |

Three recipe/toolchain bugs found by building (beyond the earlier
CMAKE_ASM_FLAGS one):

- **zig's wrapper .exe strips embedded quotes when re-spawning zig**:
  `-DCMAKE_CFG_INTDIR="$<CONFIG>"` reached the compiler as a bare
  identifier ("use of undeclared identifier 'Release'"). Fixed by removing
  llvm-config's define (its uses are `#if defined`-guarded).
- **Backslash `%SRC_DIR%` in CMAKE_MODULE_PATH** → CMake "Invalid character
  escape '\U'" at try_compile. Forward-slash everything CMake sees
  (`SRC_DIR_CMAKE` variable in both flang build.bat files).
- **Upstream flang bug for MinGW**: RTBuilder.h's getModel specialization
  for the memcpy-style fptr (`unsigned __int64`) is `#ifdef _MSC_VER`-only,
  but MinGW is LLP64 too → undefined
  `getModel<...unsigned long long>` at the first .exe link. Patched via
  `packages/flang-zig/recipe/patch-rtbuilder.ps1` (spell it
  `unsigned long long`, widen guard to `_WIN64`). **Worth reporting
  upstream** — nobody builds MinGW flang, which is how this survives.

Windows-environment lessons (all needed to get any build running at all):
github.com is DNS-blocked on kappa → seed rattler's per-build-dir
`src_cache` (tarball + `.metadata` json + `_extracted/`; and note the
build-dir hash MOVES when build-deps change, e.g. flang-rt's dir changed
when flang-zig published — re-seed the current dir); symlink privilege
(os error 1314) → Developer Mode + `schtasks /rl HIGHEST` (Start-Process
detachment silently fails; schtasks one-shots are the reliable pattern,
with IgnoreNew semantics — wait for Running→Ready before re-triggering);
logs arrive CP437-garbled over ssh (scp + iconv) and flush in bursts;
PowerShell 5.1 here-strings are unusable for embedded C code.

### The smoke-equivalent: compile works, link is the next frontier

`flang hello.f90` in a fresh solver env: **Fortran → object works**
(`-fc1 -triple x86_64-w64-windows-gnu -emit-obj` succeeds). The LINK fails
exactly as docs/11 anticipated, now with precise data. The MinGW driver
invokes bare **`ld`** (GNU ld, not in the env — needs `-fuse-ld=lld`
wiring plus lld's `ld.lld` MinGW flavor) and demands the full GNU MinGW
link world: `crt2.o crtbegin.o`, `-lmingw32 -lgcc -lgcc_eh -lmoldname
-lmingwex -lmsvcrt`, searched under `Library/x86_64-w64-mingw32/lib` —
none of which exist in the env (zig's bundled MinGW CRT is private to
zig). **Decision needed** (deliberately not made unilaterally): (a) run-dep
on conda-forge's MinGW toolchain libs (`gcc_impl_win-64` world — attractive
because r-zig-pixi already ships it for gfortran, and the driver's search
paths match its layout), or (b) extract/ship zig's CRT pieces in
flang-rt-zig (self-contained, mirrors the linux compiler-rt approach, more
engineering). Either way a `flang.cfg` with `-fuse-ld=lld` is needed on
Windows (build.bat writes no cfg today).

### win-64 stage 1 compiling: past 1200/6659 targets, zero failures (2026-08-26)

The first-ever Windows build of this project is deep in compilation. Getting
there took four Windows-environment fixes and one real recipe bug — all
found by running, none by guessing:

- **kappa cannot resolve github.com** (DNS-filtered network; conda CDN
  works). Worked around by seeding rattler-build's per-build-dir source
  cache (`packages/<pkg>/.pixi/bld/<pkg>/<hash>/output/src_cache/`) with
  the tarball scp'd from gamma's cache + its `.metadata/<hash>.json` + a
  locally-extracted `<hash>_extracted/` dir (`tar --strip-components=1` on
  kappa — the tarball alone is NOT enough; the metadata's `extracted_path`
  must exist or the work dir silently gets no source). NOTE: every new
  build-dir hash needs the cache re-seeded (robocopy from an old dir).
- **os error 1314 (symlink privilege)** during source copy: fixed by
  enabling Developer Mode (registry) and recreating the launcher as an
  elevated scheduled task (`schtasks /rl HIGHEST`). Plain `Start-Process`
  detachment silently failed; **`schtasks` one-shot tasks are the reliable
  Windows detachment pattern** for long builds over ssh.
- Windows console output arrives CP437-garbled over ssh — scp the log to
  gamma and `iconv -f CP437` to read it.
- **vs2022 activation's Windows-SDK registry probing fails harmlessly** on
  a VS-less machine ("I'm not sure if things will work, but let's
  try...") — W2 resolved in practice: the MinGW-target build needs nothing
  from MSVC, the stdlib('c') activation is inert noise here.
- **Real recipe bug: `CMAKE_ASM_COMPILER_TARGET` does not put `--target`
  on `.S` assembly compile lines.** First casualty: LLVM's
  `blake3_sse2_x86-64_windows_gnu.S` at target 183 — zig fell back to its
  windows-msvc default and died with `WindowsSdkNotFound`. Fix:
  `-DCMAKE_ASM_FLAGS=--target=x86_64-windows-gnu` (a plain flag always
  reaches the command line) in all three build.bat files + cross branches.

What the run has already proven: zig activation, cmake configure with the
zig wrappers, ninja, and C/C++/ASM compilation with the windows-gnu target
all work on Windows. The link steps and the packaging half are still ahead.

### win-64 (host `kappa`, Windows 11, 12 cores): stage-0 probe PASSES

The dormant Windows leg is now real. Getting the probe to run surfaced
three Windows-tooling lessons before any compiler question:

- **Windows PowerShell 5.1 failed to parse the probe's here-strings**
  (content with C/C++ braces/`&`/`<<` got read as PowerShell; CRLF
  conversion did NOT fix it). Rewrote `probe-zig-toolchain.ps1` to build
  embedded sources as arrays of single-quoted lines — boring and robust.
  `.gitattributes` now forces `eol=crlf` for `*.ps1`/`*.bat` regardless.
- **W1 confirmed on real hardware**: `zig cc -v` reports
  `Target: x86_64-unknown-windows-msvc` — the MSVC default. On a machine
  without Visual Studio it is not even usable: plain `zig cc t.c` dies
  with `failed to find libc installation: WindowsSdkNotFound`.
- **`--target=x86_64-windows-gnu` works out of the box**: C and C++17
  compile, link and run with zig's bundled MinGW CRT, no Windows SDK, no
  VS. CMake integration passes with `CMAKE_{C,CXX}_COMPILER_TARGET` set.
  The probe now tests this target explicitly, since it is the one every
  build.bat passes.

All six probe checks green. First `pixi run build-llvm` attempt on
Windows started — expect the unverified build.bat scripts and the W2
(`stdlib('c')` → vs2022) question to bite next.

### osx-arm64 COMPLETE: all four packages published, smoke PASSES (night update)

Stage 3 and the first end-to-end run surfaced macOS bugs 8–10:

8. **`COMPILER_RT_BUILD_CTX_PROFILE` was missing from the OFF list** — a
   newer compiler-rt component that defaults ON and drags `sanitizer_common`
   in, which needs Apple SDK headers zig doesn't expose (`asl.h`,
   `sys/timeb.h`). Now OFF everywhere. Also added the Darwin twin of the
   CRT relocation block (`lib/darwin/libclang_rt.osx.a` → resource dir;
   Mach-O has no crtbegin/crtend, so no CRT objects on this platform).
9. **conda-forge's `libcxx` has NO run_exports on itself** — a host dep
   alone adds nothing to `run:`, so every binary aborted at load with
   "Library not loaded: @rpath/libc++.1.dylib" in a fresh env. All four
   recipes now carry an explicit osx-gated `libcxx >=21` run dep; the
   already-published osx packages' repodata was hand-patched (their
   internal `info/index.json` stays stale until the next real rebuild —
   same class of fix as the "already exists" recoveries).
10. **flang's Darwin driver needs `SDKROOT`** to find libSystem at link
   time ("ld: library 'System' not found"), same as clang. It links via
   Apple's `ld` from the Command Line Tools (fine — CLT is a macOS
   developer prerequisite anyway). `smoke-test.sh` now auto-resolves
   SDKROOT via `xcrun` on Darwin; r-zig-pixi integration must ensure the
   same (it already manages SDK discovery for zig cc).

With those three: `pixi run smoke` on omicron **PASSES** self-contained —
`hello: OK`, `modules: OK`, compiled/linked/run by our own osx-arm64 flang
against a solver-clean env. **The highest-value platform of the whole
project now works end to end.** Next gate there: the ABI probe, then
r-zig-pixi's macOS validation (removing the gfortran `-O1` cap is the
prize).

### osx-arm64 stages 1, 1.5, 2 all published (evening update)

After the six macOS fixes, the clean packaged builds on omicron went
straight through: `llvm-zig-22.1.8-zig_aa435b6_0.conda` (596 MB compressed,
vs linux's 740 MiB), `lld-zig-22.1.8-zig_d40d935_0.conda` (31 content
files, 220 MiB installed — the ignore_run_exports fix held on the second
platform), and `flang-zig-22.1.8-zig_01c9890_0.conda` — all in
`channel/osx-arm64/`. One more stage-2 lesson first: **the fd-limit fix
must live in EVERY package's osx block, not just llvm-zig's** — flang-22's
link list also exceeds macOS's 256-fd default (`ProcessFdQuotaExceeded`),
so the `ulimit -n 65536` block is now in all four build.sh files. Stage 3
(flang-rt) in flight; the ELF-only `COMPILER_RT_BUILD_CRT=ON` is the
predicted next failure point there.

### r-zig-pixi validation (linux-64): R BUILDS with flang-zig

In a git worktree of `../r-zig-pixi` (branch `flang-zig-validation`, user's
WIP untouched) with `flang-zig`/`flang-rt-zig` swapped in and our channel
first: **`pixi run build` completes — "zig-built R OK: R version 4.6.1"**.
The zig-built R, with every Fortran object compiled by our flang, builds
and passes its own verify step. `pixi run check` (R's regression suite,
incl. the `lapack.R` that catches the gfortran miscompile class) launched
next — result in the following entry.

Two validation-run notes: (1) a fresh conda-forge solve pulls pango 1.58 +
the newly split `libharfbuzz` 14.3, which **breaks R 4.6.1's cairo module
compile** (`hb.h` include churn) — r-zig-pixi's own next lock refresh will
hit this; the validation pinned `pango 1.56.*`/`harfbuzz 14.2.*` to match
its current lock. Unrelated to flang. (2) zig build's parallel failure
reporting can list innocent in-flight steps as "failed command" — a
reported flang failure on `dlamch.f` turned out to reproduce cleanly (exit
0) when run manually; always re-run a "failed command" in isolation before
blaming it.

### lld-swap verified on linux-64: runtime closure 3.9 GiB → 1.5 GiB

flang-zig and flang-rt-zig rebuilt with the new run deps; **both hit the
"already exists" trap again** — extending the earlier lesson: run-dep-only
recipe changes do NOT change the build-string hash either (it really is
host/build deps + variant inputs only). Manual recovery both times, with
the fresh packages' own `info/index.json` supplying the new `depends`
(flang-zig: `lld-zig ==22.1.8` + sysroot, **no llvm-zig**; flang-rt-zig:
only `__glibc`, constrains preserved).

Fresh `pixi run smoke`: **PASS**, and the solved env now contains
flang-zig + flang-rt-zig + lld-zig + sysroot + kernel-headers + tzdata —
**no llvm-zig anywhere**. Measured: **1.5 GiB** installed (was 3.9 GiB
with llvm-zig as flang's run dep). Remaining slimming (not done): lld-zig
ships 289 MiB of which ~230 MiB is `liblld*.a` + headers nobody links at
runtime; llvm-zig also still ships its own now-redundant `bin/lld` copy.
Both are cleanup-on-next-rebuild items, not blockers.

---

## 2026-08-25 — lld-zig split proven viable; osx-arm64 probe run: macOS inverts ADR-1's libc++ story

### lld-zig split: decisive YES

Question from the size work: can `flang-zig`'s 2.98 GiB `llvm-zig` run
dependency be replaced by just lld? **Proven empirically**: in a copy of the
smoke env, deleted all 6,369 `llvm-zig`-owned files except `bin/lld` (56 MiB
stripped) + the `bin/ld.lld` symlink — flang still compiles, links
executables **and** shared libraries (the R-package mode), and the outputs
run correctly. The link line (`flang -v`) confirms `ld.lld` is the *only*
llvm-zig tool invoked at use time; every other input comes from flang-zig,
flang-rt-zig, or the sysroot.

Runtime closure math: flang-zig 880 MiB + lld 56 MiB + flang-rt-zig 38 MiB +
sysroot ≈ **1.2 GiB**, vs 3.9 GiB with the full llvm-zig dependency.
Implementation (a `packages/lld-zig` recipe + flang-zig run-dep swap with
`ignore_run_exports` on llvm-zig's strong export) is queued; note the
flang-zig rebuild for it will get a **new build string** (host-dep change),
so for once the "already exists" trap will not fire.

### osx-arm64 (host `omicron`, M2-class, 10 cores/32 GiB): stage-0 probe run

`pixi run probe`: **5 of 6 checks pass, check 5 (CMake integration) FAILS**
— and the root cause is a genuine platform-story inversion, exactly the kind
of macOS surprise the R1 notes predicted:

**On osx-arm64, conda-forge's zig links libc++ *dynamically*, against
conda-forge's own `libcxx` package** (`zig_impl_osx-arm64` depends on
`libcxx 21.*`; produced binaries reference `@rpath/libc++.1.dylib`) — the
opposite of Linux, where zig statically bundles its own libc++ (the fact
ADR-1 is built on). Worse, zig injects **no `LC_RPATH` whatsoever**, so
*every* C++ binary it links crashes at load with `Library not loaded:
@rpath/libc++.1.dylib` unless the link adds one. Verified both ways on
omicron: bare `$ZIG_CXX t.cpp -o t` → crash; adding
`-Wl,-rpath,$CONDA_PREFIX/lib` → runs, `otool -l` shows the LC_RPATH.

Consequences for the recipes (not yet applied as of this entry):

1. All three `build.sh` need a Darwin branch adding the rpath to link flags
   (and `CMAKE_INSTALL_RPATH` pointing at the install-time lib dir —
   `@loader_path/../lib` is the conda-forge convention).
2. `libcxx` must be an explicit **host + run** dependency on osx in the
   recipes — today it only arrives transitively via zig, a *build* dep,
   whose deps do not propagate to run.
3. **ADR-1's premise inverts on macOS**: our zig-built LLVM will link the
   *same* `libcxx` every other conda-forge osx package uses. There is no
   two-C++-runtimes problem on macOS at all — and by the same token, the
   "cheap path" (building flang against conda-forge's own `llvmdev`, per
   the cost observation in [11](11-r-zig-integration.md)) loses its main
   ABI risk on this platform. Staying on the zig route as specified, but
   the trade-off should be recorded honestly: on macOS the zig route's
   ABI-isolation rationale is gone; what remains is toolchain uniformity.

(Correction on a first misreading: probe check 3 — direct C++
compile+link+run — *also* failed, its log dump was just mistaken for warning
noise. The probe caught the problem in both places; no probe gap. Checks 3,
4 and 5 have since been updated to add the Darwin rpath and to treat
dynamic conda-forge libcxx as the *expected* macOS result.)

---

## 2026-08-11 (later) — full-tree rebuild: llvm-zig finally rebuilt with `-g0`+strip; whole toolchain 59.8 GiB → 3.9 GiB

**Prompted by:** user asked to "rebuild the whole package tree to see if the
changes to the LLVM package size are meaningful." Answer: **very** — this was
the deferred fix from the two previous entries finally being cashed in.

**Ran:** `pixi run build-llvm` (49 min) → channel recovery → `pixi run
build-flang` (53 min) → recovery → `pixi run build-flang-rt` (3 min) →
recovery → fresh `rm -rf .smoke && pixi run smoke`. Sequential, not
`build-all`, because each stage's channel copy had to be manually recovered
from the "already exists" trap **before** the next stage built against it
(all three hit the trap, as expected — only `build.sh` files changed since
the original builds, so all build-string hashes were unchanged).

| package | installed, before | installed, after | compressed, before | compressed, after |
|---|---|---|---|---|
| `llvm-zig` | 42.7 GiB | **2.98 GiB** (14.3x) | 9 GiB | **740 MiB** (11.7x) |
| `flang-zig` | 880 MiB | 880 MiB *(unchanged, expected)* | 100 MiB | 99.6 MiB |
| `flang-rt-zig` | 38.31 MiB | 38.31 MiB *(unchanged, expected)* | 3.31 MiB | 3.31 MiB |
| **total** | **~43.6 GiB** | **~3.9 GiB** | **~9.1 GiB** | **~843 MiB** |

Against the original pre-optimization state (before any of the three size
fixes): **59.8 GiB → 3.9 GiB installed (15x), ~11.1 GiB → ~843 MiB
compressed (13x).**

flang-zig and flang-rt-zig coming out byte-different but size-identical is
exactly right: their own code was already `-g0`+stripped last round, and the
llvm-zig `.a` archives they consume at *build* time don't land in their
packages. The rebuild's purpose for those two was verifying the tree still
builds and links cleanly against the slim llvm-zig — it does. Stage-2 link
also got cheaper (53 min vs 61 min total) since the linker now chews through
debug-free archives.

Verified on the fresh llvm-zig package before promoting it: `readelf -S` on
`bin/llvm-tblgen`, `bin/clang-22`, `lib/libclang-cpp.so.22.1` — zero debug
sections, no `.symtab` (i.e. `--strip-all`/`--strip-unneeded` both took).
Largest remaining files are honest code: `bin/mlir-opt` 137 MiB,
`lib/libclang-cpp.so.22.1` 108 MiB.

**Smoke: PASS** on a fresh throwaway env solved from the recovered channel —
which exercises all three rebuilt packages (llvm-zig comes in as flang-zig's
run dependency).

**What remains, sizewise:** conda-forge's flang stack is ~116 MiB installed
*total* because it dynamically links `libLLVM.so`/`libMLIR.so`/
`libclang-cpp.so` once, while ours statically duplicates LLVM into every
tool binary (ADR-2, the deliberate ABI-safety choice). That ~34x remaining
gap is architectural, not waste — revisiting it means revisiting ADR-2,
which is a separate decision, not a build-flag fix. The per-flag
low-hanging fruit is now fully harvested.

---

## 2026-08-11 — further size cuts: `llvm-strip` + `flang-new` dedup on flang-zig/flang-rt-zig; llvm-zig still deferred

**Prompted by:** follow-up to the `-g0` fix (previous entry) — user asked
"Are there other places where size could be optimized for the flang-zig
package?", then confirmed ("yes") applying both fixes found.

### Investigation: two more concrete, non-speculative wins

1. **`bin/flang-new` was a full second copy of `bin/flang-22`**, not a
   symlink/hardlink — installed by upstream flang's own CMake as two separate
   `install(PROGRAMS ...)` targets pointing at the same built executable.
   Confirmed byte-identical with `cmp` before touching anything. At
   ~140 MiB each post-strip, this alone was pure waste.
2. **`-g0` only stops *new* debug info from being emitted — it does not undo
   the symbol-table/relocation bloat already baked into `-O2`-built
   binaries.** `llvm-strip` (built by our own `llvm-zig`, already a runtime
   dependency) removes symbol tables and any remaining non-essential
   sections. Verified `--strip-all`/`--strip-unneeded` both work against our
   own build first, on a throwaway 738 MiB test binary → 51.5 MiB, before
   touching the real recipes.

**Fix, applied to all three packages' `build.sh` *and* `build.bat`** (Windows
mirrored pre-emptively, unverified there — same pattern as every other
cross-platform fix this session):

- `llvm-zig`: strip pass over `bin/*` (`--strip-all`) and `lib/*.so*`
  (`--strip-unneeded`), inserted after the tblgen safety-net copy loop.
- `flang-zig`: `flang-new` deduplicated into a symlink to
  `flang-<major>` (guarded by a `cmp -s` byte-check — falls back to leaving
  both files alone with a warning if they ever differ), then a strip pass
  over `bin/*` (`--strip-all`).
- `flang-rt-zig`: strip pass over `lib/*.so*` only (`--strip-unneeded`).
  **Deliberately does not touch `.a`/`.o` files** — those are linker inputs
  for consumers (r-zig-pixi links against `libflang_rt.runtime.a`), and
  stripping a static archive's member objects is a different, riskier
  operation than stripping a final binary/shared library. (In practice this
  turned out moot on Linux — `.a` members here already carried zero debug
  sections, because `-g0` in the previous fix already stopped debug info
  from being generated in the first place.)

### Rebuilt flang-zig and flang-rt-zig (llvm-zig still deliberately deferred)

Same scoping as the `-g0` round: apply the fix everywhere, spend rebuild time
only on the two smaller/cheaper packages.

| package | installed, before (post-`-g0`) | installed, after (post-strip/dedup) | compressed, before | compressed, after |
|---|---|---|---|---|
| `flang-zig` | 5.55 GiB | **880 MiB** (6.5x) | 969 MiB | **100 MiB** (9.7x) |
| `flang-rt-zig` | 40.47 MiB | **38.31 MiB** (1.06x) | 3.57 MiB | **3.31 MiB** (1.08x) |
| `llvm-zig` *(still unchanged)* | 42.7 GiB | 42.7 GiB | 9 GiB | 9 GiB |

`flang-rt-zig`'s modest gain is expected and consistent with the design
above: its dominant files (`libflang_rt.runtime.a` 20.80 MiB,
`libflang_rt.runtime.so` 13.34 MiB before stripping down further) are mostly
static archive, which this fix intentionally leaves untouched; only the
`.so` had anything left to strip.

Verified directly, not just trusted:

- `flang-zig`: `bin/flang-new` extracted as a real symlink
  (`lrwxrwxrwx ... flang-new -> flang-22`), `readelf -S bin/flang-22 | grep
  debug` empty.
- `flang-rt-zig`: `readelf -S lib/.../libflang_rt.runtime.so | grep debug`
  empty; `.a` sibling confirmed untouched (still present, same content,
  simply never had debug sections to begin with post-`-g0`).

**Hit the "already exists" packaging trap on both packages again** (expected
— only `build.sh` changed, build-string hash unchanged), recovered with the
now-standard procedure (fresh `.conda` copied over stale, `md5`/`sha256`/
`size`/`depends`/`constrains` patched into `repodata.json` from the fresh
package's own `info/index.json`, `repodata.json.zst` regenerated, stale
shard files deleted).

**Re-verified end to end:** `rm -rf .smoke && pixi run smoke` passes cleanly
— `sum of squares 1..10 = 385.` / `hello: OK`, `modules: OK`. Functionally
unchanged.

**`llvm-zig` remains the dominant unsolved factor.** Three-package installed
total is now ~43.6 GiB (was ~48.3 GiB after the `-g0`-only round, ~59.8 GiB
before either fix) — `llvm-zig`'s untouched 42.7 GiB is now **>97% of the
total**. Applying `-g0`+strip to `llvm-zig` itself remains the single highest-
leverage remaining size fix. *(Update: done the same day — see the entry
above; llvm-zig dropped to 2.98 GiB.)* Separately, and much bigger than
either of these fixes: static-vs-dynamic linking (ADR-2) is still the actual
dominant architectural size driver long-term (conda-forge's flang ships
~116 MiB total via shared `libLLVM.so`/`libMLIR.so`/`libclang-cpp.so`; ours
is fundamentally multi-GB via static duplication into every tool binary) —
noted here again as a distinct, larger, riskier decision that was
investigated but explicitly not pursued this session.

---

## 2026-08-10 — package sizes: found and fixed the `-g0` gap; flang-zig/flang-rt-zig rebuilt, llvm-zig deliberately deferred

**Prompted by:** user noticing `flang-zig`/`flang-rt-zig` were far larger than
conda-forge's equivalents (`flang` 14.5 MiB compressed vs our 2.12 GiB;
`libflang-rt` 2.5 MiB vs our ~20 MiB).

### Root cause: `zig cc`/`zig c++` emit full DWARF debug info by default

Confirmed empirically, not assumed: `readelf -S` on `bin/flang-22` showed
`.debug_info` alone at 1.33 GB, with `.debug_loc`/`.debug_str`/`.debug_line`/
`.debug_ranges` bringing the total to ~3.0 GB of a 3.2 GB binary — `.text`
(actual code) was only 97 MB. The captured `compile_commands.json` for
`Bridge.cpp` showed `-O2 -O3 -DNDEBUG ...` with **no `-g` anywhere** — proving
this isn't something our flags requested. Isolated with a two-line test: the
identical `zig c++` invocation compiling a trivial file with `-g0` added
dropped the object from 81,512 bytes to 1,200 bytes (68x on a trivial file).
`-O2`/`-DNDEBUG` govern optimization and assertions; debug-info emission is a
separate axis in Clang that neither implies, and stock Clang defaults to none
— zig's bundled Clang does not.

**Fix:** added `-g0` to `CFLAGS`/`CXXFLAGS` in all three packages' `build.sh`
*and* `build.bat` (Windows untested but the same zig binary/defaults apply,
so applied pre-emptively). Full reasoning documented inline in
`llvm-zig/recipe/build.sh`, referenced from the other two.

**A near-miss while validating:** the first spot-check after starting the
flang-zig rebuild inspected a *stale leftover work directory from a prior
session* (`o97m4YHjt3I`, containing 24 GB of old objects) instead of the
actual new one — rattler-build had allocated a genuinely fresh work-dir hash
this time (`9v7Bi7XlQC4`, unlike every previous fix this session which reused
the same hash). Caught by checking `ps aux` for the actual running process's
CWD before concluding anything was wrong. Reclaimed the stale directory
(24 GB) once confirmed unrelated to the current build.

### Rebuilt flang-zig and flang-rt-zig (llvm-zig deliberately NOT rebuilt)

**User's explicit choice**, given the cost of another ~50-minute llvm-zig
rebuild: apply the fix everywhere, but only spend the rebuild time on
flang-zig and flang-rt-zig now. This is a *partial* fix, and known to be one
going in — flang-zig statically links llvm-zig's already-built `.a` archives,
which still carry their own embedded debug info regardless of flang-zig's own
flags.

| package | installed, before | installed, after | compressed, before | compressed, after |
|---|---|---|---|---|
| `flang-zig` | 16.87 GiB | **5.55 GiB** (3.0x) | 2.12 GiB | **969 MiB** (2.2x) |
| `flang-rt-zig` | 239 MiB | **40.47 MiB** (5.9x) | ~20 MiB | **3.57 MiB** (5.6x) |
| `llvm-zig` *(unchanged)* | 42.7 GiB | 42.7 GiB | 9 GiB | 9 GiB |

`bin/flang-22` itself: 3.06 GiB → 1.25 GiB. Verified directly with
`readelf -S` that the *remaining* 1.25 GiB binary still carries ~1.1 GB of
debug sections (`.debug_info` 506 MB, `.debug_loc` 248 MB, `.debug_str`
229 MB, `.debug_line` 71 MB, `.debug_ranges` 46 MB) — down from ~3.0 GB
before, a 63% reduction in debug bytes for this one binary, entirely
consistent with "flang's own new code lost its debug info; the
statically-linked LLVM/Clang/MLIR code from unrebuilt llvm-zig kept its own."

**The honest bottom line: total toolchain size barely moved.**
`llvm-zig` (42.7 GiB / 9 GiB compressed) is unchanged and dwarfs the combined
savings on the other two packages (11.3 GiB / 1.15 GiB reclaimed). The
three-package total went from ~59.8 GiB to ~48.3 GiB installed (~19% overall)
— a real but modest win, because the single largest package was intentionally
left untouched. **A full fix requires rebuilding `llvm-zig` with `-g0`**,
deferred to whenever it's next touched for another reason (e.g. starting
osx-arm64, which needs a fresh llvm-zig build anyway).

**Hit the "already exists" packaging trap twice more** (once per package),
applying the now-established recovery both times — extract the fresh
package's own `info/index.json` for `depends`/`constrains`, patch
`repodata.json`'s `md5`/`sha256`/`size` *and* those fields, regenerate
`repodata.json.zst`, drop the sharded index files.

**Re-verified end to end:** `pixi run smoke` fresh (`rm -rf .smoke` first)
still passes cleanly against the resized packages — `sum of squares 1..10 =
385.` / `hello: OK`, `modules: OK`. The size fix changed nothing functional.

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
