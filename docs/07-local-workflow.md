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

An LLVM release build tree is tens of GB per stage (stage 1 alone was 53 GB and
climbing before finishing, in the one build observed so far — see
[10](10-status-log.md)). On a shared machine, or one with a small primary disk,
that can exhaust it outright — this happened during initial bring-up: the
primary disk filled to 100% with other tenants' data plus this build's own work
tree, aborting the build with SIGABRT (exit 134), not a build failure.

If you hit this, redirect the two things that actually consume space — the
package/repodata cache and the per-package build work tree — to a roomier
disk, without touching `pixi.toml`:

```bash
PIXI_CACHE_DIR=/path/on/roomy/disk/pixi-cache \
  pixi publish --path packages/llvm-zig --to ./channel \
  --build-dir /path/on/roomy/disk/build
```

- `PIXI_CACHE_DIR` is verifiable immediately: `pixi info --extended` should
  report the new path on the "Cache dir" line.
- `--build-dir` keeps rattler-build's work tree (the actual compiled-object
  directory) off the constrained disk. This is the dominant consumer.
- `pixi config set -l detached-environments <path>` (writes to
  `.pixi/config.toml`, gitignored except that one file) additionally relocates
  `.pixi/envs` if those need moving too — smaller than the build tree, usually
  not the bottleneck.
- Do **not** bake a specific host's path into `pixi.toml` or a committed
  `.pixi/config.toml` — it isn't portable. Set the env var per-session, or keep
  a local, uncommitted `.pixi/config.toml` on that machine.
- **Do not delete other tenants' data** on a shared host to free space
  (`~/.cache/rattler`, other projects) without checking first — other sessions
  may depend on it. Only remove what you know is yours (your own project's
  `.pixi/bld`, your own scratch environments).

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
