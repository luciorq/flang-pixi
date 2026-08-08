#!/usr/bin/env bash
#
# Stage 1 (unix): LLVM + MLIR + Clang + LLD, compiled with zig.
#
# READ docs/03-zig-toolchain-reference.md BEFORE EDITING. The three facts that
# drive everything in this file:
#
#   1. The conda-forge zig activation exports ZIG_CC / ZIG_CXX / ZIG_AR /
#      ZIG_RANLIB / ZIG_ASM / ZIG_LLD. It does NOT set CC / CXX. If you do not
#      point CMake at $ZIG_CC yourself, CMake silently finds the system gcc.
#   2. The zig wrappers filter the flags conda's gcc activation normally sets
#      (-march=, -fstack-protector-strong, -fno-plt, -stdlib=, -lgcc_s, ...).
#      Passing conda's stock CFLAGS/CXXFLAGS through is therefore noise at best
#      and misleading at worst. We start from a clean slate.
#   3. zig needs a writable global cache directory or it aborts with
#      AppDataDirUnavailable. The build sandbox may have no HOME.
#
set -euxo pipefail

# --- 3. zig cache ------------------------------------------------------------
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-${SRC_DIR}/.zig-global-cache}"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}"

# --- 1. compiler discovery ---------------------------------------------------
: "${ZIG_CC:?zig activation did not run — is zig_<target_platform> in requirements/build?}"
: "${ZIG_CXX:?zig activation did not run}"
: "${ZIG_AR:?zig activation did not run}"
: "${ZIG_RANLIB:?zig activation did not run}"

echo "== zig toolchain =="
"${ZIG:-zig}" version
echo "ZIG_CC=${ZIG_CC}"
echo "ZIG_CXX=${ZIG_CXX}"

# --- 2. flag hygiene ---------------------------------------------------------
# Drop conda's gcc-shaped flags entirely. Anything we genuinely need we add
# below, explicitly.
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS \
      DEBUG_CFLAGS DEBUG_CXXFLAGS DEBUG_CPPFLAGS \
      CC CXX AR RANLIB LD NM STRIP 2>/dev/null || true

# -fPIC everywhere: stage 2 (flang) and stage 3 (flang-rt) link these static
# archives into shared objects.
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="-O2 -fPIC"

# --- knobs from the recipe ---------------------------------------------------
LLVM_PROJECTS="${LLVM_PROJECTS:-clang;lld;mlir}"
LLVM_TARGETS_TO_BUILD="${LLVM_TARGETS_TO_BUILD:-Native}"
LLVM_PARALLEL_LINK_JOBS="${LLVM_PARALLEL_LINK_JOBS:-1}"

# --- host triple -------------------------------------------------------------
# LLVM bakes its default target triple into the driver. Use the conda triple so
# the produced flang identifies itself consistently with the rest of the
# ecosystem. $CONDA_TOOLCHAIN_HOST is set by conda-forge's stdlib/compiler
# activation; fall back to zig's own idea of the host if it is absent.
if [[ -z "${CONDA_TOOLCHAIN_HOST:-}" ]]; then
  case "${target_platform}" in
    linux-64)       CONDA_TOOLCHAIN_HOST="x86_64-conda-linux-gnu" ;;
    linux-aarch64)  CONDA_TOOLCHAIN_HOST="aarch64-conda-linux-gnu" ;;
    osx-64)         CONDA_TOOLCHAIN_HOST="x86_64-apple-darwin13.4.0" ;;
    osx-arm64)      CONDA_TOOLCHAIN_HOST="arm64-apple-darwin20.0.0" ;;
    *)              CONDA_TOOLCHAIN_HOST="" ;;
  esac
fi

CMAKE_EXTRA=()
if [[ -n "${CONDA_TOOLCHAIN_HOST}" ]]; then
  CMAKE_EXTRA+=(
    "-DLLVM_HOST_TRIPLE=${CONDA_TOOLCHAIN_HOST}"
    "-DLLVM_DEFAULT_TARGET_TRIPLE=${CONDA_TOOLCHAIN_HOST}"
  )
fi

# --- cross compilation -------------------------------------------------------
# LLVM's build generates C++ sources with tblgen, which must run on the BUILD
# machine. LLVM_NATIVE_TOOL_DIR (LLVM 16+) points at prebuilt native tools and
# skips the nested native sub-build entirely. The recipe puts a build-platform
# `llvm-zig` in requirements/build when cross, so $BUILD_PREFIX/bin has them.
if [[ "${build_platform}" != "${target_platform}" ]]; then
  echo "== cross build: ${build_platform} -> ${target_platform} =="
  test -x "${BUILD_PREFIX}/bin/llvm-tblgen" || {
    echo "ERROR: cross build needs a native llvm-zig in \$BUILD_PREFIX." >&2
    echo "       Build and publish llvm-zig for ${build_platform} first." >&2
    exit 1
  }
  # CMAKE_SYSTEM_NAME must be set for CMake to enter cross mode at all.
  case "${target_platform}" in
    linux-*) xsys=Linux ;;
    osx-*)   xsys=Darwin ;;
    win-*)   xsys=Windows ;;
    *)       xsys="" ;;
  esac
  case "${target_platform}" in
    *-64)      xproc=x86_64 ;;
    *-aarch64) xproc=aarch64 ;;
    *-arm64)   xproc=arm64 ;;
    *)         xproc="" ;;
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

# macOS: conda-forge's llvmdev patches AddLLVM.cmake so shared libraries get
# SONAME-style handling like Linux. Keep the same patch here for consistency of
# the installed layout.
if [[ "${target_platform}" == osx-* ]]; then
  sed -i.bak "s/NOT APPLE AND ARG_SONAME/ARG_SONAME/g" llvm/cmake/modules/AddLLVM.cmake
  sed -i.bak "s/NOT APPLE AND NOT ARG_SONAME/NOT ARG_SONAME/g" llvm/cmake/modules/AddLLVM.cmake
