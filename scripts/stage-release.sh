#!/usr/bin/env bash
# Stage a generation built on the trusted hosts (gamma / omicron / kappa) as
# a GitHub PRE-RELEASE so the `test` workflow can exercise it on GitHub's
# native runners before anything reaches prefix.dev. Run on gamma.
#
#   scripts/stage-release.sh <version> [tag]        # default tag: staging-<version>-<YYYYMMDD>
#   scripts/stage-release.sh 23.1.1 --dry-run
#
# Collects <subdir>/*-<version>-*.conda from gamma's own channel and from
# omicron:projects/flang-pixi/channel and kappa:C:/Users/admin/projects/flang-pixi/channel
# (ssh config names; agent must be loaded), uploads them as assets named
# <subdir>--<file>.conda (release assets are flat), then prints the
# `gh workflow run` line. Promotion to universe happens from the workflow
# (promote: true) once every platform is green. Delete the pre-release
# afterwards: gh release delete <tag> --yes --cleanup-tag
set -euo pipefail
ver="${1:?version, e.g. 23.1.1}"; shift || true
tag="staging-${ver}-$(date +%Y%m%d)"; dry=0
for a in "$@"; do case "$a" in --dry-run) dry=1 ;; *) tag="$a" ;; esac; done
root="$(cd "$(dirname "$0")/.." && pwd)"
stage="${STAGE_DIR:-/data/gamma/luciorq/workspaces/temp/staging-$tag}"
mkdir -p "$stage"

collect() { # collect <subdir> <local-dir-with-conda-files>
  local sd="$1" dir="$2" n=0
  for f in "$dir"/*-"$ver"-*.conda; do [[ -e "$f" ]] || continue; cp -n "$f" "$stage/${sd}--$(basename "$f")"; n=$((n+1)); done
  echo "  $sd: $n file(s) from $dir"
}
echo "== collecting version $ver into $stage"
for sd in linux-64 linux-aarch64; do collect "$sd" "$root/channel/$sd"; done
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for sd in osx-64 osx-arm64; do
  mkdir -p "$tmp/$sd"; rsync -a --include="*-$ver-*.conda" --exclude="*" "omicron:projects/flang-pixi/channel/$sd/" "$tmp/$sd/" && collect "$sd" "$tmp/$sd"
done
for sd in win-64 win-arm64; do
  mkdir -p "$tmp/$sd"
  for f in $(ssh kappa "dir /b C:\\Users\\admin\\projects\\flang-pixi\\channel\\$sd" | tr -d '\r' | grep -- "-$ver-.*\.conda$"); do
    scp -q "kappa:C:/Users/admin/projects/flang-pixi/channel/$sd/$f" "$tmp/$sd/$f"
  done
  collect "$sd" "$tmp/$sd"
done
ls -la "$stage"
if [[ $dry -eq 1 ]]; then echo "(dry run — nothing uploaded)"; exit 0; fi

if ! gh release view "$tag" >/dev/null 2>&1; then
  gh release create "$tag" --prerelease --title "staging $ver ($tag)" \
    --notes "Untested $ver packages built on gamma/omicron/kappa, staged for the \`test\` workflow. Not for consumption; deleted after promotion."
fi
gh release upload "$tag" "$stage"/*.conda --clobber
echo
echo "staged. Now run:"
echo "  gh workflow run test.yml -f source=release:$tag -f version=$ver"
echo "and, once green:"
echo "  gh workflow run test.yml -f source=release:$tag -f version=$ver -f promote=true"
