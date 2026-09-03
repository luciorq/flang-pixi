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
#
# -g0: unlike stock Clang, `zig cc`/`zig c++` emit full DWARF debug info by
# DEFAULT — -O2/-O3/-DNDEBUG only control optimization and assertions, a
# separate axis from debug-info emission, and neither implies -g0. Left
# unset, every static archive here carries full .debug_info/.debug_loc/
# .debug_str, and every binary that statically links them (stage 2's
# flang-22, bbc, ...) inherits and duplicates all of it. Confirmed directly:
# the same zig c++ invocation on a trivial file dropped from 81 KB to 1.2 KB
# with -g0 added, nothing else changed. This is why llvm-zig/flang-zig ended
# up 60-150x larger than conda-forge's llvmdev+clangdev+mlir/flang, which
# strip (or never emit) debug info by default. See docs/10-status-log.md.
export CFLAGS="-O2 -fPIC -g0"
export CXXFLAGS="-O2 -fPIC -g0"

# --- knobs from the recipe ---------------------------------------------------
LLVM_PROJECTS="${LLVM_PROJECTS:-clang;mlir}"
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
#
# Also macOS: zig links conda-forge's libcxx DYNAMICALLY here
# (@rpath/libc++.1.dylib — zig_impl_osx-* depends on libcxx; the OPPOSITE of
# Linux, where zig bundles libc++ statically) and injects no LC_RPATH, so
# without an explicit rpath every C++ binary built below aborts at load with
# "Library not loaded: @rpath/libc++.1.dylib". LDFLAGS seeds CMake's
# *_LINKER_FLAGS at configure; CMAKE_INSTALL_RPATH covers installed binaries
# (linked with it directly since CMAKE_BUILD_WITH_INSTALL_RPATH=ON, and it
# resolves during the build too because the host prefix exists then).
# rattler-build relocates the absolute prefix at packaging time. libcxx is a
# host dependency on osx in recipe.yaml for the same reason. Found by the
# stage-0 probe on omicron; see docs/10-status-log.md (2026-08-25).
if [[ "${target_platform}" == osx-* ]]; then
  # macOS defaults `ulimit -n` to 256; zig's driver opens every input object
  # of a link at once, and libclang-cpp.dylib links all of clang (~2000
  # objects) -> "failed to open object ...: ProcessFdQuotaExceeded". Raise
  # the soft limit as high as the hard limit allows.
  ulimit -n 65536 2>/dev/null || ulimit -n 10240 2>/dev/null || ulimit -n 4096 2>/dev/null || true

  sed -i.bak "s/NOT APPLE AND ARG_SONAME/ARG_SONAME/g" llvm/cmake/modules/AddLLVM.cmake
  sed -i.bak "s/NOT APPLE AND NOT ARG_SONAME/NOT ARG_SONAME/g" llvm/cmake/modules/AddLLVM.cmake
  export LDFLAGS="-Wl,-rpath,${PREFIX}/lib"
  CMAKE_EXTRA+=("-DCMAKE_INSTALL_RPATH=${PREFIX}/lib")

  # dsymutil needs Apple's CoreFoundation framework headers, and zig's clang
  # does not add SDK framework search paths (frameworks are largely outside
  # zig's cross-compilation model). dsymutil bundles dSYM debug symbols —
  # nothing in the flang toolchain needs it. Same disable-the-irrelevant-tool
  # pattern as LLVM_TOOL_LLVM_EXEGESIS_BUILD on Linux.
  CMAKE_EXTRA+=("-DLLVM_TOOL_DSYMUTIL_BUILD=OFF")

  # libclang (the C API dylib) sets SOVERSION 1, which CMake turns into
  # `-compatibility_version 1` — zig's driver requires a full x.y.z there
  # and dies with "unable to parse -compatibility_version '1':
  # InvalidVersion". Nothing in the flang toolchain consumes libclang's
  # C API (flang links the C++ static archives), so disable it and its
  # dependent c-index-test instead of fighting the version parse.
  CMAKE_EXTRA+=("-DCLANG_TOOL_LIBCLANG_BUILD=OFF")
  CMAKE_EXTRA+=("-DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF")

  # clang's static-analyzer example plugins and LLVM's BugpointPasses are
  # `-bundle` dylibs linked with `-Wl,-flat_namespace` — another ld64 flag
  # zig rejects outright. Nothing in the flang toolchain loads clang or
  # bugpoint plugins; disable both producers (osx-only gate: on Linux they
  # build fine and are merely dead weight already shipped in existing
  # packages). Verified via build.ninja that these were the ONLY
  # -flat_namespace targets in the graph.
  CMAKE_EXTRA+=("-DCLANG_PLUGIN_SUPPORT=OFF")
  CMAKE_EXTRA+=("-DLLVM_TOOL_BUGPOINT_PASSES_BUILD=OFF")

  # zig's driver mis-parses ld64's two-part `-exported_symbols_list <file>`
  # argument when it arrives as `-Wl,-exported_symbols_list,<file>` (or as two
  # separate -Wl tokens): the parse breaks zig's own libSystem/-syslibroot
  # injection and the link dies with "library not found for -lSystem" +
  # undefined _malloc/_atoi/etc. Only three targets use export files (libLTO,
  # libRemarks, libclang), via this one AddLLVM.cmake line. The `=` spelling
  # parses cleanly through zig. Trade-off, measured not assumed: with `=` the
  # export list is silently NOT applied (the dylib over-exports; verified via
  # nm on a minimal repro) — acceptable here because nothing consumes these
  # dylibs from our packages (flang links clang/LLVM statically; ADR-2).
  # Found at target 6008/6694 of the first osx-arm64 build; see
  # docs/10-status-log.md (2026-08-25).
  sed -i.bak3 "s/-Wl,-exported_symbols_list,/-Wl,-exported_symbols_list=/g" llvm/cmake/modules/AddLLVM.cmake

  # Same class of bug, next target down: zig's driver hard-rejects ld64's
  # `-sectcreate` ("unsupported linker arg"), which clang/tools/driver uses on
  # Apple to embed an Info.plist metadata section into bin/clang — purely
  # cosmetic version metadata, nothing reads it in a conda env. In LLVM 22 the
  # flag arrives via target_link_libraries(... PRIVATE "-Wl,-sectcreate,...")
  # — drop the item entirely (leaving `PRIVATE` with an empty list, which is
  # valid CMake; an empty-string item is NOT and poisons the link line). lldb
  # also uses -sectcreate but is not in LLVM_ENABLE_PROJECTS here. Found at
  # target 145/679 of the first osx-arm64 resume; see docs/10-status-log.md.
  sed -i.bak 's/"-Wl,-sectcreate,__TEXT,__info_plist,.*/)/' clang/tools/driver/CMakeLists.txt
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
# Reused work dirs keep a stale build tree whose CMake cache resurrects
# dropped components (lld survived BOTH the projects-list change AND an
# explicit LLVM_TOOL_LLD_BUILD=OFF this way). ninja recompiles everything
# after pixi's source re-copy regardless, so a fresh tree costs nothing.
rm -rf build

