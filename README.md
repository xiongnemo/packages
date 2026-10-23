# packages

apt, dnf, apk and MacPorts repositories for Nemo's tools, carrying **indices only**,
at **https://package.anzupop.com**. Every package stays where
its project published it, on GitHub Releases:

| Format | How a package is found |
|---|---|
| apt | `Filename: pool/<owner>/<repo>/<tag>/<asset>`; `_redirects` sends `pool/*` to the Release asset with a 302 |
| dnf | `primary.xml` carries `xml:base="https://github.com/"`; dnf fetches the asset directly, no redirect needed |
| apk | apk names files `<name>-<version>.apk`; `_redirects` has one 302 per package |
| MacPorts | a signify-signed `ports.tar` of binary Portfiles; each fetches its darwin build from `master_sites` on GitHub Releases |

On Windows, the same tools come from the
[Scoop bucket](https://github.com/xiongnemo/windows-binaries-scoop-bucket):
`scoop bucket add nemo https://github.com/xiongnemo/windows-binaries-scoop-bucket`.

The redirects are 302 on purpose: apk-tools' libfetch does not follow 308.
Indices are rebuilt from the Releases on every run, and every hash in them is
computed here from the downloaded file and checked against the digest GitHub
reports, never taken from the publishing project.

## Using it

```sh
# apt (Debian, Ubuntu)
sudo curl -fsSLo /usr/share/keyrings/nemo.gpg https://package.anzupop.com/keys/nemo-packages.gpg
echo "deb [signed-by=/usr/share/keyrings/nemo.gpg] https://package.anzupop.com/apt nightly main" | sudo tee /etc/apt/sources.list.d/nemo.list
sudo apt update && sudo apt install saki nermius nemosh gp-socks

# dnf (Fedora, RHEL and derivatives)
sudo curl -fsSLo /etc/yum.repos.d/nemo-nightly.repo https://package.anzupop.com/rpm/nemo-nightly.repo
sudo dnf install saki nermius nemosh gp-socks

# apk (Alpine)
wget -qO /etc/apk/keys/nemo-packages.rsa.pub https://package.anzupop.com/keys/nemo-packages.rsa.pub
echo https://package.anzupop.com/apk/nightly >> /etc/apk/repositories
apk update && apk add saki nermius nemosh gp-socks
```

```sh
# MacPorts (macOS)
sudo curl -fsSLo /opt/local/share/macports/nemo-macports.pub https://package.anzupop.com/keys/nemo-macports.pub
echo /opt/local/share/macports/nemo-macports.pub | sudo tee -a /opt/local/etc/macports/pubkeys.conf
# add above the [default] line of /opt/local/etc/macports/sources.conf:
#   https://package.anzupop.com/macports/nightly/ports.tar
sudo port sync && sudo port install saki nermius nemosh gp-socks
```

A MacPorts tree holds one version per port, so each channel's tree has the
newest release of each project; the ports are named as the commands are. List
one channel in `sources.conf`: with both, MacPorts takes each port from
whichever line comes first.

The apt and rpm metadata are signed with GPG key
`A55073A0CA98126E1A693E79DD3919908757998C`; packages themselves are not signed,
their hashes are pinned by the signed indices.

## Serving

A run's output is pushed as the single commit of the `site` branch. The Worker
in [`worker/`](worker/index.js) serves that branch: it resolves the branch to a
commit at most once a minute, reads every file at that commit (so `InRelease`
and the `Packages` it lists always come from the same build), and applies
`_redirects` the way Cloudflare Pages does. Publishing a site therefore needs
no Cloudflare credentials, and `verify-live` installs from the public URL once
it serves the new commit. The Worker only needs redeploying when its own code
changes: `npx wrangler deploy` in `worker/`.

The site is plain static files plus a Pages-style `_redirects`, so Cloudflare
Pages or Netlify connected to the `site` branch could serve it unchanged.

## How a release gets here

A project's release job sends a `repository_dispatch` of type
`release-published` with `repository`, `tag`, `channel` and `sha`. The tag is
fetched directly, because the releases list has lagged an upload by hours; the
six-hourly schedule catches anything that could not dispatch. Projects are
listed in [`projects.json`](projects.json), with how many releases per channel
to keep. Prereleases are `nightly`, the rest `stable`.

The dispatching repository needs a `PACKAGES_DISPATCH_TOKEN` secret: a
fine-grained token with **Contents: read and write** on this repository.

## Channels

`stable` carries releases (a project's exact `vX.Y.Z` tag, published as a GitHub
release); `nightly` carries prereleases only, versioned as a prerelease of the
next release (`1.4.3~pre-1`, apk `1.4.3_pre-r1`). The channels are separate:
subscribe to one or both. Which channel a release lands in is GitHub's
prerelease flag, nothing else.

## Scoop

A dispatch for a project marked `"scoop": true` in `projects.json` is passed on
to the [Scoop bucket](https://github.com/xiongnemo/windows-binaries-scoop-bucket)'s
Excavator, once GitHub's releases list shows the release's Windows asset. This
needs `SCOOP_BUCKET_TOKEN`: a fine-grained token with **Actions: read and write**
on the bucket. Without it the bucket's hourly sweep is the only update.

## Configuration

| Name | Kind | Purpose |
|---|---|---|
| `GPG_SIGNING_KEY` | secret | Armored private key; signs apt `InRelease`/`Release.gpg` and rpm `repomd.xml` |
| `APK_SIGNING_KEY` | secret | PEM RSA private key; signs every `APKINDEX` |
| `APK_SIGNING_KEY_NAME` | variable | Its file name, e.g. `nemo-packages.rsa`; users install `<name>.pub` |
| `MACPORTS_SIGNING_KEY` | secret | signify secret key; signs each `ports.tar` as `ports.tar.sig` (MacPorts checks http(s) tarballs with signify only). The public half is [`keys/nemo-macports.pub`](keys/nemo-macports.pub) |
| `SITE_URL` | variable | Public base URL, written into the `.repo` files and the landing page, and where `verify-live` installs from |

Without the signing keys each run signs with throwaway keys, writes
`TEST-ONLY`, and is not deployed: the signing path is still exercised, but a
site nobody can verify is never published. The built site is always the `site`
artifact of the run.

## Testing

`test` installs `saki`, `nermius`, `nemosh` and `gp-socks` from the built site on Debian, Ubuntu
22.04/24.04, Fedora, Rocky Linux 9 and Alpine 3.21/3.24 (apk-tools 2 and 3),
amd64 and arm64. [`scripts/serve.py`](scripts/serve.py) serves the site and
applies its `_redirects` the way Pages does, so each package really is fetched
from GitHub through a 302. `test-macports` installs MacPorts on an arm64 and an
Intel Mac runner, adds the site exactly as above and installs all four ports;
`live-macports` does the same against the public URL.
