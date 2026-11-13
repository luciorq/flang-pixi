# 14 — Publishing runbook: universe channel on prefix.dev

Decisions made (2026-09-05, user): publish to the existing **`universe`**
channel on prefix.dev (the same one r-zig-pixi publishes R packages to),
**consumer set only** — `lld-zig` + `flang-zig` + `flang-rt-zig` per
platform (~0.1–0.7 GB each), plus `llvm-openmp` (`zig_*` builds) since
23.1.5 (docs/18 §5.4). `llvm-zig` stays in the local file:// channels;
it is a build-time-only input needed to rebuild flang itself, not to use it.

## Status: third aligned release — LLVM 23.1.5 with `llvm-openmp` — build 0 PUBLISHED 2026-11-12; flang-rt-zig / llvm-openmp build 1 (zig_* pin) upload pending

| package 23.1.5 (zig 0.17.0) | release build | linux-64 | linux-aarch64 | osx-arm64 | osx-64 | win-64 | win-arm64 |
|---|---|---|---|---|---|---|---|
| lld-zig | **0** | `zig_88cbac0_0` | `zig_ea2e60d_0` | `zig_58db1ef_0` | `zig_ca035d8_0` | `zig_10a5536_0` | `zig_279c4b1_0` |
| flang-zig | **0** | `zig_8dcaa78_0` | `zig_22c055e_0` | `zig_679338f_0` | `zig_6d949fe_0` | `zig_3effd8f_0` | `zig_52d3e10_0` |
| flang-rt-zig | **1** | `zig_4a37d76_1` | `zig_ea2e60d_1` | `zig_ec1468c_1` | `zig_db81c21_1` | `zig_136e600_1` | `zig_1e4a608_1` |
| llvm-openmp | **1** | `zig_4a37d76_1` | `zig_ea2e60d_1` | `zig_ec1468c_1` | `zig_db81c21_1` | `zig_136e600_1` | `zig_1e4a608_1` |

Retained beside it (`retain` in `scripts/build-alignment.json`): the 36
23.1.1 files of the first and second aligned releases below. Prune dry run
before upload (2026-11-12): keep 0 / retained 36 / delete 0.

Build 1 (2026-11-12, docs/10): flang-rt-zig's run requirement became
`llvm-openmp ==23.1.5 zig_*` because universe's base-channel relation to
conda-forge let conda-forge's libomp win over the `>=` floor in every
channel order. Only flang-rt-zig and llvm-openmp were rebuilt; the build-0
upload commands below are kept as published. Build 1 upload: the same
commands with `flang-rt-zig` / `llvm-openmp` `_1` and without lld-zig /
flang-zig; afterwards prune deletes the 12 `_0` files of those two
packages (no consumer pins them).

### Upload commands (each host uploads its own subdirs; kappa uploads its own, see Cautions)

```bash
# gamma (~/projects/flang-pixi)
rattler-build -v upload prefix --channel universe --skip-existing \
  channel/linux-64/{lld-zig-23.1.5-zig_88cbac0_0,flang-zig-23.1.5-zig_8dcaa78_0,flang-rt-zig-23.1.5-zig_4a37d76_0,llvm-openmp-23.1.5-zig_4a37d76_0}.conda \
  channel/linux-aarch64/{lld-zig-23.1.5-zig_ea2e60d_0,flang-zig-23.1.5-zig_22c055e_0,flang-rt-zig-23.1.5-zig_ea2e60d_0,llvm-openmp-23.1.5-zig_ea2e60d_0}.conda
# omicron (~/rz-fp-2315/flang-pixi; binary ~/.pixi/bin/rattler-build)
~/.pixi/bin/rattler-build -v upload prefix --channel universe --skip-existing \
  channel/osx-arm64/{lld-zig-23.1.5-zig_58db1ef_0,flang-zig-23.1.5-zig_679338f_0,flang-rt-zig-23.1.5-zig_ec1468c_0,llvm-openmp-23.1.5-zig_ec1468c_0}.conda \
  channel/osx-64/{lld-zig-23.1.5-zig_ca035d8_0,flang-zig-23.1.5-zig_6d949fe_0,flang-rt-zig-23.1.5-zig_db81c21_0,llvm-openmp-23.1.5-zig_db81c21_0}.conda
# kappa (C:\Users\admin\rz-fp-2315\flang-pixi; binary C:\Users\admin\.pixi\bin\rattler-build.exe)
rattler-build -v upload prefix --channel universe --skip-existing ^
  channel\win-64\lld-zig-23.1.5-zig_10a5536_0.conda channel\win-64\flang-zig-23.1.5-zig_3effd8f_0.conda channel\win-64\flang-rt-zig-23.1.5-zig_136e600_0.conda channel\win-64\llvm-openmp-23.1.5-zig_136e600_0.conda ^
  channel\win-arm64\lld-zig-23.1.5-zig_279c4b1_0.conda channel\win-arm64\flang-zig-23.1.5-zig_52d3e10_0.conda channel\win-arm64\flang-rt-zig-23.1.5-zig_1e4a608_0.conda channel\win-arm64\llvm-openmp-23.1.5-zig_1e4a608_0.conda
# then, from gamma: prune keeps 24 / retains 36 / deletes 0; alignment says release 0/0/0/0
python3 scripts/prune-universe.py --apply && python3 scripts/check-build-alignment.py && gh workflow run test.yml
```

