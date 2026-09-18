#!/usr/bin/env bash
# Smoke: install flang-zig + flang-rt-zig from a channel into a throwaway env
# and compile+link+run every program in tests/ (hello + derived types).
# Runs on the target's own hardware — the GHA test matrix uses it on all six
# runner labels, including linux-aarch64 and win-arm64 which we cannot run
# on the build hosts.
#
# Usage: scripts/ci-smoke.sh <channel> [version]
#   <channel>  a local directory in rattler-build output layout
#              (<dir>/<subdir>/*.conda + repodata.json) or a channel URL
#              such as https://prefix.dev/universe
#   [version]  pin, e.g. 23.1.1 (default: unpinned)
set -euo pipefail
src="$1"; ver="${2:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -d "$src" ]]; then
  chan="$(cd "$src" && pwd)"
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) chan_url="file:///$(cygpath -m "$chan")";; *) chan_url="file://$chan";; esac
else
  chan_url="$src"
fi
pin=""; [[ -n "$ver" ]] && pin="==$ver"
# macOS: flang's Darwin driver needs the SDK to find libSystem at link time
# (else "ld: library 'System' not found"); same resolution as smoke-test.sh.
if [[ "$(uname -s)" == Darwin && -z "${SDKROOT:-}" ]] && command -v xcrun >/dev/null 2>&1; then
  export SDKROOT="$(xcrun --show-sdk-path)"
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cd "$work"
pixi init . >/dev/null
pixi workspace channel add "$chan_url" --prepend
pixi add "flang-zig$pin" "flang-rt-zig$pin"
pixi list | grep -E "flang-zig|flang-rt-zig|lld-zig" || true
pixi run flang --version

fail=0
for f in "$root"/tests/*.f90; do
  n="$(basename "$f" .f90)"
  echo "== $n"
  if pixi run flang -O2 "$f" -o "$n" && pixi run "./$n"; then echo "$n: OK"; else echo "$n: FAILED"; fail=1; fi
done
[[ $fail -eq 0 ]] && echo "SMOKE PASS" || echo "SMOKE FAILED"
exit $fail
