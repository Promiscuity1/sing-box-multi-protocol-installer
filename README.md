# sb: sing-box Multi-Node Manager

Independent, clean-room sing-box manager for NAT servers and regular VPS hosts. It provides a persistent `sb` command, interactive menu, independent multi-node configurations, protocol-aware client output, TLS automation, Caddy integration, rollback, migration, updates, diagnostics, and system tuning.

The project is inspired by the management experience of `233boy/sing-box`, but does not copy its GPL source code. This repository is released under the MIT License.

## Systems

- Alpine Linux 3.23+ with OpenRC
- Debian and Ubuntu with systemd
- Official Alpine and SagerNet sing-box packages
- sing-box 1.12.0 or newer

## Protocols

Core protocols:

- AnyTLS: self-signed certificate, supplied certificate, or ACME
- Shadowsocks 2022
- VLESS + REALITY with Vision
- Authenticated SOCKS5

Advanced protocols:

- Hysteria2 with Salamander obfuscation
- TUIC
- Trojan
- VMess raw TCP, WebSocket, HTTP, HTTP/2, HTTPUpgrade, and QUIC
- VLESS WebSocket, HTTP/2, and HTTPUpgrade with TLS
- Trojan WebSocket, HTTP/2, and HTTPUpgrade with TLS

HTTP-based transports can use native sing-box TLS or Caddy automatic HTTPS. Hysteria2, TUIC, and VMess QUIC use native UDP/QUIC and cannot run behind stock Caddy HTTP reverse proxy.

## Install

```sh
git clone https://github.com/Promiscuity1/sing-box-multi-protocol-installer.git
cd sing-box-multi-protocol-installer
sudo sh install.sh --server-address YOUR_PUBLIC_IP_OR_DOMAIN
sudo sb
```

The installer performs all unmanaged-configuration checks before package changes. Use `--force` only after reviewing the automatically created legacy backup.

## NAT example

Provider mapping:

```text
Public 23.134.212.11:64491
  -> container 10.10.1.134:30009
```

Node:

```sh
sb add anytls \
  --name tw-anytls \
  --listen-port 30009 \
  --public-address 23.134.212.11 \
  --public-port 64491
```

The server binds `30009`; generated client information uses `64491`.

Transport requirements:

- TCP: AnyTLS, VLESS REALITY, Trojan, normal VMess/VLESS transports
- UDP: Hysteria2, TUIC, VMess QUIC
- TCP + UDP: SS2022 and SOCKS5 when UDP relay is needed

The manager reports required mappings but does not control provider NAT panels, cloud security groups, or external DNS APIs.

## Node commands

```sh
sb add PROTOCOL [options]
sb list
sb info NAME
sb info NAME --show-secrets
sb url NAME
sb qr NAME
sb change NAME [options]
sb enable NAME
sb disable NAME
sb rotate NAME
sb delete NAME [--yes]
sb export --all
```

Common options:

```text
--name NAME
--listen-address ADDRESS
--listen-port PORT
--public-address HOST
--public-port PORT
--username NAME
--password PASSWORD
```

Advanced options:

```text
--transport tcp|ws|http|h2|httpupgrade|quic
--path /proxy
--host example.com
--tls-mode none|self-signed|trusted|caddy|acme
--cert /path/to/fullchain.pem
--key /path/to/private.key
--acme-email admin@example.com
--ss-method 2022-blake3-aes-128-gcm
--reality-server www.microsoft.com
--reality-port 443
--obfs-password PASSWORD
```

Examples:

```sh
sb add hysteria2 \
  --name hy2-main \
  --listen-port 30011 \
  --public-port 64493 \
  --public-address hy2.example.com

sb add tuic --name tuic-main --listen-port 30012 --public-port 64494

sb add vmess \
  --name vmess-ws \
  --listen-port 10001 \
  --public-address proxy.example.com \
  --public-port 443 \
  --transport ws \
  --path /vmess \
  --tls-mode caddy

sb add vless-tls \
  --name vless-h2 \
  --listen-port 10002 \
  --public-address proxy.example.com \
  --public-port 443 \
  --transport h2 \
  --path /vless \
  --tls-mode caddy

sb add anytls \
  --name anytls-acme \
  --listen-port 443 \
  --public-address anytls.example.com \
  --tls-mode acme \
  --acme-email admin@example.com
```