# And the HOST PREFIX is reused across runs in the same build dir too:
# files installed by PREVIOUS generations persist in $PREFIX and get
# packaged even when the current build never produces them (how bin/lld
# survived three rebuild attempts after the project was dropped). Purge
# lld leftovers explicitly; no-op in a fresh dir.
rm -f "${PREFIX}"/bin/lld "${PREFIX}"/bin/ld.lld "${PREFIX}"/bin/ld64.lld \
      "${PREFIX}"/bin/lld-link "${PREFIX}"/bin/wasm-ld
rm -f "${PREFIX}"/lib/liblld*.a
rm -rf "${PREFIX}/include/lld" "${PREFIX}/lib/cmake/lld"

cmake -G Ninja -S llvm -B build \
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
  -DLLVM_TOOL_LLD_BUILD=OFF \
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

# --- strip installed binaries and plugin libraries ---------------------------
# -g0 (above) stops DWARF debug info from being generated in the first place,
# but static linking still pulls a full ELF symbol table (.symtab/.strtab)
# from every statically-linked object into every executable — verified
# directly on flang-zig's binaries: stripping cut an already-`-g0`'d flang-22
# from 1.28 GB to 147 MB, a further ~9x. Using this build's own just-installed
# llvm-strip (not any host `strip`), matching ADR-1's "no system tools" rule.
# --strip-all for bin/ executables: nothing here is ever dlopen()'d, and it
# does not touch .dynsym (needed at load time). --strip-unneeded for the few
# .so plugin libraries (clang's static-analyzer plugins, bugpoint passes):
# the conventional, more conservative choice for anything dynamically loaded.
# See docs/10-status-log.md for the measurement.
STRIP_BIN="${PREFIX}/bin/llvm-strip"
if [[ -x "${STRIP_BIN}" ]]; then
  echo "== stripping installed binaries with ${STRIP_BIN} =="
  find "${PREFIX}/bin" -maxdepth 1 -type f -print0 | while IFS= read -r -d '' f; do
    "${STRIP_BIN}" --strip-all "${f}" 2>/dev/null || true
  done
  find "${PREFIX}/lib" -name '*.so*' -type f -print0 | while IFS= read -r -d '' f; do
    "${STRIP_BIN}" --strip-unneeded "${f}" 2>/dev/null || true
  done
else
  echo "WARNING: llvm-strip not found at ${STRIP_BIN}, skipping strip pass" >&2
fi

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
  if [[ "${target_platform}" == osx-* ]]; then
    echo "cxx_runtime=conda-forge libcxx (dynamic)"
  else
    echo "cxx_runtime=zig-bundled-libc++ (static)"
  fi
} > "${PREFIX}/share/llvm-zig/build-info.txt"
