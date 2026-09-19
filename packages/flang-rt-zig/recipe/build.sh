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

# Explicit glibc floor in the zig target — appended AFTER the blocks above so
# these -D values win (CMake takes the last occurrence). The conda-forge zig
# wrapper's implicit baseline changes between feedstock builds (2.31 in 13 →
# 2.17 in 15); these runtime archives get linked into END USERS' programs
# under whatever zig build is current then, so of the four packages this one
# needs the pinned floor most. Same block in all four; rationale in
# llvm-zig/recipe/build.sh and docs/13.
if [[ "${target_platform}" == linux-* ]]; then
  case "${target_platform}" in
    linux-64)      _zigarch=x86_64 ;;
    linux-aarch64) _zigarch=aarch64 ;;
  esac
  ZIG_GLIBC_FLOOR="${ZIG_GLIBC_FLOOR:-2.17}"
  ZIG_LINUX_ABI_TARGET="${_zigarch}-linux-gnu.${ZIG_GLIBC_FLOOR}"
  CMAKE_EXTRA+=(
    "-DCMAKE_C_COMPILER_TARGET=${ZIG_LINUX_ABI_TARGET}"
    "-DCMAKE_CXX_COMPILER_TARGET=${ZIG_LINUX_ABI_TARGET}"
    "-DCMAKE_ASM_COMPILER_TARGET=${ZIG_LINUX_ABI_TARGET}"
  )
  # NOTE: no CMAKE_Fortran_FLAGS here — the `.2.17` triple suffix is
  # zig-specific syntax; flang gets its (unversioned) target elsewhere.

  # Pre-warm zig's global cache for this target BEFORE CMake runs. The
  # first-ever compile for a new -target builds zig's libc++/glibc stubs;
  # letting that happen inside CMake's compiler-feature detection has
  # (twice) corrupted the generated CMakeCXXCompiler.cmake with interleaved
  # output. One throwaway compile+link takes the cold path out of band.
  echo 'int main(){return 0;}' > "${SRC_DIR}/.zig-warmup.cpp"
  "${ZIG_CXX}" --target="${ZIG_LINUX_ABI_TARGET}" "${SRC_DIR}/.zig-warmup.cpp" \
    -o "${SRC_DIR}/.zig-warmup.out" || true
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
# zig's `ar`/`ranlib` subcommands proved unreliable under Rosetta (osx-64:
# every archive create fails with "unable to open ... No such file or
# directory" while llvm-ar from our own llvm-zig works — docs/10
# 2026-09-04). llvm-zig is in the prefix for this stage anyway; prefer its
# llvm-ar/llvm-ranlib. BUILD_PREFIX first: on cross builds the PREFIX one
# is a foreign-arch binary.
AR_BIN="${ZIG_AR}"; RANLIB_BIN="${ZIG_RANLIB}"
for _p in "${BUILD_PREFIX}" "${PREFIX}"; do
  if [[ -x "${_p}/bin/llvm-ar" ]]; then
    AR_BIN="${_p}/bin/llvm-ar"; RANLIB_BIN="${_p}/bin/llvm-ranlib"; break
  fi
done

cmake -G Ninja -S runtimes -B build \
  ${CMAKE_EXTRA[@]+"${CMAKE_EXTRA[@]}"} \
  -DCMAKE_C_COMPILER="${ZIG_CC}" \
  -DCMAKE_CXX_COMPILER="${ZIG_CXX}" \
  -DCMAKE_ASM_COMPILER="${ZIG_CC}" \
  -DCMAKE_AR="${AR_BIN}" \
  -DCMAKE_RANLIB="${RANLIB_BIN}" \
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

# Cross builds name that triple dir after the BUILD machine (observed:
# linux-aarch64 runtime landing in x86_64-unknown-linux-gnu/ — the binaries
# inside are correct target-arch, only the directory is wrong). The flang
# driver resolves the runtime by the TARGET triple, so rename to it.
case "${target_platform}" in
  linux-64)      _rt_triple=x86_64-unknown-linux-gnu ;;
  linux-aarch64) _rt_triple=aarch64-unknown-linux-gnu ;;
  *)             _rt_triple="" ;;
