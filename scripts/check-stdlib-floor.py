#!/usr/bin/env python3
"""Fail if a built .conda declares a C-stdlib floor above what the recipe's
variants.yaml promises (docs/10 2026-09-18: packages built through pixi
without variants carried `__glibc >=2.28` / `sysroot_linux-64 >=2.28` /
`__osx >=13.0` although the recipe says 2.17 / 11.0 — uninstallable on the
old servers this project targets, and invisible until someone tried).

Usage: check-stdlib-floor.py <variants.yaml> <package.conda> [...]
Exit 1 on any violation. Requires Python >= 3.14 (compression.zstd) or the
zstandard package, like publish-crossbuilt.py.
"""
import io, json, re, sys, tarfile, zipfile

try:
    from compression import zstd
    def zdecomp(b): return zstd.decompress(b)
except ImportError:
    import zstandard
    def zdecomp(b): return zstandard.ZstdDecompressor().decompress(b, max_output_size=1 << 31)


def vtuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v)[:3])


def expected_floors(variants_path):
    """{'linux': '2.17', 'osx': '11.0'} from the if/then blocks of variants.yaml."""
    import yaml  # PyYAML is in the workspace env; fall back to a tiny parser if not
    doc = yaml.safe_load(open(variants_path))
    out = {}
    for entry in doc.get("c_stdlib_version", []):
        if isinstance(entry, dict) and "if" in entry:
            vals = entry.get("then") or []
            if isinstance(vals, list) and vals:
                out[str(entry["if"]).strip()] = str(vals[0])
    return out


def main():
    variants, pkgs = sys.argv[1], sys.argv[2:]
    floors = expected_floors(variants)
    bad = 0
    for f in pkgs:
        z = zipfile.ZipFile(f)
        info = [n for n in z.namelist() if n.startswith("info-")][0]
        t = tarfile.open(fileobj=io.BytesIO(zdecomp(z.read(info))))
        idx = json.load(t.extractfile("info/index.json"))
        subdir, deps = idx["subdir"], idx.get("depends", [])
        fam = "linux" if subdir.startswith("linux") else "osx" if subdir.startswith("osx") else "win"
        floor = floors.get(fam)
        problems = []
        for d in deps:
            m = re.match(r"^(__glibc|__osx|sysroot_[\w-]+)\s+>=\s*([\d.]+)", d)
            if not m or not floor:
                continue
            if vtuple(m.group(2)) > vtuple(floor):
                problems.append(f"{d!r} exceeds recipe floor {floor}")
        status = "OK" if not problems else "FAIL"
        print(f"stdlib floor {status}: {f.split('/')[-1]} [{subdir}] floor={floor} depends={deps}")
        for p in problems:
            print("   ", p)
        bad += bool(problems)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
