# Windows diagnostic for the test workflow: when flang cannot even run, show
# the exit code (NTSTATUS-style codes mean a load failure: 0xC0000135 = DLL
# not found, 0xC000007B = wrong architecture / bad image, 0xC000001D = illegal
# instruction, 0xC0000139 = entry point not found) and which imported symbol
# this machine cannot resolve. Usage: ci-diag-win.ps1 <channel> [version]
param([string]$Channel, [string]$Version = "")
$ErrorActionPreference = "Continue"
$w = Join-Path $env:RUNNER_TEMP "fz-diag"; if (Test-Path $w) { Remove-Item $w -Recurse -Force }
New-Item -ItemType Directory $w | Out-Null; Set-Location $w
$pin = if ($Version) { "==$Version" } else { "" }
& pixi init . | Out-Null
& pixi workspace channel add $Channel --prepend | Out-Null
& pixi add "flang-zig$pin" "flang-rt-zig$pin" 2>&1 | Select-Object -Last 1
$P = (& pixi info --json | ConvertFrom-Json).environments_info[0].prefix
"prefix: $P"
"machine: $env:PROCESSOR_ARCHITECTURE  OS: $([System.Environment]::OSVersion.VersionString)"
Get-ChildItem "$P\Library\bin" -Filter "flang*" | ForEach-Object { "{0}  {1:N0} bytes" -f $_.Name, $_.Length }
$env:PATH = "$P\Library\bin;" + $env:PATH
"== through pixi run (as the smoke does)"
& pixi run flang --version 2>&1 | Select-Object -First 3
"pixi run exit code: $LASTEXITCODE"
"== cmd.exe launch (raw NTSTATUS survives as %errorlevel%)"
& cmd.exe /c "`"$P\Library\bin\flang.exe`" --version & echo cmd errorlevel=%errorlevel%" 2>&1 | Select-Object -First 4
"== direct launches"
foreach ($exe in @("flang.exe", "flang-23.exe", "ld.lld.exe")) {
  $p = Join-Path "$P\Library\bin" $exe
  if (-not (Test-Path $p)) { "${exe}: missing"; continue }
  & $p --version 2>&1 | Select-Object -First 2
  "${exe} exit code: $LASTEXITCODE (0x{0:X8})" -f $LASTEXITCODE
  # PE machine + every import resolved with GetProcAddress on this machine
  # (scripts/pe-resolve-imports.py): names the symbol behind 0xC0000139.
  & pixi exec --spec "python>=3.12" python "$PSScriptRoot\pe-resolve-imports.py" $p
}
