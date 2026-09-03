#!/usr/bin/env bash
#
# Stage 1.5 (unix): standalone lld against the stage-1 llvm-zig in $PREFIX
# (HOST dep — resolves for the target platform, which is what makes cross
# builds produce a target-arch lld; see recipe.yaml's header).
#
# Same toolchain rules as llvm-zig/recipe/build.sh (read its header): zig
# exports ZIG_CC/ZIG_CXX (not CC/CXX), wants a writable global cache, and
# emits DWARF by default (hence -g0).
#
set -euxo pipefail

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-${SRC_DIR}/.zig-global-cache}"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}"

: "${ZIG_CC:?zig activation did not run}"
: "${ZIG_CXX:?zig activation did not run}"
: "${ZIG_AR:?zig activation did not run}"
: "${ZIG_RANLIB:?zig activation did not run}"

unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS \
      DEBUG_CFLAGS DEBUG_CXXFLAGS DEBUG_CPPFLAGS \
      CC CXX AR RANLIB LD NM STRIP 2>/dev/null || true

export CFLAGS="-O2 -fPIC -g0"
export CXXFLAGS="-O2 -fPIC -g0"

# llvm-zig lives in $PREFIX (host dep — target-platform archives).
LLVM_CMAKE="${PREFIX}/lib/cmake/llvm"
test -f "${LLVM_CMAKE}/LLVMConfig.cmake" || {
  echo "ERROR: ${LLVM_CMAKE}/LLVMConfig.cmake missing — llvm-zig not in host deps?" >&2
  exit 1
}

CMAKE_EXTRA=()

# Cross: tblgen must run on the BUILD machine — the recipe adds a native
# llvm-zig to requirements/build for exactly this. Native: host's own
# tblgen runs fine (same machine).
if [[ "${build_platform}" != "${target_platform}" ]]; then
  echo "== cross build: ${build_platform} -> ${target_platform} =="
  test -x "${BUILD_PREFIX}/bin/llvm-tblgen" || {
    echo "ERROR: cross build needs a native llvm-zig in \$BUILD_PREFIX." >&2
    exit 1
  }
  case "${target_platform}" in
    linux-*) xsys=Linux ;;  osx-*) xsys=Darwin ;;  win-*) xsys=Windows ;;  *) xsys="" ;;
  esac
  case "${target_platform}" in
    *-64) xproc=x86_64 ;;  *-aarch64) xproc=aarch64 ;;  *-arm64) xproc=arm64 ;;  *) xproc="" ;;
  esac
  CMAKE_EXTRA+=(
    "-DCMAKE_SYSTEM_NAME=${xsys}"
    "-DCMAKE_SYSTEM_PROCESSOR=${xproc}"
    "-DLLVM_TABLEGEN_EXE=${BUILD_PREFIX}/bin/llvm-tblgen"
  )
  STRIP_BIN="${BUILD_PREFIX}/bin/llvm-strip"
else
  CMAKE_EXTRA+=("-DLLVM_TABLEGEN_EXE=${PREFIX}/bin/llvm-tblgen")
  STRIP_BIN="${PREFIX}/bin/llvm-strip"
fi

# macOS: zig links conda-forge's libcxx DYNAMICALLY and injects no LC_RPATH —
# same story and fix as llvm-zig/recipe/build.sh; libcxx is a host dep on osx
# in recipe.yaml. See docs/10-status-log.md (2026-08-25).
if [[ "${target_platform}" == osx-* ]]; then
  export LDFLAGS="-Wl,-rpath,${PREFIX}/lib"
  CMAKE_EXTRA+=("-DCMAKE_INSTALL_RPATH=${PREFIX}/lib")
  # macOS fd-limit fix — see llvm-zig/flang-zig build.sh.
  ulimit -n 65536 2>/dev/null || ulimit -n 10240 2>/dev/null || ulimit -n 4096 2>/dev/null || true
fi

# CMAKE_BUILD_WITH_INSTALL_RPATH=ON: same .pixi-symlink RPATH_CHANGE
# workaround as the other packages — see llvm-zig/recipe/build.sh.
cmake -G Ninja -S lld -B build \
  -DCMAKE_C_COMPILER="${ZIG_CC}" \
  -DCMAKE_CXX_COMPILER="${ZIG_CXX}" \
  -DCMAKE_ASM_COMPILER="${ZIG_CC}" \
  -DCMAKE_AR="${ZIG_AR}" \
  -DCMAKE_RANLIB="${ZIG_RANLIB}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DLLVM_DIR="${LLVM_CMAKE}" \
  -DLLVM_CMAKE_DIR="${LLVM_CMAKE}" \
  -DLLD_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_PARALLEL_LINK_JOBS=1 \
  ${CMAKE_EXTRA[@]+"${CMAKE_EXTRA[@]}"}

cmake --build build -j "${CPU_COUNT}"
cmake --install build

test -x "${PREFIX}/bin/lld"

# lld's install creates the flavor symlinks (ld.lld, ld64.lld, lld-link,
# wasm-ld) — verify the ELF one exists since flang.cfg's -fuse-ld=lld
# resolves through it.
test -e "${PREFIX}/bin/ld.lld"

# --- slimming: binaries only -------------------------------------------------
# lld's install also lays down liblld*.a, include/lld and lib/cmake/lld —
# ~230 MiB that only matters for building things *against* lld's libraries,
# which nobody does at runtime (flang just executes ld.lld). Delete before
# packaging. (These paths are lld-only; the host llvm-zig files alongside
# them are untouched and excluded from the package by rattler anyway.)
rm -f "${PREFIX}"/lib/liblld*.a
rm -rf "${PREFIX}/include/lld" "${PREFIX}/lib/cmake/lld"

# lld's install can materialize the driver aliases (ld.lld, ld64.lld,
# lld-link, wasm-ld) as FULL COPIES instead of symlinks (observed: 5 real
# binaries, 378 MiB, where one 63 MiB binary + 4 symlinks is correct).
# Dedup to symlinks, then strip the single real binary.
for alias in ld.lld ld64.lld lld-link wasm-ld; do
  if [[ -f "${PREFIX}/bin/${alias}" && ! -L "${PREFIX}/bin/${alias}" ]]; then
    rm -f "${PREFIX}/bin/${alias}"
    ln -s lld "${PREFIX}/bin/${alias}"
    echo "deduplicated bin/${alias} -> lld"
  fi
done

# Strip. Cross builds use the native llvm-strip from BUILD_PREFIX (it
# handles foreign-arch binaries fine); native uses the host's own.
if [[ -x "${STRIP_BIN}" ]]; then
  echo "== stripping with ${STRIP_BIN} =="
  "${STRIP_BIN}" --strip-all "${PREFIX}/bin/lld" 2>/dev/null || true
else
  echo "WARNING: llvm-strip not found at ${STRIP_BIN}, skipping strip pass" >&2
fi
