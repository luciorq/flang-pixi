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

# -D_LIBCPP_VERSION=1 (C compiles only — see below) works around an upstream
# flang-rt bug in flang/include/flang/Common/float128.h. That header decides
# whether COMPLEX(16)/REAL(16) support is enabled by checking, among other
# things, `!defined(_LIBCPP_VERSION)` — libc++ is known not to fully support
# __float128 (its own comment: "std::complex<__float128> multiplication ends
# up calling copysign() that is not defined for __float128"), so the intent
# is to disable it whenever building against libc++.
#
# But the header only detects _LIBCPP_VERSION for C++ translation units: it
# is defined by libc++'s own headers, and the file only probes for it behind
# `#ifdef __cplusplus / #include <cstddef>`. flang-rt/lib/runtime/
# complex-reduction.c is a *C* file that also includes float128.h; under a
# libc++ build it wrongly concludes float128 support IS available (zig's
# clang defines __SIZEOF_FLOAT128__ regardless of C++ stdlib) and emits
# CALLS to _FortranACppSumComplex16 / ProductComplex16 / DotProductComplex16
# / ReduceComplex16{Ref,Value} — while the C++ template instantiations
# (sum.cpp, product.cpp, ...) correctly see libc++ and never DEFINE them.
# Result: "undefined symbol: _FortranACppSumComplex16" at the final link,
# only for the .c file, only under libc++. conda-forge never sees this: their
# flang-rt links libstdc++, where _LIBCPP_VERSION is never defined in either
# language, so both sides agree (float128 enabled) with nothing to detect.
#
# Defining _LIBCPP_VERSION for C compiles only (via CFLAGS, not CXXFLAGS)
# makes complex-reduction.c reach the same "disable float128" conclusion the
# C++ side already reaches on its own — restoring upstream's actual intent
# rather than working around it. Grepped the flang/flang-rt tree: this macro
# is checked nowhere else, so the specific value doesn't matter, only that it
# is defined. See docs/10-status-log.md for how this was found.
# -g0: `zig cc`/`zig c++` emit full DWARF debug info by default, independent
# of -O2/-DNDEBUG — see llvm-zig/recipe/build.sh for the full story.
export CFLAGS="-O2 -fPIC -D_LIBCPP_VERSION=1 -g0"
export CXXFLAGS="-O2 -fPIC -g0"

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
else
  # compiler-rt's COMPILER_RT_DEFAULT_TARGET_ONLY=ON (below) hard-requires
  # CMAKE_C_COMPILER_TARGET to be set explicitly, even for a native build —
  # it does not fall back to inferring the target from the host. Same
  # CONDA_TOOLCHAIN_HOST fallback as llvm-zig/flang-zig, since nothing in our
  # toolchain (no conda-forge gcc/clang activation) sets this variable itself.
  if [[ -z "${CONDA_TOOLCHAIN_HOST:-}" ]]; then
    case "${target_platform}" in
      linux-64)       CONDA_TOOLCHAIN_HOST="x86_64-conda-linux-gnu" ;;
      linux-aarch64)  CONDA_TOOLCHAIN_HOST="aarch64-conda-linux-gnu" ;;
      osx-64)         CONDA_TOOLCHAIN_HOST="x86_64-apple-darwin13.4.0" ;;
      osx-arm64)      CONDA_TOOLCHAIN_HOST="arm64-apple-darwin20.0.0" ;;
      *)              CONDA_TOOLCHAIN_HOST="" ;;
    esac
  fi
  if [[ -n "${CONDA_TOOLCHAIN_HOST}" ]]; then
    CMAKE_EXTRA+=(
      "-DCMAKE_C_COMPILER_TARGET=${CONDA_TOOLCHAIN_HOST}"
      "-DCMAKE_CXX_COMPILER_TARGET=${CONDA_TOOLCHAIN_HOST}"
    )
  fi
fi

# macOS: zig links conda-forge's libcxx DYNAMICALLY and injects no LC_RPATH —
# libflang_rt.runtime.dylib needs the rpath or it aborts at load. Same story
# and fix as llvm-zig/flang-zig; libcxx is a host dep on osx in recipe.yaml.
# See docs/10-status-log.md (2026-08-25).
if [[ "${target_platform}" == osx-* ]]; then
  export LDFLAGS="-Wl,-rpath,${PREFIX}/lib"
  CMAKE_EXTRA+=("-DCMAKE_INSTALL_RPATH=${PREFIX}/lib")
  # macOS fd-limit fix — see llvm-zig/flang-zig build.sh.
  ulimit -n 65536 2>/dev/null || ulimit -n 10240 2>/dev/null || ulimit -n 4096 2>/dev/null || true
fi

