#!/bin/vbash
source /opt/vyatta/etc/functions/script-template

set -e

if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: Run as root" >&2
	exit 1
fi

echo "Stopping tailscaled if running"
systemctl stop tailscaled >/dev/null 2>&1 || true

if mountpoint -q /var/lib/tailscale; then
	umount /var/lib/tailscale
fi

pkg_status=$(dpkg-query -Wf '${Status}' tailscale 2>/dev/null || true)
if echo "$pkg_status" | grep -qF "install ok installed"; then
	echo "Removing Tailscale package"
	DEBIAN_FRONTEND=noninteractive apt-get purge -y tailscale
else
	echo "Tailscale package not installed"
fi

echo "Removing Tailscale scripts, state, and overrides"
rm -f /config/scripts/firstboot.d/tailscale.sh /config/scripts/post-config.d/tailscale.sh
rm -f /etc/systemd/system/var-lib-tailscale.mount
rm -rf /etc/systemd/system/tailscaled.service.d
rm -rf /config/tailscale/systemd
rm -rf /config/tailscale/state
rm -f /config/data/firstboot/install-packages/tailscale_*.deb

systemctl daemon-reload

echo "Removing Tailscale package repository"
configure
delete system package repository tailscale
if ! commit; then
	echo "ERROR: Commit failed" >&2
	exit 1
fi
save
exit