## Status: second aligned release (zig 0.17 wave) PUBLISHED 2026-10-11 — lld-zig 6 / flang-zig 7 / flang-rt-zig 11 on all six subdirs; universe = these 18 files + the 18 RETAINED 0.16 files below

| package 23.1.1 (zig 0.17.0, LLVM 22 inside zig) | release build | linux-64 | linux-aarch64 | osx-arm64 | osx-64 | win-64 | win-arm64 |
|---|---|---|---|---|---|---|---|
| lld-zig | **6** | `zig_88cbac0_6` | `zig_ea2e60d_6` | `zig_58db1ef_6` | `zig_ca035d8_6` | `zig_10a5536_6` | `zig_279c4b1_6` |
| flang-zig | **7** | `zig_8dcaa78_7` | `zig_22c055e_7` | `zig_679338f_7` | `zig_6d949fe_7` | `zig_3effd8f_7` | `zig_52d3e10_7` |
| flang-rt-zig | **11** | `zig_4a37d76_11` | `zig_ea2e60d_11` | `zig_ec1468c_11` | `zig_db81c21_11` | `zig_136e600_11` | `zig_1e4a608_11` |

(win-arm64 strings are the same for the no-shim rebuild: the shims were
build-script content, not variant inputs.) Retained alongside, never
pruned while r-zig-toolchain pins them (`retain` in
`scripts/build-alignment.json`): the first aligned release below.

Uploaded, pruned and tested by the user on 2026-10-11:
`check-build-alignment.py` → "build alignment OK" (release 6/7/11),
`prune-universe.py` → keep 18 / retained 18 / delete 0, `test.yml` run
38144463412 green on all six native runners.

### Upload commands used for the 0.17 release (template for the next one)

```bash
# gamma
rattler-build -v upload prefix --channel universe --skip-existing \
  channel/linux-64/{lld-zig-23.1.1-zig_88cbac0_6,flang-zig-23.1.1-zig_8dcaa78_7,flang-rt-zig-23.1.1-zig_4a37d76_11}.conda \
  channel/linux-aarch64/{lld-zig-23.1.1-zig_ea2e60d_6,flang-zig-23.1.1-zig_22c055e_7,flang-rt-zig-23.1.1-zig_ea2e60d_11}.conda
# omicron
rattler-build -v upload prefix --channel universe --skip-existing \
  channel/osx-arm64/{lld-zig-23.1.1-zig_58db1ef_6,flang-zig-23.1.1-zig_679338f_7,flang-rt-zig-23.1.1-zig_ec1468c_11}.conda \
  channel/osx-64/{lld-zig-23.1.1-zig_ca035d8_6,flang-zig-23.1.1-zig_6d949fe_7,flang-rt-zig-23.1.1-zig_db81c21_11}.conda
# kappa
rattler-build -v upload prefix --channel universe --skip-existing ^
  channel\win-64\lld-zig-23.1.1-zig_10a5536_6.conda channel\win-64\flang-zig-23.1.1-zig_3effd8f_7.conda channel\win-64\flang-rt-zig-23.1.1-zig_136e600_11.conda ^
  channel\win-arm64\lld-zig-23.1.1-zig_279c4b1_6.conda channel\win-arm64\flang-zig-23.1.1-zig_52d3e10_7.conda channel\win-arm64\flang-rt-zig-23.1.1-zig_1e4a608_11.conda
# then, from gamma: prune must list the 18 retained 0.16 files, alignment must say release 6/7/11
python3 scripts/prune-universe.py --apply && python3 scripts/check-build-alignment.py && gh workflow run test.yml
```

## First aligned release PUBLISHED 2026-10-07 — lld-zig 5 / flang-zig 6 / flang-rt-zig 10 on all six subdirs (RETAINED: r-zig-toolchain pins these exact builds)

One line per package, one build number per release (docs/13 rule). Verify
after upload with `python3 scripts/check-build-alignment.py` (expects the
`release` numbers in `scripts/build-alignment.json`, no legacy map).

| package 23.1.1 | release build (all six) | linux-64 | linux-aarch64 | osx-arm64 | osx-64 | win-64 | win-arm64 |
|---|---|---|---|---|---|---|---|
| lld-zig | **5** | `zig_495485e_5` | `zig_ea2e60d_5` | `zig_1c2e337_5` | `zig_42a4ac4_5` | `zig_21cbb96_5` | `zig_279c4b1_5` |
| flang-zig | **6** | `zig_b4d422a_6` | `zig_22c055e_6` | `zig_3010818_6` | `zig_0257dba_6` | `zig_0ff6bf8_6` | `zig_52d3e10_6` |
| flang-rt-zig | **10** | `zig_3054d59_10` | `zig_ea2e60d_10` | `zig_a7874a2_10` | `zig_e4a4366_10` | `zig_03d85fb_10` | `zig_1e4a608_10` |

