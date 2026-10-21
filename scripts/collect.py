"""Collect package assets from GitHub Releases for a link-only repository.

Usage: collect.py PROJECTS_JSON WORK SITE [--include OWNER/REPO@TAG ...]

For each project, the newest `keep` releases of each channel -- prereleases are
`nightly`, the rest `stable` -- are fetched by the API, and every .deb, .rpm and
.apk attached to them is downloaded and checked against the digest GitHub
reports. The files are laid out for the index tools:

  WORK/apt-<channel>/pool/<owner>/<repo>/<tag>/<asset>                 apt-ftparchive
  WORK/rpm-<channel>/<owner>/<repo>/releases/download/<tag>/<asset>    createrepo_c -u https://github.com/
  WORK/apk-<channel>/<arch>/<name>-<version>.apk                       apk index

None of these files is published. SITE/_redirects sends each apt and apk package
path to its Release asset, and dnf follows xml:base to GitHub directly, so the
site carries only indices. The hash in every index is the one computed here from
the downloaded file, never one the publishing repository declared.

`--include` names a release a dispatch announced. It is fetched by tag, because
the releases list has lagged a fresh upload by hours.
"""

import gzip
import hashlib
import io
import json
import os
import shutil
import sys
import tarfile
import urllib.request
from pathlib import Path

API = "https://api.github.com"
FORMATS = (".deb", ".rpm", ".apk")


def api(path):
    request = urllib.request.Request(API + path, headers={"Accept": "application/vnd.github+json"})
    token = os.environ.get("GH_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def download(url, target):
    with urllib.request.urlopen(url, timeout=300) as response, open(target, "wb") as out:
        shutil.copyfileobj(response, out)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def pkginfo(path):
    """Read .PKGINFO from an apk: concatenated gzip streams of tar segments."""
    with gzip.open(path) as stream:
        data = stream.read()
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:", ignore_zeros=True) as archive:
        member = archive.extractfile(".PKGINFO")
        fields = {}
        for line in member.read().decode().splitlines():
            key, sep, value = line.partition(" = ")
            if sep and key not in fields:
                fields[key] = value
        return fields


def releases(repo, includes):
    found = {r["tag_name"]: r for r in api(f"/repos/{repo}/releases?per_page=50") if not r["draft"]}
    for tag in includes.get(repo, []):
        if tag not in found:
            release = api(f"/repos/{repo}/releases/tags/{tag}")
            if not release["draft"]:
                found[tag] = release
    return sorted(found.values(), key=lambda r: r["published_at"] or "", reverse=True)


def main():
    projects_file, work, site = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    includes = {}
    args = sys.argv[4:]
    while args:
        flag, value, args = args[0], args[1], args[2:]
        assert flag == "--include", flag
        repo, _, tag = value.partition("@")
        includes.setdefault(repo, []).append(tag)

    cache = work / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    site.mkdir(parents=True, exist_ok=True)
    manifest, redirects = [], []

    for project in json.loads(projects_file.read_text())["projects"]:
        repo, keep = project["repo"], project.get("keep", 3)
        owner, name = repo.split("/")
        per_channel = {"nightly": 0, "stable": 0}
        for release in releases(repo, includes):
            channel = "nightly" if release["prerelease"] else "stable"
            assets = [a for a in release["assets"] if a["name"].endswith(FORMATS) and a["state"] == "uploaded"]
            if not assets or per_channel[channel] >= keep:
                continue
            per_channel[channel] += 1
            tag = release["tag_name"]
            for asset in assets:
                cached = cache / f"{asset['id']}-{asset['name']}"
                declared = (asset.get("digest") or "").removeprefix("sha256:")
                if not cached.exists() or (declared and sha256(cached) != declared):
                    download(asset["browser_download_url"], cached)
                actual = sha256(cached)
                if declared and actual != declared:
                    sys.exit(f"{repo} {tag} {asset['name']}: downloaded sha256 {actual}, GitHub reports {declared}")
                url = f"https://github.com/{repo}/releases/download/{tag}/{asset['name']}"
                entry = {"repo": repo, "tag": tag, "channel": channel, "asset": asset["name"],
                         "sha256": actual, "size": cached.stat().st_size, "url": url}
                if asset["name"].endswith(".deb"):
                    target = work / f"apt-{channel}" / "pool" / owner / name / tag / asset["name"]
                    entry["format"] = "deb"
                elif asset["name"].endswith(".rpm"):
                    target = work / f"rpm-{channel}" / owner / name / "releases" / "download" / tag / asset["name"]
                    entry["format"] = "rpm"
                else:
                    info = pkginfo(cached)
                    file_name = f"{info['pkgname']}-{info['pkgver']}.apk"
                    target = work / f"apk-{channel}" / info["arch"] / file_name
                    if target.exists():
                        continue  # an older release built the same name-version; the newest wins
                    entry.update(format="apk", package=info["pkgname"], version=info["pkgver"], arch=info["arch"])
                    redirects.append(f"/apk/{channel}/{info['arch']}/{file_name} {url} 302")
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(cached, target)
                manifest.append(entry)
                print(f"{channel:8} {entry['format']} {repo} {tag} {asset['name']}", flush=True)

    rules = [
        "# Generated by scripts/collect.py. Packages are not stored here: every",
        "# package path is a 302 to the GitHub Release asset it was indexed from.",
        "# 302 rather than 301/308 on purpose: apk-tools' libfetch does not follow 308.",
        "/apt/pool/:owner/:repo/:tag/:asset https://github.com/:owner/:repo/releases/download/:tag/:asset 302",
        *redirects,
    ]
    (site / "_redirects").write_text("\n".join(rules) + "\n")
    (site / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{len(manifest)} packages, {len(redirects)} apk redirects")


if __name__ == "__main__":
    main()
