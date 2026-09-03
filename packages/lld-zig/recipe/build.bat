@echo on
setlocal enabledelayedexpansion

REM ---------------------------------------------------------------------------
REM Stage 1.5 (Windows): standalone lld against llvm-zig in %PREFIX% (HOST
REM dep — target-platform archives; this is what makes the win-arm64 cross
REM build produce a genuine arm64 lld). Mirrors build.sh.
REM ---------------------------------------------------------------------------

if not defined ZIG_GLOBAL_CACHE_DIR set "ZIG_GLOBAL_CACHE_DIR=%SRC_DIR%\.zig-global-cache"
if not exist "%ZIG_GLOBAL_CACHE_DIR%" mkdir "%ZIG_GLOBAL_CACHE_DIR%"

if not defined ZIG_CC ( echo ERROR: ZIG_CC unset & exit /b 1 )
if not defined ZIG_CXX ( echo ERROR: ZIG_CXX unset & exit /b 1 )

if not defined CFLAGS set "CFLAGS="
if not defined CXXFLAGS set "CXXFLAGS="
set "CFLAGS=%CFLAGS% -g0"
set "CXXFLAGS=%CXXFLAGS% -g0"

set "ZIG_CC_CMAKE=%ZIG_CC:\=/%"
set "ZIG_CXX_CMAKE=%ZIG_CXX:\=/%"
set "ZIG_AR_CMAKE=%ZIG_AR:\=/%"
set "ZIG_RANLIB_CMAKE=%ZIG_RANLIB:\=/%"

REM MinGW-w64/UCRT ABI, not MSVC — same as the other packages, see
REM llvm-zig/recipe/build.bat for the full rationale.
if not defined ZIG_WIN_ABI_TARGET set "ZIG_WIN_ABI_TARGET=x86_64-windows-gnu"
set "WIN_ABI_ARGS=-DCMAKE_C_COMPILER_TARGET=%ZIG_WIN_ABI_TARGET%"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_CXX_COMPILER_TARGET=%ZIG_WIN_ABI_TARGET%"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_ASM_FLAGS=--target=%ZIG_WIN_ABI_TARGET%"

REM llvm-zig is in the HOST prefix now.
set "LLVM_CMAKE=%LIBRARY_LIB%\cmake\llvm"
if not exist "%LLVM_CMAKE%\LLVMConfig.cmake" (
  echo ERROR: llvm-zig not found in the host prefix.
  exit /b 1
)
set "LLVM_CMAKE_FWD=%LLVM_CMAKE:\=/%"

REM Cross build: win-64 -> win-arm64. tblgen runs natively (llvm-zig in
REM requirements/build for cross); the arm64 archives come from host.
set "CROSS_ARGS="
set "STRIP_BIN=%LIBRARY_BIN%\llvm-strip.exe"
REM rattler sets build_platform == target_platform in the script env for
REM cross builds too — the classic equality test NEVER detects cross here.
REM Test the target directly instead.
if not "%target_platform%"=="win-arm64" goto :native_build
REM Cross build. goto-style — see llvm-zig/recipe/build.bat.
echo == cross build to %target_platform% ==
if not exist "%BUILD_PREFIX%\Library\bin\llvm-tblgen.exe" (
  echo ERROR: cross build needs a native llvm-zig in BUILD_PREFIX.
  exit /b 1
)
set "NATIVE_BIN_CMAKE=%BUILD_PREFIX:\=/%/Library/bin"
set "CROSS_ARGS=-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=ARM64"
set "CROSS_ARGS=%CROSS_ARGS% -DLLVM_TABLEGEN_EXE=%NATIVE_BIN_CMAKE%/llvm-tblgen.exe"
set "WIN_ABI_ARGS=-DCMAKE_C_COMPILER_TARGET=aarch64-windows-gnu"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_CXX_COMPILER_TARGET=aarch64-windows-gnu"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_ASM_FLAGS=--target=aarch64-windows-gnu"
set "STRIP_BIN=%BUILD_PREFIX%\Library\bin\llvm-strip.exe"
REM zig's aarch64-windows-gnu CRT lacks wcstold (x64 flavor has it) and
REM LLVM's Support code references it -> every exe/dll link fails. On
REM arm64-Windows long double IS double, so a forwarding shim is exactly
REM correct. Compile it once and put it on every link line.
powershell -Command "Set-Content -Path '%SRC_DIR%\wcstold_compat.c' -Value '#include <wchar.h>', 'long double wcstold(const wchar_t *n, wchar_t **e) { return (long double)wcstod(n, e); }'"
"%ZIG_CC%" --target=aarch64-windows-gnu -O2 -c "%SRC_DIR%\wcstold_compat.c" -o "%SRC_DIR%\wcstold_compat.o"
if %ERRORLEVEL% neq 0 exit /b 1
set "WCSTOLD_OBJ=%SRC_DIR:\=/%/wcstold_compat.o"
set "CROSS_ARGS=%CROSS_ARGS% -DCMAKE_EXE_LINKER_FLAGS=%WCSTOLD_OBJ% -DCMAKE_SHARED_LINKER_FLAGS=%WCSTOLD_OBJ%"
goto :args_done
:native_build
set "CROSS_ARGS=-DLLVM_TABLEGEN_EXE=%LIBRARY_BIN:\=/%/llvm-tblgen.exe"
:args_done
echo WIN_ABI_ARGS=%WIN_ABI_ARGS%
echo CROSS_ARGS=%CROSS_ARGS%

