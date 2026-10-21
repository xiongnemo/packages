# packages

apt, dnf and apk repositories for xiongnemo's tools, carrying **indices only**.
Every package stays where its project published it, on GitHub Releases:

| Format | How a package is found |
|---|---|
| apt | `Filename: pool/<owner>/<repo>/<tag>/<asset>`; `_redirects` sends `pool/*` to the Release asset with a 302 |
| dnf | `primary.xml` carries `xml:base="https://github.com/"`; dnf fetches the asset directly, no redirect needed |
| apk | apk names files `<name>-<version>.apk`; `_redirects` has one 302 per package |

The redirects are 302 on purpose: apk-tools' libfetch does not follow 308.
Indices are rebuilt from the Releases on every run, and every hash in them is
computed here from the downloaded file and checked against the digest GitHub
reports, never taken from the publishing project.

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
| `SITE_URL` | variable | Public base URL, written into the `.repo` files and the landing page |
| `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | secrets | Deploy to Cloudflare Pages (`vars.CLOUDFLARE_PAGES_PROJECT`, default `xiongnemo-packages`) |
| `NETLIFY_AUTH_TOKEN`, `NETLIFY_SITE_ID` | secrets | Or deploy to Netlify; both hosts read the same `_redirects` |

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
