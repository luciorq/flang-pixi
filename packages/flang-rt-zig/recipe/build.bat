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
REM Second aarch64 CRT gap (windows-11-arm GHA runner, docs/10 2026-09-19):
REM zig's arm64 libkernel32.a claims KERNEL32.dll exports __C_specific_handler
REM (the SEH personality every LLVM binary references). Only x64 kernel32 does;
REM upstream mingw-w64 limits that entry to x64/arm32, and arm64 Windows
REM exports it from the UCRT (api-ms-win-crt-private-l1-1-0 -> ucrtbase).
REM Plain `zig cc` links resolve it from the UCRT, but CMake appends
REM -lkernel32 to every MinGW link line ahead of zig's implicit CRT libs, so
REM every exe/dll imported it from KERNEL32 and died at load (0xC0000139
REM STATUS_ENTRYPOINT_NOT_FOUND). Fix: a one-symbol import library for the
REM private api set, merged into libcompat_arm64.a; lld takes the first
REM definition it sees and that archive is the first thing on the link line.
(echo LIBRARY api-ms-win-crt-private-l1-1-0.dll& echo EXPORTS& echo __C_specific_handler) > "%SRC_DIR%\csh_arm64.def"
"%BUILD_PREFIX%\Library\bin\x86_64-w64-mingw32-zig.exe" dlltool -m arm64 -d "%SRC_DIR%\csh_arm64.def" -l "%SRC_DIR%\libcsh_arm64.a"
if %ERRORLEVEL% neq 0 exit /b 1
REM One archive (wcstold shim + the import redirect) = one linker-flag token.
REM llvm-ar's MRI script is the only way to merge an archive into an archive.
del /q "%SRC_DIR%\libcompat_arm64.a" 2>nul
(echo create %SRC_DIR:\=/%/libcompat_arm64.a& echo addmod %SRC_DIR:\=/%/wcstold_compat.o& echo addlib %SRC_DIR:\=/%/libcsh_arm64.a& echo save& echo end) > "%SRC_DIR%\compat_arm64.mri"
llvm-ar -M < "%SRC_DIR%\compat_arm64.mri"
if %ERRORLEVEL% neq 0 exit /b 1
set "COMPAT_LIB=%SRC_DIR:\=/%/libcompat_arm64.a"
set "CROSS_ARGS=%CROSS_ARGS% -DCMAKE_EXE_LINKER_FLAGS=%COMPAT_LIB% -DCMAKE_SHARED_LINKER_FLAGS=%COMPAT_LIB%"
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

REM Per-target directories: on cross builds (win-64 -> win-arm64) the runtimes
REM CMake names lib\<triple> and (LLVM >= 23) finclude\flang\<triple> after
REM the BUILD host (x86_64-w64-windows-gnu); the driver resolves both by its
REM own TARGET triple. Normalise both to the target's windows-gnu triple
REM (matches the driver's default lookup), and expose the intrinsic modules
REM a second time under the conda triple that flang-zig's flang.cfg names in
REM -fintrinsic-modules-path. NOTE: cmd's `for /d` only accepts a wildcard in
REM the LAST path component, hence the nested loops (a single
REM "clang\*\finclude\flang\*" glob silently matches nothing -- that is how
REM the first 23.1.1 Windows builds shipped without this rename).
REM See the unix build.sh and docs/10 2026-09-17/18.
set "RT_TRIPLE=x86_64-w64-windows-gnu"
if "%target_platform%"=="win-arm64" set "RT_TRIPLE=aarch64-w64-windows-gnu"
set "FINC_TRIPLE=x86_64-w64-mingw32"
if "%target_platform%"=="win-arm64" set "FINC_TRIPLE=aarch64-w64-mingw32"
REM Only OUR resource dir: llvm-openmp (host dep since build 4) ships
REM Library\lib\clang\{18,19,20}\include\omp.h, and looping over clang\* made
REM the checks below fail on those (first win-64 build-4 attempt).
for /d %%D in ("%LIBRARY_LIB%\clang\*") do if exist "%%D\finclude\flang\" (
  for /d %%T in ("%%D\lib\*windows-gnu") do if /i not "%%~nxT"=="%RT_TRIPLE%" (
    if not exist "%%D\lib\%RT_TRIPLE%" ( move "%%T" "%%D\lib\%RT_TRIPLE%" >nul && echo runtime dir: %%~nxT -^> %RT_TRIPLE% )
  )
  for /d %%F in ("%%D\finclude\flang\*") do if /i not "%%~nxF"=="%RT_TRIPLE%" if /i not "%%~nxF"=="%FINC_TRIPLE%" (
    if not exist "%%D\finclude\flang\%RT_TRIPLE%" ( move "%%F" "%%D\finclude\flang\%RT_TRIPLE%" >nul && echo intrinsic modules: %%~nxF -^> %RT_TRIPLE% )
  )
  if exist "%%D\finclude\flang\%RT_TRIPLE%" if not exist "%%D\finclude\flang\%FINC_TRIPLE%" (
    xcopy /e /i /q "%%D\finclude\flang\%RT_TRIPLE%" "%%D\finclude\flang\%FINC_TRIPLE%" >nul && echo intrinsic modules also under %FINC_TRIPLE%
  )
  if not exist "%%D\finclude\flang\%FINC_TRIPLE%\__fortran_type_info.mod" ( echo ERROR: __fortran_type_info.mod missing under %%D\finclude\flang & exit /b 1 )
  if not exist "%%D\lib\%RT_TRIPLE%\libflang_rt.runtime.a" ( echo ERROR: libflang_rt.runtime.a missing under %%D\lib\%RT_TRIPLE% & exit /b 1 )
)

