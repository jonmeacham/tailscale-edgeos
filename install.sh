#!/bin/vbash
source /opt/vyatta/etc/functions/script-template

set -e

if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: Run as root" >&2
	exit 1
fi

TS_REPO_URL="[signed-by=/usr/share/keyrings/tailscale-stretch-stable.gpg] https://pkgs.tailscale.com/stable/debian"
TS_FIRSTBOOT_URL="https://raw.githubusercontent.com/jonmeacham/tailscale-edgeos/main/firstboot.d/tailscale.sh"
TS_SSH_OVERRIDE_URL="https://raw.githubusercontent.com/jonmeacham/tailscale-edgeos/main/systemd/tailscaled.service.d/before-ssh.conf"

echo "Configuring Tailscale package repository"
(
	configure
	set system package repository tailscale url "$TS_REPO_URL"
	set system package repository tailscale distribution stretch
	set system package repository tailscale components main

	if [ -n "${TAILSCALE_SSH_LISTEN_ADDRESSES:-}" ]; then
		for addr in ${TAILSCALE_SSH_LISTEN_ADDRESSES//,/ }; do
			set service ssh listen-address "$addr"
		done
		if ! commit-confirm 5; then
			echo "ERROR: Commit failed" >&2
			exit 1
		fi
		run confirm
	else
		if ! commit; then
			echo "ERROR: Commit failed" >&2
			exit 1
		fi
	fi

	save
	exit
)

echo "Installing firstboot and post-config scripts"
mkdir -p /config/scripts/firstboot.d
firstboot_script=/config/scripts/firstboot.d/tailscale.sh
firstboot_tmp=$(mktemp)
curl -fsSL -o "$firstboot_tmp" "$TS_FIRSTBOOT_URL"
if ! cmp -s "$firstboot_tmp" "$firstboot_script"; then
	mv "$firstboot_tmp" "$firstboot_script"
	chmod 755 "$firstboot_script"
else
	rm -f "$firstboot_tmp"
fi
/config/scripts/firstboot.d/tailscale.sh
/config/scripts/post-config.d/tailscale.sh

if [ "${TAILSCALE_SSH_OVERRIDE:-}" = "1" ] || [ "${TAILSCALE_SSH_OVERRIDE:-}" = "true" ]; then
	echo "Installing tailscaled ssh override unit"
	mkdir -p /config/tailscale/systemd/tailscaled.service.d
	curl -fsSL -o /config/tailscale/systemd/tailscaled.service.d/before-ssh.conf "$TS_SSH_OVERRIDE_URL"
	systemctl daemon-reload
fi

set --
if [ -n "${TAILSCALE_ADVERTISE_ROUTES:-}" ]; then
	set -- "$@" --advertise-routes "$TAILSCALE_ADVERTISE_ROUTES"
fi
if [ -n "${TAILSCALE_ADVERTISE_EXIT_NODE:-}" ]; then
	set -- "$@" --advertise-exit-node
fi
if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
	set -- "$@" --authkey "$TAILSCALE_AUTHKEY"
fi
if [ -n "${TAILSCALE_UP_EXTRA_ARGS:-}" ]; then
	set -- "$@" ${TAILSCALE_UP_EXTRA_ARGS}
fi

if [ "$#" -gt 0 ]; then
	if command -v tailscale >/dev/null 2>&1; then
		echo "Running tailscale up"
		tailscale up "$@"
	else
		echo "WARNING: tailscale not installed yet, skipping tailscale up" >&2
	fi
fi
