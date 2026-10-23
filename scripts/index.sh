#!/usr/bin/env bash
# Build and sign the apt, rpm and apk indices for what collect.py laid out.
#
# Usage: index.sh WORK SITE
#
# Signing keys come from the environment:
#   GPG_SIGNING_KEY       armored private key; signs apt InRelease/Release.gpg and rpm repomd.xml
#   APK_SIGNING_KEY       PEM RSA private key; signs every APKINDEX
#   APK_SIGNING_KEY_NAME  its file name as users install it, e.g. nemo-packages.rsa
# Without them the indices are signed with throwaway keys and SITE/TEST-ONLY is
# written, which the deploy job refuses: the signing path is exercised on every
# run, and a site nobody can verify is never published.
set -euo pipefail

work=$(realpath "$1")
site=$(realpath "$2")
site_url=${SITE_URL:-https://packages.example.invalid}
keys=$(mktemp -d)
mkdir -p "$site/keys"

# -- keys ---------------------------------------------------------------------
echo "== keys"

export GNUPGHOME="$keys/gnupg"
mkdir -m 700 "$GNUPGHOME"
if [ -n "${GPG_SIGNING_KEY:-}" ]; then
  printf '%s\n' "$GPG_SIGNING_KEY" | gpg --batch --quiet --import
else
  echo "::warning title=Test-only signing::GPG_SIGNING_KEY is not set; signing with a throwaway key. This site will not be deployed."
  gpg --batch --quiet --passphrase '' --quick-gen-key "Nemo's Packages (TEST ONLY) <packages@example.invalid>" rsa4096 sign 2d
  echo "Signed with throwaway keys; not for deployment." > "$site/TEST-ONLY"
fi
fpr=$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr/ { print $10; exit }')
gpg --batch --export "$fpr" > "$site/keys/nemo-packages.gpg"
gpg --batch --armor --export "$fpr" > "$site/keys/nemo-packages.asc"

mkdir -p "$keys/apk"
if [ -n "${APK_SIGNING_KEY:-}" ]; then
  apk_key=${APK_SIGNING_KEY_NAME:?APK_SIGNING_KEY_NAME must name the key}
  printf '%s\n' "$APK_SIGNING_KEY" > "$keys/apk/$apk_key"
else
  apk_key=nemo-packages-test.rsa
  openssl genrsa -out "$keys/apk/$apk_key" 4096 2>/dev/null
fi
openssl rsa -in "$keys/apk/$apk_key" -pubout -out "$keys/apk/$apk_key.pub" 2>/dev/null
cp "$keys/apk/$apk_key.pub" "$site/keys/"

sign_detached() { gpg --batch --yes --local-user "$fpr" --armor --detach-sign --output "$1.asc" "$1"; }

# -- apt ----------------------------------------------------------------------
echo "== apt"

for channel in nightly stable; do
  root="$work/apt-$channel"
  [ -d "$root/pool" ] || continue
  dist="$site/apt/dists/$channel"
  # apt-ftparchive --arch filters by a *_<arch>.deb file name, which Release
  # asset names do not follow, so the stanzas are split by their Architecture
  # field instead; `all` belongs in every architecture's list.
  (cd "$root" && apt-ftparchive packages pool) > "$keys/Packages"
  mapfile -t archs < <(python3 - "$keys/Packages" "$dist/main" <<'PY'
import sys
from pathlib import Path

stanzas = [s for s in Path(sys.argv[1]).read_text().split("\n\n") if s.strip()]
def arch(stanza):
    return next(l.split(":", 1)[1].strip() for l in stanza.splitlines() if l.startswith("Architecture:"))
archs = sorted({arch(s) for s in stanzas} - {"all"})
for name in archs:
    out = Path(sys.argv[2]) / f"binary-{name}"
    out.mkdir(parents=True, exist_ok=True)
    (out / "Packages").write_text("\n\n".join(s.strip() for s in stanzas if arch(s) in (name, "all")) + "\n")
    print(name)
PY
  )
  for arch in "${archs[@]}"; do
    gzip -9kn "$dist/main/binary-$arch/Packages"
  done
  (cd "$dist" && apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=nemo \
    -o APT::FTPArchive::Release::Label=nemo \
    -o APT::FTPArchive::Release::Suite="$channel" \
    -o APT::FTPArchive::Release::Codename="$channel" \
    -o APT::FTPArchive::Release::Architectures="${archs[*]}" \
    -o APT::FTPArchive::Release::Components=main \
    -o APT::FTPArchive::Release::Description="Nemo's Packages ($channel)" \
    release .) > "$keys/Release"
  mv "$keys/Release" "$dist/Release"
  gpg --batch --yes --local-user "$fpr" --clearsign --output "$dist/InRelease" "$dist/Release"
  gpg --batch --yes --local-user "$fpr" --armor --detach-sign --output "$dist/Release.gpg" "$dist/Release"
  echo "apt $channel: ${archs[*]}"
done

# -- rpm ----------------------------------------------------------------------
echo "== rpm"

for channel in nightly stable; do
  root="$work/rpm-$channel"
  [ -d "$root" ] || continue
  out="$site/rpm/$channel"
  mkdir -p "$out"
  createrepo_c --quiet --no-database --general-compress-type=gz --baseurl https://github.com/ --outputdir "$out" "$root"
  sign_detached "$out/repodata/repomd.xml"
  cat > "$site/rpm/nemo-$channel.repo" <<EOF
[nemo-$channel]
name=Nemo's Packages ($channel)
baseurl=$site_url/rpm/$channel
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=$site_url/keys/nemo-packages.asc
EOF
  echo "rpm $channel: $(find "$root" -name '*.rpm' | wc -l) packages"
done

# -- apk ----------------------------------------------------------------------
echo "== apk"

for channel in nightly stable; do
  root="$work/apk-$channel"
  [ -d "$root" ] || continue
  out="$site/apk/$channel"
  mkdir -p "$out"
  docker run --rm -e DESCRIPTION="Nemo's Packages ($channel)" -e KEY="$apk_key" -e IDS="$(id -u):$(id -g)" \
    -v "$root:/repo:ro" -v "$keys/apk:/keys:ro" -v "$out:/out" alpine:3.21 sh -euc '
      apk add -q abuild
      for dir in /repo/*/; do
        arch=$(basename "$dir")
        mkdir -p "/out/$arch"
        apk index -q --allow-untrusted -d "$DESCRIPTION" -o "/out/$arch/APKINDEX.tar.gz" "$dir"*.apk
        abuild-sign -q -k "/keys/$KEY" -p "$KEY.pub" "/out/$arch/APKINDEX.tar.gz"
      done
      chown -R "$IDS" /out
    '
  echo "apk $channel: $(ls "$out" | tr '\n' ' ')"
done

# -- landing page -------------------------------------------------------------
echo "== landing page"

python3 - "$site" "$site_url" "$apk_key.pub" <<'PY'
import html, json, sys
from pathlib import Path

site, url, apk_key = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
manifest = json.loads((site / "manifest.json").read_text())
esc = html.escape
about = {
    "stable": "Releases: an exact version tag, published as a release.",
    "nightly": "Prereleases: every push to a project's main branch, versioned as a "
               "prerelease of the next release (1.4.3~pre-1, apk 1.4.3_pre-r1).",
}


def setup(channel):
    return f"""<h3>apt</h3>
<pre>sudo curl -fsSLo /usr/share/keyrings/nemo.gpg {url}/keys/nemo-packages.gpg
echo "deb [signed-by=/usr/share/keyrings/nemo.gpg] {url}/apt {channel} main" | sudo tee /etc/apt/sources.list.d/nemo-{channel}.list
sudo apt update</pre>
<h3>dnf</h3>
<pre>sudo curl -fsSLo /etc/yum.repos.d/nemo-{channel}.repo {url}/rpm/nemo-{channel}.repo</pre>
<h3>apk</h3>
<pre>wget -qO /etc/apk/keys/{apk_key} {url}/keys/{apk_key}
echo "{url}/apk/{channel}" >> /etc/apk/repositories
apk update</pre>"""


def table(channel):
    rows = "\n".join(
        f"<tr><td>{esc(p['format'])}</td>"
        f"<td><a href=\"https://github.com/{esc(p['repo'])}\">{esc(p['repo'].split('/')[1])}</a></td>"
        f"<td>{esc(p['tag'])}</td><td><a href=\"{esc(p['url'])}\">{esc(p['asset'])}</a></td></tr>"
        for p in manifest if p["channel"] == channel
    )
    return f"<table>{rows}</table>"


sections = []
for channel in ("stable", "nightly"):
    body = f"<p>{esc(about[channel])}</p>"
    if any(p["channel"] == channel for p in manifest):
        body += setup(channel) + "<h3>Packages</h3>" + table(channel)
    else:
        body += "<p><em>Nothing published on this channel yet.</em></p>"
    sections.append(f"<h2>{channel}</h2>\n{body}")

page = f"""<!doctype html>
<meta charset="utf-8">
<title>Nemo's Packages</title>
<style>body{{font:15px/1.5 system-ui,sans-serif;max-width:60rem;margin:2rem auto;padding:0 1rem}}
pre{{background:#f4f4f4;padding:.75rem;overflow-x:auto}}td{{padding:.1rem .6rem;font-size:13px}}</style>
<h1>Nemo's Packages</h1>
<p>Indices only: every package is fetched from its GitHub Release. Two channels,
each on its own: subscribe to <code>stable</code>, <code>nightly</code> or both.
On Windows, use the <a href="https://github.com/xiongnemo/windows-binaries-scoop-bucket">Scoop bucket</a> instead:</p>
<pre>scoop bucket add nemo https://github.com/xiongnemo/windows-binaries-scoop-bucket</pre>
{chr(10).join(sections)}
"""
(site / "index.html").write_text(page)
PY
echo "$apk_key.pub" > "$site/keys/apk-key-name"
