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

REM -g0: zig cc/c++ emit full DWARF debug info by default, unrelated to
REM optimization flags -- see llvm-zig/recipe/build.bat and
REM docs/10-status-log.md for the full story and the Linux-side measurement.
if not defined CFLAGS set "CFLAGS="
if not defined CXXFLAGS set "CXXFLAGS="
set "CFLAGS=%CFLAGS% -g0"
set "CXXFLAGS=%CXXFLAGS% -g0"

set "ZIG_CC_CMAKE=%ZIG_CC:\=/%"
set "ZIG_CXX_CMAKE=%ZIG_CXX:\=/%"
set "ZIG_AR_CMAKE=%ZIG_AR:\=/%"
set "ZIG_RANLIB_CMAKE=%ZIG_RANLIB:\=/%"
set "RECIPE_DIR_CMAKE=%RECIPE_DIR:\=/%"
REM %SRC_DIR% expands with backslashes (C:\Users\...) and CMake reads \U
REM in "C:\Users" as an invalid character escape when the value crosses
REM try_compile boundaries. Forward-slash everything CMake sees.
set "SRC_DIR_CMAKE=%SRC_DIR:\=/%"

if not defined FLANG_PARALLEL_COMPILE_JOBS set "FLANG_PARALLEL_COMPILE_JOBS=2"

REM MinGW-w64/UCRT ABI, not MSVC -- see stage 1's build.bat for the full
REM rationale and docs/11-r-zig-integration.md for why R requires it.
if not defined ZIG_WIN_ABI_TARGET set "ZIG_WIN_ABI_TARGET=x86_64-windows-gnu"
set "WIN_ABI_ARGS=-DCMAKE_C_COMPILER_TARGET=%ZIG_WIN_ABI_TARGET%"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_CXX_COMPILER_TARGET=%ZIG_WIN_ABI_TARGET%"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_ASM_FLAGS=--target=%ZIG_WIN_ABI_TARGET%"

if not exist "%LIBRARY_LIB%\cmake\mlir\MLIRConfig.cmake" (
  echo ERROR: llvm-zig ^(stage 1^) not found in the host prefix.
  exit /b 1
)

set "CROSS_ARGS="
REM rattler sets build_platform == target_platform in the script env for
REM cross builds too — the classic equality test NEVER detects cross here.
REM Test the target directly instead.
if not "%target_platform%"=="win-arm64" goto :native_build
REM Cross build. goto-style — see llvm-zig/recipe/build.bat for why
REM parenthesized set-blocks are unusable here.
echo == cross build to %target_platform% ==
set "NATIVE_BIN_CMAKE=%BUILD_PREFIX:\=/%/Library/bin"
set "CROSS_ARGS=-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=ARM64"
set "CROSS_ARGS=%CROSS_ARGS% -DLLVM_NATIVE_TOOL_DIR=%NATIVE_BIN_CMAKE%"
set "CROSS_ARGS=%CROSS_ARGS% -DLLVM_TABLEGEN=%NATIVE_BIN_CMAKE%/llvm-tblgen.exe"
set "CROSS_ARGS=%CROSS_ARGS% -DMLIR_TABLEGEN_EXE=%NATIVE_BIN_CMAKE%/mlir-tblgen.exe"
set "CROSS_ARGS=%CROSS_ARGS% -DCLANG_TABLEGEN=%NATIVE_BIN_CMAKE%/clang-tblgen.exe"
set "CROSS_ARGS=%CROSS_ARGS% -DLLVM_CONFIG_PATH=%NATIVE_BIN_CMAKE%/llvm-config.exe"
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

REM Upstream MinGW gap: RTBuilder.h's memcpy-fptr getModel specialization is
REM _MSC_VER-only but size_t is unsigned long long here too. See the patch
REM script for the full story (undefined getModel<...unsigned long long> at
REM the first .exe link otherwise).
powershell -ExecutionPolicy Bypass -File "%RECIPE_DIR%\patch-rtbuilder.ps1"
if %ERRORLEVEL% neq 0 exit /b 1

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
  -DCMAKE_MODULE_PATH="%SRC_DIR_CMAKE%/cmake/Modules" ^
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

REM Deduplicate flang-new.exe / flang-<major>.exe -- mirrors the unix
REM build.sh dedup (same binary installed twice under different names).
REM Unverified on Windows: fc /b for byte comparison, hardlink via mklink
REM /H since Windows lacks a portable symlink-without-privilege option.
for /f "delims=." %%V in ("%PKG_VERSION%") do set "MAJOR_VER=%%V"
set "FLANG_NEW=%LIBRARY_BIN%\flang-new.exe"
set "FLANG_VERSIONED=%LIBRARY_BIN%\flang-%MAJOR_VER%.exe"
if exist "%FLANG_NEW%" if exist "%FLANG_VERSIONED%" (
  fc /b "%FLANG_NEW%" "%FLANG_VERSIONED%" >nul 2>nul
  if !ERRORLEVEL! equ 0 (
    del /f "%FLANG_NEW%"
    mklink /H "%FLANG_NEW%" "%FLANG_VERSIONED%" >nul
    echo flang-new.exe deduplicated -^> flang-%MAJOR_VER%.exe
  ) else (
    echo WARNING: flang-new.exe and flang-%MAJOR_VER%.exe differ; not deduplicating
  )
)

REM Driver config: route linking through our ld.lld (lld-zig run dep) --
REM without this the MinGW driver invokes bare `ld`, which does not exist
REM in the env. The Windows analog of the unix flang.cfg block. The CRT
REM the driver then finds is extracted by flang-rt-zig (stage 3).
powershell -Command "[IO.File]::WriteAllText('%LIBRARY_BIN%\flang.cfg', \"-fuse-ld=lld`n\")"
if not exist "%LIBRARY_BIN%\flang.cfg" ( echo ERROR: flang.cfg not written & exit /b 1 )

REM Strip installed executables -- mirrors the unix build.sh strip pass.
set "STRIP_BIN=%LIBRARY_BIN%\llvm-strip.exe"
REM Cross: the host llvm-strip is a foreign-arch binary -- use the native
REM one from BUILD_PREFIX (llvm-strip handles foreign COFF fine).
if "%target_platform%"=="win-arm64" set "STRIP_BIN=%BUILD_PREFIX%\Library\bin\llvm-strip.exe"
if exist "%STRIP_BIN%" (
  echo == stripping installed executables with %STRIP_BIN% ==
  for %%F in ("%LIBRARY_BIN%\*.exe") do "%STRIP_BIN%" --strip-all "%%F" 2>nul
) else (
  echo WARNING: llvm-strip.exe not found at %STRIP_BIN%, skipping strip pass
)

REM Reset ERRORLEVEL: on cross builds the host llvm-strip.exe is a
REM foreign-arch binary whose failed invocations (tolerated per-file via
REM 2>nul) otherwise leave a poisoned exit code that fails the whole
REM script AFTER a successful build.
ver >nul
