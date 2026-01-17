# Tailscale on EdgeOS

This is a short guide for getting [Tailscale](https://tailscale.com/) running on the Ubiquiti EdgeRouter platform. EdgeOS 2.0+ is required to make use of the systemd unit file shipped by Tailscale.

This was originally inspired by [lg](https://github.com/lg)'s [gist](https://gist.github.com/lg/6f80593bd55ca9c9cf886da169a972c3) and [joeshaw](https://github.com/joeshaw)'s [suggestion](https://gist.github.com/lg/6f80593bd55ca9c9cf886da169a972c3#gistcomment-3578594) of putting everything under `/config/tailscale` rather than directly in `/config`, however this guide uses Tailscale's Debian package repository instead of downloading the tarball and manually managing the files.

## Installing Tailscale

### Automated setup (recommended)

Use the setup script to handle the manual steps from this guide. It configures
the Tailscale apt repository, installs the firstboot/post-config scripts, and
optionally runs `tailscale up` and configures `sshd` listening addresses.

```sh
sudo -i
mkdir -p /config/scripts
curl -fsSL -o /config/scripts/tailscale-install.sh https://raw.githubusercontent.com/jonmeacham/tailscale-edgeos/main/install.sh
chmod 755 /config/scripts/tailscale-install.sh
/config/scripts/tailscale-install.sh
```

Optional environment variables:

- `TAILSCALE_AUTHKEY` - pre-auth key for `tailscale up`
- `TAILSCALE_ADVERTISE_ROUTES` - e.g. `192.0.2.0/24`
- `TAILSCALE_ADVERTISE_EXIT_NODE` - set to `1` to advertise exit node
- `TAILSCALE_UP_EXTRA_ARGS` - extra `tailscale up` flags
- `TAILSCALE_SSH_OVERRIDE` - set to `1` to install `before-ssh.conf`
- `TAILSCALE_SSH_LISTEN_ADDRESSES` - space/comma-separated list of addresses

Example:

```sh
TAILSCALE_AUTHKEY=tskey-XXX \
TAILSCALE_ADVERTISE_ROUTES=192.0.2.0/24 \
TAILSCALE_ADVERTISE_EXIT_NODE=1 \
TAILSCALE_SSH_OVERRIDE=1 \
TAILSCALE_SSH_LISTEN_ADDRESSES="100.x.y.z 192.168.1.1" \
/config/scripts/tailscale-install.sh
```

### Manual steps

1. Configure the Tailscale apt repository

    ```
    configure
    set system package repository tailscale url '[signed-by=/usr/share/keyrings/tailscale-stretch-stable.gpg] https://pkgs.tailscale.com/stable/debian'
    set system package repository tailscale distribution stretch
    set system package repository tailscale components main
    commit comment "Add Tailscale repository"
    save; exit
    ```

2. Create required directories and download and run firstboot script

    Scripts in the `firstboot.d` directory are run after firmware upgrades.
    This script ensures that the Tailscale daemon's state is symlinked to
    `/config` so it persists across firmware upgrades (otherwise you'll have to
    set up as a new device on every upgrade) and installs a `post-config.d`
    script to ensure Tailscale is installed after each boot.

    The `post-config.d` script also copies the Debian package to
    `/config/data/firstboot/install-packages` so the package can be installed
    during `firstboot` after a firmware upgrade to ensure the package gets
    installed and doesn't require downloading it again. This also means the
    same version will be consistently installed.

    ```sh
    sudo bash
    mkdir -p /config/scripts/firstboot.d
    curl -o /config/scripts/firstboot.d/tailscale.sh https://raw.githubusercontent.com/jonmeacham/tailscale-edgeos/main/firstboot.d/tailscale.sh
    chmod 755 /config/scripts/firstboot.d/tailscale.sh
    /config/scripts/firstboot.d/tailscale.sh
    /config/scripts/post-config.d/tailscale.sh
    ```

3. Log in to Tailscale

    The example below enables subnet routing for one subnet, enables use as an exit node (Tailscale 1.6+), and uses a one-off pre-auth key, which can be generated at https://login.tailscale.com/admin/authkeys

    :warning: Remember to change `192.0.2.0/24` with the subnet(s) you *actually want to expose* to the tailnet.

    ```sh
    tailscale up --advertise-routes 192.0.2.0/24 --advertise-exit-node --authkey tskey-XXX
    ```

4. (Optional) If you want `sshd` to explicitly listen on the Tailscale address instead of all addresses:

    1. Fetch the override unit

        ```sh
        curl -o /config/tailscale/systemd/tailscaled.service.d/before-ssh.conf https://raw.githubusercontent.com/jonmeacham/tailscale-edgeos/main/systemd/tailscaled.service.d/before-ssh.conf
        systemctl daemon-reload
        ```

    2. Exit the shell, enter configure mode and set the listen-address

        If you don't currently have any listen-address directives, make sure you add any other addresses you want to access the router by, such as a private network IP.

        The Tailscale IP can be found in the admin console, or using `tailscale ip`.

        ```
        exit
        configure
        set service ssh listen-address <Tailscale IP>
        commit comment "sshd listen on Tailscale IP"
        ```


## Firmware Upgrades

After an EdgeOS upgrade third-party packages are no longer installed, but the
`firstboot` script described above ensures Tailscale gets reinstalled.

The `post-config.d` script checks the Tailscale repository and installs or
upgrades to the latest available version using per-package installs (never
`apt-get upgrade`), so the restored package stays current.

## Upgrading Tailscale

Upgrading is straightforward as the package manager will do everything for you.
The `post-config.d` script also checks for updates on boot and will install the
latest available Tailscale package using per-package installs.

**Note:** DO NOT USE `apt-get upgrade`. This is not supported on EdgeOS and may
result in a broken system.

```
sudo apt-get update
sudo apt-get install tailscale
```

If you want to install a specific version of Tailscale use:

```
sudo apt-get install tailscale=X.Y.Z
```

Where `X.Y.Z` is the version you want. This also works for downgrading.

If you consider this version to be "stable" for your use-cases you should think
about copying the package to flash memory so it survives firmware upgrades,
otherwise an older version may get installed.

First check if old packages are saved:

```
sudo bash
ls -l /config/data/firstboot/install-packages
```

If old versions exist delete them, e.g.

```
rm /config/data/firstboot/install-packages/tailscale_1.6.0_mips.deb
```

Then copy the latest version:

```
cp /var/cache/apt/archives/tailscale_*.deb /config/data/firstboot/install-packages
```

If you still receive an **out of space** error when upgrading, try cleaning the system's images using:

```
delete system image
```

If you have a **certificate error** when upgrading, unfortunately it is an [EdgeOS problem](https://community.ui.com/questions/Fix-Solution-Lets-Encrypt-DST-Root-CA-X3-Expiration-Problems-with-IDS-IPS-Signature-Updates-HTTPS-E/0404a626-1a77-4d6c-9b4c-17ea3dea641d), but to correct it manually you can run the following commands:

```
sudo -i
if grep -q '^mozilla/DST_Root_CA_X3\.crt$' /etc/ca-certificates.conf; then
  sed -i 's|^mozilla\/DST_Root_CA_X3\.crt|!mozilla/DST_Root_CA_X3.crt|' /etc/ca-certificates.conf
  update-ca-certificates --fresh
fi
```

## Uninstalling

### Automated uninstall (recommended)

Use the uninstall script to remove the package, systemd overrides, scripts,
cached packages, and the EdgeOS repository configuration.

```sh
sudo -i
mkdir -p /config/scripts
curl -fsSL -o /config/scripts/tailscale-uninstall.sh https://raw.githubusercontent.com/jonmeacham/tailscale-edgeos/main/uninstall.sh
chmod 755 /config/scripts/tailscale-uninstall.sh
/config/scripts/tailscale-uninstall.sh
```

### Manual steps

1. Stop the daemon and uninstall the package

    ```sh
    sudo -i
    systemctl stop tailscaled
    umount /var/lib/tailscale || true
    apt-get purge -y tailscale
    ```

2. Remove scripts, overrides, and cached packages

    ```sh
    rm -f /config/scripts/firstboot.d/tailscale.sh /config/scripts/post-config.d/tailscale.sh
    rm -f /etc/systemd/system/var-lib-tailscale.mount
    rm -rf /etc/systemd/system/tailscaled.service.d
    rm -rf /config/tailscale
    rm -f /config/data/firstboot/install-packages/tailscale_*.deb
    systemctl daemon-reload
    ```

3. Remove the Tailscale repository

    ```
    configure
    delete system package repository tailscale
    commit comment "Remove Tailscale repository"
    save; exit
    ```

4. (Optional) Remove any `sshd` listen-address entries you added for Tailscale
