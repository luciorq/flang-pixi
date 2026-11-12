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
set "CFLAGS=%CFLAGS% -g0 -mcpu=baseline"
set "CXXFLAGS=%CXXFLAGS% -g0 -mcpu=baseline"
REM -mcpu=baseline: the conda wrapper injects it when absent; written out so the
REM scripts also hold with upstream zig (decision 2026-10-10, docs/17 section 9).
REM Hidden visibility, build 10 (parity with the unix build 9 flags; docs/16
REM 3d, docs/19 5). COFF has no ELF visibility: on MinGW the flag only
REM excludes symbols from lld's auto-export, and a zig-linked Fortran DLL
REM already exported none of the runtime (lld skips archive members), so
REM this changes nothing measurable here -- one flag set on all six subdirs.
set "CFLAGS=%CFLAGS% -fvisibility=hidden"
set "CXXFLAGS=%CXXFLAGS% -fvisibility=hidden -fvisibility-inlines-hidden"

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
REM zig 0.17 (both conda-forge and upstream builds) ships wcstold for
REM aarch64-windows-gnu and resolves __C_specific_handler from the UCRT api
REM set even with -lkernel32 ahead (docs/17 section 9); the wcstold shim and
REM libcompat_arm64.a that 0.16 needed (docs/10 2026-09-19) are gone since the
REM 2026-10-10 release.
:native_build
REM libomp (the openmp runtime, 23.1.5 build 0): its CMake enables ASM_MASM on
REM every Windows target, and x64 assembles z_Windows_NT-586_asm.asm with it.
REM zig has no MASM; llvm-zig (a build dependency) ships llvm-ml64, LLVM's
REM MASM. Always the BUILD machine's copy (win-64 also on the arm64 cross);
REM arm64 assembles z_Linux_asm.S with zig cc instead and never calls it.
set "LLVM_ML=%BUILD_PREFIX%\Library\bin\llvm-ml64.exe"
if not exist "%LLVM_ML%" ( echo ERROR: %LLVM_ML% missing - llvm-zig must be a build dependency & exit /b 1 )
set "LLVM_ML_CMAKE=%LLVM_ML:\=/%"
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
  -DLLVM_ENABLE_RUNTIMES="flang-rt;openmp" ^
  -DLLVM_INCLUDE_TESTS=OFF ^
  -DOPENMP_ENABLE_TESTING=OFF ^
  -DOPENMP_INSTALL_LIBDIR=lib ^
  -DOPENMP_ENABLE_LIBOMPTARGET=OFF ^
  -DOPENMP_ENABLE_OMPT_TOOLS=OFF ^
  -DLIBOMP_OMPD_SUPPORT=OFF ^
  -DLIBOMP_USE_HWLOC=OFF ^
  -DLIBOMP_INSTALL_ALIASES=OFF ^
  "-DLIBOMP_CXXFLAGS=-fvisibility=default" ^
  -DCMAKE_ASM_MASM_COMPILER="%LLVM_ML_CMAKE%" ^
  -DCMAKE_ASM_MASM_FLAGS=-m64 ^
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
    REM Build 10: keep ONLY the plain name. The .static/.dynamic/_dbg files are
    REM the same static build under CMake's other names (docs/19 section 1:
    REM .static.a is byte-identical, 4 x 14 MB of dead weight; nothing links them).
    del /q "%%T\libflang_rt.runtime.static.a" "%%T\libflang_rt.runtime.static_dbg.a" "%%T\libflang_rt.runtime.dynamic.a" "%%T\libflang_rt.runtime.dynamic_dbg.a" 2>nul
    echo duplicate runtime archives removed in %%T
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

