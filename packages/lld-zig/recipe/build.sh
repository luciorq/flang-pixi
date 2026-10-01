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
  if [[ -e "${ZIG_LIB_DIR}/../../lib/libc++.1.dylib" || -e "${ZIG_LIB_DIR}/../../lib/libc++.so.1" ]]; then
    echo "ERROR: ZIG_LIB_DIR mirror still has a libc++ sibling — the static-libc++ trick would not work" >&2; exit 1
  fi
  echo "ZIG_LIB_DIR=${ZIG_LIB_DIR} (static-libc++ mirror of ${_zig_lib_src})"
fi

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

# Explicit glibc floor in the zig target — the conda-forge zig wrapper's
# implicit baseline changes between feedstock builds (2.31 in 13 → 2.17 in
# 15) and must match llvm-zig's archives. Same block in all four packages;
# rationale in llvm-zig/recipe/build.sh and docs/13.
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

  # Pre-warm zig's global cache for this target BEFORE CMake runs. The
  # first-ever compile for a new -target builds zig's libc++/glibc stubs;
  # letting that happen inside CMake's compiler-feature detection has
  # (twice) corrupted the generated CMakeCXXCompiler.cmake with interleaved
  # output. One throwaway compile+link takes the cold path out of band.
  echo 'int main(){return 0;}' > "${SRC_DIR}/.zig-warmup.cpp"
  "${ZIG_CXX}" --target="${ZIG_LINUX_ABI_TARGET}" "${SRC_DIR}/.zig-warmup.cpp" \
    -o "${SRC_DIR}/.zig-warmup.out" || true
fi

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
# Cross builds: PREFIX's llvm-strip is a target-arch binary that cannot run
# here; the native one in BUILD_PREFIX (present only when cross) can strip
# foreign-arch ELFs fine.
[[ -x "${BUILD_PREFIX}/bin/llvm-strip" ]] && STRIP_BIN="${BUILD_PREFIX}/bin/llvm-strip"
fi

# macOS: rpath to $PREFIX/lib for our own dylibs (zig injects no LC_RPATH).
# libc++ is static since 2026-09-30 (ZIG_LIB_DIR mirror above, docs/16).
if [[ "${target_platform}" == osx-* ]]; then
  export LDFLAGS="-Wl,-rpath,${PREFIX}/lib"
  CMAKE_EXTRA+=("-DCMAKE_INSTALL_RPATH=${PREFIX}/lib")
  # macOS fd-limit fix — see llvm-zig/flang-zig build.sh.
  ulimit -n 65536 2>/dev/null || ulimit -n 10240 2>/dev/null || ulimit -n 4096 2>/dev/null || true
fi

# CMAKE_BUILD_WITH_INSTALL_RPATH=ON: same .pixi-symlink RPATH_CHANGE
# workaround as the other packages — see llvm-zig/recipe/build.sh.
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

cmake -G Ninja -S lld -B build \
  -DCMAKE_C_COMPILER="${ZIG_CC}" \
  -DCMAKE_CXX_COMPILER="${ZIG_CXX}" \
  -DCMAKE_ASM_COMPILER="${ZIG_CC}" \
  -DCMAKE_AR="${AR_BIN}" \
  -DCMAKE_RANLIB="${RANLIB_BIN}" \
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
  check_glibc_ceiling "${PREFIX}/bin/lld"
fi

# Record the exact zig toolchain this package was built with — the audit
# trail for zig-feedstock coupling issues (docs/13).
mkdir -p "${PREFIX}/share/lld-zig"
{
  echo "zig_conda_package=$(ls "${BUILD_PREFIX}"/conda-meta/zig*_*.json 2>/dev/null | xargs -rn1 basename | tr '\n' ' ')"
  echo "zig_abi_target=${ZIG_LINUX_ABI_TARGET:-wrapper-default}"
} > "${PREFIX}/share/lld-zig/zig-toolchain.txt"

# --- tripwires (docs/16): no shared C++ runtime shipped; macOS floor kept ----
# Fail here, not at a consumer's load: (1) nothing under $PREFIX may depend on
# a shared libc++/libstdc++ (the zig-feedstock shared-libc++ preference would
# do exactly that if the ZIG_LIB_DIR mirror above stopped working); (2) on
# macOS every Mach-O, archive members included, must be built for at most
# MACOSX_DEPLOYMENT_TARGET (flang-rt-zig shipped minos 13.0 against a declared
# 11.0 floor until 2026-09-30 because the conda wrapper drops the version when
# it translates a conda triple).
_tw_fail() { echo "ERROR: $*" >&2; exit 1; }
if [[ "${target_platform}" == linux-* ]]; then
  _tw_od=""; for _c in "${BUILD_PREFIX}/bin/llvm-objdump" "${PREFIX}/bin/llvm-objdump" objdump; do command -v "${_c}" >/dev/null 2>&1 && { _tw_od="${_c}"; break; }; done
  if [[ -n "${_tw_od}" ]]; then
    _tw_n=0
    while IFS= read -r -d '' _f; do
      _needed=$("${_tw_od}" -p "${_f}" 2>/dev/null | grep -E '^\s*NEEDED' | grep -E 'libc\+\+|libstdc\+\+|libunwind\.so' || true)
      [[ -n "${_needed}" ]] && _tw_fail "${_f} depends on a shared C++ runtime (${_needed}) — libcxx in the build env? ZIG_LIB_DIR mirror ineffective? see docs/16"
      _tw_n=$((_tw_n+1))
    done < <(find "${PREFIX}/bin" "${PREFIX}/lib" -type f \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null)
    echo "C++ runtime tripwire OK: ${_tw_n} ELF files, no shared libc++/libstdc++ (docs/16)"
  else
    echo "WARNING: no objdump; skipping shared-C++-runtime tripwire" >&2
  fi
elif [[ "${target_platform}" == osx-* ]]; then
  _tw_floor="${MACOSX_DEPLOYMENT_TARGET:-11.0}"; _tw_n=0
  command -v otool >/dev/null 2>&1 || _tw_fail "otool not found; cannot run the Mach-O tripwire"
  while IFS= read -r -d '' _f; do
    file "${_f}" 2>/dev/null | grep -qE 'Mach-O|ar archive' || continue
    if otool -L "${_f}" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -qE 'libc\+\+|libstdc\+\+'; then
      _tw_fail "${_f} depends on a shared C++ runtime ($(otool -L "${_f}" | tail -n +2 | awk '{print $1}' | grep -E 'libc\+\+|libstdc\+\+' | tr '\n' ' ')) — ZIG_LIB_DIR mirror ineffective? see docs/16"
    fi
    _minos=$(otool -l "${_f}" 2>/dev/null | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; b=0}' | sort -uV | tail -1)
    if [[ -n "${_minos}" && "$(printf '%s\n' "${_minos}" "${_tw_floor}" | sort -V | tail -1)" != "${_tw_floor}" ]]; then
      _tw_fail "${_f} is built for macOS ${_minos} > declared floor ${_tw_floor} (docs/16 D4: pass a zig-form --target with the version)"
    fi
    _tw_n=$((_tw_n+1))
  done < <(find "${PREFIX}/bin" "${PREFIX}/lib" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.a' \) -print0 2>/dev/null)
  echo "Mach-O tripwire OK: ${_tw_n} files, no shared libc++, minos <= ${_tw_floor} (docs/16)"
fi
