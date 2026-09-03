#!/usr/bin/env bash
#
# Stage 0 — toolchain probe.
#
#   pixi run probe
#
# Answers, in about ten seconds, the questions you do NOT want to discover two
# hours into an LLVM build:
#
#   1. Did the zig activation actually run? (ZIG_CC/ZIG_CXX set?)
#   2. Does `zig cc` compile and link a C program?
#   3. Does `zig c++` compile and link a C++17 program?
#   4. WHICH C++ RUNTIME does it link? This is the fact the whole architecture
#      rests on — see docs/02-architecture-decisions.md.
#   5. Does CMake accept the zig wrappers as CMAKE_C/CXX_COMPILER, including
#      its own try-compile probes?
#   6. Is a conda sysroot present and being picked up?
#
set -uo pipefail

fail=0
say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
note() { printf '       %s\n' "$*"; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# --- 1. activation -----------------------------------------------------------
say "1. zig activation"
for v in ZIG ZIG_CC ZIG_CXX ZIG_AR ZIG_RANLIB; do
  if [[ -n "${!v:-}" ]]; then ok "${v}=${!v}"; else bad "${v} is unset"; fi
done
if [[ ${fail} -eq 1 ]]; then
  note "The conda-forge zig packages export ZIG_CC/ZIG_CXX, NOT CC/CXX."
  note "If these are unset, zig_<platform> is not installed or activate.d did not run."
  exit 1
fi
note "zig version: $("${ZIG}" version)"

# --- 2. C --------------------------------------------------------------------
say "2. zig cc: compile + link C"
cat > "${work}/t.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("c-ok\n"); return 0; }
EOF
if "${ZIG_CC}" "${work}/t.c" -o "${work}/tc" >"${work}/cc.log" 2>&1 && [[ "$("${work}/tc")" == "c-ok" ]]; then
  ok "C program compiled, linked and ran"
else
  bad "C program failed"; sed 's/^/       /' "${work}/cc.log" | tail -20
fi

# --- 3. C++ ------------------------------------------------------------------
say "3. zig c++: compile + link C++17"
# macOS: zig links conda-forge's libcxx DYNAMICALLY (@rpath/libc++.1.dylib —
# zig_impl_osx-* depends on libcxx; the opposite of Linux, where zig bundles
# libc++ statically) and injects no LC_RPATH, so every C++ link needs an
# explicit rpath to $CONDA_PREFIX/lib or the binary aborts at load. The build
# scripts do the same. See docs/10-status-log.md (2026-08-25).
cxx_link_flags=()
if [[ "$(uname -s)" == "Darwin" ]]; then
  cxx_link_flags+=("-Wl,-rpath,${CONDA_PREFIX}/lib")
fi
cat > "${work}/t.cpp" <<'EOF'
#include <string>
#include <vector>
#include <iostream>
#include <stdexcept>
int main() {
  std::vector<std::string> v{"cxx", "ok"};
  try { throw std::runtime_error("x"); } catch (const std::exception&) {}
  std::cout << v[0] << "-" << v[1] << "\n";
  return 0;
}
EOF
if "${ZIG_CXX}" -std=c++17 "${work}/t.cpp" ${cxx_link_flags[@]+"${cxx_link_flags[@]}"} -o "${work}/tcxx" >"${work}/cxx.log" 2>&1 \
   && [[ "$("${work}/tcxx")" == "cxx-ok" ]]; then
  ok "C++17 program compiled, linked and ran (exceptions included)"
else
  bad "C++17 program failed"; sed 's/^/       /' "${work}/cxx.log" | tail -30
fi

# --- 4. C++ runtime identification ------------------------------------------
say "4. which C++ runtime is linked (THE load-bearing fact)"
if [[ -x "${work}/tcxx" ]]; then
  case "$(uname -s)" in
    Linux)  deps="$(ldd "${work}/tcxx" 2>/dev/null || true)" ;;
    Darwin) deps="$(otool -L "${work}/tcxx" 2>/dev/null || true)" ;;
    *)      deps="" ;;
  esac
  printf '%s\n' "${deps}" | sed 's/^/       /'

  if printf '%s' "${deps}" | grep -qi 'libstdc++'; then
    note ">> links libstdc++ DYNAMICALLY"
    note ">> If you ever see this, re-read docs/02-architecture-decisions.md:"
    note ">> the 'must rebuild LLVM ourselves' conclusion would need revisiting."
  elif printf '%s' "${deps}" | grep -qi 'libc++'; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      ok "links libc++ dynamically — conda-forge's libcxx package (expected on macOS)"
      note ">> zig_impl_osx-* depends on libcxx; zig does NOT bundle it statically here."
      note ">> Recipes must add libcxx to host deps and -Wl,-rpath,\$PREFIX/lib to links."
    else
      note ">> links libc++ dynamically"
    fi
  else
    ok "no C++ runtime in the dependency list => zig's bundled libc++ is STATIC"
    note ">> This is the expected result, and it is why we cannot link against"
    note ">> conda-forge's libstdc++-built llvmdev/clangdev/mlir."
  fi