cmake -G Ninja -S lld -B build %WIN_ABI_ARGS% %CROSS_ARGS% ^
  -DCMAKE_C_COMPILER="%ZIG_CC_CMAKE%" ^
  -DCMAKE_CXX_COMPILER="%ZIG_CXX_CMAKE%" ^
  -DCMAKE_ASM_COMPILER="%ZIG_CC_CMAKE%" ^
  -DCMAKE_AR="%ZIG_AR_CMAKE%" ^
  -DCMAKE_RANLIB="%ZIG_RANLIB_CMAKE%" ^
  -DCMAKE_RC_COMPILER="%ZIG_RC_CMAKE%" ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_INSTALL_PREFIX="%LIBRARY_PREFIX%" ^
  -DCMAKE_CXX_STANDARD=17 ^
  -DLLVM_DIR="%LLVM_CMAKE_FWD%" ^
  -DLLVM_CMAKE_DIR="%LLVM_CMAKE_FWD%" ^
  -DLLD_INCLUDE_TESTS=OFF ^
  -DLLVM_INCLUDE_TESTS=OFF ^
  -DLLVM_PARALLEL_LINK_JOBS=1
if %ERRORLEVEL% neq 0 exit /b 1

cmake --build build -j %CPU_COUNT%
if %ERRORLEVEL% neq 0 exit /b 1

cmake --install build
if %ERRORLEVEL% neq 0 exit /b 1

if not exist "%LIBRARY_BIN%\lld.exe" (
  echo ERROR: lld.exe was not installed.
  exit /b 1
)

REM --- slimming: binaries only ---------------------------------------------
REM Delete liblld*.lib + include\lld + lib\cmake\lld (build-against-lld
REM inputs nobody consumes at runtime) before packaging.
del /q "%LIBRARY_LIB%\lld*.lib" 2>nul
rmdir /s /q "%LIBRARY_PREFIX%\include\lld" 2>nul
rmdir /s /q "%LIBRARY_LIB%\cmake\lld" 2>nul

REM Strip (native: host llvm-strip; cross: native llvm-strip from build).
if exist "%STRIP_BIN%" (
  for %%F in ("%LIBRARY_BIN%\lld*.exe" "%LIBRARY_BIN%\ld.lld.exe" "%LIBRARY_BIN%\ld64.lld.exe" "%LIBRARY_BIN%\wasm-ld.exe") do "%STRIP_BIN%" --strip-all "%%F" 2>nul
) else (
  echo WARNING: llvm-strip not found at %STRIP_BIN%, skipping strip pass
)
ver >nul

REM Hardlink-dedup the alias exes (Windows twin of the unix symlink dedup;
REM post-strip the copies are byte-identical -- fc-guarded like the
REM flang-new dedup, so a mismatch leaves both files alone).
for %%A in (ld.lld.exe ld64.lld.exe lld-link.exe wasm-ld.exe) do (
  if exist "%LIBRARY_BIN%\%%A" (
    fc /b "%LIBRARY_BIN%\lld.exe" "%LIBRARY_BIN%\%%A" >nul 2>nul
    if not errorlevel 1 (
      del /f "%LIBRARY_BIN%\%%A"
      mklink /h "%LIBRARY_BIN%\%%A" "%LIBRARY_BIN%\lld.exe" >nul
      echo deduplicated %%A -^> lld.exe
    )
  )
)
ver >nul

REM Reset ERRORLEVEL: on cross builds the host llvm-strip.exe is a
REM foreign-arch binary whose failed invocations (tolerated per-file via
REM 2>nul) otherwise leave a poisoned exit code that fails the whole
REM script AFTER a successful build.
ver >nul
