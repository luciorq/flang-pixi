#!/usr/bin/env bash
# check-load-deps.sh <dir> [...]: apply the load-time dependency ALLOWLIST
# (docs/18 §6.6) to every ELF / Mach-O / PE image under the given directories
# — the same predicates the four build scripts enforce at the end of a build,
# usable on an extracted .conda, an installed prefix, or a consumer's tree.
#   Linux:   NEEDED ⊆ { libc libm libdl libpthread librt libresolv libutil }.so.N + ld-linux-*.so.N
#   macOS:   LC_LOAD_DYLIB (weak/reexport too) ⊆ { /usr/lib/libSystem.B.dylib }
#   Windows: imports ⊆ { KERNEL32 ntdll ADVAPI32 SHELL32 ole32 VERSION } + api-ms-win-crt-*-l1-1-0
# Tools: llvm-objdump (env OBJDUMP; falls back to `pixi exec -s llvm-tools`),
# python3 + scripts/pe-resolve-imports.py for PE. Exit 1 on any violation.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ALLOW_ELF='^(libc|libm|libdl|libpthread|librt|libresolv|libutil)\.so\.[0-9]+$|^ld-linux[-a-z0-9_]*\.so\.[0-9]+$'
ALLOW_MACHO='^/usr/lib/libSystem\.B\.dylib$'
ALLOW_PE='^(kernel32|ntdll|advapi32|shell32|ole32|version|crypt32|winhttp)\.dll$|^api-ms-win-crt-[a-z0-9]+-l1-1-0\.dll$'
od="${OBJDUMP:-}"
if [[ -z "$od" ]]; then
  if command -v llvm-objdump >/dev/null 2>&1; then od=llvm-objdump; else od="pixi exec -s llvm-tools -- llvm-objdump"; fi
fi
bad=0; n=0
for root in "$@"; do
  while IFS= read -r -d '' f; do
    kind=$(file -b "$f")
    case "$kind" in
      ELF*shared*|ELF*executable*|ELF*pie*)
        n=$((n+1))
        out=$($od -p "$f" 2>/dev/null | awk '/^ *NEEDED/{print $2}' | grep -v -E "$ALLOW_ELF" | while read -r n; do [[ "$f" == *.so* && -e "$(dirname "$f")/$n" ]] || echo "$n"; done || true)   # shared libs may need siblings
        [[ -n "$out" ]] && { echo "FAIL $f: NEEDED outside allowlist: $(echo $out | tr '\n' ' ')"; bad=$((bad+1)); } ;;
      Mach-O*)
        n=$((n+1))
        out=$($od --macho --private-headers "$f" 2>/dev/null | awk '/LC_(LOAD|LOAD_WEAK|REEXPORT|LAZY_LOAD|LOAD_UPWARD)_DYLIB/{c=1} c&&/ name /{print $2; c=0}' | grep -v -E "$ALLOW_MACHO" | while read -r n; do [[ "$f" == *.dylib && "$n" == @rpath/* && -e "$(dirname "$f")/${n#@rpath/}" ]] || echo "$n"; done || true)
        [[ -n "$out" ]] && { echo "FAIL $f: loads outside allowlist: $(echo $out | tr '\n' ' ')"; bad=$((bad+1)); } ;;
      PE32*)
        n=$((n+1))
        out=$(python3 "$here/pe-resolve-imports.py" "$f" 2>/dev/null | awk '/^  /{print $1}' | grep -v -i -E "$ALLOW_PE" | while read -r n; do [[ "$f" == *.dll && -e "$(dirname "$f")/$n" ]] || echo "$n"; done || true)
        [[ -n "$out" ]] && { echo "FAIL $f: imports outside allowlist: $(echo $out | tr '\n' ' ')"; bad=$((bad+1)); } ;;
    esac
  done < <(find "$root" -type f \( -perm -u+x -o -name '*.so*' -o -name '*.dylib' -o -name '*.exe' -o -name '*.dll' \) -print0 2>/dev/null)
done
echo "checked $n images under: $*"
[[ $bad -eq 0 ]] && echo "load-dep allowlist OK" || { echo "$bad violation(s)"; exit 1; }
