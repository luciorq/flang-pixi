#!/usr/bin/env bash
# ABI probe in a throwaway env: conda-forge's zig for this platform + our
# flang from <channel>, then scripts/abi-probe.sh (complex*16 returns, hidden
# CHARACTER lengths, by-reference arrays — the mismatches that give silently
# wrong numbers rather than crashes). Unix only: abi-probe.sh drives the zig
# wrapper through ZIG_CC, which the Windows activation spells differently.
#
# Usage: scripts/ci-abi.sh <channel-dir-or-url> <platform> [version]
set -euo pipefail
src="$1"; plat="$2"; ver="${3:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -d "$src" ]]; then chan_url="file://$(cd "$src" && pwd)"; else chan_url="$src"; fi
pin=""; [[ -n "$ver" ]] && pin="==$ver"
case "$plat" in
  linux-64|linux-aarch64|osx-64|osx-arm64) zigpkg="zig_${plat}=0.16.0" ;;
  *) echo "ABI probe: no zig_${plat} package usable here — skipped"; exit 0 ;;
esac
if [[ "$(uname -s)" == Darwin && -z "${SDKROOT:-}" ]] && command -v xcrun >/dev/null 2>&1; then
  export SDKROOT="$(xcrun --show-sdk-path)"
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cd "$work"
pixi init . >/dev/null
pixi workspace channel add "$chan_url" --prepend
extra=""; [[ "$plat" == linux-* ]] && extra="sysroot_${plat}=2.17"
pixi add "flang-zig$pin" "flang-rt-zig$pin" "$zigpkg" $extra
# abi-probe.sh expects ZIG_CC (set by the zig activation inside `pixi run`)
# and flang on PATH.
pixi run bash "$root/scripts/abi-probe.sh"