REM --- OpenMP: Fortran module + the two MinGW link shims ----------------------
REM (1) omp_lib.mod / omp_lib_kinds.mod / omp_lib.h built from LLVM's
REM     openmp\module\omp_lib.F90.var with this flang (see build.sh).
REM (2) libomp.dll.a: `flang -fopenmp` emits -lomp, and the MinGW driver only
REM     finds lib<name>.dll.a / <name>.lib, never conda-forge's MSVC-named
REM     libomp.lib. Generate a MinGW import library from the exports of the
REM     conda-forge libomp.dll (host dep) with zig's dlltool, so Fortran
REM     OpenMP binds the SAME libomp.dll that zig cc's C/C++ code uses —
REM     one OpenMP runtime per process.
REM (3) libatomic.a: the driver also emits -latomic on Windows; zig's MinGW
REM     CRT has no libatomic. An empty archive satisfies the reference
REM     (atomic helpers live in compiler-rt builtins). docs/10 2026-09-18.
set "OMP_TMP=%SRC_DIR%\omp-mod"
mkdir "%OMP_TMP%" 2>nul
for /f "tokens=3" %%V in ('findstr /c:"define KMP_VERSION_BUILD" "%SRC_DIR%\openmp\runtime\src\kmp_version.cpp"') do set "OMP_BUILD=%%V"
if not defined OMP_BUILD set "OMP_BUILD=20140926"
powershell -NoProfile -Command "$b='%OMP_BUILD%'; foreach ($f in 'omp_lib.F90','omp_lib.h') { (Get-Content -Raw \"%SRC_DIR%\openmp\module\$f.var\").Replace('@LIBOMP_VERSION_MAJOR@','5').Replace('@LIBOMP_VERSION_MINOR@','0').Replace('@LIBOMP_OMP_YEAR_MONTH@','201611').Replace('@LIBOMP_VERSION_BUILD@',$b).Replace('@LIBOMP_BUILD_DATE@','No_Timestamp') | Set-Content -NoNewline \"%OMP_TMP%\$f\" }"
if errorlevel 1 ( echo ERROR: omp_lib template substitution failed & exit /b 1 )
set "OMP_TARGET_FLAG="
if "%target_platform%"=="win-arm64" set "OMP_TARGET_FLAG=--target=aarch64-w64-windows-gnu"
pushd "%OMP_TMP%"
REM -fintrinsic-modules-path: the freshly built intrinsic modules in %PREFIX%
REM (see build.sh for why); the RT_TRIPLE dir exists after the rename above.
set "OMP_FINC="
for /d %%D in ("%LIBRARY_LIB%\clang\*") do if exist "%%D\finclude\flang\%RT_TRIPLE%\iso_c_binding.mod" set "OMP_FINC=%%D\finclude\flang\%RT_TRIPLE%"
if not defined OMP_FINC ( echo ERROR: freshly built intrinsic modules not found & exit /b 1 )
"%FLANG_BIN%" -c -fopenmp %OMP_TARGET_FLAG% -fintrinsic-modules-path "%OMP_FINC%" omp_lib.F90 -module-dir "%OMP_TMP%" -o omp_lib.obj
if errorlevel 1 ( popd & echo ERROR: omp_lib.F90 did not compile & exit /b 1 )
popd
for /d %%D in ("%LIBRARY_LIB%\clang\*") do (
  for %%N in (%RT_TRIPLE% %FINC_TRIPLE%) do if exist "%%D\finclude\flang\%%N" (
    copy /y "%OMP_TMP%\omp_lib.mod" "%%D\finclude\flang\%%N\" >nul
    copy /y "%OMP_TMP%\omp_lib_kinds.mod" "%%D\finclude\flang\%%N\" >nul
    copy /y "%OMP_TMP%\omp_lib.h" "%%D\finclude\flang\%%N\" >nul
    echo OpenMP Fortran module installed under %%D\finclude\flang\%%N
  )
)
set "OMP_DLL=%LIBRARY_BIN%\libomp.dll"
if not exist "%OMP_DLL%" ( echo ERROR: %OMP_DLL% missing - llvm-openmp must be a host dependency & exit /b 1 )
set "DLLTOOL_MACHINE=i386:x86-64"
if "%target_platform%"=="win-arm64" set "DLLTOOL_MACHINE=arm64"
python "%RECIPE_DIR%\pe-exports.py" "%OMP_DLL%" > "%OMP_TMP%\libomp.def"
if errorlevel 1 ( echo ERROR: could not read libomp.dll exports & exit /b 1 )
"%BUILD_PREFIX%\Library\bin\x86_64-w64-mingw32-zig.exe" dlltool -m %DLLTOOL_MACHINE% -d "%OMP_TMP%\libomp.def" -D libomp.dll -l "%LIBRARY_PREFIX%\%CRT_TRIPLE%\lib\libomp.dll.a"
if errorlevel 1 ( echo ERROR: dlltool failed & exit /b 1 )
powershell -NoProfile -Command "[IO.File]::WriteAllBytes('%LIBRARY_PREFIX%\%CRT_TRIPLE%\lib\libatomic.a', [byte[]](0x21,0x3C,0x61,0x72,0x63,0x68,0x3E,0x0A))"
if not exist "%LIBRARY_PREFIX%\%CRT_TRIPLE%\lib\libatomic.a" ( echo ERROR: libatomic.a not written & exit /b 1 )
dir "%LIBRARY_PREFIX%\%CRT_TRIPLE%\lib\libomp.dll.a" "%LIBRARY_PREFIX%\%CRT_TRIPLE%\lib\libatomic.a"

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
