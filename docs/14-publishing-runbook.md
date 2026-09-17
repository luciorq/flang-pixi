# 14 — Publishing runbook: universe channel on prefix.dev

Decisions made (2026-09-05, user): publish to the existing **`universe`**
channel on prefix.dev (the same one r-zig-pixi publishes R packages to),
**consumer set only** — `lld-zig` + `flang-zig` + `flang-rt-zig` per
platform (~0.1–0.7 GB each). `llvm-zig` stays in the local file:// channels;
it is a build-time-only input needed to rebuild flang itself, not to use it.

## Status: staged, BLOCKED on auth

Everything below was attempted on 2026-09-05 and failed only on
authentication. The `~/.rattler/credentials.json` on gamma/omicron holds a
`*.prefix.dev` **BearerToken** — a download-scoped credential that gets
**HTTP 401** from the upload API; kappa has no prefix.dev entry at all.
Uploads need a real **API key** (`pfx_…`, prefix.dev → Account Settings →
API Keys, write scope on `universe`), supplied as `PREFIX_API_KEY` or
stored via `rattler-build auth login prefix.dev --api-key pfx_…`.
r-zig-pixi's own `scripts/prefix-delete-package.sh` documents the same
BearerToken-vs-API-key distinction. **No pfx_ key exists on any build
host** — get one from the user, place it on all three hosts, rerun.

## Exactly what to upload (current generation, per host)

Every command is `rattler-build upload prefix --channel universe
--skip-existing <files>` run from the channel directory of the named host.

**gamma** (`~/projects/flang-pixi/channel`), the 2.17-floor generation:

```
linux-64/flang-rt-zig-22.1.8-zig_1e79d9a_5.conda
linux-64/flang-zig-22.1.8-zig_a030ffe_5.conda
linux-64/lld-zig-22.1.8-zig_1e79d9a_6.conda
linux-aarch64/flang-rt-zig-22.1.8-zig_11eb1b2_5.conda
linux-aarch64/flang-zig-22.1.8-zig_634dca5_5.conda
linux-aarch64/lld-zig-22.1.8-zig_11eb1b2_6.conda
```

**omicron** (`/Users/luciorq/projects/flang-pixi/channel`, binary
`/Users/luciorq/.pixi/bin/rattler-build`):

```
osx-arm64/flang-rt-zig-22.1.8-zig_d40d935_2.conda
osx-arm64/flang-zig-22.1.8-zig_01c9890_2.conda
osx-arm64/lld-zig-22.1.8-zig_d40d935_4.conda
osx-64/flang-rt-zig-22.1.8-zig_79df4ff_5.conda
osx-64/flang-zig-22.1.8-zig_28cffc0_5.conda
osx-64/lld-zig-22.1.8-zig_79df4ff_6.conda
```

**kappa** (`C:\Users\admin\projects\flang-pixi\channel`, binary
`C:\Users\admin\.pixi\envs\rattler-build\bin\rattler-build.exe`; a ready
launcher exists at `C:\Users\admin\upload-win.bat` driven by the
`uploadwin` scheduled task — refresh its contents if the file list ever
changes):

```
win-64/flang-rt-zig-22.1.8-zig_54cc864_2.conda
win-64/flang-zig-22.1.8-zig_62c4a52_2.conda
win-64/lld-zig-22.1.8-zig_54cc864_4.conda
win-arm64/flang-rt-zig-22.1.8-zig_1e4a608_3.conda
win-arm64/flang-zig-22.1.8-zig_b5fcbbe_3.conda
win-arm64/lld-zig-22.1.8-zig_1e4a608_4.conda
```

Build-number asymmetry is intentional: linux subdirs carry the 2.17-floor
rebuilds (docs/13); osx/win were never affected by the glibc story, so
their validated earlier builds remain current there.

## After upload

1. Verify with r-zig-pixi's `scripts/prefix-list-packages.sh universe
   <subdir>` for all six subdirs.
2. Flip the r-zig-pixi validation worktree's channel from
   `file:///home/luciorq/projects/flang-pixi/channel` to
   `https://prefix.dev/universe`... (universe is already first in its
   channel list — just drop the file:// entry), `pixi update
   flang-zig flang-rt-zig lld-zig`, and re-run `pixi run build` +
   `pixi run check` once as the end-to-end proof that CI machines can
   consume the published toolchain.
3. Note in docs/10.

## Cautions

- kappa cannot reach github (~1 KB/s) but reaches prefix.dev at full
  speed — upload FROM kappa, never route win packages through gamma
  (gamma↔kappa ssh is ~50–110 KB/s; see docs/10 2026-09-03 ops lessons).
- `--skip-existing` makes reruns idempotent.
- Do NOT publish `llvm-zig` without a fresh decision — ~0.8–4 GB per
  subdir, ~10 GB total.
