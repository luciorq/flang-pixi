#!/usr/bin/env python3
"""Print a .def file for a Windows DLL from its export table (pure Python, no
pefile). Used by flang-rt-zig's build.bat to turn conda-forge's MSVC-built
libomp.dll into a MinGW import library (libomp.dll.a via `zig dlltool`) so
`flang -fopenmp`'s `-lomp` resolves against the same DLL that zig cc's C code
uses. Usage: pe-exports.py <file.dll> > file.def
"""
import struct, sys

data = open(sys.argv[1], "rb").read()
pe = struct.unpack_from("<I", data, 0x3C)[0]
assert data[pe:pe+4] == b"PE\0\0", "not a PE file"
nsec = struct.unpack_from("<H", data, pe + 6)[0]
opt_size = struct.unpack_from("<H", data, pe + 20)[0]
opt = pe + 24
magic = struct.unpack_from("<H", data, opt)[0]
dd_off = opt + (112 if magic == 0x20B else 96)          # PE32+ vs PE32
exp_rva, exp_size = struct.unpack_from("<II", data, dd_off)
sections = []
so = opt + opt_size
for i in range(nsec):
    name, vsize, va, rsize, rptr = struct.unpack_from("<8sIIII", data, so + 40 * i)
    sections.append((va, max(vsize, rsize), rptr))

def rva2off(rva):
    for va, size, rptr in sections:
        if va <= rva < va + size:
            return rva - va + rptr
    raise ValueError(f"rva {rva:#x} not in any section")

e = rva2off(exp_rva)
(_, _, _, _, name_rva, base, nfunc, nnames, funcs_rva, names_rva, ords_rva) = struct.unpack_from("<IIHHIIIIIII", data, e)
dllname = data[rva2off(name_rva):].split(b"\0", 1)[0].decode()
print(f"LIBRARY {dllname}")
print("EXPORTS")
names_off, ords_off = rva2off(names_rva), rva2off(ords_rva)
for i in range(nnames):
    n_rva = struct.unpack_from("<I", data, names_off + 4 * i)[0]
    sym = data[rva2off(n_rva):].split(b"\0", 1)[0].decode()
    print(f"    {sym}")
