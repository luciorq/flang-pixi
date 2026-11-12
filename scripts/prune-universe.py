#!/usr/bin/env python3
"""Delete superseded consumer-set files from prefix.dev `universe`.

Rule: for each of lld-zig / flang-zig / flang-rt-zig / llvm-openmp (our zig_* builds) and
each subdir, keep the newest build number of VERSION (default: `version` in
scripts/build-alignment.json) AND every (version, build number) listed under
`retain` there (release builds a published consumer pins exactly —
r-zig-toolchain pins 23.1.1 `*_5`/`*_6`/`*_10`, 2026-10-07, r-zig-pixi's lock
23.1.1 `*_6`/`*_7`/`*_11`; deleting them 404s its installs); everything else
of those packages is deleted. `retain` is keyed by version since the 23.1.5
release (2026-11-11): a version bump would otherwise delete every pinned
build of the previous version. llvm-zig is never on universe (asserted).
Dry run by default; `--apply` performs `batchDeletePackageVariants`. Needs
a key with the `channel:delete-package` scope in ~/.rattler/credentials.json
(the 2026-09-30 key has it). Usage: prune-universe.py [--apply] [--version V]
"""
import argparse, json, re, sys, urllib.request, os

PKGS = ("lld-zig", "flang-zig", "flang-rt-zig", "llvm-openmp")

def gql(key, query, variables=None):
    req = urllib.request.Request("https://prefix.dev/api/graphql", data=json.dumps({"query": query, "variables": variables or {}}).encode(),
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req))

def variants(key, name):
    d = gql(key, '{ channel(name:"universe") { packages(filters:{name:{eq:"%s"}}, limit:1) { page { variants(includeHidden:true, limit:500) { page { filename platform } } } } } }' % name)
    return [(v["platform"], v["filename"]) for pk in d["data"]["channel"]["packages"]["page"] for v in pk["variants"]["page"]]

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--apply", action="store_true"); ap.add_argument("--version")
    a = ap.parse_args()
    key = json.load(open(os.path.expanduser("~/.rattler/credentials.json")))["*.prefix.dev"]["BearerToken"]
    cfg_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "build-alignment.json")
    cfg = json.load(open(cfg_path)) if os.path.exists(cfg_path) else {}
    a.version = a.version or cfg.get("version") or sys.exit("no --version and no version in build-alignment.json")
    # retain: {version: {package: [build, ...]}}
    retain = {(ver, p, int(b)) for ver, per in (cfg.get("retain") or {}).items() for p, bs in per.items() for b in bs}
    assert not variants(key, "llvm-zig"), "llvm-zig must never be on universe"
    keep, delete, retained = {}, [], []
    for pkg in PKGS:
        for plat, fn in variants(key, pkg):
            m = re.match(rf"{re.escape(pkg)}-([\d.]+)-zig_[0-9a-f]+_(\d+)\.conda$", fn)
            if not m:
                print("skip (unparsed):", plat, fn); continue
            ver, bn = m.group(1), int(m.group(2))
            if (ver, pkg, bn) in retain:
                retained.append((plat, fn)); continue
            if ver != a.version:
                delete.append((plat, fn)); continue
            k = (pkg, plat)
            if k not in keep or bn > keep[k][1]:
                if k in keep: delete.append((plat, keep[k][0]))
                keep[k] = (fn, bn)
            else:
                delete.append((plat, fn))
    print("keep (%d):" % len(keep)); [print("  ", plat, fn) for (pkg, plat), (fn, bn) in sorted(keep.items(), key=lambda x: (x[0][1], x[0][0]))]
    print("retained for pinned consumers (%d):" % len(retained)); [print("  ", plat, fn) for plat, fn in sorted(retained)]
    # a retained build that is also the newest counts once; keep newest-per-subdir of the rest
    print("delete (%d):" % len(delete)); [print("  ", plat, fn) for plat, fn in sorted(delete)]
    if not delete:
        return
    if not a.apply:
        print("dry run — pass --apply to delete"); return
    r = gql(key, "mutation($c:String!,$e:[PackageVariantInput!]!){ batchDeletePackageVariants(channelName:$c, entries:$e) }",
            {"c": "universe", "e": [{"subdir": p, "filename": f} for p, f in delete]})
    print("result:", r)
    sys.exit(0 if r.get("data", {}).get("batchDeletePackageVariants") else 1)

if __name__ == "__main__":
    main()
