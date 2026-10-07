#!/usr/bin/env python3
"""Carve the minimal relocatable Fortran *compile* set out of the published
flang-zig + flang-rt-zig .conda files (docs/19). The result is what r-zig-pixi's
zig-fc needs outside conda: flang compiles, zig links against the static
runtime. Nothing in it needs lld-zig, a sysroot or an SDK at COMPILE time.

  <out>/<subdir>/flang-standalone/
    bin/flang-23 (+ flang symlink)          unix        Library/bin/flang.exe   windows
    bin/flang.cfg                           one line: -fintrinsic-modules-path <CFGDIR>/../lib/clang/23/finclude/flang/<triple>
    lib/clang/23/finclude/flang/<triple>/   intrinsic .mod files + omp_lib.mod/omp_lib_kinds.mod/omp_lib.h
    lib/clang/23/lib/<rt-dir>/libflang_rt.runtime.a
    lib/libflang_rt.runtime.a -> ...        unix only, what the conda package ships; lets `-L<dir>/lib -lflang_rt.runtime` work

Usage: carve-fortran-standalone.py --out DIR [--archive zst|xz|gz|none] <flang-zig.conda> <flang-rt-zig.conda> [...]
Pairs are matched by subdir (both files must be the same subdir). Needs
Python >= 3.14 (compression.zstd) or the zstandard package, like
check-stdlib-floor.py: `pixi exec --spec "python>=3.14" python scripts/carve-fortran-standalone.py ...`
"""
import argparse, io, json, os, re, shutil, sys, tarfile, zipfile

try:
    from compression import zstd
    def zdecomp(b): return zstd.decompress(b)
    def zcomp(b): return zstd.compress(b, level=19)
except ImportError:
    import zstandard
    def zdecomp(b): return zstandard.ZstdDecompressor().decompress(b, max_output_size=1 << 32)
    def zcomp(b): return zstandard.ZstdCompressor(level=19).compress(b)

FINC_RX = re.compile(r"^(Library/)?lib/clang/(\d+)/finclude/flang/([^/]+)/[^/]+$")
RT_RX = re.compile(r"^(Library/)?lib/clang/(\d+)/lib/([^/]+)/libflang_rt\.runtime\.a$")


def members(conda):
    z = zipfile.ZipFile(conda)
    idx = None; files = {}; links = {}
    for n in z.namelist():
        if not n.endswith(".tar.zst"):
            continue
        t = tarfile.open(fileobj=io.BytesIO(zdecomp(z.read(n))))
        for m in t.getmembers():
            if m.name == "info/index.json":
                idx = json.load(t.extractfile(m))
            elif m.issym():
                links[m.name] = m.linkname
            elif m.isfile():
                files[m.name] = (t.extractfile(m).read(), m.mode)
    return idx, files, links