Built with zig 0.16.0 (zig_impl build 20 on every host), LLVM 23.1.1;
what changed versus the previous spread: docs/10 2026-10-07. Uploaded,
pruned and tested by the user on 2026-10-07: `check-build-alignment.py` →
"build alignment OK" (release build 5/6/10), `prune-universe.py` → keep 18 /
delete 0, `test.yml` run 37610086141 green on all six native runners. The
pre-rule spread (lld `_1/_0/_4/_4/_0/_3`, flang `_2/_1/_5/_5/_1/_4`,
flang-rt `_9/_9/_9/_9/_4/_7`; hotfix history in docs/13) is gone from the
channel.

**Consumer contract (r-zig-pixi, 2026-10-07):** (1) build strings always
end in `_<build number>` (`zig_<hash>_<N>`, the recipes' `string:` line) —
r-zig-toolchain's recipe pins `flang-zig ==23.1.1 *_6`, `lld-zig ==23.1.1
*_5`, `flang-rt-zig ==23.1.1 *_10` (build-string form: the only pin every
solver parses; pixi/rattler-build reject build-number ranges, libmamba/
micromamba reject `[build_number=…]` brackets). (2) **Release builds a
published r-zig-toolchain pins are never pruned**: they are listed under
`retain` in `scripts/build-alignment.json` and `prune-universe.py` skips
them even after a newer release (their lock broke with 404s when
superseded builds were deleted on 2026-10-01). Remove a set from `retain`
only when r-zig-pixi says no published r-zig-toolchain pins it any more.
Cost: ~6 files / ~0.6 GB kept per retained release on prefix.dev. (3) From
the next release flang-zig pins its own lld-zig by build string
(`lld-zig ==23.1.1 *_<lld build>`), so releases cannot mix.

**Next release after the 0.17 wave: lld-zig `_7`, flang-zig `_8`, flang-rt-zig
`_12`** (llvm-zig `_6`, build-only) — planned as the upstream-zig switch
(docs/19 §6). Hotfixes between releases: declare in `scripts/build-alignment.json`
`hotfixes` and note here.

### Upload commands used for this release (template for the next one)

Every host uploads its own subdirs from its channel directory with the
stored key (`~/.rattler/credentials.json`); `--skip-existing` makes reruns
idempotent; the channel re-indexes asynchronously (check with
`check-build-alignment.py`, which reads the GraphQL variants, not repodata).

```bash
# gamma (/home/luciorq/projects/flang-pixi)
rattler-build -v upload prefix --channel universe --skip-existing \
  channel/linux-64/lld-zig-23.1.1-zig_495485e_5.conda channel/linux-64/flang-zig-23.1.1-zig_b4d422a_6.conda channel/linux-64/flang-rt-zig-23.1.1-zig_3054d59_10.conda \
  channel/linux-aarch64/lld-zig-23.1.1-zig_ea2e60d_5.conda channel/linux-aarch64/flang-zig-23.1.1-zig_22c055e_6.conda channel/linux-aarch64/flang-rt-zig-23.1.1-zig_ea2e60d_10.conda
# omicron (/Users/luciorq/projects/flang-pixi, binary ~/.pixi/bin/rattler-build)
rattler-build -v upload prefix --channel universe --skip-existing \
  channel/osx-arm64/lld-zig-23.1.1-zig_1c2e337_5.conda channel/osx-arm64/flang-zig-23.1.1-zig_3010818_6.conda channel/osx-arm64/flang-rt-zig-23.1.1-zig_a7874a2_10.conda \
  channel/osx-64/lld-zig-23.1.1-zig_42a4ac4_5.conda channel/osx-64/flang-zig-23.1.1-zig_0257dba_6.conda channel/osx-64/flang-rt-zig-23.1.1-zig_e4a4366_10.conda
# kappa (C:\Users\admin\projects\flang-pixi; rattler-build.exe via pixi)
rattler-build -v upload prefix --channel universe --skip-existing ^
  channel\win-64\lld-zig-23.1.1-zig_21cbb96_5.conda channel\win-64\flang-zig-23.1.1-zig_0ff6bf8_6.conda channel\win-64\flang-rt-zig-23.1.1-zig_03d85fb_10.conda ^
  channel\win-arm64\lld-zig-23.1.1-zig_279c4b1_5.conda channel\win-arm64\flang-zig-23.1.1-zig_52d3e10_6.conda channel\win-arm64\flang-rt-zig-23.1.1-zig_1e4a608_10.conda
# then, from gamma
python3 scripts/prune-universe.py --apply && python3 scripts/check-build-alignment.py && gh workflow run test.yml
```

### Previous status (2026-09-18 → 2026-10-06): 23.1.1 pre-rule spread, 18 files

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
