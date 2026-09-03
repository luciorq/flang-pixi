@echo on
setlocal enabledelayedexpansion

REM ---------------------------------------------------------------------------
REM Stage 3 (Windows): the Fortran runtime.
REM
REM Known upstream limitation: the *shared* flang runtime is not supported on
REM Windows (llvm/llvm-project#134186). conda-forge builds only the static
REM flavours there. FLANG_RT_ENABLE_SHARED is therefore OFF on this platform.
REM ---------------------------------------------------------------------------

if not defined ZIG_GLOBAL_CACHE_DIR set "ZIG_GLOBAL_CACHE_DIR=%SRC_DIR%\.zig-global-cache"
if not exist "%ZIG_GLOBAL_CACHE_DIR%" mkdir "%ZIG_GLOBAL_CACHE_DIR%"

if not defined ZIG_CC ( echo ERROR: ZIG_CC unset & exit /b 1 )
if not defined ZIG_CXX ( echo ERROR: ZIG_CXX unset & exit /b 1 )

set "ZIG_CC_CMAKE=%ZIG_CC:\=/%"
set "ZIG_CXX_CMAKE=%ZIG_CXX:\=/%"
set "ZIG_AR_CMAKE=%ZIG_AR:\=/%"
set "ZIG_RANLIB_CMAKE=%ZIG_RANLIB:\=/%"
set "RECIPE_DIR_CMAKE=%RECIPE_DIR:\=/%"
REM %SRC_DIR% expands with backslashes (C:\Users\...) and CMake reads \U
REM in "C:\Users" as an invalid character escape when the value crosses
REM try_compile boundaries. Forward-slash everything CMake sees.
set "SRC_DIR_CMAKE=%SRC_DIR:\=/%"

REM _LIBCPP_VERSION=1 for C compiles only: works around an upstream flang-rt
REM bug where flang/include/flang/Common/float128.h's libc++ detection
REM (`!defined(_LIBCPP_VERSION)`, meant to disable COMPLEX(16)/REAL(16)
REM support under libc++, which doesn't fully support __float128) only works
REM for C++ translation units. flang-rt/lib/runtime/complex-reduction.c is a
REM C file hitting the same header; without this it wrongly enables
REM float128 support and emits undefined-symbol references
REM (_FortranACppSumComplex16 and friends) that the C++ side never defines.
REM Found and fixed on linux-64 first; not yet verified on Windows. See the
REM unix build.sh and docs/10-status-log.md for the full story.
if not defined CFLAGS set "CFLAGS="
set "CFLAGS=%CFLAGS% -D_LIBCPP_VERSION=1"

REM -g0: zig cc/c++ emit full DWARF debug info by default, unrelated to
REM optimization flags -- see llvm-zig/recipe/build.bat and
REM docs/10-status-log.md for the full story and the Linux-side measurement.
if not defined CXXFLAGS set "CXXFLAGS="
set "CFLAGS=%CFLAGS% -g0"
set "CXXFLAGS=%CXXFLAGS% -g0"

set "FLANG_BIN=%BUILD_PREFIX%\Library\bin\flang.exe"
if not exist "%FLANG_BIN%" (
  echo ERROR: %FLANG_BIN% not found - flang-zig ^(stage 2^) missing from build prefix.
  exit /b 1
)
"%FLANG_BIN%" --version

set "FLANG_BIN_CMAKE=%FLANG_BIN:\=/%"

REM The runtime MUST be built for the same MinGW ABI the compiler emits, or
REM nothing R compiles will link. See docs/11-r-zig-integration.md.
if not defined ZIG_WIN_ABI_TARGET set "ZIG_WIN_ABI_TARGET=x86_64-windows-gnu"
if not defined LLVM_WIN_TRIPLE    set "LLVM_WIN_TRIPLE=x86_64-w64-windows-gnu"
set "WIN_ABI_ARGS=-DCMAKE_C_COMPILER_TARGET=%ZIG_WIN_ABI_TARGET%"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_CXX_COMPILER_TARGET=%ZIG_WIN_ABI_TARGET%"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_ASM_FLAGS=--target=%ZIG_WIN_ABI_TARGET%"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_Fortran_FLAGS=--target=%LLVM_WIN_TRIPLE%"

REM ---------------------------------------------------------------------------
REM Cross build: win-64 -> win-arm64.
REM
REM CMAKE_Fortran_COMPILER is the win-64 flang, which must emit arm64 code. That
REM requires the win-64 stage 1 to have been built with AArch64 in
REM LLVM_TARGETS_TO_BUILD. See docs/05-platform-matrix.md.
REM ---------------------------------------------------------------------------
set "CROSS_ARGS="
REM rattler sets build_platform == target_platform in the script env for
REM cross builds too — the classic equality test NEVER detects cross here.
REM Test the target directly instead.
if not "%target_platform%"=="win-arm64" goto :native_build
REM Cross build. goto-style — see llvm-zig/recipe/build.bat.
echo == cross build to %target_platform% ==
set "CROSS_ARGS=-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=ARM64"
set "CROSS_ARGS=%CROSS_ARGS% -DCMAKE_Fortran_FLAGS=--target=aarch64-w64-windows-gnu"
set "WIN_ABI_ARGS=-DCMAKE_C_COMPILER_TARGET=aarch64-windows-gnu"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_CXX_COMPILER_TARGET=aarch64-windows-gnu"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_ASM_FLAGS=--target=aarch64-windows-gnu"
REM zig's aarch64-windows-gnu CRT lacks wcstold (x64 flavor has it) and
REM LLVM's Support code references it -> every exe/dll link fails. On
REM arm64-Windows long double IS double, so a forwarding shim is exactly
REM correct. Compile it once and put it on every link line.
powershell -Command "Set-Content -Path '%SRC_DIR%\wcstold_compat.c' -Value '#include <wchar.h>', 'long double wcstold(const wchar_t *n, wchar_t **e) { return (long double)wcstod(n, e); }'"
"%ZIG_CC%" --target=aarch64-windows-gnu -O2 -c "%SRC_DIR%\wcstold_compat.c" -o "%SRC_DIR%\wcstold_compat.o"
if %ERRORLEVEL% neq 0 exit /b 1
set "WCSTOLD_OBJ=%SRC_DIR:\=/%/wcstold_compat.o"
set "CROSS_ARGS=%CROSS_ARGS% -DCMAKE_EXE_LINKER_FLAGS=%WCSTOLD_OBJ% -DCMAKE_SHARED_LINKER_FLAGS=%WCSTOLD_OBJ%"
:native_build
echo WIN_ABI_ARGS=%WIN_ABI_ARGS%
echo CROSS_ARGS=%CROSS_ARGS%

cmake -G Ninja -S runtimes -B build %WIN_ABI_ARGS% %CROSS_ARGS% ^
  -DCMAKE_C_COMPILER="%ZIG_CC_CMAKE%" ^
  -DCMAKE_CXX_COMPILER="%ZIG_CXX_CMAKE%" ^
  -DCMAKE_ASM_COMPILER="%ZIG_CC_CMAKE%" ^
  -DCMAKE_AR="%ZIG_AR_CMAKE%" ^
  -DCMAKE_RANLIB="%ZIG_RANLIB_CMAKE%" ^
  -DCMAKE_RC_COMPILER="%ZIG_RC_CMAKE%" ^
  -DCMAKE_Fortran_COMPILER="%FLANG_BIN_CMAKE%" ^
  -DCMAKE_Fortran_COMPILER_WORKS=yes ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_INSTALL_PREFIX="%LIBRARY_PREFIX%" ^
  -DCMAKE_PREFIX_PATH="%LIBRARY_PREFIX%" ^
  -DCMAKE_CXX_STANDARD=17 ^
  -DCMAKE_MODULE_PATH="%SRC_DIR_CMAKE%/cmake/Modules" ^
  -DCMAKE_PROJECT_INCLUDE="%RECIPE_DIR_CMAKE%/cmake-project-include.cmake" ^
  -DLLVM_DIR="%LIBRARY_LIB%/cmake/llvm" ^
  -DLLVM_CMAKE_DIR="%LIBRARY_LIB%/cmake/llvm" ^
  -DLLVM_ENABLE_RUNTIMES="flang-rt" ^
  -DFLANG_RT_ENABLE_SHARED=OFF ^
  -DFLANG_RT_ENABLE_STATIC=ON ^
  -DFLANG_RT_INCLUDE_TESTS=OFF
if %ERRORLEVEL% neq 0 exit /b 1

cmake --build build -j %CPU_COUNT%
if %ERRORLEVEL% neq 0 exit /b 1

cmake --install build
if %ERRORLEVEL% neq 0 exit /b 1

REM Extract zig's MinGW CRT into the driver's search path (user decision
REM 2026-08-27: self-contained; the Windows twin of the linux compiler-rt
REM approach). Validated end-to-end by hand before baking in: with this +
REM flang.cfg's -fuse-ld=lld (stage 2) + the runtime alias below,
REM `flang hello.f90` links and runs on a clean Windows machine.
set "CRT_TRIPLE=x86_64-w64-mingw32"
set "CRT_ZIGTARGET=x86_64-windows-gnu"
if not "%build_platform%"=="%target_platform%" (
  set "CRT_TRIPLE=aarch64-w64-mingw32"
  set "CRT_ZIGTARGET=aarch64-windows-gnu"
)
powershell -ExecutionPolicy Bypass -File "%RECIPE_DIR%\extract-zig-crt.ps1" -DestLib "%LIBRARY_PREFIX%\!CRT_TRIPLE!\lib" -ZigTarget "!CRT_ZIGTARGET!"
if %ERRORLEVEL% neq 0 exit /b 1

REM Windows flang-rt installs MSVC-convention multi-flavor names
REM (libflang_rt.runtime.static.a etc.); the driver links -lflang_rt.runtime.
REM Alias the static flavor to the plain name.
for /d %%D in ("%LIBRARY_LIB%\clang\*") do (
  for /d %%T in ("%%D\lib\*windows-gnu") do if exist "%%T\libflang_rt.runtime.static.a" (
    copy /y "%%T\libflang_rt.runtime.static.a" "%%T\libflang_rt.runtime.a" >nul
    echo runtime aliased in %%D
  )
)

REM Strip shared libraries -- mirrors the unix build.sh strip pass. Windows
REM flang-rt is static-only for now (FLANG_RT_ENABLE_SHARED=OFF, see the
REM header comment above), so this is a no-op until that changes; static
REM .lib archives are deliberately left untouched, same rationale as the
REM unix .a files (they are linker inputs for future consumers).
set "STRIP_BIN=%LIBRARY_BIN%\llvm-strip.exe"
REM Cross: the host llvm-strip is a foreign-arch binary -- use the native
REM one from BUILD_PREFIX (llvm-strip handles foreign COFF fine).
if "%target_platform%"=="win-arm64" set "STRIP_BIN=%BUILD_PREFIX%\Library\bin\llvm-strip.exe"
if exist "%STRIP_BIN%" (
  if exist "%LIBRARY_BIN%\*.dll" (
    echo == stripping shared libraries with %STRIP_BIN% ==
    for %%F in ("%LIBRARY_BIN%\*.dll") do "%STRIP_BIN%" --strip-unneeded "%%F" 2>nul
  )
) else (
  echo WARNING: llvm-strip.exe not found at %STRIP_BIN%, skipping strip pass
)

REM Reset ERRORLEVEL: on cross builds the host llvm-strip.exe is a
REM foreign-arch binary whose failed invocations (tolerated per-file via
REM 2>nul) otherwise leave a poisoned exit code that fails the whole
REM script AFTER a successful build.
ver >nul