def carve(fz, frt, out, archive):
    idx_f, files_f, links_f = members(fz)
    idx_r, files_r, links_r = members(frt)
    assert idx_f["name"] == "flang-zig" and idx_r["name"] == "flang-rt-zig", (idx_f["name"], idx_r["name"])
    sub = idx_f["subdir"]; assert sub == idx_r["subdir"], (sub, idx_r["subdir"])
    win = sub.startswith("win-")
    root = os.path.join(out, sub, "flang-standalone")
    shutil.rmtree(root, ignore_errors=True)
    def put(rel, data, mode=0o644):
        p = os.path.join(root, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f: f.write(data)
        os.chmod(p, mode)
    # 1. the driver
    if win:
        put("Library/bin/flang.exe", files_f["Library/bin/flang.exe"][0], 0o755)
    else:
        data, mode = files_f["bin/flang-23"]; put("bin/flang-23", data, 0o755)
        os.symlink("flang-23", os.path.join(root, "bin/flang"))
    # 2. intrinsic + OpenMP modules: the conda-triple directory (what flang.cfg names) and,
    #    on Windows, also the driver-triple copy the package ships (no cfg needed with it)
    finc_dirs = {}
    for name, (data, mode) in files_r.items():
        m = FINC_RX.match(name)
        if m:
            finc_dirs.setdefault(m.group(3), []).append(name); put(name, data, mode)
    for name, target in links_r.items():
        m = FINC_RX.match(name + "/x")  # symlinked finclude dir (linux: x86_64-unknown-linux-gnu -> conda triple)
        if m and name.startswith(("lib/clang", "Library/lib/clang")):
            os.symlink(target, os.path.join(root, name)); finc_dirs.setdefault(os.path.basename(name), [])
    # 3. the static runtime archive (one copy; the win package carries four duplicate names)
    rt = [n for n in files_r if RT_RX.match(n)]
    assert len(rt) == 1, rt
    put(rt[0], files_r[rt[0]][0]); rt_dir = os.path.dirname(rt[0])
    if not win:
        os.makedirs(os.path.join(root, "lib"), exist_ok=True)
        os.symlink(os.path.relpath(rt[0], "lib"), os.path.join(root, "lib/libflang_rt.runtime.a"))
    # 4. compile-only driver config: one line. <CFGDIR> = the directory of the cfg file.
    cfg_dir = sorted(d for d in finc_dirs if "conda" in d or "apple" in d or "mingw32" in d)[0]
    major = RT_RX.match(rt[0]).group(2)
    cfg = f"-fintrinsic-modules-path <CFGDIR>/../lib/clang/{major}/finclude/flang/{cfg_dir}\n"
    put(("Library/bin/" if win else "bin/") + "flang.cfg", cfg.encode())
    # 5. provenance
    put("STANDALONE-ORIGIN.txt", (f"carved by scripts/carve-fortran-standalone.py (flang-pixi docs/19)\n"
        f"flang-zig: {os.path.basename(fz)} build={idx_f['build']}\nflang-rt-zig: {os.path.basename(frt)} build={idx_r['build']}\n"
        f"subdir: {sub}\nfinclude dirs: {sorted(finc_dirs)}\nruntime: {rt[0]}\n"
        "compile: flang -c x.f90 (the cfg beside flang supplies the intrinsic-module path; or pass -fintrinsic-modules-path yourself and drop the cfg)\n"
        "link: zig cc x.o <root>/" + rt[0] + " -lm   (plus -lomp and the libomp of your choice for -fopenmp)\n"
        "The flang DRIVER link needs more than this set: lld-zig + a sysroot (Linux), SDKROOT (macOS), lld-zig + the MinGW CRT snapshot (Windows); docs/19.\n").encode())
    n = sum(len(f) for _, _, f in os.walk(root)); raw = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(root) for f in fs if not os.path.islink(os.path.join(d, f)))
    print(f"{sub}: {n} files, {raw} bytes raw -> {root}")
    if archive != "none":
        base = os.path.join(out, sub, "flang-standalone-" + idx_f["version"] + "-" + sub)
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as t:
            t.add(root, arcname="flang-standalone", filter=lambda ti: (setattr(ti, "mtime", 0), setattr(ti, "uid", 0), setattr(ti, "gid", 0), setattr(ti, "uname", ""), setattr(ti, "gname", ""), ti)[-1])
        data = buf.getvalue()
        if archive == "zst":
            path = base + ".tar.zst"; open(path, "wb").write(zcomp(data))
        elif archive == "xz":
            import lzma; path = base + ".tar.xz"; open(path, "wb").write(lzma.compress(data, preset=9))
        else:
            import gzip; path = base + ".tar.gz"; open(path, "wb").write(gzip.compress(data, compresslevel=9))
        print(f"{sub}: archive {path} {os.path.getsize(path)} bytes (tar {len(data)})")


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--out", required=True); ap.add_argument("--archive", default="zst", choices=["zst", "xz", "gz", "none"]); ap.add_argument("conda", nargs="+")
    a = ap.parse_args()
    by = {}
    for c in a.conda:
        idx = members(c)[0]; by.setdefault(idx["subdir"], {})[idx["name"]] = c
    for sub, d in sorted(by.items()):
        if "flang-zig" not in d or "flang-rt-zig" not in d:
            print(f"{sub}: need both flang-zig and flang-rt-zig, have {sorted(d)}", file=sys.stderr); sys.exit(2)
        carve(d["flang-zig"], d["flang-rt-zig"], a.out, a.archive)


if __name__ == "__main__":
    main()
