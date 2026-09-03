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
#   * CMAKE_PROJECT_INCLUDE injects cmake-project-include.cmake, working around
#     a missing include(CMakePushCheckState) in flang's own
#     cmake/modules/FlangCommon.cmake — see that file for the full story. Only
#     surfaces in a standalone/out-of-tree flang build (this one, and
#     conda-forge's), not an in-tree LLVM super-build.
#
set -euxo pipefail

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-${SRC_DIR}/.zig-global-cache}"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}"

: "${ZIG_CC:?zig activation did not run}"
: "${ZIG_CXX:?zig activation did not run}"

unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS \
      DEBUG_CFLAGS DEBUG_CXXFLAGS DEBUG_CPPFLAGS \
      CC CXX AR RANLIB LD NM STRIP 2>/dev/null || true

# -g0: `zig cc`/`zig c++` emit full DWARF debug info by default, independent
# of -O2/-DNDEBUG. Without this, flang-22/bbc/tco etc. balloon to multi-GB
# each. See llvm-zig/recipe/build.sh for the full story and the confirming
# test. This alone does not fully fix flang-zig's package size, since it
# still statically links llvm-zig's .a archives, which carry their own
# embedded debug info until llvm-zig itself is rebuilt with this flag too.
export CFLAGS="-O2 -fPIC -g0"
export CXXFLAGS="-O2 -fPIC -g0"

FLANG_PARALLEL_COMPILE_JOBS="${FLANG_PARALLEL_COMPILE_JOBS:-2}"

# --- host triple -------------------------------------------------------------
# Normally set by conda-forge's gcc/clang compiler activation, which we don't
# use (zig is our compiler). Without this fallback, CONDA_TOOLCHAIN_HOST stays
# empty and the driver-config-file block near the end of this script silently
# never runs — no <triple>-flang.cfg gets written, and `flang hello.f90`
# outside the build sandbox fails at RUNTIME with "libflang_rt.runtime.so:
# cannot open shared object file", because the produced binary has no rpath
# back to $PREFIX/lib. Found via `pixi run smoke` failing exactly that way on
# the first real link+run of our own flang; see docs/10-status-log.md. Kept in
# sync with the same fallback in llvm-zig/recipe/build.sh.
if [[ -z "${CONDA_TOOLCHAIN_HOST:-}" ]]; then
  case "${target_platform}" in
    linux-64)       CONDA_TOOLCHAIN_HOST="x86_64-conda-linux-gnu" ;;
    linux-aarch64)  CONDA_TOOLCHAIN_HOST="aarch64-conda-linux-gnu" ;;
    osx-64)         CONDA_TOOLCHAIN_HOST="x86_64-apple-darwin13.4.0" ;;
    osx-arm64)      CONDA_TOOLCHAIN_HOST="arm64-apple-darwin20.0.0" ;;
    *)              CONDA_TOOLCHAIN_HOST="" ;;
  esac
fi

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

# macOS: zig links conda-forge's libcxx DYNAMICALLY (@rpath/libc++.1.dylib)
# and injects no LC_RPATH — without this, flang-22/bbc/etc. abort at load.
# Same story and fix as llvm-zig/recipe/build.sh; libcxx is a host dep on osx
# in recipe.yaml. See docs/10-status-log.md (2026-08-25).
if [[ "${target_platform}" == osx-* ]]; then
  export LDFLAGS="-Wl,-rpath,${PREFIX}/lib"
  CMAKE_EXTRA+=("-DCMAKE_INSTALL_RPATH=${PREFIX}/lib")
  # macOS ulimit -n defaults to 256; zig opens every static archive of a link
  # at once and flang-22's link list exceeds it (ProcessFdQuotaExceeded).
  # Same fix as llvm-zig/recipe/build.sh.
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
cmake -G Ninja -S flang -B build \
  ${CMAKE_EXTRA[@]+"${CMAKE_EXTRA[@]}"} \
  -DCMAKE_C_COMPILER="${ZIG_CC}" \
  -DCMAKE_CXX_COMPILER="${ZIG_CXX}" \
  -DCMAKE_ASM_COMPILER="${ZIG_CC}" \
  -DCMAKE_AR="${ZIG_AR}" \
  -DCMAKE_RANLIB="${ZIG_RANLIB}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DCMAKE_PREFIX_PATH="${PREFIX}" \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DCMAKE_MODULE_PATH="${SRC_DIR}/cmake/Modules" \
  -DCMAKE_PROJECT_INCLUDE="${RECIPE_DIR}/cmake-project-include.cmake" \
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

MAJOR_VER="${PKG_VERSION%%.*}"

