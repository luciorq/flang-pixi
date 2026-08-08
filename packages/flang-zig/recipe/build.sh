#!/usr/bin/env bash
#
# Stage 2 (unix): standalone LLVM Flang against the stage-1 llvm-zig tree.
#
# Structurally this mirrors conda-forge/flang-feedstock's recipe/build.sh. The
# differences, all deliberate:
#
#   * compilers are $ZIG_CC / $ZIG_CXX, not conda's gcc
#   * BUILD_SHARED_LIBS=OFF, because stage 1 produced static archives (no
#     libLLVM.so — see llvm-zig/recipe/build.sh for why)
#   * LLVM_EXTERNAL_LIT / FLANG_INCLUDE_TESTS are off, so we don't need `lit`
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

FLANG_PARALLEL_COMPILE_JOBS="${FLANG_PARALLEL_COMPILE_JOBS:-2}"

# Sanity: fail immediately and legibly if stage 1 is not actually in the host
# prefix, rather than after CMake has produced a wall of "LLVM_DIR-NOTFOUND".
for f in lib/cmake/llvm/LLVMConfig.cmake \
         lib/cmake/clang/ClangConfig.cmake \
         lib/cmake/mlir/MLIRConfig.cmake; do
  test -f "${PREFIX}/${f}" || {
    echo "ERROR: ${PREFIX}/${f} missing — llvm-zig (stage 1) is not in the host prefix." >&2
    echo "       Did you run 'pixi run build-llvm' and publish it to ./channel?" >&2
    exit 1
  }
done

echo "== stage 1 build info =="
cat "${PREFIX}/share/llvm-zig/build-info.txt" || true

# --- cross compilation -------------------------------------------------------
# Same story as stage 1: flang's build runs tblgen (LLVM's, MLIR's and clang's)
# to generate sources, and those must be build-machine executables.
CMAKE_EXTRA=()
if [[ "${build_platform}" != "${target_platform}" ]]; then
  echo "== cross build: ${build_platform} -> ${target_platform} =="
  case "${target_platform}" in
    linux-*) xsys=Linux ;;  osx-*) xsys=Darwin ;;  win-*) xsys=Windows ;;  *) xsys="" ;;
  esac
  case "${target_platform}" in
    *-64) xproc=x86_64 ;;  *-aarch64) xproc=aarch64 ;;  *-arm64) xproc=arm64 ;;  *) xproc="" ;;
  esac
  CMAKE_EXTRA+=(
    "-DCMAKE_SYSTEM_NAME=${xsys}"
    "-DCMAKE_SYSTEM_PROCESSOR=${xproc}"
    "-DLLVM_NATIVE_TOOL_DIR=${BUILD_PREFIX}/bin"
    "-DLLVM_TABLEGEN=${BUILD_PREFIX}/bin/llvm-tblgen"
    "-DMLIR_TABLEGEN_EXE=${BUILD_PREFIX}/bin/mlir-tblgen"
    "-DCLANG_TABLEGEN=${BUILD_PREFIX}/bin/clang-tblgen"
    "-DLLVM_CONFIG_PATH=${BUILD_PREFIX}/bin/llvm-config"
  )
fi

cmake -G Ninja -S flang -B build \
  ${CMAKE_EXTRA[@]+"${CMAKE_EXTRA[@]}"} \
  -DCMAKE_C_COMPILER="${ZIG_CC}" \
  -DCMAKE_CXX_COMPILER="${ZIG_CXX}" \
  -DCMAKE_ASM_COMPILER="${ZIG_CC}" \
  -DCMAKE_AR="${ZIG_AR}" \
  -DCMAKE_RANLIB="${ZIG_RANLIB}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DCMAKE_PREFIX_PATH="${PREFIX}" \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DCMAKE_MODULE_PATH="${SRC_DIR}/cmake/Modules" \
  -DBUILD_SHARED_LIBS=OFF \
  -DLLVM_DIR="${PREFIX}/lib/cmake/llvm" \
  -DLLVM_CMAKE_DIR="${PREFIX}/lib/cmake/llvm" \
  -DCLANG_DIR="${PREFIX}/lib/cmake/clang" \
  -DMLIR_DIR="${PREFIX}/lib/cmake/mlir" \
  -DFLANG_INCLUDE_RUNTIME=OFF \
  -DFLANG_INCLUDE_TESTS=OFF \
  -DFLANG_INCLUDE_DOCS=OFF \
  -DFLANG_PARALLEL_COMPILE_JOBS="${FLANG_PARALLEL_COMPILE_JOBS}" \
  -DLLVM_PARALLEL_LINK_JOBS=1

# Compile parallelism is capped by FLANG_PARALLEL_COMPILE_JOBS inside the flang
# job pool; the outer -j only governs everything else.
cmake --build build -j "${CPU_COUNT}"
cmake --install build

test -x "${PREFIX}/bin/flang"

# --- driver configuration file ----------------------------------------------
# conda-forge's clangdev writes <target>-flang.cfg so the driver picks up the
# environment's lib dir and (on Linux) the conda sysroot. Do the same, otherwise
# a `flang hello.f90` in an activated env will not find libflang_rt or the
# sysroot's crt objects.
if [[ -n "${CONDA_TOOLCHAIN_HOST:-}" ]]; then
  cfg="${PREFIX}/bin/${CONDA_TOOLCHAIN_HOST}-flang.cfg"
  {
    echo '$-Wl,-L,<CFGDIR>/../lib'
    echo '$-Wl,-rpath,<CFGDIR>/../lib'
    if [[ "${target_platform}" == linux-* ]]; then
      echo '$-Wl,-rpath-link,<CFGDIR>/../lib'
      echo "--sysroot=<CFGDIR>/../${CONDA_TOOLCHAIN_HOST}/sysroot"
    fi
  } > "${cfg}"
  # The driver looks for <triple>-flang.cfg *and* flang.cfg; provide both so it
  # works whether or not the caller passes --target.
  cp "${cfg}" "${PREFIX}/bin/flang.cfg"
fi
