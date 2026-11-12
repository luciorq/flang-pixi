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

# --- zig lib-dir mirror: keep libc++ STATIC on every platform (docs/16) ------
# conda-forge's zig carries `Lld.zig-prefer-shared-libcxx`: any native link
# uses a SHARED libc++ whenever <zig-lib-dir>/../../lib/libc++.{so.1,1.dylib}
# exists — always on macOS (zig_impl_osx-* depends on libcxx), and on Linux
# the moment any host dep drags libcxx in. No flag opts out (-static-libstdc++
# is "unused", -stdlib= is stripped by the wrapper). ZIG_LIB_DIR pointed at a
# real directory of symlinks into zig's lib dir, with no lib/libc++ beside it,
# makes the probe miss and restores zig's bundled static libc++/libc++abi/
# libunwind. Measured on gamma (with libcxx present) and omicron, 2026-09-30.
if [[ "${target_platform}" != win-* ]]; then
  _zig_lib_src="${BUILD_PREFIX}/lib/zig"
  [[ -d "${_zig_lib_src}" ]] || { echo "ERROR: zig lib dir not found at ${_zig_lib_src} (conda layout changed?)" >&2; exit 1; }
  ZIG_LIB_DIR="${SRC_DIR}/zig-libdir-mirror/lib/zig"
  rm -rf "${SRC_DIR}/zig-libdir-mirror"; mkdir -p "${ZIG_LIB_DIR}"
  for _e in "${_zig_lib_src}"/* "${_zig_lib_src}"/.[!.]*; do [[ -e "${_e}" ]] && ln -s "${_e}" "${ZIG_LIB_DIR}/"; done
  export ZIG_LIB_DIR
  # (0.17 feedstock track also probes ../../lib/zig-llvm/lib first — docs/17)
  if [[ -e "${ZIG_LIB_DIR}/../../lib/libc++.1.dylib" || -e "${ZIG_LIB_DIR}/../../lib/libc++.so.1" || -d "${ZIG_LIB_DIR}/../../lib/zig-llvm/lib" ]]; then
    echo "ERROR: ZIG_LIB_DIR mirror still has a libc++ sibling — the static-libc++ trick would not work" >&2; exit 1
  fi
  echo "ZIG_LIB_DIR=${ZIG_LIB_DIR} (static-libc++ mirror of ${_zig_lib_src})"
fi

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
# -fvisibility=hidden (build 9, 2026-10-01): the runtime is static-only now
# and every Fortran .so/.dylib that links it statically used to re-export its
# ~1,100 symbols (docs/16 §3d). Hidden visibility in the objects is the only
# mechanism that works under zig's Mach-O linker (which ignores
# -exported_symbols_list); on ELF it is equivalent to the version script a
# consumer would otherwise need. flang-rt has no option for it, so it is set
# here; compiler-rt's builtins (same runtimes build) already hide theirs.
# -mcpu=baseline: the conda wrapper injects it when absent; written out so the
# scripts also hold with upstream zig (decision 2026-10-10, docs/17 §9).
export CFLAGS="-O2 -fPIC -D_LIBCPP_VERSION=1 -g0 -fvisibility=hidden -mcpu=baseline"
export CXXFLAGS="-O2 -fPIC -g0 -fvisibility=hidden -fvisibility-inlines-hidden -mcpu=baseline"

# Staging outputs get no PKG_NAME / PKG_VERSION from rattler-build (docs/16
# §3c note); the recipe passes the LLVM major as FLANG_RT_MAJOR.
MAJOR_VER="${FLANG_RT_MAJOR:?recipe.yaml sets FLANG_RT_MAJOR for the staging build}"

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
  # macOS floor (docs/16 D4, found 2026-09-30): the conda zig wrapper turns
  # `--target=arm64-apple-darwin20.0.0` into a version-less zig triple, so
  # zig's default (13.0 on 0.16, 15.0 on 0.17 — docs/17) wins over
  # MACOSX_DEPLOYMENT_TARGET and every object
  # of libflang_rt.runtime.a came out `minos 13.0` against a declared 11.0.
  # Only the zig-form triple (`aarch64-macos.11.0-none`) keeps the version,
  # but compiler-rt needs the conda triple in CMAKE_*_COMPILER_TARGET. So:
  # CMake keeps the conda triple, and a two-line shim rewrites that one flag
  # into the zig form before it reaches the wrapper.
  if [[ "${target_platform}" == osx-* ]]; then
    _osx_floor="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    case "${target_platform}" in
      osx-arm64) _zig_mac="aarch64-macos.${_osx_floor}-none" ;;
      *)         _zig_mac="x86_64-macos.${_osx_floor}-none" ;;
    esac
    for _lang in cc cxx; do
      _real="${ZIG_CC}"; [[ "${_lang}" == cxx ]] && _real="${ZIG_CXX}"
      cat > "${SRC_DIR}/zig-${_lang}-mac" <<EOS
#!/usr/bin/env bash
# flang-rt-zig build.sh: --target=${CONDA_TOOLCHAIN_HOST} -> --target=${_zig_mac} (docs/16 D4)
args=(); skip=0
for a in "\$@"; do
  if [[ \$skip == 1 ]]; then skip=0; [[ "\$a" == "${CONDA_TOOLCHAIN_HOST}" ]] && a="${_zig_mac}"; args+=("\$a"); continue; fi
  case "\$a" in
    --target=${CONDA_TOOLCHAIN_HOST}) a="--target=${_zig_mac}" ;;
    -target) skip=1 ;;
  esac
  args+=("\$a")
done
exec "${_real}" "\${args[@]}"
EOS
      chmod +x "${SRC_DIR}/zig-${_lang}-mac"
    done
    ZIG_CC="${SRC_DIR}/zig-cc-mac"; ZIG_CXX="${SRC_DIR}/zig-cxx-mac"
    echo "macOS: ${CONDA_TOOLCHAIN_HOST} -> ${_zig_mac} via ${ZIG_CC} (floor ${_osx_floor})"
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

# macOS: rpath to $PREFIX/lib as on the other stages (zig injects no
# LC_RPATH). libc++ is static since 2026-09-30 (ZIG_LIB_DIR mirror, docs/16).
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

# libomp's own flags (it builds inside the runtimes build below; the
# libomp section after `cmake --install` says why each option is set).
# Default visibility for libomp alone: see there.
OMP_CXXFLAGS="-fvisibility=default"
OMP_LDFLAGS=""
if [[ "${target_platform}" == osx-* ]]; then
  # kmp_wrapper_getpid.h includes <sys/syscall.h> on every Unix; zig's
  # bundled Darwin headers (used with the explicit zig target above) lack it,
  # and Darwin's libomp uses nothing from it (__kmp_gettid is
  # pthread_mach_thread_np). An empty stub, found by the prototype
  # cross-build 2026-11-11 (docs/10).
  mkdir -p "${SRC_DIR}/omp-darwin-stub/sys"; : > "${SRC_DIR}/omp-darwin-stub/sys/syscall.h"
  OMP_CXXFLAGS="${OMP_CXXFLAGS} -I${SRC_DIR}/omp-darwin-stub"
  # zig's own Mach-O linker exports ___dso_handle from every dylib, and a
  # dylib exporting it breaks Apple ld's link of an archive's static
  # initializer on the same line (docs/16 §3d) — `flang -fopenmp` with
  # libflang_rt.runtime.a and -lomp. conda-forge's zig honours -fuse-ld=lld
  # for Mach-O (docs/16 D7) and lld keeps ___dso_handle private, but
  # ld64.lld finds libSystem only in the SDK ("library not found for
  # -lSystem" without it). Measured on omicron 2026-11-11 (zig 0.17.0 _6):
  # zig's linker exports ___dso_handle, lld + -L$SDK/usr/lib does not, and
  # the dylib keeps minos 11.0 and loads libSystem only. The tripwire at the
  # end of this script checks the result.
  _omp_sdk="${SDKROOT:-$(xcrun --show-sdk-path 2>/dev/null || true)}"
  [[ -n "${_omp_sdk}" && -d "${_omp_sdk}/usr/lib" ]] || { echo "ERROR: no macOS SDK (SDKROOT / xcrun) for libomp's lld link" >&2; exit 1; }
  OMP_LDFLAGS="-fuse-ld=lld -L${_omp_sdk}/usr/lib"
fi

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
  -DLLVM_ENABLE_RUNTIMES="compiler-rt;flang-rt;openmp" \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DOPENMP_ENABLE_TESTING=OFF \
  -DOPENMP_INSTALL_LIBDIR=lib \
  -DOPENMP_ENABLE_LIBOMPTARGET=OFF \
  -DOPENMP_ENABLE_OMPT_TOOLS=OFF \
  -DLIBOMP_OMPD_SUPPORT=OFF \
  -DLIBOMP_USE_HWLOC=OFF \
  -DLIBOMP_INSTALL_ALIASES=OFF \
  "-DLIBOMP_CXXFLAGS=${OMP_CXXFLAGS}" \
  "-DLIBOMP_LDFLAGS=${OMP_LDFLAGS}" \
  -DFLANG_RT_ENABLE_SHARED=OFF \
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

# --- libomp: the llvm-openmp output's files (docs/18 §5) ------------------
# The runtimes build's `openmp` (23.1.5 build 0; LLVM 23 has no standalone
# libomp build any more). Options above, and why:
#   OPENMP_INSTALL_LIBDIR=lib   $PREFIX/lib/libomp.so, as conda-forge's, not a
#                               per-target lib/<triple>/ dir;
#   LIBOMP_CXXFLAGS=-fvisibility=default   libomp's sources come after the
#       global CXXFLAGS on each compile line, so this undoes flang-rt's
#       -fvisibility=hidden for libomp alone: on Linux its exports come from
#       exports_so.txt (a version script cannot export a hidden symbol) and
#       on macOS from default visibility (zig's Mach-O linker ignores
#       export lists), so a hidden libomp would export nothing there;
#   OMPT tools, OMPD, libomptarget, hwloc off: conda-forge's libarcher and
#       libompd are omitted (nothing in R uses them; docs/18 §5.3 item 4);
#   LIBOMP_INSTALL_ALIASES=OFF: upstream's aliases are libgomp + libiomp5,
#       and a libgomp here would shadow GCC's real libgomp. conda-forge
#       ships only the libiomp5 alias (lib/libiomp5.so, lib/libiomp5.dylib):
#       made below.
# The quad-precision atomics (__kmpc_atomic_*cmplx16*, *_fp) that
# conda-forge's GCC-built Linux libomp exports are absent: libomp enables
# them for GCC and Intel compilers only (kmp_os.h, KMP_HAVE_QUAD), and only
# Intel compilers call them. Measured 2026-11-11: exports 1,202 vs 1,385
# (linux-64), 1,092 vs 1,173 (linux-aarch64), the difference is exactly
# those entry points; symbol-version nodes OMP_1.0 … OMP_6.0 and
# GOMP_1.0 … GOMP_5.0.1 match.
case "${target_platform}" in
  osx-*) _omp_lib="${PREFIX}/lib/libomp.dylib" ;;
  *)     _omp_lib="${PREFIX}/lib/libomp.so" ;;
esac
test -f "${_omp_lib}" || { echo "ERROR: ${_omp_lib} was not installed (openmp runtime)" >&2; find "${PREFIX}" -name 'libomp*' >&2; exit 1; }
# omp.h etc. go to include/ when the runtimes build sees no LLVM tree, to the
# clang resource dir's include/ otherwise; consumers (zig cc -fopenmp,
# r-zig-pixi) read $PREFIX/include, as with conda-forge's package.
for _h in omp.h ompx.h omp-tools.h ompt.h; do
  if [[ ! -f "${PREFIX}/include/${_h}" ]]; then
    _hsrc="$(find "${PREFIX}/lib/clang" -path "*/include/${_h}" -print -quit 2>/dev/null || true)"
    [[ -n "${_hsrc}" ]] || { echo "ERROR: ${_h} was not installed (openmp runtime)" >&2; exit 1; }
    mkdir -p "${PREFIX}/include"; mv "${_hsrc}" "${PREFIX}/include/${_h}"
  fi
