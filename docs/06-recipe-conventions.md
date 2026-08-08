# 06 — How the pixi + rattler-build pieces fit together

## Repository layout

```
flang-pixi/
├── pixi.toml                  workspace root — dev tools + task graph, NOT a package
├── channel/                   local conda channel; the stage-to-stage hand-off (gitignored)
├── docs/                      you are here
├── packages/
│   ├── llvm-zig/
│   │   ├── pixi.toml          [package] + [package.build] backend declaration
│   │   └── recipe/
│   │       ├── recipe.yaml    the source of truth for binary dependencies
│   │       ├── variants.yaml  zig_compiler, c_stdlib, tuning knobs
│   │       ├── build.sh       unix
│   │       └── build.bat      windows
│   ├── flang-zig/             same shape, plus hello.f90 for the package test
│   └── flang-rt-zig/          same shape
├── scripts/
│   ├── probe-zig-toolchain.sh    stage 0, unix
│   ├── probe-zig-toolchain.ps1   stage 0, windows
│   └── smoke-test.sh             end-to-end acceptance
├── tests/                     Fortran programs the smoke test compiles and runs
└── .github/workflows/build.yml
```

## Why each package has its own `pixi.toml`

A pixi manifest may declare at most one `[package]`. Three packages therefore
means three manifests. They are driven from the root with
`pixi publish --path packages/<name>`, so from a user's point of view there is
still one entry point.

## The `[package.build]` block

```toml
[workspace]
channels = ["../../channel", "conda-forge"]   # ← build/host deps resolve from here

[package.build]
backend = { name = "pixi-build-rattler-build", version = "0.4.*", channels = ["conda-forge"] }

[package.build.config]
recipe = "recipe/recipe.yaml"
```

- `pixi-build-rattler-build` 0.4.5 is on conda-forge, so no extra backend
  channel is needed.
- The backend looks for a recipe at `package.build.config.recipe`, then
  `recipe.yaml` in the manifest directory, then `recipe/recipe.yaml`. We set it
  explicitly and keep recipes in their own directory, as the docs recommend.

> **The two `channels` keys are not interchangeable.** `backend.channels` is
> only where the *build backend package itself* is fetched from. The recipe's
> own `requirements/build` and `requirements/host` resolve against the
> **`[workspace]` channel list** — which is why `../../channel` belongs there,
> first, so a freshly rebuilt stage wins over anything cached.
>
> A top-level `channels` key directly under `[package.build]` is deprecated;
> pixi warns about it.

`../../channel` is a relative local channel, resolved against the manifest's
directory. Verified working.

## Binary dependencies live in the recipe, not the manifest

This is a hard rule of the backend: *"the rattler-build recipe is the source of
truth for binary dependencies"*. Only workspace **source** dependencies may
appear in the pixi manifest. So `llvm-zig ==22.1.8` is written in
`recipe.yaml`'s `requirements/host`, never in `pixi.toml`'s `[dependencies]`.

## `publish`, not `build`

```
pixi publish --path packages/llvm-zig --to ./channel     # ✅
pixi build   --path packages/llvm-zig -o output          # ❌ for staged builds
```

`pixi build -o DIR` drops a bare `.conda` file into `DIR` — no `<subdir>/`
structure, no `repodata.json`. The next stage cannot resolve a dependency
against that. `pixi publish --to <dir>` builds *and* indexes, producing:

```
channel/
├── noarch/repodata.json
└── linux-64/
    ├── llvm-zig-22.1.8-zig_h….conda
    ├── repodata.json
    └── …
```

`pixi build` remains useful for a one-off "does this recipe render and compile"
check.

## `variants.yaml` is mandatory here, not optional

Every recipe ships one, for two reasons:

1. **`${{ compiler('zig') }}` has no built-in default.** rattler-build resolves
   `compiler('<lang>')` through the `<lang>_compiler` and
   `<lang>_compiler_version` variant keys. It knows defaults for c, cxx,
   fortran, rust and so on — but not zig. Without

   ```yaml
   zig_compiler: [zig]
   zig_compiler_version: ["0.16"]
   ```

   the recipe fails to render. These values mirror
   `conda-forge/zig-feedstock/recipe/variants.yaml`.

2. **`${{ stdlib('c') }}`** needs `c_stdlib` / `c_stdlib_version`, which
   normally come from conda-forge's global pinning file. We are not building
   inside conda-forge's infrastructure, so we declare them ourselves
   (`sysroot` 2.28 on Linux, `macosx_deployment_target` 11.0 on macOS, `vs`
   2022.14 on Windows).

> **Conditional variant values need a list under `then:`.** This form is
> silently ignored — you inherit rattler-build's built-in default with no
> warning:
>
> ```yaml
> c_stdlib_version:
>   - if: linux
>     then: "2.28"          # ✗ scalar — does nothing
> ```
>
> This one works:
>
> ```yaml
> c_stdlib_version:
>   - if: linux
>     then:
>       - "2.28"            # ✓ list
> ```
>
> This actually bit us; see the 2026-08-07 entry in
> [10](10-status-log.md). Verify an override took effect by rendering and
> reading the resolved spec, not by reading the variant file.

`variants.yaml` sitting next to `recipe.yaml` **is** auto-discovered by the
backend — no need to pass `-m`.

Tuning knobs (`llvm_targets_to_build`, `llvm_parallel_link_jobs`,
`flang_parallel_compile_jobs`) also live here, so changing one is a one-line
edit that participates in the build hash.

## Passing variants into build scripts

Variant values are surfaced explicitly through `build.script.env`:

```yaml
build:
  script:
    env:
      LLVM_TARGETS_TO_BUILD: ${{ llvm_targets_to_build }}
    file: build
```

Referencing a variant key in Jinja is also what marks it as a *used variant*, so
it contributes to the build hash — change the target list and you get a distinct
package, as you should.

`file: build` with no extension resolves to `build.sh` on unix and `build.bat`
on Windows automatically.

## Naming conventions

| convention | value | why |
|---|---|---|
| package names | `llvm-zig`, `flang-zig`, `flang-rt-zig` | must never be confused with, or co-solved against, conda-forge's `llvmdev` / `flang` |
| build string | `zig_${{ hash }}_${{ build_number }}` | the `zig_` prefix is a visible warning label in `conda list` |
| version | `22.1.8` for all three | they are one source tree; a version skew between stages is a link error |

## Environment variables available in build scripts

Set by rattler-build: `PREFIX`, `BUILD_PREFIX`, `SRC_DIR`, `RECIPE_DIR`,
`PKG_VERSION`, `PKG_NAME`, `CPU_COUNT`, `target_platform`, `build_platform`, and
on Windows `LIBRARY_PREFIX`, `LIBRARY_BIN`, `LIBRARY_LIB`.

Set by the zig activation: `ZIG`, `ZIG_CC`, `ZIG_CXX`, `ZIG_AR`, `ZIG_RANLIB`,
`ZIG_ASM`, `ZIG_RC`, `ZIG_LLD`, `CONDA_ZIG_BUILD`, `CONDA_ZIG_HOST`.
**Not** `CC` or `CXX` — see [03](03-zig-toolchain-reference.md).
