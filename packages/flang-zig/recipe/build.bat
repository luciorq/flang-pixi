@echo on
setlocal enabledelayedexpansion

REM ---------------------------------------------------------------------------
REM Stage 2 (Windows): standalone LLVM Flang against stage-1 llvm-zig.
REM See docs/05-platform-matrix.md, section "win-64", before editing.
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

if not defined FLANG_PARALLEL_COMPILE_JOBS set "FLANG_PARALLEL_COMPILE_JOBS=2"

REM MinGW-w64/UCRT ABI, not MSVC -- see stage 1's build.bat for the full
REM rationale and docs/11-r-zig-integration.md for why R requires it.
if not defined ZIG_WIN_ABI_TARGET set "ZIG_WIN_ABI_TARGET=x86_64-windows-gnu"
set "WIN_ABI_ARGS=-DCMAKE_C_COMPILER_TARGET=%ZIG_WIN_ABI_TARGET%"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_CXX_COMPILER_TARGET=%ZIG_WIN_ABI_TARGET%"

if not exist "%LIBRARY_LIB%\cmake\mlir\MLIRConfig.cmake" (
  echo ERROR: llvm-zig ^(stage 1^) not found in the host prefix.
  exit /b 1
)

REM Cross build: win-64 -> win-arm64. tblgen must run natively.
set "CROSS_ARGS="
if not "%build_platform%"=="%target_platform%" (
  echo == cross build: %build_platform% -^> %target_platform% ==
  set "NATIVE_BIN=%BUILD_PREFIX%\Library\bin"
  set "NATIVE_BIN_CMAKE=!NATIVE_BIN:\=/!"
  set "CROSS_ARGS=-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=ARM64"
  set "CROSS_ARGS=!CROSS_ARGS! -DLLVM_NATIVE_TOOL_DIR=!NATIVE_BIN_CMAKE!"
  set "CROSS_ARGS=!CROSS_ARGS! -DLLVM_TABLEGEN=!NATIVE_BIN_CMAKE!/llvm-tblgen.exe"
  set "CROSS_ARGS=!CROSS_ARGS! -DMLIR_TABLEGEN_EXE=!NATIVE_BIN_CMAKE!/mlir-tblgen.exe"
  set "CROSS_ARGS=!CROSS_ARGS! -DCLANG_TABLEGEN=!NATIVE_BIN_CMAKE!/clang-tblgen.exe"
  set "CROSS_ARGS=!CROSS_ARGS! -DLLVM_CONFIG_PATH=!NATIVE_BIN_CMAKE!/llvm-config.exe"
)

cmake -G Ninja -S flang -B build %WIN_ABI_ARGS% %CROSS_ARGS% ^
  -DCMAKE_C_COMPILER="%ZIG_CC_CMAKE%" ^
  -DCMAKE_CXX_COMPILER="%ZIG_CXX_CMAKE%" ^
  -DCMAKE_ASM_COMPILER="%ZIG_CC_CMAKE%" ^
  -DCMAKE_AR="%ZIG_AR_CMAKE%" ^
  -DCMAKE_RANLIB="%ZIG_RANLIB_CMAKE%" ^
  -DCMAKE_RC_COMPILER="%ZIG_RC_CMAKE%" ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_INSTALL_PREFIX="%LIBRARY_PREFIX%" ^
  -DCMAKE_PREFIX_PATH="%LIBRARY_PREFIX%" ^
  -DCMAKE_CXX_STANDARD=17 ^
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON ^
  -DCMAKE_MODULE_PATH="%SRC_DIR%/cmake/Modules" ^
  -DCMAKE_PROJECT_INCLUDE="%RECIPE_DIR_CMAKE%/cmake-project-include.cmake" ^
  -DBUILD_SHARED_LIBS=OFF ^
  -DLLVM_DIR="%LIBRARY_LIB%/cmake/llvm" ^
  -DLLVM_CMAKE_DIR="%LIBRARY_LIB%/cmake/llvm" ^
  -DCLANG_DIR="%LIBRARY_LIB%/cmake/clang" ^
  -DMLIR_DIR="%LIBRARY_LIB%/cmake/mlir" ^
  -DFLANG_INCLUDE_RUNTIME=OFF ^
  -DFLANG_INCLUDE_TESTS=OFF ^
  -DFLANG_INCLUDE_DOCS=OFF ^
  -DFLANG_PARALLEL_COMPILE_JOBS=%FLANG_PARALLEL_COMPILE_JOBS% ^
  -DLLVM_PARALLEL_LINK_JOBS=1
if %ERRORLEVEL% neq 0 exit /b 1

cmake --build build -j %CPU_COUNT%
if %ERRORLEVEL% neq 0 exit /b 1

cmake --install build
if %ERRORLEVEL% neq 0 exit /b 1

if not exist "%LIBRARY_BIN%\flang.exe" (
  echo ERROR: flang.exe was not installed.
  exit /b 1
)
