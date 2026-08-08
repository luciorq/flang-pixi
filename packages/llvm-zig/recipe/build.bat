@echo on
setlocal enabledelayedexpansion

REM ---------------------------------------------------------------------------
REM Stage 1 (Windows): LLVM + MLIR + Clang + LLD, compiled with zig.
REM
REM Windows is the leg with the most at stake: it is the only platform where a
REM MinGW-ABI flang does not exist anywhere, which is why r-zig-pixi still uses
REM MinGW gfortran there. Read docs/11-r-zig-integration.md before editing.
REM
REM The zig activation on Windows sets ZIG_CC / ZIG_CXX / ZIG_AR / ZIG_RANLIB /
REM ZIG_RC / ZIG_RC_CMAKE, all pointing at .exe wrappers in %LIBRARY_BIN%.
REM ---------------------------------------------------------------------------

if not defined ZIG_GLOBAL_CACHE_DIR set "ZIG_GLOBAL_CACHE_DIR=%SRC_DIR%\.zig-global-cache"
if not exist "%ZIG_GLOBAL_CACHE_DIR%" mkdir "%ZIG_GLOBAL_CACHE_DIR%"

if not defined ZIG_CC (
  echo ERROR: ZIG_CC unset - zig activation did not run.
  exit /b 1
)
if not defined ZIG_CXX (
  echo ERROR: ZIG_CXX unset - zig activation did not run.
  exit /b 1
)

echo == zig toolchain ==
"%ZIG%" version
echo ZIG_CC=%ZIG_CC%
echo ZIG_CXX=%ZIG_CXX%

REM CMake wants forward slashes for compiler paths on Windows.
set "ZIG_CC_CMAKE=%ZIG_CC:\=/%"
set "ZIG_CXX_CMAKE=%ZIG_CXX:\=/%"
set "ZIG_AR_CMAKE=%ZIG_AR:\=/%"
set "ZIG_RANLIB_CMAKE=%ZIG_RANLIB:\=/%"

if not defined LLVM_PROJECTS set "LLVM_PROJECTS=clang;lld;mlir"
if not defined LLVM_TARGETS_TO_BUILD set "LLVM_TARGETS_TO_BUILD=Native"
if not defined LLVM_PARALLEL_LINK_JOBS set "LLVM_PARALLEL_LINK_JOBS=1"

REM ===========================================================================
REM WINDOWS ABI: MinGW-w64/UCRT, *not* MSVC. This is the whole point of the
REM Windows leg — see docs/11-r-zig-integration.md.
REM
REM R's gnuwin32 build and `zig cc`'s -windows-gnu target are both MinGW.
REM conda-forge's own flang_win-64 targets x86_64-pc-windows-msvc, which is
REM why r-zig-pixi had to drop it and fall back to MinGW gfortran. A
REM MinGW-ABI flang does not exist anywhere; producing one is this project's
REM reason to exist on Windows.
REM
REM zig_win-64's wrappers default to `-target x86_64-windows-msvc`
REM (zig-feedstock: zig_triplet, selected by xc_w64 which is true for the
REM native package too). The wrapper only injects its own -target when the
REM caller supplies none, so passing ours explicitly wins.
REM
REM zig ships the MinGW CRT to make this work: zig-feedstock's own
REM testing/test_mingw_crt.py asserts libucrt.a and libwinpthread.a are
REM present -- UCRT + winpthread, matching conda-forge's MinGW gcc world.
REM
REM Two DIFFERENT settings, do not conflate them:
REM   CMAKE_{C,CXX}_COMPILER_TARGET -> the ABI flang.exe ITSELF is built to
REM   LLVM_DEFAULT_TARGET_TRIPLE    -> the ABI flang EMITS CODE FOR  <-- the
REM                                    one R actually cares about
REM ===========================================================================
if not defined ZIG_WIN_ABI_TARGET set "ZIG_WIN_ABI_TARGET=x86_64-windows-gnu"
if not defined LLVM_WIN_TRIPLE    set "LLVM_WIN_TRIPLE=x86_64-w64-windows-gnu"

set "WIN_ABI_ARGS=-DCMAKE_C_COMPILER_TARGET=%ZIG_WIN_ABI_TARGET%"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_CXX_COMPILER_TARGET=%ZIG_WIN_ABI_TARGET%"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DCMAKE_ASM_COMPILER_TARGET=%ZIG_WIN_ABI_TARGET%"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DLLVM_HOST_TRIPLE=%LLVM_WIN_TRIPLE%"
set "WIN_ABI_ARGS=%WIN_ABI_ARGS% -DLLVM_DEFAULT_TARGET_TRIPLE=%LLVM_WIN_TRIPLE%"

