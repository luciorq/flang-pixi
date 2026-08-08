#!/usr/bin/env bash
#
# Mixed-toolchain ABI probe: does our flang agree with `zig cc` about calling
# conventions?
#
#   pixi run abi-probe            # after build-all
#
# This is the gate before wiring the compiler into r-zig-pixi. r-zig-pixi did
# the equivalent check for zig+gfortran before committing to that combination
# ("validated by a mixed zig+gfortran ABI test before wiring the build") and it
# is the only cheap way to catch the failure mode that actually matters:
# silently wrong numbers out of LAPACK, with info=0 and no crash.
#
# Passing this does NOT mean the compiler is good — it means it is worth
# spending an R build on. The real bar is r-zig-pixi's `make check` lapack.R.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${root}/.abi-probe"

FLANG="${FLANG:-flang}"
command -v "${FLANG}" >/dev/null 2>&1 || {
  echo "error: '${FLANG}' not on PATH. Install flang-zig first, or set FLANG=." >&2
  exit 1
}
: "${ZIG_CC:?ZIG_CC unset — run inside the zig-probe environment or an env with zig_<platform>}"

rm -rf "${work}"; mkdir -p "${work}"

echo "== toolchain =="
echo "  flang : $(command -v "${FLANG}")"
"${FLANG}" --version | head -2 | sed 's/^/          /'
echo "  zig cc: ${ZIG_CC}"

# --- locate the Fortran runtime ---------------------------------------------
# flang-rt installs into the clang RESOURCE directory, not $PREFIX/lib:
#   $PREFIX/lib/clang/<major>/lib/<llvm-triple>/libflang_rt.runtime.a
# and that directory is not on the default library search path, so a bare
# `-lflang_rt.runtime` fails to link. r-zig-pixi solves this by globbing for it
# and passing an explicit -L (zigbuild/tools/configure-only.sh); we do exactly
# the same, both to work and to stay faithful to how the consumer links.
prefix="${CONDA_PREFIX:-}"
rt=""
if [[ -n "${prefix}" ]]; then
  for f in "${prefix}"/lib/clang/*/lib/*/libflang_rt.runtime.a; do
    [[ -f "${f}" ]] && rt="${f}" && break
  done
fi
if [[ -z "${rt}" ]]; then
  echo "error: libflang_rt.runtime.a not found under ${prefix}/lib/clang — is the runtime installed?" >&2
  exit 1
fi
FLIBS_DIR="$(dirname "${rt}")"
echo "  flang-rt: ${FLIBS_DIR}"

echo
echo "== compiling =="
# Fortran half with flang, C half with zig cc — deliberately different compilers.
( cd "${work}" && "${FLANG}" -O2 -c "${root}/tests/abi/fortran_side.f90" -o fortran_side.o )
( cd "${work}" && "${ZIG_CC}" -O2 -c "${root}/tests/abi/c_side.c" -o c_side.o )

# Link with flang so it drives the link the way R does, with FLIBS supplied
# explicitly exactly as r-zig-pixi's configure does.
# -rpath as well as -L: conda-forge ships both libflang_rt.runtime.a and .so,
# the linker prefers the .so, and the resource directory is not on the default
# loader path either.
( cd "${work}" && "${FLANG}" c_side.o fortran_side.o -o abi_probe \
    -L"${FLIBS_DIR}" -Wl,-rpath,"${FLIBS_DIR}" -lflang_rt.runtime -lm )

echo
echo "== running =="
"${work}/abi_probe"
