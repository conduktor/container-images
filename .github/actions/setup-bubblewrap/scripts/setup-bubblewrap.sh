#!/usr/bin/env bash
# Install bubblewrap, melange's default Linux runner, which the runner image does
# not ship. Adapted from chainguard-dev/actions/setup-melange, minus the Go
# toolchain, qemu and the unverified melange download — see the README.
set -euo pipefail

# Only refresh the index if the image's apt lists turn out to be too stale: that
# update is the mirror round trip that has stalled this job for 20+ minutes.
sudo apt-get install --assume-yes bubblewrap \
  || { sudo apt-get update && sudo apt-get install --assume-yes bubblewrap; }

# https://github.com/chainguard-dev/melange/issues/1508
sudo tee /etc/apparmor.d/local-bwrap >/dev/null <<"EOF"
abi <abi/4.0>,
include <tunables/global>

profile local-bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  # Site-specific additions and overrides. See local/README for details.
  include if exists <local/bwrap>
}
EOF

sudo systemctl reload apparmor

if ! bwrap --unshare-user --bind / / true; then
  echo "::error::failed to verify 'bwrap --unshare-user'"
  command -v bwrap || :
  ls /proc/self/ns || echo "no /proc/self/ns"
  kver="$(uname -r)" || echo "uname -r failed"
  if [ -f "/boot/config-${kver}" ]; then
    grep CONFIG_USER_NS "/boot/config-${kver}" || echo "no CONFIG_USER_NS in /boot/config-${kver}"
  fi
  exit 1
fi

echo "bubblewrap (bwrap) installed successfully."