REM ---------------------------------------------------------------------------
REM Cross build: win-64 -> win-arm64.
REM
REM This is the ONLY cross path in the project, and it is not optional:
REM conda-forge publishes zig_win-arm64 exclusively into the win-64 subdir, so
REM there is no native win-arm64 toolchain to build with.
REM
REM tblgen must run on the build machine, so we hand LLVM a previously built
REM native (win-64) llvm-zig via LLVM_NATIVE_TOOL_DIR. The recipe adds it to
REM requirements/build when build_platform != target_platform.
REM
REM IMPORTANT: the win-64 llvm-zig used here must have been built with AArch64
REM in LLVM_TARGETS_TO_BUILD, or its tools cannot handle the arm64 target.
REM See docs/05-platform-matrix.md.
REM ---------------------------------------------------------------------------
set "CROSS_ARGS="
if not "%build_platform%"=="%target_platform%" (
  echo == cross build: %build_platform% -^> %target_platform% ==
  if not exist "%BUILD_PREFIX%\Library\bin\llvm-tblgen.exe" (
    echo ERROR: cross build needs a native llvm-zig in BUILD_PREFIX.
    echo        Build and publish llvm-zig for %build_platform% first.
    exit /b 1
  )
  set "NATIVE_BIN=%BUILD_PREFIX%\Library\bin"
  set "NATIVE_BIN_CMAKE=!NATIVE_BIN:\=/!"
  set "CROSS_ARGS=-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=ARM64"
  set "CROSS_ARGS=!CROSS_ARGS! -DLLVM_NATIVE_TOOL_DIR=!NATIVE_BIN_CMAKE!"
  set "CROSS_ARGS=!CROSS_ARGS! -DLLVM_TABLEGEN=!NATIVE_BIN_CMAKE!/llvm-tblgen.exe"
  set "CROSS_ARGS=!CROSS_ARGS! -DMLIR_TABLEGEN_EXE=!NATIVE_BIN_CMAKE!/mlir-tblgen.exe"
  set "CROSS_ARGS=!CROSS_ARGS! -DCLANG_TABLEGEN=!NATIVE_BIN_CMAKE!/clang-tblgen.exe"
  set "CROSS_ARGS=!CROSS_ARGS! -DLLVM_CONFIG_PATH=!NATIVE_BIN_CMAKE!/llvm-config.exe"
  REM win-arm64 keeps the same GNU ABI choice as win-64.
  set "CROSS_ARGS=!CROSS_ARGS! -DLLVM_HOST_TRIPLE=aarch64-w64-windows-gnu"
  set "CROSS_ARGS=!CROSS_ARGS! -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-w64-windows-gnu"
  set "WIN_ABI_ARGS=-DCMAKE_C_COMPILER_TARGET=aarch64-windows-gnu"
  set "WIN_ABI_ARGS=!WIN_ABI_ARGS! -DCMAKE_CXX_COMPILER_TARGET=aarch64-windows-gnu"
  set "WIN_ABI_ARGS=!WIN_ABI_ARGS! -DLLVM_HOST_TRIPLE=aarch64-w64-windows-gnu"
  set "WIN_ABI_ARGS=!WIN_ABI_ARGS! -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-w64-windows-gnu"
)

cmake -G Ninja -S llvm -B build %WIN_ABI_ARGS% %CROSS_ARGS% ^
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
  -DPython3_EXECUTABLE="%BUILD_PREFIX%\python.exe" ^
  -DLLVM_ENABLE_PROJECTS="%LLVM_PROJECTS%" ^
  -DLLVM_TARGETS_TO_BUILD="%LLVM_TARGETS_TO_BUILD%" ^
  -DLLVM_PARALLEL_LINK_JOBS="%LLVM_PARALLEL_LINK_JOBS%" ^
  -DLLVM_ENABLE_RTTI=ON ^
  -DLLVM_ENABLE_ASSERTIONS=OFF ^
  -DLLVM_ENABLE_ZLIB=OFF ^
  -DLLVM_ENABLE_ZSTD=OFF ^
  -DLLVM_ENABLE_LIBXML2=OFF ^
  -DLLVM_ENABLE_TERMINFO=OFF ^
  -DLLVM_BUILD_LLVM_DYLIB=OFF ^
  -DLLVM_LINK_LLVM_DYLIB=OFF ^
  -DLLVM_INCLUDE_BENCHMARKS=OFF ^
  -DLLVM_INCLUDE_DOCS=OFF ^
  -DLLVM_INCLUDE_EXAMPLES=OFF ^
  -DLLVM_INCLUDE_TESTS=OFF ^
  -DLLVM_INCLUDE_UTILS=ON ^
  -DLLVM_INSTALL_UTILS=ON ^
  -DCLANG_INCLUDE_TESTS=OFF ^
  -DCLANG_INCLUDE_DOCS=OFF ^
  -DMLIR_INCLUDE_TESTS=OFF ^
  -DMLIR_INCLUDE_DOCS=OFF ^
  -DLLD_INCLUDE_TESTS=OFF ^
  -DLLVM_TOOL_LLVM_EXEGESIS_BUILD=OFF
if %ERRORLEVEL% neq 0 exit /b 1

cmake --build build -j %CPU_COUNT%
if %ERRORLEVEL% neq 0 exit /b 1

cmake --install build
if %ERRORLEVEL% neq 0 exit /b 1

REM tblgen safety net - see the unix script for the rationale.
for %%T in (llvm-tblgen mlir-tblgen clang-tblgen) do (
  if not exist "%LIBRARY_BIN%\%%T.exe" (
    if exist "build\bin\%%T.exe" copy /Y "build\bin\%%T.exe" "%LIBRARY_BIN%\%%T.exe"
  )
)

if not exist "%LIBRARY_PREFIX%\share\llvm-zig" mkdir "%LIBRARY_PREFIX%\share\llvm-zig"
(
  echo llvm_version=%PKG_VERSION%
  echo llvm_projects=%LLVM_PROJECTS%
  echo llvm_targets=%LLVM_TARGETS_TO_BUILD%
  echo cxx_runtime=zig-bundled-libc++ ^(static^)
) > "%LIBRARY_PREFIX%\share\llvm-zig\build-info.txt"