esac
if [[ -n "${_rt_triple}" && "$(basename "${rtdir}")" != "${_rt_triple}" ]]; then
  _rt_parent="$(dirname "${rtdir}")"
  if [[ ! -e "${_rt_parent}/${_rt_triple}" ]]; then
    mv "${rtdir}" "${_rt_parent}/${_rt_triple}"
    rtdir="${_rt_parent}/${_rt_triple}"
    echo "renamed clang resource dir to target triple: ${rtdir}"
  fi
fi

# --- intrinsic .mod files (LLVM >= 23: installed by flang-rt, not flang) ----
# The runtimes build names lib/clang/<major>/finclude/flang/<triple>/ after
# CMake's idea of LLVM_DEFAULT_TARGET_TRIPLE — the BUILD machine's host triple
# (arm-apple-darwin25.4.0 on omicron, x86_64-... on an aarch64 cross), which
# the driver never matches on macOS or cross builds (docs/10 2026-09-17).
# Rename it to the conda triple, which flang-zig's flang.cfg passes via
# -fintrinsic-modules-path, and keep a link under the driver's exact
# Linux triple so the default lookup works there too.
# The conda triple is derived from target_platform HERE, unconditionally:
# CONDA_TOOLCHAIN_HOST is only set on the native branch above, so on cross
# builds (linux-aarch64) and on a Rosetta build that rattler-build saw as
# cross (osx-64, first build 4) the guard below was silently false, the
# rename and the OpenMP module never happened, and the packages shipped
# unusable (GHA run 35443411628: derived types failed on exactly those
# two subdirs). Must match what flang-zig writes into flang.cfg.
case "${target_platform}" in
  linux-64)      _finc_triple="x86_64-conda-linux-gnu" ;;
  linux-aarch64) _finc_triple="aarch64-conda-linux-gnu" ;;
  osx-64)        _finc_triple="x86_64-apple-darwin13.4.0" ;;
  osx-arm64)     _finc_triple="arm64-apple-darwin20.0.0" ;;
  *) echo "ERROR: no conda triple known for ${target_platform}" >&2; exit 1 ;;
esac
finc="${PREFIX}/lib/clang/${MAJOR_VER}/finclude/flang"
if [[ -d "${finc}" ]]; then
  _finc_src="$(find "${finc}" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  if [[ -n "${_finc_src}" ]]; then
    _finc_dst="${finc}/${_finc_triple}"
    if [[ "${_finc_src}" != "${_finc_dst}" ]]; then
      mv "${_finc_src}" "${_finc_dst}"
      echo "intrinsic modules: $(basename "${_finc_src}") -> ${_finc_triple}"
    fi
    if [[ -n "${_rt_triple:-}" && ! -e "${finc}/${_rt_triple}" ]]; then
      ln -s "${_finc_triple}" "${finc}/${_rt_triple}"
    fi
    test -f "${_finc_dst}/__fortran_type_info.mod" || { echo "ERROR: __fortran_type_info.mod missing in ${_finc_dst}" >&2; exit 1; }

    # --- OpenMP Fortran module (omp_lib / omp_lib_kinds / omp_lib.h) -------
    # conda-forge's llvm-openmp ships libomp + omp.h but no Fortran module,
    # and .mod files are compiler-specific, so we build LLVM's own
    # openmp/module/omp_lib.F90.var with this flang — the same five
    # placeholders openmp/CMakeLists.txt substitutes (major/minor 5.0, spec
    # year-month 201611, build number from kmp_version.cpp, no timestamp).
    # The module is pure bind(c) interfaces onto libomp's stable C ABI, so
    # it works against conda-forge's runtime (run dep). docs/10 2026-09-18.
    _omp_src="${SRC_DIR}/openmp/module"
    _omp_build="$(grep -oE 'KMP_VERSION_BUILD +[0-9]+' "${SRC_DIR}/openmp/runtime/src/kmp_version.cpp" | grep -oE '[0-9]+$')"
    _omp_tmp="$(mktemp -d)"
    for f in omp_lib.F90 omp_lib.h; do
      sed -e "s/@LIBOMP_VERSION_MAJOR@/5/g" -e "s/@LIBOMP_VERSION_MINOR@/0/g" \
          -e "s/@LIBOMP_OMP_YEAR_MONTH@/201611/g" -e "s/@LIBOMP_VERSION_BUILD@/${_omp_build:-20140926}/g" \
          -e "s/@LIBOMP_BUILD_DATE@/No_Timestamp/g" "${_omp_src}/${f}.var" > "${_omp_tmp}/${f}"
    done
    # -fintrinsic-modules-path: use the iso_c_binding etc. we JUST built (in
    # $PREFIX); the build-env flang's own cfg points at $BUILD_PREFIX, where
    # no flang-rt is installed, and a stale/absent module set makes kinds
    # like c_size_t non-interoperable ("A BIND(C) VALUE dummy argument must
    # have an interoperable type" on the first build-4 attempt).
    ( cd "${_omp_tmp}" && "${FLANG_BIN}" -c -fopenmp -fintrinsic-modules-path "${_finc_dst}" omp_lib.F90 -module-dir "${_omp_tmp}" -o omp_lib.o )
    cp "${_omp_tmp}"/omp_lib.mod "${_omp_tmp}"/omp_lib_kinds.mod "${_omp_tmp}"/omp_lib.h "${_finc_dst}/"
    rm -rf "${_omp_tmp}"
    echo "OpenMP Fortran module installed: $(ls "${_finc_dst}" | grep -c omp_lib) files under ${_finc_dst}"
  fi