fi

# --- 5. CMake integration ----------------------------------------------------
say "5. CMake accepts the zig wrappers"
mkdir -p "${work}/cm"
cat > "${work}/cm/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.28)
project(zigprobe C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_library(probelib STATIC lib.cpp)
set_property(TARGET probelib PROPERTY POSITION_INDEPENDENT_CODE ON)
add_executable(probeapp main.cpp)
target_link_libraries(probeapp PRIVATE probelib)
EOF
cat > "${work}/cm/lib.cpp" <<'EOF'
#include <string>
std::string greet() { return "cmake-ok"; }
EOF
cat > "${work}/cm/main.cpp" <<'EOF'
#include <string>
#include <iostream>
std::string greet();
int main() { std::cout << greet() << "\n"; }
EOF
if cmake -G Ninja -S "${work}/cm" -B "${work}/cm/build" \
      -DCMAKE_C_COMPILER="${ZIG_CC}" \
      -DCMAKE_CXX_COMPILER="${ZIG_CXX}" \
      -DCMAKE_AR="${ZIG_AR}" \
      -DCMAKE_RANLIB="${ZIG_RANLIB}" \
      -DCMAKE_EXE_LINKER_FLAGS="${cxx_link_flags[*]-}" \
      -DCMAKE_BUILD_TYPE=Release >"${work}/cmake.log" 2>&1 \
   && cmake --build "${work}/cm/build" >>"${work}/cmake.log" 2>&1 \
   && [[ "$("${work}/cm/build/probeapp")" == "cmake-ok" ]]; then
  ok "CMake configure + static lib + link + run"
  idfile="$(find "${work}/cm/build/CMakeFiles" -name 'CMakeCXXCompiler.cmake' -print -quit 2>/dev/null)"
  if [[ -n "${idfile}" ]]; then
    note "CMake sees: $(grep -E 'CMAKE_CXX_COMPILER_(ID|VERSION) ' "${idfile}" | tr -d '\n')"
  fi
else
  bad "CMake integration failed"; sed 's/^/       /' "${work}/cmake.log" | tail -40
fi

# --- 6. sysroot --------------------------------------------------------------
say "6. conda sysroot (Linux only)"
if [[ "$(uname -s)" == "Linux" ]]; then
  found=0
  for d in "${CONDA_PREFIX}"/*-conda-linux-gnu/sysroot; do
    [[ -d "${d}" ]] || continue
    ok "sysroot present: ${d}"
    found=1
  done
  if [[ ${found} -eq 0 ]]; then
    bad "no conda sysroot found under \$CONDA_PREFIX"
    note "The zig wrapper looks for \$CONDA_PREFIX/<arch>-conda-linux-gnu/sysroot"
    note "and falls back to \$CONDA_BUILD_SYSROOT. Without it, zig links against"
    note "the HOST glibc and the resulting package has no portable glibc floor."
    note "Add sysroot_linux-64 to the environment."
  fi
  if [[ -x "${work}/tc" ]]; then
    note "C binary glibc refs: $(objdump -T "${work}/tc" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -3 | tr '\n' ' ')"
  fi
else
  note "skipped (not Linux)"
fi

say "result"
if [[ ${fail} -eq 0 ]]; then
  ok "toolchain probe passed — safe to attempt stage 1"
else
  bad "toolchain probe FAILED — fix this before running pixi run build-llvm"
fi
exit "${fail}"
