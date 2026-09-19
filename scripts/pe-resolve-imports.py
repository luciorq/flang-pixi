#!/usr/bin/env python3
"""List a PE image's imports and, on Windows, resolve every imported symbol
with LoadLibrary + GetProcAddress on THIS machine. Prints the machine type,
the import summary and every symbol the loader would fail on — the direct
answer to a 0xC0000139 STATUS_ENTRYPOINT_NOT_FOUND exit (docs/10 2026-09-19:
zig's arm64 CRT imported `__intrinsic_setjmpex`, which arm64 ucrtbase does
not export). Pure Python, no pefile. Usage: pe-resolve-imports.py <exe> [...]
"""
import os, struct, sys


def parse(d):
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    assert d[pe:pe + 4] == b"PE\0\0", "not a PE image"
    mach = struct.unpack_from("<H", d, pe + 4)[0]
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    opt = pe + 24
    pe32p = struct.unpack_from("<H", d, opt)[0] == 0x20B
    imp_rva = struct.unpack_from("<I", d, opt + (112 if pe32p else 96) + 8)[0]
    so = opt + struct.unpack_from("<H", d, pe + 20)[0]
    secs = [struct.unpack_from("<8sIIII", d, so + 40 * i) for i in range(nsec)]

    def off(r):
        for _, vs, va, rs, rp in secs:
            if va <= r < va + max(vs, rs):
                return r - va + rp

    out, o = {}, off(imp_rva)
    while o:
        ilt, _, _, name_rva, iat = struct.unpack_from("<IIIII", d, o)
        if name_rva == 0:
            break
        dll = d[off(name_rva):].split(b"\0", 1)[0].decode()
        syms, t = [], off(ilt or iat)
        while True:
            e = struct.unpack_from("<Q" if pe32p else "<I", d, t)[0]
            if e == 0:
                break
            if e & (1 << (63 if pe32p else 31)):
                syms.append("#%d" % (e & 0xFFFF))
            else:
                syms.append(d[off(e & 0x7FFFFFFF) + 2:].split(b"\0", 1)[0].decode())
            t += 8 if pe32p else 4
        out[dll] = syms
        o += 20
    return mach, out


def main():
    rc = 0
    for f in sys.argv[1:]:
        mach, imports = parse(open(f, "rb").read())
        print("%s: machine 0x%04x (%s), %d DLLs, %d symbols" % (
            os.path.basename(f), mach, {0x8664: "x86_64", 0xAA64: "arm64", 0x14C: "i386"}.get(mach, "?"),
            len(imports), sum(map(len, imports.values()))))
        if os.name != "nt":
            for dll, syms in imports.items():
                print("  %-40s %s" % (dll, " ".join(syms)))
            continue
        import ctypes
        for dll, syms in imports.items():
            try:
                h = ctypes.WinDLL(dll)
            except OSError as e:
                print("  UNRESOLVED DLL %s: %s" % (dll, e)); rc = 1; continue
            missing = []
            for s in syms:
                if s.startswith("#"):
                    ok = ctypes.windll.kernel32.GetProcAddress(ctypes.c_void_p(h._handle), ctypes.c_void_p(int(s[1:])))
                else:
                    ok = ctypes.windll.kernel32.GetProcAddress(ctypes.c_void_p(h._handle), s.encode())
                if not ok:
                    missing.append(s)
            if missing:
                print("  UNRESOLVED in %s: %s" % (dll, " ".join(missing))); rc = 1
        print("  all imports resolve" if rc == 0 else "  -> the loader fails on the symbols above")
    sys.exit(rc)


if __name__ == "__main__":
    main()
