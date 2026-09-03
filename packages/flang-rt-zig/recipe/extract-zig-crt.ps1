# Extract zig's materialized MinGW CRT into the layout flang's driver
# searches (user decision 2026-08-27: self-contained, no gcc_impl_win-64
# dependency — the Windows twin of the linux compiler-rt approach).
#
# Background (docs/10, "win-64 COMPLETE"): flang.exe's MinGW driver links
#   crt2.o crtbegin.o ... -lmingw32 -lgcc -lgcc_eh -lmoldname -lmingwex
#   -lmsvcrt -ladvapi32 -lshell32 -luser32 -lkernel32 ... crtend.o
# searching <prefix>\Library\x86_64-w64-mingw32\lib — none of which exist:
# zig keeps its MinGW CRT private, materialized on demand into its cache.
#
# Method: run one verbose `zig cc --target=x86_64-windows-gnu` link of a
# trivial program; zig prints the exact lld-link invocation listing every
# CRT artifact it built (crt2.obj, libmingw32.lib, compiler_rt.lib,
# zigc.lib, api-ms-win-crt-*.lib UCRT import libs, system import libs).
# Harvest those into GNU names:
#   crt2.obj                -> crt2.o
#   libmingw32.lib          -> libmingw32.a
#   compiler_rt.lib         -> libgcc.a        (zig's libgcc replacement)
#   zigc.lib + api-ms-*.lib -> libmsvcrt.a    (merged via llvm-ar MRI ADDLIB)
#   <sys>.lib               -> lib<sys>.a     (advapi32, kernel32, ...)
#   (empty archives)        -> libgcc_eh.a, libmoldname.a, libmingwex.a
#                              (SEH exception model needs no gcc_eh; modern
#                              mingw-w64 merged mingwex/moldname into mingw32)
#   (empty objects)         -> crtbegin.o, crtend.o (zig links without them;
#                              ctor/dtor handling lives in crt2+mingw32 with
#                              lld; validated by the smoke link)
#
# Requires: ZIG_CC (zig activation), llvm-ar on PATH (llvm-zig host dep).
# Output dir passed as -DestLib (e.g. %LIBRARY_PREFIX%\x86_64-w64-mingw32\lib).
param(
    [Parameter(Mandatory=$true)][string]$DestLib,
    # zig target triple for the CRT to extract — x86_64-windows-gnu for
    # win-64, aarch64-windows-gnu for the win-arm64 cross build.
    [string]$ZigTarget = "x86_64-windows-gnu"
)
# "Continue", not "Stop": zig/llvm-ar write progress to stderr and PS turns
# any native stderr into a terminating NativeCommandError under Stop.
$ErrorActionPreference = "Continue"

