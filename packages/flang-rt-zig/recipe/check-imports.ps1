# check-imports.ps1 -ObjDump <llvm-objdump.exe> -Dir <dir> [-Exclude name,...]
# Build-time tripwire (flang-pixi docs/18 section 6.6): every .exe/.dll under
# -Dir may import ONLY Windows OS DLLs and the UCRT api-sets. Anything else
# (VCRUNTIME140, MSVCP140, libc++.dll, libwinpthread-1.dll, libgcc_s_*.dll,
# libstdc++-6.dll, libomp.dll, zlib1.dll, ...) fails the build. The same
# file lives in all four recipe dirs; keep them identical. The list was
# measured clean on all 18 published files on 2026-10-06 (ADVAPI32, SHELL32,
# ole32 and VERSION are what LLVM Support uses; CRYPT32 and WINHTTP are LLVM's
# debuginfod client in llvm-symbolizer/llvm-objdump/llvm-cov (llvm-zig only,
# found on the 2026-10-06 release build); all are OS DLLs, not runtimes).
param(
  [Parameter(Mandatory = $true)][string]$ObjDump,
  [Parameter(Mandatory = $true)][string]$Dir,
  [string[]]$Exclude = @()
)
$ErrorActionPreference = 'Continue'
$allow = '^(kernel32|ntdll|advapi32|shell32|ole32|version|crypt32|winhttp)\.dll$|^api-ms-win-crt-[a-z0-9]+-l1-1-0\.dll$'
if (-not (Test-Path -LiteralPath $ObjDump)) { Write-Host "ERROR: llvm-objdump not found at $ObjDump"; exit 1 }
$files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File | Where-Object { ($_.Extension -eq '.exe' -or $_.Extension -eq '.dll') -and ($Exclude -notcontains $_.Name) })
$bad = 0
foreach ($f in $files) {
  $out = & $ObjDump --private-headers $f.FullName 2>&1
  if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: llvm-objdump failed on $($f.FullName)"; $bad++; continue }
  $dlls = New-Object System.Collections.Generic.List[string]
  foreach ($line in $out) {
    $m = [regex]::Match([string]$line, '^\s*DLL Name:\s+(\S+)\s*$')
    if ($m.Success) { $dlls.Add($m.Groups[1].Value) }
  }
  # A DLL may import SIBLING DLLs from its own directory (llvm-zig's MLIR
  # runner DLLs import each other); executables stay OS-DLL-only.
  $dir = $f.DirectoryName; $isDll = ($f.Extension -eq '.dll')
  $outside = @($dlls | Sort-Object -Unique | Where-Object { ($_ -inotmatch $allow) -and -not ($isDll -and (Test-Path -LiteralPath (Join-Path $dir $_))) })
  if ($outside.Count -gt 0) {
    Write-Host "ERROR: $($f.FullName) imports outside the libc allowlist: $($outside -join ' ') -- docs/18 section 6.6"
    $bad++
  }
}
if ($bad -gt 0) { exit 1 }
Write-Host "load-dep allowlist OK: $($files.Count) PE files, OS DLLs + UCRT api-sets only (docs/18 section 6.6)"
exit 0