else
  echo "ERROR: no ${finc} — the intrinsic modules were not installed" >&2; exit 1
fi

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
# Cross builds: PREFIX's llvm-strip is a target-arch binary that cannot run
# here; the native one in BUILD_PREFIX (present only when cross) can strip
# foreign-arch ELFs fine.
[[ -x "${BUILD_PREFIX}/bin/llvm-strip" ]] && STRIP_BIN="${BUILD_PREFIX}/bin/llvm-strip"
if [[ -x "${STRIP_BIN}" ]]; then
  echo "== stripping shared libraries with ${STRIP_BIN} =="
  find "${PREFIX}/lib" -name '*.so*' -type f -print0 | while IFS= read -r -d '' f; do
    "${STRIP_BIN}" --strip-unneeded "${f}" 2>/dev/null || true
  done
else
  echo "WARNING: llvm-strip not found at ${STRIP_BIN}, skipping strip pass" >&2
fi

# Build-time tripwire for zig-feedstock glibc-baseline drift (docs/13): fail
# here, loudly, if anything we ship requires glibc newer than the declared
# floor — not at some future consumer's link.
check_glibc_ceiling() {
  local f="$1" od="" cand ceil
  for cand in "${BUILD_PREFIX}/bin/llvm-objdump" "${PREFIX}/bin/llvm-objdump" objdump; do
    command -v "$cand" >/dev/null 2>&1 && { od="$cand"; break; }
  done
  [[ -z "$od" ]] && { echo "WARNING: no objdump; skipping glibc ceiling check for $f" >&2; return 0; }
  ceil=$("$od" -T "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/^GLIBC_//' | sort -uV | tail -1)
  [[ -z "$ceil" ]] && return 0
  if [[ "$(printf '%s\n' "$ceil" "${ZIG_GLIBC_FLOOR}" | sort -V | tail -1)" != "${ZIG_GLIBC_FLOOR}" ]]; then
    echo "ERROR: $f requires GLIBC_${ceil} > declared floor ${ZIG_GLIBC_FLOOR} — zig baseline drift? see docs/13" >&2
    exit 1
  fi
  echo "glibc ceiling OK: $f (${ceil} <= floor ${ZIG_GLIBC_FLOOR})"
}
if [[ "${target_platform}" == linux-* ]]; then
  ZIG_GLIBC_FLOOR="${ZIG_GLIBC_FLOOR:-2.17}"
  # The real .so lives in the clang resource dir; lib/libflang_rt.runtime.so
  # is a symlink to it (which the -L test skips) — glob both locations.
  for c in "${PREFIX}"/lib/libflang_rt*.so* "${PREFIX}"/lib/clang/*/lib/*/libflang_rt*.so*; do
    [[ -f "$c" && ! -L "$c" ]] && check_glibc_ceiling "$c"
  done
fi

# Record the exact zig toolchain this package was built with — the audit
# trail for zig-feedstock coupling issues (docs/13).
mkdir -p "${PREFIX}/share/flang-rt-zig"
{
  echo "zig_conda_package=$(ls "${BUILD_PREFIX}"/conda-meta/zig*_*.json 2>/dev/null | xargs -rn1 basename | tr '\n' ' ')"
  echo "zig_abi_target=${ZIG_LINUX_ABI_TARGET:-wrapper-default}"
} > "${PREFIX}/share/flang-rt-zig/zig-toolchain.txt"
