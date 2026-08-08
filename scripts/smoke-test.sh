#!/usr/bin/env bash
#
# End-to-end check: install the three built packages from ./channel into a
# throwaway prefix and compile + run every program under tests/.
#
#   pixi run smoke
#
# This is the acceptance test for the whole project. Package-level `tests:`
# blocks in the recipes check that files exist and that the driver starts;
# this checks that the toolchain actually produces working Fortran binaries.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chan="${root}/channel"
work="${root}/.smoke"

[[ -d "${chan}" ]] || { echo "No ./channel — run 'pixi run build-all' first." >&2; exit 1; }

rm -rf "${work}"
mkdir -p "${work}"

echo "== creating a throwaway env from ./channel =="
pixi init "${work}" >/dev/null
(
  cd "${work}"
  pixi workspace channel add "file://${chan}" --prepend
  pixi add flang-zig flang-rt-zig
)

fail=0
shopt -s nullglob
for src in "${root}"/tests/*.f90; do
  name="$(basename "${src}" .f90)"
  echo
  echo "== ${name} =="
  if (cd "${work}" && pixi run flang "${src}" -o "${work}/${name}"); then
    if out="$("${work}/${name}")"; then
      printf '%s\n' "${out}" | sed 's/^/  | /'
      echo "  -> PASS"
    else
      echo "  -> FAIL (ran but exited non-zero)"; fail=1
    fi
  else
    echo "  -> FAIL (did not compile/link)"; fail=1
  fi
done

echo
if [[ ${fail} -eq 0 ]]; then echo "smoke test PASSED"; else echo "smoke test FAILED"; fi
exit "${fail}"
