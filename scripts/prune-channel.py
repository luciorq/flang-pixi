#!/usr/bin/env python3
"""Keep only the newest build of each package in a local channel subdir and
re-index it. Usage: prune-channel.py <channel-subdir-path> [--dry-run]

"Newest" = highest (version, build_number) per package name, parsed from the
filename <name>-<version>-<buildstring>.conda. Then calls publish-crossbuilt.py
with an empty source dir, which drops repodata entries for deleted files.
Requires Python >= 3.14 (or zstandard) like publish-crossbuilt.py."""
import os, re, sys, subprocess, tempfile
sub = os.path.abspath(sys.argv[1]); dry = "--dry-run" in sys.argv
def key(v): return tuple(int(x) if x.isdigit() else x for x in re.split(r"[.]", v))
groups = {}
for f in os.listdir(sub):
    m = re.match(r"^(.+?)-(\d[^-]*)-([^-]+)\.conda$", f)
    if not m: continue
    name, ver, bs = m.groups(); bn = int(bs.rsplit("_", 1)[-1])
    groups.setdefault(name, []).append((key(ver), bn, f))
for name, lst in sorted(groups.items()):
    lst.sort()
    for _, _, f in lst[:-1]:
        print(("would delete " if dry else "deleting ") + f)
        if not dry: os.remove(os.path.join(sub, f))
    print("keep", lst[-1][2])
if not dry:
    empty = tempfile.mkdtemp()
    here = os.path.dirname(os.path.abspath(__file__))
    subprocess.check_call([sys.executable, os.path.join(here, "publish-crossbuilt.py"), empty, sub])
