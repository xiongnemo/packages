#!/usr/bin/env bash
# Install the four ports from a site the way a MacPorts user would, and run them.
#
# Usage: test-macports.sh BASE_URL [CHANNEL]
#
# Expects MacPorts installed under /opt/local. The site's public key goes into
# pubkeys.conf and its tree above the [default] line of sources.conf, exactly as
# the landing page says; `port sync` then verifies the tarball's signature
# before anything is installed.
set -euo pipefail

base=$1
channel=${2:-nightly}
prefix=/opt/local
conf=$prefix/etc/macports

sudo curl -fsSLo "$prefix/share/macports/nemo-macports.pem" "$base/keys/nemo-macports.pem"
echo "$prefix/share/macports/nemo-macports.pem" | sudo tee -a "$conf/pubkeys.conf" >/dev/null
{ echo "$base/macports/$channel/ports.tar"; cat "$conf/sources.conf"; } > sources.conf.new
sudo mv sources.conf.new "$conf/sources.conf"
grep -v '^#' "$conf/sources.conf" | grep .

sudo port -N sync
port info --version --platforms saki nermius nemosh gp-socks
sudo port -N install saki nermius nemosh gp-socks
port installed saki nermius nemosh gp-socks

"$prefix/bin/saki" --version
"$prefix/bin/nermius" version
"$prefix/bin/nemosh" --version
"$prefix/bin/gp-socks" --help 2>&1 | grep -q "Usage of gp-socks"
file "$prefix/bin/saki" "$prefix/bin/nermius" "$prefix/bin/nemosh" "$prefix/bin/gp-socks"
