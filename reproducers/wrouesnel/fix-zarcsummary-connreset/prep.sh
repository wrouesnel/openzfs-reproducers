#!/bin/bash
# prep.sh ROOT -- bug #124 image, run in the userland builder by builder/in/demo-disk.sh:
# the Python standard library for /demo/bin/python3 (from `bins`), without
# the parts zarcsummary and the helpers don't need.  Python finds it as
# /demo/LIBDIR/python3.X (its prefix is /demo, from the executable's path;
# LIBDIR is sys.platlibdir: lib, or lib64 on Fedora/EL).
set -euo pipefail
R=${1:?root}
py=$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')
ld=$(python3 -c 'import sys; print(sys.platlibdir)')
mkdir -p "$R/$ld/${py##*/}"
tar -C "$py" -c --exclude=__pycache__ --exclude=test --exclude=tests \
    --exclude=idlelib --exclude=tkinter --exclude=turtledemo --exclude=ensurepip \
    --exclude=lib2to3 --exclude=pydoc_data --exclude=site-packages \
    --exclude=dist-packages --exclude='config-*' --exclude=sitecustomize.py \
    --exclude=_ssl.* --exclude=_hashlib.* --exclude=_tkinter.* \
    --exclude=_sqlite3.* --exclude=sqlite3 --exclude=_dbm.* --exclude=_gdbm.* . |
    tar -C "$R/$ld/${py##*/}" -x
du -sh "$R/$ld/${py##*/}" | sed 's/^/python stdlib: /'