AnyTLS ACME automatically emits legacy `tls.acme` for sing-box 1.12/1.13 and `certificate_provider` for 1.14+.

## Caddy

```sh
sb caddy sync
sb caddy status
sb caddy log
```

Adding a Caddy-mode node installs Caddy when needed, creates path-based reverse proxies, validates the Caddyfile, and reloads the service. Multiple HTTP nodes can share one domain and public port 443 when their paths are unique.

Caddy automatic HTTPS requires public 80/443 reachability and correct A/AAAA records. It is not used for Hysteria2, TUIC, VMess QUIC, AnyTLS, REALITY, SS2022, or SOCKS5.

## Service and diagnostics

```sh
sb start
sb stop
sb restart
sb status
sb check
sb log 200
sb doctor
sb dns
```

The manager owns a distinct `sb-sing-box` service and does not overwrite the distribution package's `sing-box` service file.

`sb doctor` reports:

- sing-box and platform versions
- service/config state
- node protocol, local listener, public mapping, and TCP/UDP requirements
- DNS resolution
- detected UFW, nftables, or iptables rules

External NAT reachability cannot always be proven from inside the same server because hairpin NAT may be unavailable.

## BBR

```sh
sb bbr status
sb bbr enable
sb bbr disable
```

Only `/etc/sysctl.d/99-sb-bbr.conf` is managed. Existing global sysctl files are not rewritten.

## Backups, snapshots, and rollback

```sh
sb snapshot
sb rollback RELEASE_ID

sb backup
sb backup /root/my-sb-backup.tar.gz
sb restore /root/my-sb-backup.tar.gz
```

Backup behavior:

- Controlled `sb-backup/` archive root
- External SHA-256 sidecar
- Internal `SHA256SUMS`
- Link, special-file, traversal, and unexpected-layout checks
- Staged sing-box validation before activation
- Pre-restore snapshot and service rollback

Backups contain credentials and private keys and are written with mode `0600`.

## Migration

Import one legacy inbound from an existing sing-box configuration:

```sh
sb migrate /path/to/legacy-config.json \
  --name imported-node \
  --public-address YOUR_PUBLIC_IP \
  --public-port PUBLIC_PORT
```

Supported migration inputs:

- AnyTLS
- Shadowsocks 2022
- SOCKS5
- VLESS + REALITY

VLESS REALITY migration requires the client public key explicitly:

```text
--reality-public-key PUBLIC_KEY
```

The manager never fabricates a missing REALITY public key.

## Updates and rollback

```sh
sb update manager
sb manager-rollback

sb core status
sb core update
sb core rollback
```

Manager updates consume tagged GitHub release assets with published SHA-256 checksums and keep a local rollback copy. Core updates back up the current binary, validate every active configuration, restart, and restore the previous binary if verification fails.

## Uninstall

```sh
sb uninstall
sb uninstall --purge --remove-core --yes
```

Default uninstall preserves `/etc/sing-box`. `--purge` removes configurations, secrets, snapshots, and backups. `--remove-core` also removes the sing-box package.

## Files

```text
/usr/local/bin/sb
/usr/local/lib/sb-manager/
/etc/sing-box/config.json
/etc/sing-box/manager.json
/etc/sing-box/conf.d/
/etc/sing-box/nodes/
/etc/sing-box/certs/
/etc/sing-box/releases/
/etc/sing-box/backups/
/etc/caddy/sb-managed.caddy
```

## Security

- `sb info` redacts secrets by default.
- Use `--show-secrets` only in a private terminal.
- SOCKS5 authentication does not encrypt traffic.
- Prefer trusted certificates over `insecure=1` self-signed deployments.
- Review scripts and release checksums before running code as root.

## Tests

GitHub Actions runs:

- BusyBox `ash` and Debian `dash` syntax/dry-run tests
- ShellCheck
- Four original protocols in one sing-box configuration
- Hysteria2, TUIC, Trojan, VMess transports, VLESS TLS, and AnyTLS ACME rendering
- NAT public-port versus local-port output checks
