#!/usr/bin/env bash
# Install the newest MacPorts release built for this runner's macOS.
# Needs GH_TOKEN for the GitHub API (unauthenticated calls share a small limit).
set -euo pipefail

major=$(sw_vers -productVersion | cut -d. -f1)
url=$(gh api repos/macports/macports-base/releases/latest \
  --jq ".assets[] | select(.name | test(\"^MacPorts-[0-9.]+-${major}-[A-Za-z]+\\\\.pkg\$\")) | .browser_download_url" | head -1)
if [ -z "$url" ]; then
  echo "no MacPorts installer for macOS ${major} in the latest release" >&2
  exit 1
fi
echo "macOS $(sw_vers -productVersion) $(uname -m): ${url##*/}"
curl -fsSLo MacPorts.pkg "$url"
sudo installer -pkg MacPorts.pkg -target / >/dev/null
echo /opt/local/bin >> "$GITHUB_PATH"
echo /opt/local/sbin >> "$GITHUB_PATH"
/opt/local/bin/port version
