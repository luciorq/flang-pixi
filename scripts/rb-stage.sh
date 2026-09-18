#!/usr/bin/env bash
# Build one package with standalone rattler-build (the ONLY supported build
# path since 2026-09-18 — `pixi publish` ignores variants.yaml, see pixi.toml)
# and copy the result into ./channel/<subdir>.
#
#   scripts/rb-stage.sh <package> [target_platform] [extra rattler-build args...]
#
# Env: RB_OUT   output/work dir (default: $RB_OUT_DEFAULT below; keep it on
#               /data on gamma). Work trees under it are removed on success.
#      RB_TEST  native|skip (default: native, or skip when cross-building)
set -euo pipefail
pkg="${1:?package}"; shift || true
root="$(cd "$(dirname "$0")/.." && pwd)"
host="${RB_BUILD_PLATFORM:-$(pixi info --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["platform"])' 2>/dev/null || true)}"
# RB_BUILD_PLATFORM=osx-64 on an Apple Silicon host = the Rosetta "native"
# osx-64 build (tests run under Rosetta) instead of an arm64->x86_64 cross.
target="${1:-$host}"; [[ $# -gt 0 ]] && shift
[[ -n "$target" ]] || { echo "cannot determine platform; pass it explicitly" >&2; exit 1; }
if [[ "$target" == "$host" ]]; then bp=(); test="${RB_TEST:-native}"; else bp=(--build-platform "$host"); test="${RB_TEST:-skip}"; fi
RB_OUT_DEFAULT="$root/rb-out"; [[ -d /data/gamma/luciorq/workspaces ]] && RB_OUT_DEFAULT=/data/gamma/luciorq/workspaces/temp/rb-out
out="${RB_OUT:-$RB_OUT_DEFAULT}"; mkdir -p "$out"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) chan="file:///$(cygpath -m "$root")/channel";; *) chan="file://$root/channel";; esac
echo "== rattler-build $pkg -> $target (build $host, test=$test, out=$out)"
rattler-build build \
  --recipe "$root/packages/$pkg/recipe/recipe.yaml" \
  --variant-config "$root/packages/$pkg/recipe/variants.yaml" \
  --target-platform "$target" ${bp[@]+"${bp[@]}"} --test "$test" \
  -c "$chan" -c conda-forge --output-dir "$out" "$@"
# Tripwire: the package must not declare a C-stdlib floor above the recipe's
# c_stdlib_version (the class of defect the pixi-publish path shipped).
built=$(ls -t "$out/$target"/${pkg}-*.conda | head -1)
pixi exec --spec "python>=3.14" --spec pyyaml python "$root/scripts/check-stdlib-floor.py" "$root/packages/$pkg/recipe/variants.yaml" "$built"
pixi exec --spec "python>=3.14" python "$root/scripts/publish-crossbuilt.py" "$out/$target" "$root/channel/$target"
rm -rf "$out/bld" "$out/src_cache"