# CMAKE_BUILD_WITH_INSTALL_RPATH=ON avoids a specific failure mode:
# `packages/<pkg>/.pixi` may be a symlink to a roomier disk (see
# docs/07-local-workflow.md, "Disk space on constrained or shared hosts").
# $PREFIX/$BUILD_PREFIX then refer to the LOGICAL (symlinked) path, but the
# linker can embed the REAL (canonical, post-symlink) path in a binary's
# RUNPATH. At `cmake --install` time, CMake's file(RPATH_CHANGE) does a
# literal byte-for-byte match against the OLD rpath it recorded at configure
# time (the logical path) and fails when the binary's actual embedded rpath
# (the real path) does not match, even though both refer to the identical
# file. Building directly with the install rpath sidesteps the rewrite step
# entirely, since old==new before it would even run. Found via flang-zig's
# stage-2 build failing on `bin/bbc`'s install step with exactly this
# mismatch; see docs/10-status-log.md. Safe here because the build tree's
# bin/../lib layout matches the install prefix's.
# Also build LLVM's compiler-rt runtime here, alongside flang-rt, for one
# reason: flang.exe (a genuine Clang-derived driver, not `zig cc`) does its
# own classic GNU/Linux toolchain probing at RUNTIME — it looks for
# crtbeginS.o/crtendS.o and libgcc/libgcc_s, exactly the way a real GCC
# install would provide them. We have no GCC anywhere in this toolchain by
# design (ADR-1). Found via `pixi run smoke`'s first real link+run:
# "cannot find crtbeginS.o" even after fixing the sysroot dependency.
# compiler-rt built with COMPILER_RT_BUILD_CRT=ON produces LLVM's own
# GCC-independent equivalents (clang_rt.crtbegin.o / clang_rt.crtend.o) and
# libclang_rt.builtins.a (replacing libgcc.a) in the clang resource
# directory, where Clang's driver automatically finds and prefers them once
# `--rtlib=compiler-rt` is passed (added to flang.cfg — see this package's
# effect on flang-zig/recipe/build.sh). The various COMPILER_RT_BUILD_*=OFF
# flags below skip sanitizers/XRay/memprof/profiling/ORC/libFuzzer — none of
# it needed to link a Fortran program, all of it adds build time.
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
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DCMAKE_PREFIX_PATH="${PREFIX}" \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_MODULE_PATH="${SRC_DIR}/cmake/Modules" \
  -DCMAKE_PROJECT_INCLUDE="${RECIPE_DIR}/cmake-project-include.cmake" \
  -DLLVM_DIR="${PREFIX}/lib/cmake/llvm" \
  -DLLVM_CMAKE_DIR="${PREFIX}/lib/cmake/llvm" \
  -DLLVM_ENABLE_RUNTIMES="compiler-rt;flang-rt" \
  -DFLANG_RT_ENABLE_SHARED=ON \
  -DFLANG_RT_ENABLE_STATIC=ON \
  -DFLANG_RT_INCLUDE_TESTS=OFF \
  -DCOMPILER_RT_BUILD_CRT=ON \
  -DCOMPILER_RT_BUILD_BUILTINS=ON \
  -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
  -DCOMPILER_RT_BUILD_XRAY=OFF \
  -DCOMPILER_RT_BUILD_MEMPROF=OFF \
  -DCOMPILER_RT_BUILD_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_ORC=OFF \
  -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
  -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  -DCOMPILER_RT_INCLUDE_TESTS=OFF

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

# --- relocate compiler-rt's CRT objects into the clang resource dir --------
# compiler-rt's own CMake installs clang_rt.crtbegin/crtend and
# libclang_rt.builtins into $PREFIX/lib/<os>/ (a top-level sibling of
# lib/clang/), following its standalone-build default. Clang's driver,
# however, only searches for these files *inside* the resource directory it
# computes from its own binary location — $PREFIX/lib/clang/<major>/lib/<os>/
# — never the top-level path. Left where CMake put them, `--rtlib=compiler-rt`
# (in flang.cfg) finds nothing and flang falls back to looking for GCC's
# crtbeginS.o, which does not exist in this toolchain. Copying (not just
# symlinking, to survive package extraction cleanly) into the resource-dir
# location is what actually makes `--rtlib=compiler-rt` work. Confirmed by
# hand before adding this: manually copying these same files let
# `flang tests/hello.f90` link and run for the first time this session.
crt_src="${PREFIX}/lib/linux"
if [[ -d "${crt_src}" ]]; then
  crt_dst="${PREFIX}/lib/clang/${MAJOR_VER}/lib/linux"
  mkdir -p "${crt_dst}"
  cp -f "${crt_src}"/* "${crt_dst}/"
  echo "compiler-rt CRT objects relocated to: ${crt_dst}"
fi

# Darwin twin of the block above: compiler-rt's builtins install as
# $PREFIX/lib/darwin/libclang_rt.osx.a there (no CRT objects — Mach-O has
# no crtbegin/crtend), and clang's driver searches the resource dir's
# lib/darwin/. Same copy-not-symlink rationale.
crt_src_darwin="${PREFIX}/lib/darwin"
if [[ -d "${crt_src_darwin}" ]]; then
  crt_dst_darwin="${PREFIX}/lib/clang/${MAJOR_VER}/lib/darwin"
  mkdir -p "${crt_dst_darwin}"
  cp -f "${crt_src_darwin}"/* "${crt_dst_darwin}/"
  echo "compiler-rt builtins relocated to: ${crt_dst_darwin}"
fi

# --- strip shared libraries ---------------------------------------------
# -g0 (above) stops DWARF debug info from being generated; static linking is
# not the concern here (this package installs no executables), but the
# shared runtime (libflang_rt.runtime.so) still carries a full ELF symbol
# table. --strip-unneeded (not --strip-all) is the conventional choice for
# .so files: it preserves whatever dlopen()/dynamic-linking machinery needs
# to resolve symbols, only dropping what nothing can reach. Deliberately does
# NOT touch .a or .o files here (libflang_rt.runtime.a,
# libclang_rt.builtins*.a, clang_rt.crtbegin/crtend*.o) — those are linker
# *inputs* for programs built later; stripping their symbols could break
# that linking. See docs/10-status-log.md.
STRIP_BIN="${PREFIX}/bin/llvm-strip"
if [[ -x "${STRIP_BIN}" ]]; then
  echo "== stripping shared libraries with ${STRIP_BIN} =="
  find "${PREFIX}/lib" -name '*.so*' -type f -print0 | while IFS= read -r -d '' f; do
    "${STRIP_BIN}" --strip-unneeded "${f}" 2>/dev/null || true
  done
else
  echo "WARNING: llvm-strip not found at ${STRIP_BIN}, skipping strip pass" >&2
fi
