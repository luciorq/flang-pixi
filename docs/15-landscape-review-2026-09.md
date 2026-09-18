# 15 — Landscape review, 2026-09-17: where the project stands, what changed outside it, what is still needed

Written after all six platform chains were built (docs/10) and before the
first publish. Everything external below was measured on 2026-09-17 against
anaconda.org, prefix.dev, GitHub and mac.r-project.org; the local facts come
from the channels on gamma and the r-zig-pixi checkout. Re-verify the
external rows before acting on them if more than a few weeks have passed.

## 1. What this project has actually delivered

*(table rewritten 2026-09-18; the original 22.1.8 assessment is in git history)*

| deliverable | state |
|---|---|
| zig-built llvm-zig / lld-zig / flang-zig / flang-rt-zig, LLVM **23.1.1**, zig **0.16.0** | built for all six subdirs (gamma: linux-64 native + linux-aarch64 cross; omicron: osx-arm64 native + osx-64 Rosetta; kappa: win-64 native + win-arm64 cross) |
| smoke (compile+link+run `tests/*.f90`, incl. derived types) | PASS linux-64, osx-arm64, osx-64, win-64; linux-aarch64 / win-arm64 unrun (no hardware; GHA jobs written) |
| zig-cc ↔ flang ABI probe | PASS linux-64 (23.1.1); osx-arm64 passed at 22.1.8, not yet re-run |
| r-zig-pixi `lapack.R` at -O2 with LAPACK compiled by this flang | PASS **linux-64** (clean rebuild, `flang version 23.1.1` in libRlapack.so) |
| glibc ≤ 2.17 floor, build-time tripwire | enforced on both linux subdirs |
| MinGW-ABI flang for win-64 / win-arm64 | exists; win-arm64 flang-rt is being rebuilt (build 2) for a per-target directory-name bug |
| published to prefix.dev `universe` | consumer set (lld/flang/flang-rt) for all six subdirs uploaded 2026-09-18; win-64/win-arm64 repodata still re-indexing; Windows flang-rt build 2 to follow |
| 22.1.8 generation | never published; deleted from every local channel |

The definition of done (docs/01) now holds on linux-64 for the 23.1.1
generation. The other platforms have a smoke-level proof; the r-zig-pixi
consumer wiring (§2.8) is what turns them into real proofs.

## 2. What changed outside the project since the design was written

### 2.1 conda-forge flang: still no macOS, still no linux-aarch64 — but win-arm64 appeared

`flang` 23.1.1 (2026-09-10/16) is published for **linux-64, win-64,
win-arm64**. win-arm64 was added by flang-feedstock PR #139 (merged
2026-08-29). The recipe still carries `skip: true  # [osx]`, and there is
no linux-aarch64 build. `llvmdev`/`clangdev`/`mlir` 23.1.1 cover every
subdir including win-arm64 and linux-riscv64.

Consequence: the gap this project fills (osx-arm64, osx-64,
linux-aarch64, MinGW-ABI Windows) is unchanged. The conda-forge win-arm64
flang is MSVC-ABI like its win-64 sibling, so it is no more usable for R
than `flang_win-64` was; our cross-built MinGW win-arm64 chain keeps its
reason to exist.

### 2.2 CRAN itself is moving macOS arm64 R to LLVM flang — the strongest external validation we could have asked for

mac.r-project.org/tools now offers an **experimental LLVM flang 23.1.0
build for the arm64 sonoma R-devel** (`flang-23.1.0-darwin23.tar.xz`,
installs to `/opt/R/flang-23`, used via `FC=/opt/R/flang-23/bin/flang`
plus `SDKROOT`). The page says the sonoma build of **R 4.7.0 will likely
use this approach**; released R (4.6) still uses GNU Fortran 14.2, and
CRAN's rule remains "compile packages with the same Fortran compiler R was
built with".

Consequences:

