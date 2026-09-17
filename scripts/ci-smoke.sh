#!/usr/bin/env bash
# CI smoke: install flang-zig + flang-rt-zig from a local channel directory
# (rattler-build output layout: <dir>/<subdir>/*.conda + repodata.json) into
# a throwaway env and compile+run every program in tests/. Runs on the
# target's own hardware (incl. windows-11-arm for the cross-built chain).
#
# Usage: scripts/ci-smoke.sh <channel-dir>
set -euo pipefail
chan="$(cd "$1" && pwd)"
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) chan_url="file:///$(cygpath -m "$chan")";; *) chan_url="file://$chan";; esac
ls "$chan"/*/ >/dev/null

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cd "$work"
pixi init . >/dev/null
pixi workspace channel add "$chan_url" --prepend
pixi add flang-zig flang-rt-zig
pixi run flang --version

fail=0
for f in "$root"/tests/*.f90; do
  n="$(basename "$f" .f90)"
  echo "== $n"
  if pixi run flang -O2 "$f" -o "$n" && pixi run "./$n"; then echo "$n: OK"; else echo "$n: FAILED"; fail=1; fi
done
exit $fail