done
rm -f "${PREFIX}"/lib/libgomp* "${PREFIX}"/lib/libiomp5*
case "${target_platform}" in
  linux-*) ln -s libomp.so "${PREFIX}/lib/libiomp5.so" ;;
  osx-*)   ln -s libomp.dylib "${PREFIX}/lib/libiomp5.dylib" ;;
esac

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
    # Built by the runtimes build's openmp/module with this flang and the
    # intrinsic modules just built (flang_module_target), installed beside
    # them; until 23.1.1 build 11 this script compiled omp_lib.F90.var by hand
    # with guessed version values (5.0 / 201611). Check it is there.
    for _m in omp_lib.mod omp_lib_kinds.mod omp_lib.h; do
      test -f "${_finc_dst}/${_m}" || { echo "ERROR: ${_m} missing in ${_finc_dst} (openmp/module did not build: LIBOMP_FORTRAN_MODULES?)" >&2; exit 1; }
    done
    echo "OpenMP Fortran module present under ${_finc_dst}"
  fi
else
  echo "ERROR: no ${finc} — the intrinsic modules were not installed" >&2; exit 1
fi

# Static-only since build 9 (FLANG_RT_ENABLE_SHARED=OFF): a shared runtime
# beside the archive made `-lflang_rt.runtime` pick the .dylib on macOS
# (packages then loaded only inside the build env) and made Apple's ld fail
# to link the archive at all when the dylib was on the search path
# (zig-built dylibs export ___dso_handle). docs/16 §3c-§3d, docs/10
# 2026-10-01. Only the archive gets the lib/ convenience symlink.
ln -sf "${rtdir}/libflang_rt.runtime.a" "${PREFIX}/lib/libflang_rt.runtime.a"

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
# Since build 9 there is no shared runtime, so this pass finds nothing of
# ours; kept because compiler-rt may still install .so files on some
# configurations. Original rationale: -g0 (above) stops DWARF debug info
# from being generated, but a shared library still carries a full ELF symbol
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
  for c in "${PREFIX}"/lib/libflang_rt*.so* "${PREFIX}"/lib/clang/*/lib/*/libflang_rt*.so* "${PREFIX}/lib/libomp.so"; do
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

