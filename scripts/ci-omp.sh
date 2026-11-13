#!/usr/bin/env bash
# OpenMP check on the target's own hardware: install flang-zig + flang-rt-zig
# (which pulls llvm-openmp, the channel's own zig-built libomp from the same
# recipe, since 23.1.5 build 0) from <channel>, compile
# tests/openmp/*.f90 with -fopenmp and run them with several threads.
# Covers: `!$omp` directives → libomp (all platforms), `use omp_lib` (the
# module flang-rt-zig ships), and on Windows the -lomp/-latomic resolution
# through the shims flang-rt-zig ships. Usage: ci-omp.sh <channel> [version]
set -euo pipefail
src="$1"; ver="${2:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -d "$src" ]]; then
  chan="$(cd "$src" && pwd)"
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) chan_url="file:///$(cygpath -m "$chan")";; *) chan_url="file://$chan";; esac
else chan_url="$src"; fi
pin=""; [[ -n "$ver" ]] && pin="==$ver"
if [[ "$(uname -s)" == Darwin && -z "${SDKROOT:-}" ]] && command -v xcrun >/dev/null 2>&1; then export SDKROOT="$(xcrun --show-sdk-path)"; fi
exe=""; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) exe=".exe";; esac
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cd "$work"
pixi init . >/dev/null
pixi workspace channel add "$chan_url" --prepend
pixi add "flang-zig$pin" "flang-rt-zig$pin"
pixi list | grep -E "flang-rt-zig|llvm-openmp" || true
# The libomp must be ours (llvm-openmp, a zig_* build), not conda-forge's
# same-named package: flang-rt-zig pins `llvm-openmp ==<version> zig_*`
# (build 1; docs/18 §5.4, amended 2026-11-12).
if ! pixi list | awk '$1 == "llvm-openmp" && $3 ~ /^zig_/ {f=1} END {exit !f}'; then echo "llvm-openmp is not the channel's zig_* build"; pixi list | grep llvm-openmp; exit 1; fi
fail=0
for f in "$root"/tests/openmp/*.f90; do
  n="$(basename "$f" .f90)"
  echo "== $n (-fopenmp, OMP_NUM_THREADS=3)"
  if pixi run flang -O2 -fopenmp "$f" -o "$n$exe" && OMP_NUM_THREADS=3 pixi run -- "./$n$exe"; then echo "$n: OK"; else echo "$n: FAILED"; fail=1; fi
done
[[ $fail -eq 0 ]] && echo "OPENMP PASS" || echo "OPENMP FAILED"
exit $fail
