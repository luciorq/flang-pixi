# 14 — Publishing runbook: universe channel on prefix.dev

Decisions made (2026-09-05, user): publish to the existing **`universe`**
channel on prefix.dev (the same one r-zig-pixi publishes R packages to),
**consumer set only** — `lld-zig` + `flang-zig` + `flang-rt-zig` per
platform (~0.1–0.7 GB each). `llvm-zig` stays in the local file:// channels;
it is a build-time-only input needed to rebuild flang itself, not to use it.

## Status: 23.1.1 consumer set PUBLISHED to `universe` (2026-09-18), all six subdirs

What is on the channel — **one line per package, one build number per
release** (the docs/13 rule from 2026-10-06; this generation predates it, so
its "release build" column is empty and the per-subdir numbers are the
declared legacy spread in `scripts/build-alignment.json`). Verify with
`python3 scripts/check-build-alignment.py` (and the GraphQL
`packages(filters:{name:{eq:…}}){variants(includeHidden:true)}` query or
r-zig-pixi's `scripts/prefix-list-packages.sh universe <subdir>`):

| package 23.1.1 | release build (all six) | linux-64 | linux-aarch64 | osx-arm64 | osx-64 | win-64 | win-arm64 |
|---|---|---|---|---|---|---|---|
| lld-zig | — (pre-rule) | `zig_db819e7_1` | `zig_852aba2_0` | `zig_a177b76_4` | `zig_5732dad_4` | `zig_21cbb96_0` | `zig_279c4b1_3` |
| flang-zig | — (pre-rule) | `zig_16e4e22_2` | `zig_8408465_1` | `zig_e52f94e_5` | `zig_705a114_5` | `zig_0ff6bf8_1` | `zig_52d3e10_4` |
| flang-rt-zig | — (pre-rule) | `zig_501841f_9` | `zig_852aba2_9` | `zig_eb63498_9` | `zig_79df4ff_9` | `zig_03d85fb_4` | `zig_1e4a608_7` |

Hotfix notes for this generation (the reason each subdir differs; docs/13
has the mechanism): macOS lld `_4` / flang `_5` and flang-rt `_8` = static
libc++ + floor 11.0 (2026-09-30); flang-rt `_9` on the four unix subdirs =
static-only, hidden runtime (2026-10-01); win-arm64 lld `_3` / flang `_4` /
flang-rt `_7` = `libcompat_arm64.a` (2026-09-19); flang-rt `_5` on
linux-aarch64/osx-64 = cross-build finclude fix. Windows flang-rt was always
static-only and keeps `_4` / `_7`.

**Next release (zig 0.17 wave): lld-zig `_5`, flang-zig `_6`, flang-rt-zig
`_10` on all six subdirs** (llvm-zig `_4`, build-only). After it, this table
has one build string per cell at the same number, the legacy map in
`build-alignment.json` is deleted, and every later per-subdir rebuild is a
declared hotfix (JSON `hotfixes` + a note here).

Exactly 18 files, nothing else (superseded flang-rt `_4`/`_5`/`_8` pruned
2026-10-01 after build 9): every superseded or broken build was deleted with
`scripts/prune-universe.py --apply` (keeps the newest build per subdir of
the three consumer packages; dry run without `--apply`). The current key
has the delete scope.

Lessons from the first publish: `rattler-build upload prefix` prints nothing
on success without `-v`; the channel's `repodata.json` re-indexes
asynchronously (the win subdirs lagged ~30 min and win-arm64 was 404 until
then) — check variants via GraphQL before assuming an upload failed;
uploading from kappa works but is silent, uploading from gamma is
equivalent (copy the files over first, 6.5 MB/s).

### Earlier status (2026-09-17): SUPERSEDED for 22.1.8 (never published); reuse the procedure for 23.x

The `pfx-…` API key is now stored on all three hosts (2026-09-17). The
file lists below are the 22.1.8 generation and must be regenerated for
23.1.1 (`ls channel/<subdir>/*23.1.1*`). The GHA workflow's `publish` job
(docs/08) can do the same upload from artifacts.

### Original status (2026-09-05): staged, BLOCKED on auth

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
