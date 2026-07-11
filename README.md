# sing-box Multi-Protocol Installer

Auditable one-click installer for Alpine Linux/OpenRC and Debian or Ubuntu/systemd.

Supported server protocols:

- AnyTLS
- Shadowsocks 2022
- VLESS + REALITY with `xtls-rprx-vision`
- Authenticated SOCKS5

The installer uses official sing-box packages, generates secure credentials, backs up existing files, validates the configuration before startup, rolls back failures, and writes client JSON plus compatible share URIs to `/root/sing-box-client.txt`.

## Quick start

```sh
chmod +x install.sh
./install.sh --protocol anytls --server-address YOUR_PUBLIC_IP --port 64999
```

Select another protocol:

```sh
./install.sh --protocol ss2022 --server-address YOUR_PUBLIC_IP --port 8388
./install.sh --protocol vless-reality --server-address YOUR_PUBLIC_IP --port 443 --reality-server www.microsoft.com
./install.sh --protocol socks5 --server-address YOUR_PUBLIC_IP --port 1080
```

Use `--dry-run` to validate inputs without changing the host:

```sh
./install.sh --protocol vless-reality --server-address 203.0.113.10 --dry-run
```

## System support

- Alpine Linux 3.23 or newer with OpenRC
- Debian and Ubuntu with systemd
- sing-box 1.12.0 or newer

Alpine uses the official community package. Debian/Ubuntu use the official SagerNet APT repository at `https://deb.sagernet.org/`.

## Protocol defaults

| Protocol | Default port | Generated credentials |
|---|---:|---|
| AnyTLS | 443 | 192-bit hexadecimal password and self-signed ECDSA certificate |
| Shadowsocks 2022 | 8388 | Method-sized Base64 key |
| VLESS + REALITY | 443 | UUID, REALITY key pair, 8-byte short ID |
| SOCKS5 | 1080 | URL-safe username/password authentication |

AnyTLS can use a trusted certificate:

```sh
./install.sh \
  --protocol anytls \
  --server-address anytls.example.com \
  --port 443 \
  --cert /path/to/fullchain.pem \
  --key /path/to/private.key
```

VLESS + REALITY uses `www.microsoft.com:443` as the default handshake target. Choose a stable TLS 1.3 site reachable from the server:

```sh
./install.sh \
  --protocol vless-reality \
  --server-address YOUR_PUBLIC_IP \
  --port 443 \
  --reality-server YOUR_HANDSHAKE_DOMAIN \
  --reality-port 443
```

## Existing configurations

The installer refuses to replace a configuration it does not own. Use `--force` only after reviewing the existing configuration:

```sh
./install.sh --protocol ss2022 --server-address YOUR_PUBLIC_IP --force
```

Backups are stored under `/etc/sing-box/backups/<UTC timestamp>-<PID>/`. A failed validation or startup restores the previous files and service state.

## Important behavior

- One invocation installs one inbound protocol in the main sing-box configuration.
- Running the installer again replaces the previously managed protocol after creating a backup.
- AnyTLS and VLESS + REALITY use TCP.
- Shadowsocks 2022 and SOCKS support TCP and UDP; expose both when required.
- The installer does not change firewall rules or hosting-provider NAT mappings.
- Self-signed AnyTLS output uses `insecure=1`. Prefer a trusted domain certificate where possible.
- SOCKS5 is authenticated but not encrypted. Do not expose it over untrusted networks without an encrypted tunnel.
- VLESS share links are compatibility URIs; the generated sing-box client JSON is authoritative.

## GitHub download

```sh
wget -O install.sh https://raw.githubusercontent.com/Promiscuity1/sing-box-multi-protocol-installer/main/install.sh
chmod +x install.sh
./install.sh --protocol anytls --server-address YOUR_PUBLIC_IP
```

Download and inspect scripts before executing them as root.

## Verification

```sh
sing-box check -c /etc/sing-box/config.json
```

Alpine:

```sh
rc-service sing-box status
```

Debian/Ubuntu:

```sh
systemctl status sing-box --no-pager
```

## Files

```text
/etc/sing-box/config.json
/etc/sing-box/cert.pem
/etc/sing-box/key.pem
/root/sing-box-client.txt
/var/lib/sing-box-installer/state
```

Sensitive configuration, keys, state, and client output are restricted to root or the `sing-box` service group.