- The osx-arm64 priority in docs/01 is not just r-zig-pixi's local
  miscompile workaround any more; it is the direction R core is taking.
  Once R 4.7 ships with flang, CRAN packages on arm64 macOS will expect a
  flang-compatible Fortran ABI/runtime, which is exactly what flang-zig
  provides in a conda environment.
- For the first time there is a **reference flang on osx-arm64** to diff
  against (module files, `libflang_rt` layout, codegen). docs/01 called
  linux-64 the only parity harness; osx-arm64 now has one too. Worth a
  session on omicron: install CRAN's tarball, build the same test set with
  both compilers, compare `lapack.R` and the ABI probe.
- CRAN is on **flang 23**. So is conda-forge (23.1.1). We are on 22.1.8.

### 2.3 LLVM 23.1.1 is current; we are one major behind

llvmorg-23.1.0 2026-08-25, 23.1.1 2026-09-08. Flang 23 release notes are
quiet on Windows/macOS; the one runtime-visible change is 64-byte
alignment of global/allocatable/pointer arrays. A bump is a full
chain-wide rebuild on all three build hosts (llvm stage ≈ 70 min on
omicron, longer on kappa with its transfer limits) plus re-smoke and
re-validation. Not urgent, but the parity argument (conda-forge's flang
for the linux-64 diff, CRAN's flang for the osx-arm64 diff) now points at
23.

### 2.4 zig: 0.16.0 remains the release; 0.17 exists only as `zig_dev` builds

ziglang.org still lists 0.16.0 (2026-04-13) as latest; 0.17.0 has not
shipped. conda-forge has a stream of `0.17.0` packages but all under the
**`zig_dev` label**, not main. Our exact `0.16.0` pin (docs/13) is right;
do not chase 0.17 until it is a release *and* on the main label.

### 2.5 zig-feedstock 0.16.0 build 17 (2026-09-15): the wrappers were rewritten in C, and every assumption we depend on was re-checked

The shell wrapper quoted in ADR-1 (`_zig-cc-common.sh`) no longer exists;
the dispatcher is now compiled (`recipe/building/zig-cc-unix.c`,
`zig-cc-nonunix.c`, rules in `flag_rules.py`). Re-verified against the
current source:

| assumption | still true? | where |
|---|---|---|
| `-stdlib=` is stripped → cannot link libstdc++ → ADR-1 (build our own LLVM) stands | **yes** | `zig-cc-unix.c:168` |
| wrapper injects its default `-target` only when the caller passes none → our explicit glibc-floored target wins | **yes** | `zig-cc-unix.c` step 10, `zig-cc-nonunix.c` R5 |
| linux default glibc in the baked triple | now **explicitly 2.17** (`c_stdlib_version \| default("2.17")`), matching our floor; riscv64 2.27 | `recipe.yaml` context |
| `zig_win-64` default target | still **`x86_64-windows-msvc`** (`zig_triplet`); the `x86_64-windows-gnu` mapping in `zig_target_triplet` is only used for unhosted cross builds | `recipe.yaml` lines 52-66 vs 122-135 |
| new patch `llvm.zig-triple-no-glibc-version` | strips the glibc version from the *LLVM* triple string zig hands to clang; link-time stub selection is unchanged, so the floor mechanism is intact |
| native `zig_win-arm64` in the win-arm64 subdir | **closed as not planned** (zig-feedstock issue #179, 2026-09-06) → win-arm64 stays cross-only from win-64 |

Net: docs/02, 03, 05 and 13 remain accurate. One thing to keep in mind
for the *next* Windows rebuild: build 17 reworked the MinGW CRT
generation (`_mingw.sh`, arm64 stubs patch). flang-rt-zig ships a
snapshot of that CRT (docs/13, Windows analog), so the win-64/win-arm64
chains should be rebuilt in the same wave whenever they are next touched,
and the aarch64 `wcstold` shim should be re-tested for redundancy rather
than assumed.

### 2.6 "zig as a toolchain" on conda-forge is real but not yet an official compiler axis

The zig-feedstock now publishes a `zig-compiler` metapackage (zig + a C
toolchain) and its maintainer is porting real feedstocks to zig — e.g.
ocaml-feedstock PR #103 "Add win zig port" adds zig as a compiler axis for
the Windows branch and win-arm64 cross from win-64. That PR is still a
draft against an experimental branch; `conda-forge-pinning` has no `zig`
entry and there is no CFEP. So: the ecosystem is moving the way this
project bet, but nothing upstream yet provides what we build (a
libc++-consistent LLVM/flang for zig consumers), and our `-zig` package
names and separate channel remain the right isolation.

### 2.7 gfortran 16.2 is on conda-forge for osx-arm64

r-zig-pixi's `-O1` cap was measured against gfortran 15.2. gfortran
16.2.0 (2026-09-15) and 15.3.0 are now available. Whether the `zgesdd`
miscompile is gone is unknown and cheap to test on omicron (one
`lapack.R` run at -O2). This does **not** change the strategic answer —
CRAN is moving to flang, and one-ABI-everywhere still needs flang — but
it would remove the "correctness" urgency from the macOS row if it passes,
and it is worth knowing.

### 2.8 r-zig-pixi moved under us

Since docs/11 was written r-zig-pixi replaced its autoconf pipeline with a
pure `zig build` (`build.zig`) path and added linux-aarch64 + osx-64
support (commit b8132f7, 2026-09-05). The Fortran dispatch now lives in
`build.zig`'s `fortranOne`: **flang only on linux-x86_64**, gfortran
everywhere else, `-O1` hard-coded on macOS, flang-rt located only on
linux-x86_64 (`findFlangRt`), gfortran's private libdir on the others.
`scripts/env.sh` keeps the `flang` → `flang-new` → `gfortran` probe.

Consequence: publishing flang-zig is necessary but not sufficient.
Consuming it on osx-*/linux-aarch64/win-64 needs r-zig-pixi changes:
a flang branch per platform in `fortranOne` (`-module-dir`, `-O2`),
`findFlangRt` generalised to every platform (the resource-dir path is the
same shape everywhere; on Windows it is under `Library/lib/clang`), and
the link step using `flang_rt.runtime` instead of gfortran's runtime set.
The `flang-zig-validation` worktree is 3 commits behind r-zig-pixi main
and carries uncommitted lock/pixi.toml/verify-bundle changes.

### 2.9 Infrastructure deltas

- `~/.rattler/credentials.json` on gamma was rewritten on 2026-09-17
  08:23 and now holds a `pfx-…` API key (stored under the BearerToken key,
  which is how rattler-build sends it). The prefix.dev GraphQL `viewer`
  query authenticates as `luciorq`, and universe is public and owned by
  that user. **The auth blocker from 2026-09-05 appears cleared on gamma**;
  the key still has to be placed on omicron and kappa.
- gamma root disk: 138 GB free today (was 100% full on 2026-09-04). The
  /data rule still applies.
- pixi 0.81.0 / rattler-build 0.76.1 on gamma (docs say 0.79/0.75).
- The ssh agent is not loaded in this session; omicron and kappa were
  unreachable, so nothing was checked or changed there.
- universe has no `win-arm64` subdir yet (404); the first upload creates it.

## 3. What is still needed, in order

*Update 2026-09-17, later: the user decided to skip publishing 22.1.8
entirely (prefix.dev storage) and go straight to 23.1.1, and to use
GitHub-hosted runners where they fit — see docs/08 and docs/10 for the
resulting plan. Items 1 and 5 below merged into "build, validate and
publish 23.1.1".*

1. **Publish the 22.1.8 consumer set** (lld/flang/flang-rt × 6 subdirs)
   per docs/14. Gamma is unblocked; omicron/kappa need the key. This
   converts a local artefact into something r-zig-pixi CI can solve
   against and is the prerequisite for everything below.
2. **Make r-zig-pixi able to consume it** (§2.8). This is now the
   critical path for the project's actual goal, and it is work in the
   other repository: flang branches in `fortranOne`, cross-platform
   `findFlangRt`, runtime link, then `lapack.R` at -O2 on osx-arm64
   (the target the project exists for), osx-64 (Rosetta on omicron),
   win-64. Until this runs, the macOS deliverable is unproven.
3. **osx-arm64 parity against CRAN's flang 23** (§2.2): same test set,
   both compilers, compare. Cheap once (2) exists.
4. **Hardware validation** for linux-aarch64 and win-arm64. Options:
   qemu-user binfmt on gamma for the aarch64 smoke (no hardware needed
   for a smoke; `lapack.R` would be too slow), a GitHub `ubuntu-24.04-arm`
   runner, or a `windows-11-arm` runner for win-arm64.
5. **Plan the LLVM 23.1.x generation** (§2.3) as the next chain-wide
   rebuild — bundle it with the zig-feedstock build-17 Windows CRT
   refresh (§2.5) so kappa's expensive rebuild is paid once. Do not start
   it before (1)–(2) have proven the 22.1.8 generation end to end;
   a version bump on top of an unproven consumer path doubles the
   unknowns.
6. Test gfortran 16.2 at -O2 on omicron (§2.7) — one run, informational.
7. Upstream r-zig-pixi's verify-bundle glibc-ceiling check and rebase
   the validation worktree.

## 4. What can change

- **docs/01 priority table and docs/11**: rewrite the macOS rationale
  around CRAN's flang move, and record that osx-arm64 now has a reference
  build. Mark linux-64 as "parity harness" still, but note conda-forge is
  on 23.1.1, so a 22.1.8 diff there needs the older conda-forge build
  pinned explicitly.
- **docs/02 ADR-1**: the quoted shell wrapper is gone; point at
  `zig-cc-unix.c` and `flag_rules.py` instead. The decision is unchanged.
- **docs/05 / 09**: win-arm64 "cross only" is now confirmed policy
  upstream (issue #179), not just an observation.
- **README / docs/README banners** still said nothing had been compiled —
  fixed in this session.
- **Package size** (flang-zig 880 MiB installed on linux-64, 1.43 GiB on
  win-64): consumers pull this per environment. Worth a pass before the
  23 generation — strip more aggressively, drop unused MLIR/clang tools
  from flang-zig's payload, and consider whether `lld-zig` can become a
  `bin/`-only package as docs/10 already suggested.
- **Scope questions the user should decide** (not build details):
  publish `llvm-zig` at all (≈10 GB across subdirs; needed only to rebuild
  flang); whether to keep the "no upstream filing" stance now that the
  zig-feedstock maintainer is actively porting feedstocks to zig and would
  likely take drafts 2 and 5 from docs/12; and whether LLVM 23 should be
  the first *published* generation instead of 22.1.8 (recommendation: no —
  publish what is validated, then iterate).

## Sources checked

- anaconda.org package APIs: flang, flang_win-64, flang_win-arm64,
  flang-rt_linux-64, libflang-rt, llvmdev, clangdev, mlir, gfortran,
  gfortran_impl_osx-arm64, zig, zig_linux-64
- github.com/conda-forge/flang-feedstock (recipe/meta.yaml 23.1.1, PR #139)
- github.com/conda-forge/zig-feedstock (recipe.yaml, NOTES.md,
  building/zig-cc-unix.c, zig-cc-nonunix.c, flag_rules.py, _mingw.sh,
  patches/linux/llvm.zig-triple-no-glibc-version.patch, PR #176,
  issue #179)
- github.com/conda-forge/ocaml-feedstock PR #103
- conda-forge-pinning conda_build_config.yaml (no zig)
- mac.r-project.org and mac.r-project.org/tools (flang-23 for R-devel)
- releases.llvm.org 23.1.0 flang release notes; llvm-project releases API
- ziglang.org/download/index.json
- prefix.dev universe repodata (all subdirs) and GraphQL `viewer`/`channel`
- local: r-zig-pixi main (`build.zig`, `pixi.toml`, `TODO.md`), the
  `flang-zig-validation` worktree, `channel/`, `~/.rattler/credentials.json`
