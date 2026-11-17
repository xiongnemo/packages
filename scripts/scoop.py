"""Read what the Scoop bucket installs for the projects marked "scoop": true.

Usage: scoop.py PROJECTS_JSON OUT_JSON

The landing page's project list and support matrix show Scoop beside apt, dnf,
apk and MacPorts, and only the bucket knows what Scoop installs: each manifest
names an app, the release it installs and the architectures it has. A manifest
belongs to the project its `homepage` names. Apps ending in -nightly track
prereleases and the others releases, as the bucket names them.

The bucket is $BUCKET (xiongnemo/windows-binaries-scoop-bucket by default), read
through the API, with $GH_TOKEN when it is set. OUT_JSON gets one entry per app:
repo, app, channel, version, tag (from the download URL) and arches, spelled
x64, arm64 and x86 for Scoop's 64bit, arm64 and 32bit.
"""

import json
import os
import re
import sys
import urllib.request
from pathlib import Path

API = "https://api.github.com"
ARCHES = {"64bit": "x64", "arm64": "arm64", "32bit": "x86"}


def get(url):
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    token = os.environ.get("GH_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def urls(manifest):
    """Every download URL in a manifest, whether one string or a list, top level or per architecture."""
    found = []
    for value in [manifest.get("url")] + [a.get("url") for a in manifest.get("architecture", {}).values()]:
        found += value if isinstance(value, list) else [value] if value else []
    return found


def main():
    projects = json.loads(Path(sys.argv[1]).read_text())["projects"]
    bucket = os.environ.get("BUCKET") or "xiongnemo/windows-binaries-scoop-bucket"
    repos = {f"https://github.com/{p['repo']}".lower(): p["repo"] for p in projects if p.get("scoop")}
    apps = []
    for item in json.loads(get(f"{API}/repos/{bucket}/contents/bucket")):
        if not item["name"].endswith(".json"):
            continue
        manifest = json.loads(get(item["download_url"]))
        repo = repos.get(manifest.get("homepage", "").rstrip("/").lower())
        if not repo:
            continue
        app = item["name"].removesuffix(".json")
        tag = next((m.group(1) for u in urls(manifest) if (m := re.search(r"/releases/download/([^/]+)/", u))), None)
        arches = [ARCHES.get(a, a) for a in manifest.get("architecture", {})] or ["any"]
        apps.append({"repo": repo, "app": app, "channel": "nightly" if app.endswith("-nightly") else "stable",
                     "version": manifest.get("version"), "tag": tag, "arches": arches})
        print(f"scoop {app:20} {repo} {manifest.get('version')} ({', '.join(arches)})", flush=True)
    Path(sys.argv[2]).write_text(json.dumps(apps, indent=2) + "\n")
    print(f"{len(apps)} Scoop apps in {bucket}")


if __name__ == "__main__":
    main()