# --- tripwires (docs/18 §6.6, docs/16): load-time deps = libc only; macOS floor kept
# Fail here, not at a consumer's load: (1) every ELF / Mach-O under $PREFIX
# may depend on the C library and the loader ONLY — an allowlist, so a shared
# libc++/libstdc++ (the zig-feedstock shared-libc++ preference, if the
# ZIG_LIB_DIR mirror above stopped working), zlib, libxml2, libomp or anything
# else fails the build (positive form of the contract since 2026-10-06;
# measured clean on all 18 published files); (2) on
# macOS every Mach-O, archive members included, must be built for at most
# MACOSX_DEPLOYMENT_TARGET (flang-rt-zig shipped minos 13.0 against a declared
# 11.0 floor until 2026-09-30 because the conda wrapper drops the version when
# it translates a conda triple).
_tw_fail() { echo "ERROR: $*" >&2; exit 1; }
if [[ "${target_platform}" == linux-* ]]; then
  # Allowlist (docs/18 §6.6): glibc's own libraries and the loader, nothing
  # else. librt/libresolv/libutil are the pre-2.34 split libraries the 2.17
  # target links; they are glibc too. Measured clean on all 18 published
  # files (2026-10-06) before this became the rule.
  _tw_allow_elf='^(libc|libm|libdl|libpthread|librt|libresolv|libutil)\.so\.[0-9]+$|^ld-linux[-a-z0-9_]*\.so\.[0-9]+$'
  _tw_od=""; for _c in "${BUILD_PREFIX}/bin/llvm-objdump" "${PREFIX}/bin/llvm-objdump" objdump; do command -v "${_c}" >/dev/null 2>&1 && { _tw_od="${_c}"; break; }; done
  if [[ -n "${_tw_od}" ]]; then
    _tw_n=0
    while IFS= read -r -d '' _f; do
      # Shared libraries under $PREFIX/lib may also need SIBLINGS shipped in
      # the same lib dir (llvm-zig's MLIR runner libraries load each other);
      # executables stay libc-only. First seen on the 2026-10-06 release.
      _needed=$("${_tw_od}" -p "${_f}" 2>/dev/null | awk '/^ *NEEDED/{print $2}' | grep -v -E "${_tw_allow_elf}" | while read -r _n; do [[ "${_f}" == "${PREFIX}/lib/"* && -e "${PREFIX}/lib/${_n}" ]] || echo "${_n}"; done || true)
      [[ -n "${_needed}" ]] && _tw_fail "${_f} needs a library outside the libc allowlist: $(echo ${_needed} | tr '\n' ' ') — docs/18 §6.6 (a shared libc++/libstdc++ here means the ZIG_LIB_DIR mirror stopped working, docs/16)"
      _tw_n=$((_tw_n+1))
    done < <(find "${PREFIX}/bin" "${PREFIX}/lib" -type f \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null)
    echo "load-dep allowlist OK: ${_tw_n} ELF files, glibc + loader only (docs/18 §6.6)"
  else
    echo "WARNING: no objdump; skipping the load-dep allowlist tripwire" >&2
  fi
