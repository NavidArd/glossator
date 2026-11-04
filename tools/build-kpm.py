#!/usr/bin/env python3
"""Build Glossator's KPM package and update the repository index.

    python3 tools/build-kpm.py

Packs kpm/package/ (manifest and hooks) with glossator.koplugin/ into
kpm/packages/glossator/glossator_<version>_kindleany.kpkg, the way KPM's
kpm-helper.py packs a package (a gzip tar with the files at its root), and adds
the version to kpm/manifest.v2.json. The version comes from
glossator.koplugin/_meta.lua and is written into the package manifest.
"""
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG_SRC = os.path.join(ROOT, "kpm", "package")
PLUGIN = os.path.join(ROOT, "glossator.koplugin")
OUT_DIR = os.path.join(ROOT, "kpm", "packages", "glossator")
INDEX = os.path.join(ROOT, "kpm", "manifest.v2.json")
# never ship these, even if they turn up in the plugin folder
SECRETS = re.compile(r"(_key\.txt|\.key|_mock\.txt)$")


def plugin_version():
    meta = open(os.path.join(PLUGIN, "_meta.lua"), encoding="utf-8").read()
    m = re.search(r'version\s*=\s*"(\d+)\.(\d+)\.(\d+)"', meta)
    if not m:
        sys.exit("No version = \"x.y.z\" in glossator.koplugin/_meta.lua")
    return [int(x) for x in m.groups()]


def main():
    version = plugin_version()
    vs = ".".join(map(str, version))
    manifest = json.load(open(os.path.join(PKG_SRC, "manifest.json"), encoding="utf-8"))
    manifest["version"] = version

    with tempfile.TemporaryDirectory() as tmp:
        stage = os.path.join(tmp, "glossator")
        shutil.copytree(PKG_SRC, stage)
        shutil.copytree(PLUGIN, os.path.join(stage, "glossator.koplugin"),
                        ignore=lambda d, names: [n for n in names if SECRETS.search(n)])
        with open(os.path.join(stage, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2)
        os.makedirs(OUT_DIR, exist_ok=True)
        name = f"glossator_{vs}_kindleany.kpkg"
        out = os.path.join(OUT_DIR, name)

        def reset(ti):
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            if ti.isfile() and ti.name.endswith(".sh"):
                ti.mode = 0o755
            return ti

        with tarfile.open(out, "w:gz", compresslevel=9) as tar:
            for item in sorted(os.listdir(stage)):
                tar.add(os.path.join(stage, item), arcname=item, filter=reset)

    index = json.load(open(INDEX, encoding="utf-8"))
    pkg = index["packages"].setdefault("glossator", {
        "name": manifest["name"], "author": manifest["author"],
        "description": manifest["description"], "artifacts": []})
    pkg["name"], pkg["author"], pkg["description"] = manifest["name"], manifest["author"], manifest["description"]
    url = f"packages/glossator/{name}"
    pkg["artifacts"] = [a for a in pkg["artifacts"] if a["url"] != url]
    pkg["artifacts"].append({"url": url, "version": version, "dependencies": [], "supported_platforms": None})
    pkg["artifacts"].sort(key=lambda a: a["version"])
    with open(INDEX, "w", encoding="utf-8") as f:
        json.dump(index, f, indent=2)
        f.write("\n")
    print(f"Built kpm/packages/glossator/{name} ({os.path.getsize(out) // 1024} KB) and updated kpm/manifest.v2.json")


if __name__ == "__main__":
    main()
