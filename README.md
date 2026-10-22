# packages

apt, dnf and apk repositories for xiongnemo's tools, carrying **indices only**,
at **https://package.anzupop.com**. Every package stays where
its project published it, on GitHub Releases:

| Format | How a package is found |
|---|---|
| apt | `Filename: pool/<owner>/<repo>/<tag>/<asset>`; `_redirects` sends `pool/*` to the Release asset with a 302 |
| dnf | `primary.xml` carries `xml:base="https://github.com/"`; dnf fetches the asset directly, no redirect needed |
| apk | apk names files `<name>-<version>.apk`; `_redirects` has one 302 per package |

The redirects are 302 on purpose: apk-tools' libfetch does not follow 308.
Indices are rebuilt from the Releases on every run, and every hash in them is
computed here from the downloaded file and checked against the digest GitHub
reports, never taken from the publishing project.

## Using it

```sh
# apt (Debian, Ubuntu)
sudo curl -fsSLo /usr/share/keyrings/xiongnemo.gpg https://package.anzupop.com/keys/xiongnemo-packages.gpg
echo "deb [signed-by=/usr/share/keyrings/xiongnemo.gpg] https://package.anzupop.com/apt nightly main" | sudo tee /etc/apt/sources.list.d/xiongnemo.list
sudo apt update && sudo apt install saki nermius

# dnf (Fedora, RHEL and derivatives)
sudo curl -fsSLo /etc/yum.repos.d/xiongnemo-nightly.repo https://package.anzupop.com/rpm/xiongnemo-nightly.repo
sudo dnf install saki nermius

# apk (Alpine)
wget -qO /etc/apk/keys/xiongnemo-packages.rsa.pub https://package.anzupop.com/keys/xiongnemo-packages.rsa.pub
echo https://package.anzupop.com/apk/nightly >> /etc/apk/repositories
apk update && apk add saki nermius
```

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

## Configuration

| Name | Kind | Purpose |
|---|---|---|
| `GPG_SIGNING_KEY` | secret | Armored private key; signs apt `InRelease`/`Release.gpg` and rpm `repomd.xml` |
| `APK_SIGNING_KEY` | secret | PEM RSA private key; signs every `APKINDEX` |
| `APK_SIGNING_KEY_NAME` | variable | Its file name, e.g. `xiongnemo-packages.rsa`; users install `<name>.pub` |
| `SITE_URL` | variable | Public base URL, written into the `.repo` files and the landing page, and where `verify-live` installs from |

Without the signing keys each run signs with throwaway keys, writes
`TEST-ONLY`, and is not deployed: the signing path is still exercised, but a
site nobody can verify is never published. The built site is always the `site`
artifact of the run.

## Testing

`test` installs `saki` and `nermius` from the built site on Debian, Ubuntu
22.04/24.04, Fedora, Rocky Linux 9 and Alpine 3.21/3.24 (apk-tools 2 and 3),
amd64 and arm64. [`scripts/serve.py`](scripts/serve.py) serves the site and
applies its `_redirects` the way Pages does, so each package really is fetched
from GitHub through a 302.
