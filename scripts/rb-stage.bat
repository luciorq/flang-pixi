@echo off
REM Windows twin of rb-stage.sh: build one package with standalone rattler-build
REM (variants.yaml honoured) and copy the result into channel\<subdir>.
REM   scripts\rb-stage.bat <package> [target_platform]
REM Env: RB_OUT (output/work dir, default %ROOT%\rb-out), RB_TEST (native|skip).
setlocal EnableDelayedExpansion
set "PKG=%~1"
if "%PKG%"=="" ( echo usage: rb-stage.bat ^<package^> [target_platform] & exit /b 1 )
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "HOST=win-64"
set "TARGET=%~2"
if "%TARGET%"=="" set "TARGET=%HOST%"
set "BP="
set "TEST=%RB_TEST%"
if not "%TARGET%"=="%HOST%" (
  set "BP=--build-platform %HOST%"
  if "!TEST!"=="" set "TEST=skip"
)
if "!TEST!"=="" set "TEST=native"
if "%RB_OUT%"=="" set "RB_OUT=%ROOT%\rb-out"
if not exist "%RB_OUT%" mkdir "%RB_OUT%"
set "CHAN=file:///%ROOT:\=/%/channel"
echo == rattler-build %PKG% -^> %TARGET% (build %HOST%, test=!TEST!, out=%RB_OUT%)
rattler-build build --recipe "%ROOT%\packages\%PKG%\recipe\recipe.yaml" --variant-config "%ROOT%\packages\%PKG%\recipe\variants.yaml" --target-platform %TARGET% !BP! --test !TEST! -c "%CHAN%" -c conda-forge --output-dir "%RB_OUT%"
if errorlevel 1 exit /b 1
REM tripwire: no C-stdlib floor above the recipe's c_stdlib_version
for /f "delims=" %%F in ('dir /b /o-d "%RB_OUT%\%TARGET%\%PKG%-*.conda"') do ( set "BUILT=%RB_OUT%\%TARGET%\%%F" & goto :gotbuilt )
:gotbuilt
pixi exec --spec "python>=3.14" --spec pyyaml python "%ROOT%\scripts\check-stdlib-floor.py" "%ROOT%\packages\%PKG%\recipe\variants.yaml" "!BUILT!"
if errorlevel 1 exit /b 1
pixi exec --spec "python>=3.14" python "%ROOT%\scripts\publish-crossbuilt.py" "%RB_OUT%\%TARGET%" "%ROOT%\channel\%TARGET%"
if errorlevel 1 exit /b 1
rmdir /s /q "%RB_OUT%\bld" 2>nul
rmdir /s /q "%RB_OUT%\src_cache" 2>nul
exit /b 0