elif [[ "${target_platform}" == osx-* ]]; then
  _tw_floor="${MACOSX_DEPLOYMENT_TARGET:-11.0}"; _tw_n=0
  _tw_allow_macho='^/usr/lib/libSystem\.B\.dylib$'
  command -v otool >/dev/null 2>&1 || _tw_fail "otool not found; cannot run the Mach-O tripwire"
  while IFS= read -r -d '' _f; do
    file "${_f}" 2>/dev/null | grep -qE 'Mach-O|ar archive' || continue
    # Allowlist (docs/18 §6.6): only libSystem may be loaded. LC_LOAD_* and
    # LC_REEXPORT_DYLIB are counted; a dylib's own LC_ID_DYLIB is not.
    # Dylibs under $PREFIX/lib may load SIBLINGS from the same dir via @rpath
    # (llvm-zig's MLIR runner dylibs do); executables stay libSystem-only.
    _loads=$(otool -l "${_f}" 2>/dev/null | awk '/LC_(LOAD|LOAD_WEAK|REEXPORT|LAZY_LOAD|LOAD_UPWARD)_DYLIB/{c=1} c&&/ name /{print $2; c=0}' | grep -v -E "${_tw_allow_macho}" | while read -r _n; do [[ "${_f}" == "${PREFIX}/lib/"* && "${_n}" == @rpath/* && -e "${PREFIX}/lib/${_n#@rpath/}" ]] || echo "${_n}"; done || true)
    [[ -n "${_loads}" ]] && _tw_fail "${_f} loads a library outside the libc allowlist: $(echo ${_loads} | tr '\n' ' ') — docs/18 §6.6 (a shared libc++ here means the ZIG_LIB_DIR mirror stopped working, docs/16)"
    _minos=$(otool -l "${_f}" 2>/dev/null | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; b=0}' | sort -uV | tail -1)
    if [[ -n "${_minos}" && "$(printf '%s\n' "${_minos}" "${_tw_floor}" | sort -V | tail -1)" != "${_tw_floor}" ]]; then
      _tw_fail "${_f} is built for macOS ${_minos} > declared floor ${_tw_floor} (docs/16 D4: pass a zig-form --target with the version)"
    fi
    _tw_n=$((_tw_n+1))
  done < <(find "${PREFIX}/bin" "${PREFIX}/lib" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.a' \) -print0 2>/dev/null)
  echo "load-dep allowlist OK: ${_tw_n} Mach-O files, libSystem only, minos <= ${_tw_floor} (docs/18 §6.6, docs/16)"
fi

# --- tripwires for build 9 (docs/16 §3d): static-only, hidden runtime ------
_shared=$(find "${PREFIX}/lib" \( -name 'libflang_rt.runtime*.so*' -o -name 'libflang_rt.runtime*.dylib' \) 2>/dev/null | head -3)
[[ -n "${_shared}" ]] && _tw_fail "a shared flang runtime was installed (${_shared}) — FLANG_RT_ENABLE_SHARED must stay OFF"
_rt_a=$(ls "${PREFIX}"/lib/clang/*/lib/*/libflang_rt.runtime.a 2>/dev/null | head -1)
[[ -n "${_rt_a}" ]] || _tw_fail "libflang_rt.runtime.a not found under ${PREFIX}/lib/clang/*/lib/*/"
_probe_sym=_FortranAioBeginExternalListOutput
if [[ "${target_platform}" == osx-* ]]; then
  _vis=$(nm -m "${_rt_a}" 2>/dev/null | grep -E " _${_probe_sym}\$" | head -1)
  echo "${_vis}" | grep -q "private external" || _tw_fail "runtime symbol ${_probe_sym} is not hidden in ${_rt_a}: '${_vis}' — -fvisibility=hidden did not reach the runtime objects"
else
  _tw_od=""; for _c in "${BUILD_PREFIX}/bin/llvm-objdump" "${PREFIX}/bin/llvm-objdump"; do [[ -x "${_c}" ]] && { _tw_od="${_c}"; break; }; done
  if [[ -n "${_tw_od}" ]]; then
    _vis=$("${_tw_od}" -t "${_rt_a}" 2>/dev/null | grep -E " ${_probe_sym}\$" | head -1)
    echo "${_vis}" | grep -q "\.hidden" || _tw_fail "runtime symbol ${_probe_sym} is not hidden in ${_rt_a}: '${_vis}' — -fvisibility=hidden did not reach the runtime objects"
  else
    echo "WARNING: no llvm-objdump; skipping the hidden-visibility tripwire" >&2
  fi
fi
echo "runtime tripwire OK: static-only archive, ${_probe_sym} hidden (docs/16 §3d)"

# --- tripwire: libomp's export surface (llvm-openmp, docs/18 §5.3) -------
# A drop-in must export the OpenMP API under conda-forge's symbol versions
# (Linux: binaries linked against conda-forge's libomp carry references like
# omp_get_num_threads@OMP_1.0 and fail to load without the version nodes),
# the GOMP compatibility layer, and no C++ runtime (zig's libc++ is static
# and must stay internal).
_omp_od=""; for _c in "${BUILD_PREFIX}/bin/llvm-objdump" "${PREFIX}/bin/llvm-objdump"; do [[ -x "${_c}" ]] && { _omp_od="${_c}"; break; }; done
[[ -n "${_omp_od}" ]] || _tw_fail "no llvm-objdump for the libomp export tripwire"
# Each tool runs once into a variable: `tool | grep -q` under pipefail fails
# at random (grep exits at the first match, the tool gets SIGPIPE).
case "${target_platform}" in
  linux-*)
    _omp_syms=$("${_omp_od}" -T "${PREFIX}/lib/libomp.so")
    _omp_n=$(grep -c ' DF .text' <<<"${_omp_syms}" || true)
    _omp_vn=$("${_omp_od}" -p "${PREFIX}/lib/libomp.so" | awk '/Version definitions:/{v=1;next} v&&NF==0{v=0} v{print $NF}' | sort -u | tr '\n' ' ')
    for _v in OMP_1.0 OMP_5.0 OMP_6.0 GOMP_1.0 GOMP_4.0 GOMP_5.0.1 VERSION; do
      [[ " ${_omp_vn} " == *" ${_v} "* ]] || _tw_fail "libomp.so lacks the symbol-version node ${_v} (have: ${_omp_vn})"
    done
    for _s in omp_get_num_threads GOMP_parallel __kmpc_fork_call __kmpc_global_thread_num; do
      grep -qE " ${_s}\$" <<<"${_omp_syms}" || _tw_fail "libomp.so does not export ${_s}"
    done
    _omp_cxx=$(grep -v '\*UND\*' <<<"${_omp_syms}" | grep -cE ' _ZN?St|__cxa_|__gxx_' || true)
    ;;
  osx-*)
    _omp_syms=$(nm -gU "${PREFIX}/lib/libomp.dylib")
    _omp_n=$(grep -c . <<<"${_omp_syms}" || true)
    for _s in _omp_get_num_threads ___kmpc_fork_call ___kmpc_global_thread_num _GOMP_parallel; do
      grep -qE " ${_s}\$" <<<"${_omp_syms}" || _tw_fail "libomp.dylib does not export ${_s} (hidden visibility reached libomp?)"
    done
    # docs/16 §3d: a dylib exporting ___dso_handle breaks Apple ld's link of
    # an archive's static initializer (libflang_rt.runtime.a) on the same
    # line — exactly `flang -fopenmp` on macOS.
    grep -qE ' ___dso_handle$' <<<"${_omp_syms}" && _tw_fail "libomp.dylib exports ___dso_handle (docs/16 §3d): link it with lld"
    _omp_id=$(otool -D "${PREFIX}/lib/libomp.dylib" | tail -1)
    [[ "${_omp_id}" == "@rpath/libomp.dylib" ]] || _tw_fail "libomp.dylib install name is ${_omp_id}, conda-forge's is @rpath/libomp.dylib"
    _omp_cxx=$(grep -cE ' __ZN?St|___cxa_|___gxx_' <<<"${_omp_syms}" || true)
    ;;
esac
[[ "${_omp_cxx:-0}" == 0 ]] || _tw_fail "libomp exports ${_omp_cxx} C++ runtime symbols — zig's static libc++ leaked into the export table"
echo "libomp tripwire OK: ${_omp_n} exported functions, version nodes and API present, no C++ runtime exports (docs/18 §5.3)"
