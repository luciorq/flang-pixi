#!/usr/bin/env python3
"""Fail when a consumer package's build number differs across subdirs outside
a declared hotfix (docs/13 rule, 2026-10-06: one build number per package per
release). Reads the newest build per (package, subdir) from prefix.dev
`universe` (GraphQL, like prune-universe.py; key in ~/.rattler/credentials.json)
or from a local channel directory (--channel-dir ./channel), and compares it
with scripts/build-alignment.json:
  release[pkg] = N        -> every subdir must be N, unless (pkg, subdir, build) is in `hotfixes`
  release[pkg] = null     -> pre-rule generation: every subdir must match `legacy[pkg][subdir]`
Usage: check-build-alignment.py [--channel-dir DIR] [--config scripts/build-alignment.json]
Exit 1 on any violation or on a subdir with no file at all.
"""
import argparse, json, os, re, sys, urllib.request

PKGS = ("lld-zig", "flang-zig", "flang-rt-zig")
SUBDIRS = ("linux-64", "linux-aarch64", "osx-arm64", "osx-64", "win-64", "win-arm64")
RX = re.compile(r"^(?P<pkg>[a-z-]+)-(?P<ver>[\d.]+)-zig_[0-9a-f]+_(?P<bn>\d+)\.conda$")


def gql(key, query):
    req = urllib.request.Request("https://prefix.dev/api/graphql", data=json.dumps({"query": query}).encode(),
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req))


def from_universe(version):
    key = json.load(open(os.path.expanduser("~/.rattler/credentials.json")))["*.prefix.dev"]["BearerToken"]
    newest = {}
    for pkg in PKGS:
        d = gql(key, '{ channel(name:"universe") { packages(filters:{name:{eq:"%s"}}, limit:1) { page { variants(includeHidden:true, limit:500) { page { filename platform } } } } } }' % pkg)
        for pk in d["data"]["channel"]["packages"]["page"]:
            for v in pk["variants"]["page"]:
                m = RX.match(v["filename"])
                if m and m["ver"] == version:
                    k = (pkg, v["platform"]); newest[k] = max(newest.get(k, -1), int(m["bn"]))
    return newest


def from_dir(root, version):
    newest = {}
    for sub in SUBDIRS:
        for fn in os.listdir(os.path.join(root, sub)) if os.path.isdir(os.path.join(root, sub)) else []:
            m = RX.match(fn)
            if m and m["pkg"] in PKGS and m["ver"] == version:
                k = (m["pkg"], sub); newest[k] = max(newest.get(k, -1), int(m["bn"]))
    return newest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--channel-dir"); ap.add_argument("--config", default=os.path.join(os.path.dirname(__file__), "build-alignment.json"))
    a = ap.parse_args()
    cfg = json.load(open(a.config)); version = cfg["version"]
    newest = from_dir(a.channel_dir, version) if a.channel_dir else from_universe(version)
    hot = {(h["package"], h["subdir"], int(h["build"])) for h in cfg.get("hotfixes", [])}
    bad = 0
    print(f"{'package':14s} " + " ".join(f"{s:>13s}" for s in SUBDIRS) + "   rule")
    for pkg in PKGS:
        rel = cfg["release"].get(pkg)
        row = []
        for sub in SUBDIRS:
            bn = newest.get((pkg, sub))
            if bn is None:
                row.append("MISSING"); bad += 1; continue
            if rel is None:
                exp = cfg.get("legacy", {}).get(pkg, {}).get(sub)
                ok = exp is not None and bn == exp
            else:
                ok = bn == rel or (pkg, sub, bn) in hot
            row.append(f"_{bn}" + ("" if ok else " !!"))
            bad += 0 if ok else 1
        print(f"{pkg:14s} " + " ".join(f"{c:>13s}" for c in row) + f"   {'legacy spread (pre-rule)' if rel is None else 'release build ' + str(rel)}")
    if bad:
        print(f"build alignment FAILED: {bad} cell(s) outside the declared release/hotfix/legacy state — docs/13, scripts/build-alignment.json")
        sys.exit(1)
    print("build alignment OK" + (" (pre-rule generation: numbers match the declared legacy spread)" if any(v is None for v in cfg["release"].values()) else ""))


if __name__ == "__main__":
    main()
