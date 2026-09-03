# Upstream flang bug for MinGW builds (found at link of fir-lsp-server.exe on
# the first win-64 flang build): RTBuilder.h's getModel specialization for the
# memcpy-style function pointer `void *(*)(void *, const void *, size_t)` is
# guarded by #ifdef _MSC_VER with an `unsigned __int64` spelling. Under a
# windows-gnu (MinGW) build, _MSC_VER is not defined but size_t is still
# unsigned long long (LLP64), so the specialization the FIRBuilder objects
# reference does not exist -> lld-link undefined symbol
#   fir::runtime::getModel<void* (*)(void*, void const*, unsigned long long)>
# Fix: spell the type `unsigned long long` (identical type under MSVC) and
# widen the guard to any 64-bit Windows. Idempotent string replaces.
# Nobody builds MinGW flang upstream, which is why this survives there.
$f = 'flang/include/flang/Optimizer/Builder/Runtime/RTBuilder.h'
$c = [IO.File]::ReadAllText($f)
$c = $c.Replace('unsigned __int64', 'unsigned long long')
$c = $c.Replace("#ifdef _MSC_VER`ntemplate <>", "#if defined(_MSC_VER) || defined(_WIN64)`ntemplate <>")
$c = $c.Replace("#ifdef _MSC_VER`r`ntemplate <>", "#if defined(_MSC_VER) || defined(_WIN64)`r`ntemplate <>")
[IO.File]::WriteAllText($f, $c)
Write-Host "RTBuilder.h patched for MinGW getModel<unsigned long long>"
