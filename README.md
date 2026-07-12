# sb：sing-box 多节点管理器

[简体中文](#简体中文) | [English](#english)

<a id="简体中文"></a>
## 简体中文

这是一个面向 NAT 服务器和普通 VPS 的独立 sing-box 管理器，采用 clean-room 方式实现。项目提供持久化 `sb` 命令、交互式菜单、多节点独立配置、客户端配置输出、TLS 自动化、Caddy 集成、备份回滚、旧配置迁移、在线更新、故障诊断和系统优化。

本项目借鉴了 `233boy/sing-box` 的管理体验，但没有复制其 GPL 源代码；本仓库使用 MIT License。

### 支持系统

- Alpine Linux 3.23+（OpenRC）
- Debian、Ubuntu（systemd）
- 官方 Alpine 或 SagerNet sing-box 软件包
- sing-box 1.12.0 或更高版本

### 支持协议

- AnyTLS：自签名证书、已有证书或 ACME
- Shadowsocks 2022
- VLESS + REALITY + Vision
- 带认证的 SOCKS5
- Hysteria2 + Salamander 混淆
- TUIC
- Trojan
- VMess：TCP、WebSocket、HTTP、HTTP/2、HTTPUpgrade、QUIC
- VLESS TLS：WebSocket、HTTP/2、HTTPUpgrade
- Trojan TLS：WebSocket、HTTP/2、HTTPUpgrade

HTTP 类传输可以使用 sing-box 原生 TLS 或 Caddy 自动 HTTPS。Hysteria2、TUIC 和 VMess QUIC 使用原生 UDP/QUIC，不能放在普通 Caddy HTTP 反向代理后面。

### 安装

Alpine：

```sh
apk update
apk add --no-cache git curl ca-certificates
git clone https://github.com/Promiscuity1/sing-box-multi-protocol-installer.git
cd sing-box-multi-protocol-installer
sh install.sh --server-address 你的公网IP或域名
sb
```

Debian/Ubuntu：

```sh
apt update
apt install -y git curl ca-certificates
git clone https://github.com/Promiscuity1/sing-box-multi-protocol-installer.git
cd sing-box-multi-protocol-installer
sudo sh install.sh --server-address 你的公网IP或域名
sudo sb
```

如果当前终端已经是 `root`，不要加 `sudo`。请把“你的公网IP或域名”替换为客户端实际连接的地址，不要照抄占位文字。安装器会在修改软件包前检查已有的非托管配置；只有确认自动备份无误后才应使用 `--force`。

### NAT 机器示例

假设服务商端口映射为：

```text
公网 23.134.212.11:64491
  -> 内网 10.10.1.134:30009
```

创建 AnyTLS 节点：

```sh
sb add anytls \
  --name tw-anytls \
  --listen-port 30009 \
  --public-address 23.134.212.11 \
  --public-port 64491
```

`--listen-port` 是服务器内部监听端口，`--public-port` 是 NAT 映射后的外部端口。生成的客户端链接会使用外部端口 `64491`。

端口映射要求：

- TCP：AnyTLS、VLESS REALITY、Trojan、普通 VMess/VLESS
- UDP：Hysteria2、TUIC、VMess QUIC
- TCP + UDP：需要 UDP 转发时的 SS2022 和 SOCKS5

管理器只能显示所需映射，不能自动操作服务商 NAT 面板、云安全组或外部 DNS API。

### 常用节点命令

```sh
sb                         # 打开交互菜单
sb add 协议 [参数]          # 添加节点
sb list                    # 查看节点
sb info 节点名             # 查看脱敏信息
sb info 节点名 --show-secrets
sb url 节点名              # 输出分享链接
sb qr 节点名               # 输出二维码
sb change 节点名 [参数]     # 修改节点
sb enable 节点名           # 启用节点
sb disable 节点名          # 禁用节点
sb rotate 节点名           # 重新生成凭据
sb delete 节点名 --yes      # 删除节点
sb export --all            # 导出全部节点
```

通用参数：

```text
--name NAME
--listen-address ADDRESS
--listen-port PORT
--public-address HOST
--public-port PORT
--username NAME
--password PASSWORD
```

高级参数：

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

### 创建节点示例

```sh
sb add hysteria2 \
  --name hy2-main \
  --listen-port 30011 \
  --public-address hy2.example.com \
  --public-port 64493

sb add tuic \
  --name tuic-main \
  --listen-port 30012 \
  --public-port 64494

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

AnyTLS ACME 会根据 sing-box 版本自动生成兼容配置：1.12/1.13 使用旧版 `tls.acme`，1.14+ 使用 `certificate_provider`。

### Caddy

```sh
sb caddy sync
sb caddy status
sb caddy log
```

使用 `--tls-mode caddy` 添加节点时，管理器会按需安装 Caddy、创建基于路径的反向代理、验证 Caddyfile 并重载服务。多个 HTTP 节点可以在路径不重复时共用同一个域名和公网 443 端口。

Caddy 自动 HTTPS 要求公网 80/443 可访问，且 A/AAAA 记录正确。Caddy 不用于 Hysteria2、TUIC、VMess QUIC、AnyTLS、REALITY、SS2022 或 SOCKS5。

### 服务与诊断

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

管理器使用独立的 `sb-sing-box` 服务，不会覆盖发行版自带的 `sing-box` 服务文件。`sb doctor` 会检查系统和 sing-box 版本、服务与配置状态、节点监听和公网映射、TCP/UDP 要求、DNS 解析及防火墙规则。

### BBR

```sh
sb bbr status
sb bbr enable
sb bbr disable
```

管理器只维护 `/etc/sysctl.d/99-sb-bbr.conf`，不会重写其他全局 sysctl 配置。

### 备份、快照与回滚

```sh
sb snapshot
sb rollback RELEASE_ID
sb backup
sb backup /root/my-sb-backup.tar.gz
sb restore /root/my-sb-backup.tar.gz
```

备份包含节点密码和私钥，并使用 `0600` 权限保存。恢复前会检查 SHA-256、归档布局、路径穿越、链接和特殊文件，并先验证 sing-box 配置和创建恢复前快照。

### 迁移旧配置

```sh
sb migrate /path/to/legacy-config.json \
  --name imported-node \
  --public-address 你的公网IP \
  --public-port 公网端口
```

支持迁移 AnyTLS、Shadowsocks 2022、SOCKS5 和 VLESS + REALITY。迁移 REALITY 时必须显式提供客户端公钥：

```text
--reality-public-key PUBLIC_KEY
```

### 更新与回滚

```sh
sb update manager
sb manager-rollback
sb core status
sb core update
sb core rollback
```

管理器更新使用带 SHA-256 校验的 GitHub Release 文件并保留本地回滚副本。核心更新会备份旧二进制、检查所有启用配置并验证服务，失败时自动恢复。

### 卸载

```sh
sb uninstall
sb uninstall --purge --remove-core --yes
```

默认卸载会保留 `/etc/sing-box`；`--purge` 会删除配置、密钥、快照和备份；`--remove-core` 还会卸载 sing-box 软件包。

### 安全提示

- `sb info` 默认隐藏密码、UUID 和私钥。
- 只在私密终端中使用 `--show-secrets`。
- SOCKS5 身份认证不会加密流量。
- 正式部署优先使用可信证书，不建议长期使用 `insecure=1`。
- 以 root 运行脚本前，应先检查脚本和 Release 校验值。

---

<a id="english"></a>
## English
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

Alpine Linux:

```sh
apk update
apk add --no-cache git curl ca-certificates
git clone https://github.com/Promiscuity1/sing-box-multi-protocol-installer.git
cd sing-box-multi-protocol-installer
sh install.sh --server-address YOUR_PUBLIC_IP_OR_DOMAIN
sb
```

Debian/Ubuntu:

```sh
apt update
apt install -y git curl ca-certificates
git clone https://github.com/Promiscuity1/sing-box-multi-protocol-installer.git
cd sing-box-multi-protocol-installer
sudo sh install.sh --server-address YOUR_PUBLIC_IP_OR_DOMAIN
sudo sb
```

Do not use `sudo` when the current shell is already running as root. Replace `YOUR_PUBLIC_IP_OR_DOMAIN` with the address clients will actually connect to.

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
