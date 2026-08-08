#!/usr/bin/env bash
#
# Stage 3 (unix): the Fortran runtime, flang-rt.
#
# Mirrors conda-forge/flang-rt-feedstock's recipe/build.sh: configure the
# `runtimes/` directory with LLVM_ENABLE_RUNTIMES=flang-rt and hand it the
# stage-2 flang as CMAKE_Fortran_COMPILER.
#
# CMAKE_Fortran_COMPILER_WORKS=yes is not laziness — CMake's Fortran compiler
# probe tries to *link* a test program, which needs the very runtime we are
# about to build. Without this the configure step deadlocks on itself.
#
set -euxo pipefail

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-${SRC_DIR}/.zig-global-cache}"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}"

: "${ZIG_CC:?zig activation did not run}"
: "${ZIG_CXX:?zig activation did not run}"

unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS \
      DEBUG_CFLAGS DEBUG_CXXFLAGS DEBUG_CPPFLAGS \
      CC CXX AR RANLIB LD NM STRIP 2>/dev/null || true

export CFLAGS="-O2 -fPIC"
export CXXFLAGS="-O2 -fPIC"

MAJOR_VER="${PKG_VERSION%%.*}"

FLANG_BIN="${BUILD_PREFIX}/bin/flang"
test -x "${FLANG_BIN}" || {
  echo "ERROR: ${FLANG_BIN} not found — flang-zig (stage 2) missing from the build prefix." >&2
  exit 1
}
"${FLANG_BIN}" --version

# --- cross compilation -------------------------------------------------------
# Stage 3 is the hardest stage to cross-build: CMAKE_Fortran_COMPILER must be a
# *build-machine* executable that emits *target-machine* code. That works only
# if the build-platform flang was compiled with the target's backend in
# LLVM_TARGETS_TO_BUILD — e.g. cross-building win-arm64 requires the win-64
# stage 1 to have been built with AArch64 enabled, not just Native.
# See docs/05-platform-matrix.md.
CMAKE_EXTRA=()
if [[ "${build_platform}" != "${target_platform}" ]]; then
  echo "== cross build: ${build_platform} -> ${target_platform} =="
  case "${target_platform}" in
    linux-64)      xsys=Linux;   xproc=x86_64;  xtriple=x86_64-conda-linux-gnu ;;
    linux-aarch64) xsys=Linux;   xproc=aarch64; xtriple=aarch64-conda-linux-gnu ;;
    osx-64)        xsys=Darwin;  xproc=x86_64;  xtriple=x86_64-apple-darwin13.4.0 ;;
    osx-arm64)     xsys=Darwin;  xproc=arm64;   xtriple=arm64-apple-darwin20.0.0 ;;
    win-64)        xsys=Windows; xproc=AMD64;   xtriple=x86_64-pc-windows-msvc ;;
    win-arm64)     xsys=Windows; xproc=ARM64;   xtriple=aarch64-pc-windows-msvc ;;
    *)             xsys=""; xproc=""; xtriple="" ;;
  esac
  CMAKE_EXTRA+=(
    "-DCMAKE_SYSTEM_NAME=${xsys}"
    "-DCMAKE_SYSTEM_PROCESSOR=${xproc}"
    "-DCMAKE_Fortran_FLAGS=--target=${xtriple}"
    "-DCMAKE_C_COMPILER_TARGET=${xtriple}"
    "-DCMAKE_CXX_COMPILER_TARGET=${xtriple}"
    "-DLLVM_CONFIG_PATH=${BUILD_PREFIX}/bin/llvm-config"
  )
fi

cmake -G Ninja -S runtimes -B build \
  ${CMAKE_EXTRA[@]+"${CMAKE_EXTRA[@]}"} \
  -DCMAKE_C_COMPILER="${ZIG_CC}" \
  -DCMAKE_CXX_COMPILER="${ZIG_CXX}" \
  -DCMAKE_ASM_COMPILER="${ZIG_CC}" \
  -DCMAKE_AR="${ZIG_AR}" \
  -DCMAKE_RANLIB="${ZIG_RANLIB}" \
  -DCMAKE_Fortran_COMPILER="${FLANG_BIN}" \
  -DCMAKE_Fortran_COMPILER_WORKS=yes \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DCMAKE_PREFIX_PATH="${PREFIX}" \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_MODULE_PATH="${SRC_DIR}/cmake/Modules" \
  -DLLVM_DIR="${PREFIX}/lib/cmake/llvm" \
  -DLLVM_CMAKE_DIR="${PREFIX}/lib/cmake/llvm" \
  -DLLVM_ENABLE_RUNTIMES="flang-rt" \
  -DFLANG_RT_ENABLE_SHARED=ON \
  -DFLANG_RT_ENABLE_STATIC=ON \
  -DFLANG_RT_INCLUDE_TESTS=OFF

cmake --build build -j "${CPU_COUNT}"
cmake --install build

# --- expose the runtime at $PREFIX/lib --------------------------------------
# flang-rt installs into the clang resource dir, at
#   lib/clang/<major>/lib/<target-triple>/libflang_rt.runtime.{a,so}
# The triple in that path is LLVM's own normalised triple, which is NOT the
# conda triple (e.g. `x86_64-unknown-linux-gnu`, not `x86_64-conda-linux-gnu`),
# so glob for it rather than hard-coding — this is exactly the line most likely
# to break when the host triple changes.
rtdir="$(dirname "$(find "${PREFIX}/lib/clang/${MAJOR_VER}/lib" -name 'libflang_rt.runtime.a' -print -quit)")"
test -n "${rtdir}" || { echo "ERROR: could not locate libflang_rt.runtime.a" >&2; exit 1; }
echo "flang-rt installed under: ${rtdir}"

ln -sf "${rtdir}/libflang_rt.runtime.a" "${PREFIX}/lib/libflang_rt.runtime.a"
if [[ -f "${rtdir}/libflang_rt.runtime.so" ]]; then
  ln -sf "${rtdir}/libflang_rt.runtime.so" "${PREFIX}/lib/libflang_rt.runtime.so"
fi
if [[ -f "${rtdir}/libflang_rt.runtime.dylib" ]]; then
  ln -sf "${rtdir}/libflang_rt.runtime.dylib" "${PREFIX}/lib/libflang_rt.runtime.dylib"
fi
