# Windows diagnostic for the test workflow: when flang cannot even run, show
# the exit code (NTSTATUS-style codes mean a load failure: 0xC0000135 = DLL
# not found, 0xC000007B = wrong architecture / bad image, 0xC000001D = illegal
# instruction) and the DLLs flang.exe imports. Usage: ci-diag-win.ps1 <channel> [version]
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
  # PE machine + imports (pure python, no pefile)
  $py = @'
import struct, sys
d = open(sys.argv[1], "rb").read(); pe = struct.unpack_from("<I", d, 0x3C)[0]
mach = struct.unpack_from("<H", d, pe + 4)[0]; print("  PE machine: 0x%04x (%s)" % (mach, {0x8664: "x86_64", 0xAA64: "arm64", 0x14C: "i386"}.get(mach, "?")))
nsec = struct.unpack_from("<H", d, pe + 6)[0]; opt = pe + 24; magic = struct.unpack_from("<H", d, opt)[0]
dd = opt + (112 if magic == 0x20B else 96) + 8  # import table = 2nd data directory
imp_rva = struct.unpack_from("<I", d, dd)[0]
secs = []
so = opt + struct.unpack_from("<H", d, pe + 20)[0]
for i in range(nsec):
    n, vs, va, rs, rp = struct.unpack_from("<8sIIII", d, so + 40 * i); secs.append((va, max(vs, rs), rp))
def off(r):
    for va, sz, rp in secs:
        if va <= r < va + sz: return r - va + rp
    return None
o = off(imp_rva); names = []
while o:
    e = struct.unpack_from("<IIIII", d, o)
    if e[3] == 0: break
    no = off(e[3]); names.append(d[no:].split(b"\0", 1)[0].decode()); o += 20
print("  imports:", " ".join(sorted(names)))
'@
  Set-Content -Path "$w\pe.py" -Value $py
  & pixi exec --spec "python>=3.12" python "$w\pe.py" $p
}
