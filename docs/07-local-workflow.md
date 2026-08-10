# 07 — Local workflow

## Prerequisites

- `pixi` ≥ 0.75 (`pixi --version`)
- Disk: budget **60 GB**. The llvm-project source tree, an LLVM release build
  tree, three package payloads and the local channel all coexist.
- RAM: 16 GB is workable with the default job caps. Below that, expect OOM in
  stage 2.

## The happy path

```bash
# 0. toolchain sanity — ~10 seconds. Do not skip.
pixi run probe            # unix
pixi run probe-win        # windows

# 1-3. the actual build, hours
pixi run build-llvm
pixi run build-flang
pixi run build-flang-rt
# or: pixi run build-all

# acceptance
pixi run smoke
```

Each stage publishes into `./channel/`, which the next stage reads. Nothing is
uploaded anywhere.

### win-arm64

Cross-only, from a win-64 machine, after the native win-64 build:

```powershell
# first, set llvm_targets_to_build to "X86;AArch64" in
# packages/llvm-zig/recipe/variants.yaml and rebuild the win-64 stage 1 —
# see docs/05-platform-matrix.md
pixi run build-all
pixi run build-all-winarm
```

The win-arm64 packages cannot be tested on the win-64 host; validation needs an
arm64 machine.

## Iterating

**Changing a stage-2 or stage-3 CMake flag** does not require rebuilding stage 1.
Just re-run that stage; it resolves `llvm-zig` out of `./channel`.

**Changing stage 1** invalidates everything downstream. Rebuild all three.

**Rendering a recipe without building it:**

```bash
pixi build --path packages/flang-zig --output-dir /tmp/render 2>&1 | head -50
```

Catches Jinja and variant errors in seconds rather than after a stage-1 build.

**Keeping the build tree between runs** — the single biggest time saver while
debugging a CMake flag:

```bash
pixi publish --path packages/llvm-zig --to ./channel --build-dir .bld
```

**Dropping into a failed build:** `rattler-build debug` reconstructs the build
environment for a recipe so you can run `cmake` by hand:

```bash
pixi run rattler-build debug -r packages/llvm-zig/recipe/recipe.yaml
```

## Inspecting what you built

```bash
# what is in the channel
find channel -name '*.conda'

# unpack a package without installing it
pixi run rattler-build package extract channel/linux-64/llvm-zig-*.conda -o /tmp/x

# how stage 1 was actually configured (version, zig version, projects,
# target list, host triple, C++ runtime)
cat /tmp/x/share/llvm-zig/build-info.txt
```

## Verifying the important properties by hand

```bash
# 1. No libstdc++ / libc++ runtime dependency (ADR-1/ADR-2 hold)
ldd channel-installed-prefix/bin/flang | grep -Ei 'libstdc|libc\+\+' && echo "PROBLEM"

# 2. glibc floor (Linux)
objdump -T <prefix>/bin/flang | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1
# expect <= GLIBC_2.28

# 3. the compiler actually works
<prefix>/bin/flang tests/hello.f90 -o /tmp/hello && /tmp/hello
```

## Disk space on constrained or shared hosts

An LLVM release build tree is genuinely large — stage 1's `.pixi/bld` work
directory reached **113 GB**, and the installed package itself is **42.7 GB**
(9 GB compressed). On a shared machine, or one with a small primary disk, that
can exhaust it outright — this happened during initial bring-up, aborting a
build with SIGABRT (exit 134) purely from disk pressure, not a build failure.
See [10](10-status-log.md) for the full incident.

**`pixi publish`'s `--build-dir` flag does NOT redirect the build backend's
sandbox.** This was tried first and empirically does nothing for
`pixi-build-rattler-build` builds: the `work/`, `bld/`, `artifacts-v0/` etc.
subdirectories still land under `<package>/.pixi/bld/...` regardless of the
flag. (The flag may do something for other backends or for `pixi build`
directly against a `recipe.yaml` — not verified — but do not rely on it here.)
`PIXI_CACHE_DIR` *does* work for the package/repodata download cache (verify
via `pixi info --extended`'s "Cache dir" line) but that cache is small; it is
not the disk-space problem.

**What actually works: replace `<package>/.pixi` with a symlink** to a
directory on the roomy disk, before running that package's first build. This
is filesystem-level and tool-agnostic — it doesn't depend on any build tool
cooperating with an env var or flag:

```bash
mkdir -p /path/on/roomy/disk/pkg-pixi/llvm-zig
mv packages/llvm-zig/.pixi /path/on/roomy/disk/pkg-pixi/llvm-zig   # if it already has data
ln -s /path/on/roomy/disk/pkg-pixi/llvm-zig packages/llvm-zig/.pixi
```

For a package that hasn't been built yet, skip the `mv` and just create the
symlink pointing at an empty directory before the first `pixi publish` /
`pixi build` for that package. Do this **per package** — `packages/flang-zig/.pixi`
and `packages/flang-rt-zig/.pixi` each need their own symlink, they do not
share llvm-zig's.

- Do **not** commit these symlinks or bake a specific host's path into
  `pixi.toml` — `.pixi/` is already gitignored (except `.pixi/config.toml`),
  so the symlink itself never enters version control; it's purely local
  machine state.
- **Do not delete other tenants' data** on a shared host to free space
  (`~/.cache/rattler`, other projects) without checking first — other sessions
  may depend on it. Only remove what you know is yours (your own project's
  `.pixi/bld`, your own scratch environments).
- The root workspace's own `.pixi/` (dev tools: zig-probe, rattler-build) is
  small (~1.5 GB) and not worth relocating.

## Cleaning up

```bash
pixi run clean        # channel/, output/, .pixi/bld
rm -rf .smoke         # throwaway env from the smoke test
```

`pixi run clean` does **not** touch pixi's package cache, so a rebuild re-downloads
nothing.

## When something fails

1. Note which stage, and copy the last ~50 lines of the log into
   [10-status-log.md](10-status-log.md).
2. Check [09](09-risks-and-open-questions.md) — the failure is quite possibly
   already predicted there, with a suggested mitigation.
3. If it is a compiler-flag rejection, re-read the flag-filtering table in
   [03](03-zig-toolchain-reference.md); the zig wrapper drops several flags CMake
   probes for.
4. If it is an OOM, lower `flang_parallel_compile_jobs` /
   `llvm_parallel_link_jobs` in the relevant `variants.yaml` before anything
   else.
