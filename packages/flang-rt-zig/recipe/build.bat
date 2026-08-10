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
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_Fortran_FLAGS=--target=%LLVM_WIN_TRIPLE%"

REM ---------------------------------------------------------------------------
REM Cross build: win-64 -> win-arm64.
REM
REM CMAKE_Fortran_COMPILER is the win-64 flang, which must emit arm64 code. That
REM requires the win-64 stage 1 to have been built with AArch64 in
REM LLVM_TARGETS_TO_BUILD. See docs/05-platform-matrix.md.
REM ---------------------------------------------------------------------------
set "CROSS_ARGS="
if not "%build_platform%"=="%target_platform%" (
  echo == cross build: %build_platform% -^> %target_platform% ==
  set "CROSS_ARGS=-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=ARM64"
  set "CROSS_ARGS=!CROSS_ARGS! -DCMAKE_Fortran_FLAGS=--target=aarch64-w64-windows-gnu"
  set "CROSS_ARGS=!CROSS_ARGS! -DCMAKE_C_COMPILER_TARGET=aarch64-windows-gnu"
  set "CROSS_ARGS=!CROSS_ARGS! -DCMAKE_CXX_COMPILER_TARGET=aarch64-windows-gnu"
)

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
  -DCMAKE_MODULE_PATH="%SRC_DIR%/cmake/Modules" ^
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
