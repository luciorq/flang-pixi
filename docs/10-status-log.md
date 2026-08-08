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

| stage | linux-64 *(ref)* | osx-arm64 | osx-64 | win-64 | linux-aarch64 | win-arm64 |
|---|---|---|---|---|---|---|
| recipes render + resolve | ✅ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| 0 · toolchain probe | ✅ | ⬜ | ⬜ | ⬜ | ⬜ | n/a |
| 1 · llvm-zig | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| 2 · flang-zig | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| 3 · flang-rt-zig | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| smoke | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| ABI probe (zig cc ↔ flang) | ✅ *(conda-forge flang)* | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| r-zig `make check` lapack.R | n/a | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |

✅ pass · ❌ fail · ⬜ not attempted

**No compilation of LLVM or flang has been attempted yet.**

## Next actions, in order

1. `pixi run build-llvm` on linux-64. Expect hours. Not a deliverable — it is
   the parity harness against conda-forge's known-good flang 22.1.8.
2. Record here: wall clock, peak RAM, installed size, `ls $PREFIX/bin/*tblgen*`
   (resolves **Q3**).
3. `pixi run build-flang` → `build-flang-rt` → `smoke` → **`abi-probe`**.
   Compare `abi-probe` output against the conda-forge baseline below.
4. Check **Q5** the moment stage 3 exists (two minutes):
   `nm -D --defined-only $PREFIX/lib/libflang_rt.runtime.so | grep -E '_Znwm|_ZdlPv|__cxa_throw'`
5. **Then osx-arm64** — the highest-value target. If stage 3 fights back, read
   the cost observation in [11](11-r-zig-integration.md) before sinking days
   into it.
6. win-64 with the MinGW target (R9), then linux-aarch64, then win-arm64.

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

### Standing fix for this host

The stale 59 GB `.pixi/bld` on the root disk was deleted (reclaimed to 57 GB
free on root). Going forward, on **this host**, stage builds are invoked with
both the package cache and the rattler-build work tree redirected:

```bash
PIXI_CACHE_DIR=/data/gamma/luciorq/workspaces/temp/pixi-cache \
  pixi publish --path packages/llvm-zig --to ./channel \
  --build-dir /data/gamma/luciorq/workspaces/temp/build
```

- `PIXI_CACHE_DIR` redirects pixi/rattler's package + repodata cache (proven via
  `pixi info --extended` — the reported "Cache dir" line changes immediately).
  A `pixi config set -l cache.root <path>` writes the same intent into
  `.pixi/config.toml`, but **does not visibly take effect** in `pixi info`'s
  display — untrusted until verified further, so the env var is what's actually
  relied on.
- `--build-dir` redirects rattler-build's per-package work tree (the multi-GB
  compiled-object directory), which is the dominant disk consumer by far.
- `pixi config set -l detached-environments <path>` also exists (moves
  `.pixi/envs` installs) but was not needed here — those environments are small
  relative to the build tree, and reclaiming the stale `.pixi/bld` alone
  restored enough headroom.
- **Deliberately not committed to `pixi.toml` or `.pixi/config.toml`**: the
  `/data/gamma/...` path is specific to this host. `pixi.toml`'s tasks stay
  portable; the redirect is applied per-invocation on this machine only. If you
  are continuing this project on `gamma`, keep using this pattern (or set
  `PIXI_CACHE_DIR` once for the shell session) until root-disk pressure eases.

**Status:** stage 1 relaunched with the redirect in place, running.  Update
this entry (or add a new one) with the outcome once it lands — do not assume
success from the fact that it stopped erroring on disk space.

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