fi

# --- configure ---------------------------------------------------------------
#
# Deliberate choices, each with a reason:
#
#   LLVM_BUILD_LLVM_DYLIB=OFF / LLVM_LINK_LLVM_DYLIB=OFF
#       A libLLVM.so built with zig's statically-linked libc++ would be a trap:
#       any downstream conda package linking it with gcc would mis-link. Static
#       archives keep the libc++ ABI sealed inside our own binaries.
#
#   LLVM_ENABLE_RTTI=ON
#       Matches conda-forge and is required by several MLIR/flang consumers.
#
#   LLVM_ENABLE_ZLIB/ZSTD/LIBXML2/TERMINFO/LIBEDIT=OFF
#       Every one of these is an optional dependency flang does not need, and
#       each is one more C library to get linking right through zig on three
#       platforms. Re-enable later, one at a time. See docs/09-risks.md R4.
#
#   LLVM_ENABLE_LIBCXX is intentionally NOT set: it would add `-stdlib=libc++`,
#       which the zig wrapper strips anyway. zig already defaults to its own
#       bundled libc++.
#
#   LLVM_INCLUDE_TESTS=OFF
#       We never run check-llvm here (too slow) — this is unrelated to tblgen
#       installation, which LLVM_INSTALL_UTILS/LLVM_INCLUDE_UTILS govern on
#       their own. Turning tests OFF also sidesteps a real problem: LLVM's
#       test/CMakeLists.txt wires several check-llvm-tools-* targets with a
#       hard add_dependencies() on the llvm-exegesis target regardless of
#       whether it is built, so leaving tests ON while exegesis is OFF (below)
#       fails CMake's generate step outright ("dependency target llvm-exegesis
#       ... does not exist"). Found by running the actual build; see
#       docs/10-status-log.md.
#
#   LLVM_TOOL_LLVM_EXEGESIS_BUILD=OFF
#       llvm-exegesis's SubProcess benchmarking mode references glibc's
#       __rseq_size/__rseq_offset (thread-local rseq registration symbols),
#       which only exist in glibc >= 2.35. Our sysroot pins an older glibc
#       floor on purpose (c_stdlib_version in variants.yaml), so the link
#       fails with "undefined symbol: __rseq_size". llvm-exegesis is a
#       microarchitecture benchmarking tool, irrelevant to building flang —
#       disable it rather than raise the glibc floor for its sake.
#
cmake -G Ninja -S llvm -B build \
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
  -DPython3_EXECUTABLE="${BUILD_PREFIX}/bin/python" \
  -DLLVM_ENABLE_PROJECTS="${LLVM_PROJECTS}" \
  -DLLVM_TARGETS_TO_BUILD="${LLVM_TARGETS_TO_BUILD}" \
  -DLLVM_PARALLEL_LINK_JOBS="${LLVM_PARALLEL_LINK_JOBS}" \
  -DLLVM_ENABLE_RTTI=ON \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF \
  -DLLVM_ENABLE_LIBPFM=OFF \
  -DLLVM_BUILD_LLVM_DYLIB=OFF \
  -DLLVM_LINK_LLVM_DYLIB=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_GO_TESTS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_UTILS=ON \
  -DLLVM_INSTALL_UTILS=ON \
  -DLLVM_UTILS_INSTALL_DIR=libexec/llvm \
  -DCLANG_INCLUDE_TESTS=OFF \
  -DCLANG_INCLUDE_DOCS=OFF \
  -DMLIR_INCLUDE_TESTS=OFF \
  -DMLIR_INCLUDE_DOCS=OFF \
  -DLLD_INCLUDE_TESTS=OFF \
  -DLLVM_TOOL_LLVM_EXEGESIS_BUILD=OFF \
  ${CMAKE_EXTRA[@]+"${CMAKE_EXTRA[@]}"}

# --- build -------------------------------------------------------------------
# CPU_COUNT is set by rattler-build. Compile parallelism is fine; it is the
# *link* steps that blow up memory, and those are throttled above.
cmake --build build -j "${CPU_COUNT}"
cmake --install build

# --- tblgen safety net -------------------------------------------------------
# Stage 2 (standalone flang) needs llvm-tblgen / mlir-tblgen / clang-tblgen to
# exist in $PREFIX/bin. Whether each is installed by default has varied across
# LLVM releases and with LLVM_UTILS_INSTALL_DIR, so copy any that are missing
# rather than discovering it an hour into stage 2.
for tg in llvm-tblgen mlir-tblgen clang-tblgen mlir-linalg-ods-yaml-gen mlir-pdll; do
  if [[ ! -x "${PREFIX}/bin/${tg}" && -x "build/bin/${tg}" ]]; then
    cp "build/bin/${tg}" "${PREFIX}/bin/${tg}"
  fi
done

# --- record how this was built -----------------------------------------------
# Stage 2/3 and future sessions should be able to see the exact configuration
# without re-reading this script.
mkdir -p "${PREFIX}/share/llvm-zig"
{
  echo "llvm_version=${PKG_VERSION}"
  echo "zig_version=$("${ZIG:-zig}" version)"
  echo "llvm_projects=${LLVM_PROJECTS}"
  echo "llvm_targets=${LLVM_TARGETS_TO_BUILD}"
  echo "host_triple=${CONDA_TOOLCHAIN_HOST}"
  echo "cxx_runtime=zig-bundled-libc++ (static)"
} > "${PREFIX}/share/llvm-zig/build-info.txt"