REM --- OpenMP: libomp (llvm-openmp), omp_lib.mod, the link shims ----------
REM Since 23.1.5 build 0 the runtimes build builds `openmp` itself (docs/18
REM section 5): libomp.dll with zig for the MinGW ABI, its own MinGW import
REM library, and omp_lib.mod / omp_lib_kinds.mod / omp_lib.h through
REM openmp\module with this flang. Until 23.1.1 build 11 this block compiled
REM omp_lib.F90.var by hand and generated libomp.dll.a with dlltool from the
REM exports of conda-forge's MSVC-built libomp.dll; conda-forge's win-arm64
REM build drops every microtask argument after the sixth (its C fallback of
REM __kmp_invoke_microtask; zig's build assembles z_Linux_asm.S instead).
REM (1) omp_lib: the xcopy above copied the RT_TRIPLE dir, module included.
for /d %%D in ("%LIBRARY_LIB%\clang\*") do if exist "%%D\finclude\flang\" (
  for %%N in (%RT_TRIPLE% %FINC_TRIPLE%) do for %%M in (omp_lib.mod omp_lib_kinds.mod omp_lib.h) do (
    if not exist "%%D\finclude\flang\%%N\%%M" ( echo ERROR: %%M missing under %%D\finclude\flang\%%N - openmp\module did not build & exit /b 1 )
  )
)
REM (2) libomp: the files of the llvm-openmp output, in conda-forge
REM     llvm-openmp's places: Library\bin\libomp.dll and libiomp5md.dll (a
REM     copy, upstream's Windows alias), headers in Library\include. The
REM     import library is installed as Library\lib\libomp.dll.a (MinGW name);
REM     add conda-forge's MSVC names (r-zig-pixi links Library\lib\libomp.lib;
REM     lld reads the archive under either name).
if not exist "%LIBRARY_BIN%\libomp.dll" ( echo ERROR: libomp.dll was not installed & exit /b 1 )
if not exist "%LIBRARY_BIN%\libiomp5md.dll" copy /y "%LIBRARY_BIN%\libomp.dll" "%LIBRARY_BIN%\libiomp5md.dll" >nul
if not exist "%LIBRARY_LIB%\libomp.dll.a" ( echo ERROR: libomp.dll.a was not installed & exit /b 1 )
copy /y "%LIBRARY_LIB%\libomp.dll.a" "%LIBRARY_LIB%\libomp.lib" >nul
REM libiomp5md: upstream installs Library\lib\libiomp5md.a, a copy of
REM libomp's import library (it names libomp.dll, as conda-forge's
REM libiomp5md.lib does too); conda-forge's name is .lib.
if exist "%LIBRARY_LIB%\libiomp5md.a" move /y "%LIBRARY_LIB%\libiomp5md.a" "%LIBRARY_LIB%\libiomp5md.lib" >nul
if not exist "%LIBRARY_LIB%\libiomp5md.lib" copy /y "%LIBRARY_LIB%\libomp.dll.a" "%LIBRARY_LIB%\libiomp5md.lib" >nul
for %%H in (omp.h ompx.h) do if not exist "%LIBRARY_INC%\%%H" (
  for /d %%D in ("%LIBRARY_LIB%\clang\*") do if exist "%%D\include\%%H" move /y "%%D\include\%%H" "%LIBRARY_INC%\%%H" >nul
  if not exist "%LIBRARY_INC%\%%H" ( echo ERROR: %%H was not installed & exit /b 1 )
)
REM conda-forge ships no OMPT headers on Windows (OMPT is off there too).
del /q "%LIBRARY_INC%\omp-tools.h" "%LIBRARY_INC%\ompt.h" 2>nul
REM (3) The driver's own search directory: `flang -fopenmp` emits -lomp and
REM     the MinGW driver searches Library\<triple>\lib (the CRT dir), where
REM     flang-rt-zig keeps a copy of the import library, and -latomic, which
REM     zig's MinGW CRT lacks: an empty archive satisfies it (the atomic
REM     helpers live in compiler-rt builtins). docs/10 2026-09-18.
copy /y "%LIBRARY_LIB%\libomp.dll.a" "%LIBRARY_PREFIX%\%CRT_TRIPLE%\lib\libomp.dll.a" >nul
if errorlevel 1 ( echo ERROR: could not copy libomp.dll.a into the CRT dir & exit /b 1 )
powershell -NoProfile -Command "[IO.File]::WriteAllBytes('%LIBRARY_PREFIX%\%CRT_TRIPLE%\lib\libatomic.a', [byte[]](0x21,0x3C,0x61,0x72,0x63,0x68,0x3E,0x0A))"
if not exist "%LIBRARY_PREFIX%\%CRT_TRIPLE%\lib\libatomic.a" ( echo ERROR: libatomic.a not written & exit /b 1 )
dir "%LIBRARY_BIN%\libomp.dll" "%LIBRARY_LIB%\libomp.dll.a" "%LIBRARY_LIB%\libomp.lib" "%LIBRARY_LIB%\libiomp5md.lib" "%LIBRARY_PREFIX%\%CRT_TRIPLE%\lib\libomp.dll.a" "%LIBRARY_PREFIX%\%CRT_TRIPLE%\lib\libatomic.a"

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

REM --- tripwires (docs/18 section 6.6 and 5.3) --------------------------------
REM flang-rt-zig ships no PE image: no runtime DLL/EXE of flang-rt anywhere.
dir /s /b "%LIBRARY_PREFIX%\*flang_rt*.dll" "%LIBRARY_PREFIX%\*flang_rt*.exe" >nul 2>nul && ( echo ERROR: a shared flang runtime image was installed; FLANG_RT_ENABLE_SHARED must stay OFF & exit /b 1 )
ver >nul
REM llvm-openmp's libomp.dll: imports OS DLLs and the UCRT api-sets only
REM (check-imports.ps1's allowlist: VCRUNTIME140, MSVCP140, libc++ or
REM libwinpthread here means the build left zig's MinGW toolchain), and
REM exports the OpenMP API.
REM Measured on the 2026-11-11 cross-builds: 787 exports (x64) / 675 (arm64),
REM the same names as conda-forge's llvm-openmp 23.1.5.
set "OMP_OD=%BUILD_PREFIX%\Library\bin\llvm-objdump.exe"
if not exist "%OMP_OD%" ( echo ERROR: %OMP_OD% missing for the libomp tripwire & exit /b 1 )
"%OMP_OD%" -p "%LIBRARY_BIN%\libomp.dll" > "%SRC_DIR%\libomp-pe.txt"
if errorlevel 1 ( echo ERROR: llvm-objdump could not read libomp.dll & exit /b 1 )
REM The shared allowlist script, on a directory with only our two DLLs (the
REM host env's llvm-zig files sit in %LIBRARY_BIN% too).
set "OMP_TW=%SRC_DIR%\libomp-tripwire"
mkdir "%OMP_TW%" 2>nul
copy /y "%LIBRARY_BIN%\libomp.dll" "%OMP_TW%\" >nul
copy /y "%LIBRARY_BIN%\libiomp5md.dll" "%OMP_TW%\" >nul
powershell -ExecutionPolicy Bypass -File "%RECIPE_DIR%\check-imports.ps1" -ObjDump "%OMP_OD%" -Dir "%OMP_TW%"
if errorlevel 1 exit /b 1
for %%S in (omp_get_num_threads __kmpc_fork_call __kmpc_global_thread_num omp_get_max_threads) do (
  findstr /c:" %%S" "%SRC_DIR%\libomp-pe.txt" >nul || ( echo ERROR: libomp.dll does not export %%S & exit /b 1 )
)
ver >nul
echo libomp tripwire OK: OS DLLs + UCRT api-sets only, OpenMP API exported (docs/18 section 5.3)