New-Item -ItemType Directory -Force -Path $DestLib | Out-Null
$work = Join-Path $env:TEMP ("zigcrt-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work -Force | Out-Null

Set-Content -Path "$work\t.c" -Value @('#include <stdio.h>', 'int main(void){ printf("x\n"); return 0; }')
# Capture via cmd redirect to a file: PS mangles native stderr into wrapped
# ErrorRecords (Out-String wraps at console width, splitting the long
# lld-link line and defeating the path regex).
& cmd /c "`"$env:ZIG_CC`" --target=$ZigTarget -v `"$work\t.c`" -o `"$work\t.exe`" > `"$work\v.txt`" 2>&1"
$out = [IO.File]::ReadAllText("$work\v.txt")

$lldLine = ($out -split "`n" | Where-Object { $_ -match 'lld-link' } | Select-Object -First 1)
if (-not $lldLine) {
    Write-Host "=== zig -v output (no lld-link line found) ==="
    Write-Host $out
    Write-Error "no lld-link line in zig -v output"; exit 1
}
Write-Host ("lld-link line length: " + $lldLine.Length)

# Every .obj/.lib argument on the link line. CRITICAL: when
# ZIG_GLOBAL_CACHE_DIR sits under the CWD (build.bat sets it to
# %SRC_DIR%\.zig-global-cache), zig prints RELATIVE paths
# (.zig-global-cache\o\<hash>\crt2.obj) - an absolute-only regex harvests
# nothing (the first packaged build shipped empty stubs because of this).
# Tokenize and resolve instead.
$tokens = $lldLine -split '\s+' | Where-Object { $_ -match '\.(obj|lib)$' -and $_ -notmatch '^-' }
$arts = @()
foreach ($t in $tokens) {
    $p = $t
    if ($p -notmatch '^[A-Za-z]:') { $p = Join-Path (Get-Location).Path $p }
    if (Test-Path $p) { $arts += (Resolve-Path $p).Path }
}
$arts = $arts | Sort-Object -Unique

Write-Host ("artifacts parsed: " + $arts.Count)
if ($arts.Count -eq 0) { Write-Host "=== lld-link line ==="; Write-Host $lldLine }
$apiSets = @()
foreach ($a in $arts) {
    $name = Split-Path $a -Leaf
    switch -Wildcard ($name) {
        't.obj'            { }
        't.lib'            { }
        'crt2.obj'         { Copy-Item $a (Join-Path $DestLib 'crt2.o') -Force }
        'libmingw32.lib'   { Copy-Item $a (Join-Path $DestLib 'libmingw32.a') -Force }
        'compiler_rt.lib'  { Copy-Item $a (Join-Path $DestLib 'libgcc.a') -Force }
        'ubsan_rt.lib'     { }
        'zigc.lib'         { $apiSets += $a }
        'api-ms-*.lib'     { $apiSets += $a }
        default            { # system import libs: advapi32.lib -> libadvapi32.a
                             $base = [IO.Path]::GetFileNameWithoutExtension($name)
                             Copy-Item $a (Join-Path $DestLib ("lib" + $base + ".a")) -Force }
    }
}

# Merge zigc + UCRT api-set import libs into libmsvcrt.a (the name flang's
# driver asks for). llvm-ar MRI ADDLIB merges archives member-safely.
$mri = @("create " + (Join-Path $DestLib 'libmsvcrt.a'))
foreach ($a in $apiSets) { $mri += ("addlib " + $a) }
$mri += "save"; $mri += "end"
$mriFile = Join-Path $work 'merge.mri'
# Write BOM-free (PS5.1 Set-Content sneaks BOMs in; llvm-ar's MRI parser
# chokes on them) and feed via cmd redirect, not the PS pipeline.
[IO.File]::WriteAllLines($mriFile, [string[]]$mri, (New-Object System.Text.UTF8Encoding($false)))
& cmd /c "llvm-ar -M < `"$mriFile`""
if ($LASTEXITCODE -ne 0) { Write-Error "llvm-ar MRI merge failed"; exit 1 }

# aarch64 CRT gap: zig's aarch64-windows-gnu libs lack wcstold (long double
# == double on arm64-Windows, so forwarding to wcstod is exactly correct).
# Bake the shim into the extracted libmsvcrt.a so end-user links get it.
if ($ZigTarget -like 'aarch64*') {
    Set-Content -Path "$work\wcstold_compat.c" -Value @(
        '#include <wchar.h>',
        'long double wcstold(const wchar_t *n, wchar_t **e) { return (long double)wcstod(n, e); }'
    )
    & $env:ZIG_CC --target=$ZigTarget -O2 -c "$work\wcstold_compat.c" -o "$work\wcstold_compat.o"
    & llvm-ar rs (Join-Path $DestLib 'libmsvcrt.a') "$work\wcstold_compat.o"
    Write-Host "wcstold shim baked into libmsvcrt.a"
}

# Empty archives for the legacy names the driver emits.
foreach ($n in @('libgcc_eh.a', 'libmoldname.a', 'libmingwex.a')) {
    $p = Join-Path $DestLib $n
    Remove-Item $p -Force -ErrorAction SilentlyContinue
    & llvm-ar rcs $p
    if ($LASTEXITCODE -ne 0) { Write-Error "llvm-ar rcs $n failed"; exit 1 }
}

# Empty objects for crtbegin.o / crtend.o.
Set-Content -Path "$work\empty.c" -Value ''
& $env:ZIG_CC --target=$ZigTarget -c "$work\empty.c" -o (Join-Path $DestLib 'crtbegin.o')
& $env:ZIG_CC --target=$ZigTarget -c "$work\empty.c" -o (Join-Path $DestLib 'crtend.o')

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host "zig CRT extracted to $DestLib :"
Get-ChildItem $DestLib | ForEach-Object { Write-Host ("  " + $_.Name + "  " + $_.Length) }