# --- deduplicate flang-new -----------------------------------------------
# LLVM's own install() logic produces bin/flang-new as a full, independent
# copy of bin/flang-<major> — verified byte-identical via md5sum on this
# build. Upstream never bothered fixing this because with shared linking the
# driver binary is ~56 KB, so the duplication costs them nothing; statically
# linked here, each copy is 1+ GB. Only collapse it if still identical for
# THIS build (guards against a future flang version where they diverge —
# silently symlinking mismatched binaries would be worse than leaving the
# duplicate). See docs/10-status-log.md.
flang_new="${PREFIX}/bin/flang-new"
flang_versioned="${PREFIX}/bin/flang-${MAJOR_VER}"
if [[ -f "${flang_new}" && -f "${flang_versioned}" ]] && cmp -s "${flang_new}" "${flang_versioned}"; then
  rm -f "${flang_new}"
  ln -s "$(basename "${flang_versioned}")" "${flang_new}"
  echo "flang-new deduplicated -> $(basename "${flang_versioned}")"
else
  echo "WARNING: flang-new and flang-${MAJOR_VER} differ or are missing; not deduplicating" >&2
fi

# --- strip installed binaries ------------------------------------------------
# -g0 (above) stops DWARF debug info from being generated in the first place,
# but static linking still pulls a full ELF symbol table (.symtab/.strtab)
# from every statically-linked object into every executable. Verified
# directly: stripping flang-22 (already -g0'd) dropped it from 1.28 GB to
# 147 MB, a further ~9x. Using llvm-zig's own llvm-strip (a run dependency,
# so guaranteed present) rather than any host `strip`, matching ADR-1's
# "no system tools" rule. --strip-all is safe here: nothing in bin/ is ever
# dlopen()'d, and --strip-all does not touch .dynsym (needed to resolve
# libc/libm/etc at load time) — only .symtab/.strtab, which nothing at
# runtime reads. See docs/10-status-log.md for the measurement.
STRIP_BIN="${PREFIX}/bin/llvm-strip"
if [[ -x "${STRIP_BIN}" ]]; then
  echo "== stripping installed executables with ${STRIP_BIN} =="
  find "${PREFIX}/bin" -maxdepth 1 -type f -print0 | while IFS= read -r -d '' f; do
    "${STRIP_BIN}" --strip-all "${f}" 2>/dev/null || true
  done
else
  echo "WARNING: llvm-strip not found at ${STRIP_BIN}, skipping strip pass" >&2
fi

# --- driver configuration file ----------------------------------------------
# conda-forge's clangdev writes <target>-flang.cfg so the driver picks up the
# environment's lib dir and (on Linux) the conda sysroot. Do the same, otherwise
# a `flang hello.f90` in an activated env will not find libflang_rt or the
# sysroot's crt objects.
#
# -fuse-ld=lld / --rtlib=compiler-rt: flang.exe is a genuine Clang-derived
# driver (not `zig cc`) and does its own classic GNU/Linux toolchain probing
# at RUNTIME — left to its defaults it looks for the system `ld` and for
# GCC's crtbeginS.o/crtendS.o/libgcc, none of which exist anywhere in this
# toolchain by design (ADR-1, no GCC at all). `-fuse-ld=lld` routes through
# lld-zig's ld.lld (the runtime dependency; was llvm-zig's before the
# lld-zig split, see docs/10-status-log.md 2026-08-25) instead of
# whatever `ld` happens to be on the host's PATH. `--rtlib=compiler-rt`
# makes the driver look for LLVM's own GCC-independent CRT objects and
# builtins library, which flang-rt-zig (stage 3) builds alongside flang-rt —
# see that package's build.sh for the COMPILER_RT_BUILD_CRT=ON side. Found
# via `pixi run smoke`'s first real link+run; see docs/10-status-log.md.
if [[ -n "${CONDA_TOOLCHAIN_HOST:-}" ]]; then
  cfg="${PREFIX}/bin/${CONDA_TOOLCHAIN_HOST}-flang.cfg"
  {
    echo '$-Wl,-L,<CFGDIR>/../lib'
    echo '$-Wl,-rpath,<CFGDIR>/../lib'
    if [[ "${target_platform}" == linux-* ]]; then
      echo '$-Wl,-rpath-link,<CFGDIR>/../lib'
      echo "--sysroot=<CFGDIR>/../${CONDA_TOOLCHAIN_HOST}/sysroot"
      echo '-fuse-ld=lld'
      echo '--rtlib=compiler-rt'
    fi
  } > "${cfg}"
  # The driver looks for <triple>-flang.cfg *and* flang.cfg; provide both so it
  # works whether or not the caller passes --target.
  cp "${cfg}" "${PREFIX}/bin/flang.cfg"
fi
