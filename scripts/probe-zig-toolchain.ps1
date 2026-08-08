# Stage 0 — toolchain probe (Windows).
#
#   pixi run probe-win
#
# Windows counterpart of probe-zig-toolchain.sh. It is deliberately less
# thorough: nobody has run it yet, and the questions it needs to answer are
# different (see docs/05-platform-matrix.md, section "win-64").
#
# The single most valuable thing this script does is print the -target triple
# baked into the zig wrapper. Whether zig_win-64 targets the MSVC ABI or the
# MinGW ABI decides whether the produced flang can interoperate with the rest
# of conda-forge on Windows at all — and that question is currently OPEN.

$ErrorActionPreference = "Continue"
$script:failed = 0

function Say  ($m) { Write-Host "`n== $m ==" -ForegroundColor White }
function Ok   ($m) { Write-Host "  ok   $m" -ForegroundColor Green }
function Bad  ($m) { Write-Host "  FAIL $m" -ForegroundColor Red; $script:failed = 1 }
function Note ($m) { Write-Host "       $m" }

$work = Join-Path $env:TEMP ("zigprobe-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work -Force | Out-Null

Say "1. zig activation"
foreach ($v in @("ZIG", "ZIG_CC", "ZIG_CXX", "ZIG_AR", "ZIG_RANLIB")) {
    $val = [Environment]::GetEnvironmentVariable($v)
    if ($val) { Ok "$v=$val" } else { Bad "$v is unset" }
}
if ($script:failed) {
    Note "conda-forge's zig packages export ZIG_CC/ZIG_CXX, not CC/CXX."
    exit 1
}
Note ("zig version: " + (& $env:ZIG version))

Say "2. TARGET ABI (the open question for Windows)"
# The wrapper is a generated .exe, but the conda-forge zig recipe derives the
# target from the same mapping used on unix. Ask the compiler itself.
& $env:ZIG_CC -v 2>&1 | Select-String -Pattern "Target:", "Thread model", "InstalledDir" | ForEach-Object { Note $_.ToString().Trim() }
Note "Record whatever 'Target:' says in docs/10-status-log.md — it settles OPEN QUESTION W1."

Say "3. zig cc: compile + link C"
Set-Content -Path "$work\t.c" -Value @"
#include <stdio.h>
int main(void) { printf("c-ok\n"); return 0; }
"@
& $env:ZIG_CC "$work\t.c" -o "$work\tc.exe" 2>&1 | Out-Null
if ((Test-Path "$work\tc.exe") -and ((& "$work\tc.exe") -eq "c-ok")) { Ok "C program compiled, linked and ran" }
else { Bad "C program failed" }

Say "4. zig c++: compile + link C++17"
Set-Content -Path "$work\t.cpp" -Value @"
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
"@
& $env:ZIG_CXX -std=c++17 "$work\t.cpp" -o "$work\tcxx.exe" 2>&1 | Out-Null
if ((Test-Path "$work\tcxx.exe") -and ((& "$work\tcxx.exe") -eq "cxx-ok")) { Ok "C++17 program compiled, linked and ran" }
else { Bad "C++17 program failed" }

Say "5. DLL dependencies of the C++ binary"
# Tells us which CRT flavour we ended up on: ucrtbase.dll/vcruntime*.dll => MSVC
# ABI; msvcrt.dll => MinGW ABI. Record the answer in the status log.
if (Test-Path "$work\tcxx.exe") {
    $dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
    if ($dumpbin) { & dumpbin /dependents "$work\tcxx.exe" | Select-String "\.dll" | ForEach-Object { Note $_.ToString().Trim() } }
    else { Note "dumpbin not on PATH; run 'llvm-objdump -p tcxx.exe | findstr DLL' from an llvm env instead" }
}

Say "6. CMake accepts the zig wrappers"
New-Item -ItemType Directory -Path "$work\cm" -Force | Out-Null
Set-Content -Path "$work\cm\CMakeLists.txt" -Value @"
cmake_minimum_required(VERSION 3.28)
project(zigprobe C CXX)
set(CMAKE_CXX_STANDARD 17)
add_library(probelib STATIC lib.cpp)
add_executable(probeapp main.cpp)
target_link_libraries(probeapp PRIVATE probelib)
"@
Set-Content -Path "$work\cm\lib.cpp" -Value 'include_placeholder'
Set-Content -Path "$work\cm\lib.cpp" -Value @"
#include <string>
std::string greet() { return "cmake-ok"; }
"@
Set-Content -Path "$work\cm\main.cpp" -Value @"
#include <string>
#include <iostream>
std::string greet();
int main() { std::cout << greet() << "\n"; }
"@
$cc = $env:ZIG_CC -replace '\\', '/'
$cxx = $env:ZIG_CXX -replace '\\', '/'
& cmake -G Ninja -S "$work\cm" -B "$work\cm\build" "-DCMAKE_C_COMPILER=$cc" "-DCMAKE_CXX_COMPILER=$cxx" -DCMAKE_BUILD_TYPE=Release 2>&1 | Out-Null
& cmake --build "$work\cm\build" 2>&1 | Out-Null
if ((Test-Path "$work\cm\build\probeapp.exe") -and ((& "$work\cm\build\probeapp.exe") -eq "cmake-ok")) { Ok "CMake configure + build + run" }
else { Bad "CMake integration failed" }

Say "result"
if ($script:failed -eq 0) { Ok "toolchain probe passed" } else { Bad "toolchain probe FAILED" }
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
exit $script:failed
