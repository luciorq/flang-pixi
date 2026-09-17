#!/usr/bin/env python3
"""Publish standalone-rattler-build outputs into the local file:// channel.

Usage: publish-crossbuilt.py <outdir-subdir> <channel-subdir>
  e.g. publish-crossbuilt.py aarch64out/linux-aarch64 channel/linux-aarch64

Copies any .conda missing from the channel subdir, drops repodata entries for
files that no longer exist, adds entries for new files (reading
info/index.json out of the .conda), and deletes derived repodata files.
This is the pixi-publish bypass for cross-built packages (pixi publish
panics on cross; see docs/12). Requires Python >= 3.14 (compression.zstd)
or the zstandard package.
"""
import hashlib, io, json, os, shutil, sys, tarfile, zipfile

try:
    from compression import zstd
    def zdecomp(b): return zstd.decompress(b)
except ImportError:
    import zstandard
    def zdecomp(b): return zstandard.ZstdDecompressor().decompress(b, max_output_size=1 << 31)

OUT, CH = sys.argv[1], sys.argv[2]
os.makedirs(CH, exist_ok=True)

for f in sorted(os.listdir(OUT)):
    if f.endswith(".conda") and not os.path.exists(os.path.join(CH, f)):
        shutil.copy2(os.path.join(OUT, f), os.path.join(CH, f))
        print("copied", f)

rp = os.path.join(CH, "repodata.json")
repo = json.load(open(rp)) if os.path.exists(rp) else {
    "info": {"subdir": os.path.basename(CH)}, "packages": {},
    "packages.conda": {}, "repodata_version": 2}
pkgs = repo.setdefault("packages.conda", {})

for fn in [k for k in list(pkgs) if not os.path.exists(os.path.join(CH, k))]:
    del pkgs[fn]; print("dropped", fn)

def index_json(path):
    with zipfile.ZipFile(path) as z:
        info = [n for n in z.namelist() if n.startswith("info-") and n.endswith(".tar.zst")][0]
        with tarfile.open(fileobj=io.BytesIO(zdecomp(z.read(info))), mode="r") as t:
            return json.load(t.extractfile("info/index.json"))

for fn in sorted(os.listdir(CH)):
    if not fn.endswith(".conda") or fn in pkgs:
        continue
    p = os.path.join(CH, fn)
    idx = index_json(p)
    data = open(p, "rb").read()
    entry = {k: idx[k] for k in ("name", "version", "build", "build_number",
                                 "subdir", "depends") if k in idx}
    for k in ("constrains", "license", "timestamp", "arch", "platform", "run_exports"):
        if k in idx:
            entry[k] = idx[k]
    entry["size"] = len(data)
    entry["sha256"] = hashlib.sha256(data).hexdigest()
    entry["md5"] = hashlib.md5(data).hexdigest()
    pkgs[fn] = entry
    print("added", fn)

json.dump(repo, open(rp, "w"), indent=2, sort_keys=True)
for f in os.listdir(CH):
    if f.startswith("repodata") and f != "repodata.json":
        os.remove(os.path.join(CH, f)); print("removed derived", f)
print("OK", rp)
