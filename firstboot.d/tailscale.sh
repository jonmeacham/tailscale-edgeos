#!/bin/sh

set -e

if grep -q '^mozilla/DST_Root_CA_X3\.crt$' /etc/ca-certificates.conf; then
	sed -i 's|^mozilla\/DST_Root_CA_X3\.crt|!mozilla/DST_Root_CA_X3.crt|' /etc/ca-certificates.conf
	update-ca-certificates --fresh
fi

mkdir -p /config/tailscale/systemd/tailscaled.service.d
mkdir -p /config/tailscale/state

# Create a bind mount for the Tailscale state directory
if [ ! -f /config/tailscale/systemd/var-lib-tailscale.mount ]; then
	cat > /config/tailscale/systemd/var-lib-tailscale.mount <<-EOF
[Mount]
What=/config/tailscale/state
Where=/var/lib/tailscale
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
	EOF
fi

# Add an override to tailscaled.service to require the bind mount
if [ ! -f /config/tailscale/systemd/tailscaled.service.d/mount.conf ]; then
	cat > /config/tailscale/systemd/tailscaled.service.d/mount.conf <<-EOF
[Unit]
RequiresMountsFor=/var/lib/tailscale
	EOF
fi
# Add an override to tailscaled.service to wait until "UBNT Routing Daemons"
# has finished, otherwise tailscaled won't have proper networking
if [ ! -f /config/tailscale/systemd/tailscaled.service.d/wait-for-networking.conf ]; then
	cat > /config/tailscale/systemd/tailscaled.service.d/wait-for-networking.conf <<-EOF
[Unit]
Wants=vyatta-router.service network-online.target
After=vyatta-router.service network-online.target
	EOF
fi

if [ ! -e /etc/systemd/system/tailscaled.service.d ]; then
	ln -s /config/tailscale/systemd/tailscaled.service.d /etc/systemd/system/tailscaled.service.d
elif [ ! -L /etc/systemd/system/tailscaled.service.d ]; then
	# Fall back to copying drop-ins if the directory already exists.
	mkdir -p /etc/systemd/system/tailscaled.service.d
	for unit in /config/tailscale/systemd/tailscaled.service.d/*.conf; do
		[ -e "$unit" ] || continue
		cp "$unit" /etc/systemd/system/tailscaled.service.d/
	done
fi
systemctl daemon-reload

# Ensure the post-config script matches the current version
mkdir -p /config/scripts/post-config.d
post_config_script=/config/scripts/post-config.d/tailscale.sh
post_config_tmp=$(mktemp)
cat > "$post_config_tmp" <<"EOF"
#!/bin/sh

set -e

reload=""

# The mount unit needs to be copied rather than linked.
# systemd errors with "Link has been severed" if the unit is a symlink.
if [ ! -f /etc/systemd/system/var-lib-tailscale.mount ]; then
	echo Installing /var/lib/tailscale mount unit
	cp /config/tailscale/systemd/var-lib-tailscale.mount /etc/systemd/system/var-lib-tailscale.mount
	reload=y
fi

if [ ! -e /etc/systemd/system/tailscaled.service.d ]; then
	ln -s /config/tailscale/systemd/tailscaled.service.d /etc/systemd/system/tailscaled.service.d
	reload=y
elif [ ! -L /etc/systemd/system/tailscaled.service.d ]; then
	mkdir -p /etc/systemd/system/tailscaled.service.d
	for unit in /config/tailscale/systemd/tailscaled.service.d/*.conf; do
		[ -e "$unit" ] || continue
		if [ ! -f /etc/systemd/system/tailscaled.service.d/$(basename "$unit") ]; then
			cp "$unit" /etc/systemd/system/tailscaled.service.d/
			reload=y
		fi
	done
fi

if [ -n "$reload" ]; then
	# Ensure systemd has loaded the unit overrides
	systemctl daemon-reload
fi

KEYRING=/usr/share/keyrings/tailscale-stretch-stable.gpg
mkdir -p /usr/share/keyrings

if ! gpg --list-keys --with-colons --keyring $KEYRING 2>/dev/null | grep -qF info@tailscale.com; then
	echo Installing Tailscale repository signing key
	if [ ! -e /config/tailscale/stretch.gpg ]; then
		curl -fsSL https://pkgs.tailscale.com/stable/debian/stretch.asc -o /config/tailscale/stretch.asc
		gpg --dearmor < /config/tailscale/stretch.asc > /config/tailscale/stretch.gpg
		rm -f /config/tailscale/stretch.asc
	fi
	cp /config/tailscale/stretch.gpg $KEYRING
fi

pkg_status=$(dpkg-query -Wf '${Status}' tailscale 2>/dev/null || true)
if ! echo $pkg_status| grep -qF "install ok installed"; then
	# Sometimes after a firmware upgrade the package goes into half-configured state
	if echo $pkg_status | grep -qF "half-configured"; then
		# Use systemd-run to configure the package in a separate unit, otherwise it will block
		# due to tailscaled.service waiting on vyatta-router.service, which is running this script.
		systemd-run --no-block dpkg --configure -a
	fi
fi

# Note: do not use `apt-get upgrade` on EdgeOS; install specific packages instead.
echo "Checking for the latest Tailscale package"
apt-get update
candidate_version=$(apt-cache policy tailscale 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
installed_version=$(dpkg-query -W -f='${Version}' tailscale 2>/dev/null || true)

if [ -z "$candidate_version" ] || [ "$candidate_version" = "(none)" ]; then
	echo "No candidate Tailscale package found; skipping install/upgrade"
elif [ -z "$installed_version" ]; then
	echo "Installing Tailscale"
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tailscale
	mkdir -p /config/data/firstboot/install-packages
	cp /var/cache/apt/archives/tailscale_*.deb /config/data/firstboot/install-packages
elif [ "$installed_version" != "$candidate_version" ]; then
	echo "Upgrading Tailscale from $installed_version to $candidate_version"
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tailscale
	mkdir -p /config/data/firstboot/install-packages
	cp /var/cache/apt/archives/tailscale_*.deb /config/data/firstboot/install-packages
else
	echo "Tailscale is already up to date ($installed_version)"
fi

if [ -n "$reload" ]; then
	systemctl --no-block restart tailscaled
fi
EOF
if ! cmp -s "$post_config_tmp" "$post_config_script"; then
	mv "$post_config_tmp" "$post_config_script"
	chmod 755 "$post_config_script"
else
	rm -f "$post_config_tmp"
fi
