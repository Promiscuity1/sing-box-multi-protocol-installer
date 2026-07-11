#!/bin/sh

set -eu

umask 077

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

PROGRAM=${0##*/}
VERSION=2.0.0

PROTOCOL=${PROTOCOL:-anytls}
SERVER_ADDRESS=${SERVER_ADDRESS:-}
LISTEN_ADDRESS=${LISTEN_ADDRESS:-0.0.0.0}
LISTEN_PORT=${LISTEN_PORT:-}
USERNAME=${USERNAME:-default}
PASSWORD=${PASSWORD:-}
SS_METHOD=${SS_METHOD:-2022-blake3-aes-128-gcm}
REALITY_SERVER=${REALITY_SERVER:-www.microsoft.com}
REALITY_PORT=${REALITY_PORT:-443}
CERT_SOURCE=${CERT_SOURCE:-}
KEY_SOURCE=${KEY_SOURCE:-}
SELF_SIGNED_DAYS=${SELF_SIGNED_DAYS:-3650}
FORCE=0
DRY_RUN=0

CONFIG_DIR=/etc/sing-box
CONFIG_FILE=$CONFIG_DIR/config.json
CERT_FILE=$CONFIG_DIR/cert.pem
KEY_FILE=$CONFIG_DIR/key.pem
STATE_DIR=/var/lib/sing-box-installer
STATE_FILE=$STATE_DIR/state
CLIENT_FILE=/root/sing-box-client.txt
BACKUP_ROOT=$CONFIG_DIR/backups

usage() {
  cat <<EOF
Usage:
  $PROGRAM --protocol PROTOCOL --server-address ADDRESS [options]

Protocols:
  anytls          AnyTLS over TLS
  ss2022          Shadowsocks 2022
  vless-reality   VLESS with REALITY and Vision flow
  socks5          Authenticated SOCKS5

Required:
  --server-address ADDRESS   Public IPv4 address or DNS name

Common options:
  --protocol NAME            Protocol to install (default: anytls)
  --port PORT                Listen port; protocol-specific default when omitted
  --listen ADDRESS           IPv4 listen address (default: 0.0.0.0)
  --username NAME            AnyTLS label or SOCKS5 username (default: default)
  --password PASSWORD        AnyTLS/SOCKS5 password; generated when omitted
  --force                    Replace an existing unmanaged sing-box configuration
  --dry-run                  Validate arguments and show the plan without changes
  --help                     Show help
  --version                  Show installer version

AnyTLS options:
  --cert PATH                Trusted certificate/fullchain
  --key PATH                 Matching private key
  --self-signed-days DAYS    Self-signed lifetime (default: 3650)

Shadowsocks 2022 options:
  --ss-method METHOD         2022 method (default: 2022-blake3-aes-128-gcm)
  --password BASE64_KEY      Exact method key; generated when omitted

VLESS + REALITY options:
  --reality-server DOMAIN    TLS handshake domain (default: www.microsoft.com)
  --reality-port PORT        TLS handshake port (default: 443)
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_ipv4() {
  printf '%s' "$1" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
    }
  '
}

validate_host() {
  value=$1
  label=$2
  case "$value" in
    ''|*[!A-Za-z0-9.-]*|.*|*.|*..*) die "$label must be an IPv4 address or DNS name" ;;
  esac
  if printf '%s' "$value" | grep -Eq '^[0-9.]+$'; then
    is_ipv4 "$value" || die "$label is not a valid IPv4 address"
  else
    printf '%s' "$value" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' \
      || die "$label is not a valid DNS name"
  fi
}

validate_port() {
  value=$1
  label=$2
  is_uint "$value" || die "$label must be an integer"
  [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || die "$label must be between 1 and 65535"
}

default_port() {
  case "$PROTOCOL" in
    anytls|vless-reality) printf '443\n' ;;
    ss2022) printf '8388\n' ;;
    socks5) printf '1080\n' ;;
  esac
}

ss_key_bytes() {
  case "$SS_METHOD" in
    2022-blake3-aes-128-gcm) printf '16\n' ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) printf '32\n' ;;
    *) die 'unsupported Shadowsocks 2022 method' ;;
  esac
}

validate_arguments() {
  case "$PROTOCOL" in
    anytls|ss2022|vless-reality|socks5) ;;
    *) die '--protocol must be anytls, ss2022, vless-reality, or socks5' ;;
  esac

  validate_host "$SERVER_ADDRESS" '--server-address'
  is_ipv4 "$LISTEN_ADDRESS" || die '--listen currently supports IPv4 addresses only'
  [ -n "$LISTEN_PORT" ] || LISTEN_PORT=$(default_port)
  validate_port "$LISTEN_PORT" '--port'

  printf '%s' "$USERNAME" | grep -Eq '^[A-Za-z0-9._~-]+$' \
    || die '--username must be URL-safe'

  if [ -n "$PASSWORD" ] && [ "$PROTOCOL" != ss2022 ]; then
    printf '%s' "$PASSWORD" | grep -Eq '^[A-Za-z0-9._~-]+$' \
      || die '--password must be URL-safe: A-Z a-z 0-9 . _ ~ -'
    [ "${#PASSWORD}" -ge 16 ] || die '--password must be at least 16 characters'
  fi

  validate_port "$REALITY_PORT" '--reality-port'
  validate_host "$REALITY_SERVER" '--reality-server'
  is_uint "$SELF_SIGNED_DAYS" || die '--self-signed-days must be an integer'
  [ "$SELF_SIGNED_DAYS" -ge 1 ] && [ "$SELF_SIGNED_DAYS" -le 36500 ] \
    || die '--self-signed-days must be between 1 and 36500'

  if [ -n "$CERT_SOURCE" ] || [ -n "$KEY_SOURCE" ]; then
    [ "$PROTOCOL" = anytls ] || die '--cert and --key are valid only for AnyTLS'
    [ -n "$CERT_SOURCE" ] && [ -n "$KEY_SOURCE" ] || die '--cert and --key must be provided together'
    [ -r "$CERT_SOURCE" ] || die "certificate is not readable: $CERT_SOURCE"
    [ -r "$KEY_SOURCE" ] || die "private key is not readable: $KEY_SOURCE"
  fi
}

detect_platform() {
  [ "$(id -u)" -eq 0 ] || die 'run this installer as root'
  [ -r /etc/os-release ] || die 'cannot identify the operating system'
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    alpine) PLATFORM=alpine ;;
    debian|ubuntu) PLATFORM=debian ;;
    *) die 'supported systems: Alpine Linux, Debian, and Ubuntu' ;;
  esac
}

install_packages() {
  if [ "$PLATFORM" = alpine ]; then
    apk add --no-cache sing-box sing-box-openrc openssl ca-certificates
    return
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl openssl
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod 0644 /etc/apt/keyrings/sagernet.asc
  cat >/etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  apt-get update
  apt-get install -y --no-install-recommends sing-box
}

version_supported() {
  version=$(sing-box version | awk 'NR == 1 { print $3 }')
  major=${version%%.*}
  rest=${version#*.}
  minor=${rest%%.*}
  is_uint "$major" && is_uint "$minor" || return 1
  [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 12 ]; }
}

service_active() {
  if [ "$PLATFORM" = alpine ]; then
    rc-service sing-box status >/dev/null 2>&1
  else
    systemctl is-active --quiet sing-box
  fi
}

service_enabled() {
  if [ "$PLATFORM" = alpine ]; then
    rc-update show default | grep -Eq '^[[:space:]]*sing-box([[:space:]]|$)'
  else
    systemctl is-enabled --quiet sing-box
  fi
}

service_stop() {
  if [ "$PLATFORM" = alpine ]; then rc-service sing-box stop; else systemctl stop sing-box; fi
}

service_start() {
  if [ "$PLATFORM" = alpine ]; then
    rc-update add sing-box default
    rc-service sing-box start
  else
    systemctl daemon-reload
    systemctl enable --now sing-box
  fi
}

service_start_without_enable() {
  if [ "$PLATFORM" = alpine ]; then rc-service sing-box start; else systemctl start sing-box; fi
}

service_disable() {
  if [ "$PLATFORM" = alpine ]; then
    rc-update del sing-box default >/dev/null 2>&1 || true
  else
    systemctl disable sing-box >/dev/null 2>&1 || true
  fi
}

generate_credentials() {
  case "$PROTOCOL" in
    anytls|socks5)
      [ -n "$PASSWORD" ] || PASSWORD=$(openssl rand -hex 24)
      ;;
    ss2022)
      bytes=$(ss_key_bytes)
      if [ -z "$PASSWORD" ]; then
        PASSWORD=$(sing-box generate rand --base64 "$bytes")
      else
        decoded_bytes=$(printf '%s' "$PASSWORD" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
        [ "$decoded_bytes" -eq "$bytes" ] || die "the selected SS2022 method requires a $bytes-byte Base64 key"
      fi
      ;;
    vless-reality)
      UUID=$(sing-box generate uuid)
      keypair=$(sing-box generate reality-keypair)
      REALITY_PRIVATE_KEY=$(printf '%s\n' "$keypair" | awk -F': ' '/PrivateKey/ { print $2; exit }')
      REALITY_PUBLIC_KEY=$(printf '%s\n' "$keypair" | awk -F': ' '/PublicKey/ { print $2; exit }')
      [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] \
        || die 'failed to generate REALITY key pair'
      SHORT_ID=$(openssl rand -hex 8)
      ;;
  esac
}

certificate_san() {
  if is_ipv4 "$SERVER_ADDRESS"; then printf 'IP:%s\n' "$SERVER_ADDRESS"; else printf 'DNS:%s\n' "$SERVER_ADDRESS"; fi
}

install_anytls_certificate() {
  work_dir=$1
  if [ -n "$CERT_SOURCE" ]; then
    openssl x509 -in "$CERT_SOURCE" -pubkey -noout >"$work_dir/cert.pub"
    openssl pkey -in "$KEY_SOURCE" -pubout >"$work_dir/key.pub"
    cmp -s "$work_dir/cert.pub" "$work_dir/key.pub" || die 'certificate and private key do not match'
    if is_ipv4 "$SERVER_ADDRESS"; then
      openssl x509 -in "$CERT_SOURCE" -noout -checkip "$SERVER_ADDRESS" >/dev/null \
        || die 'certificate does not cover the server IP address'
    else
      openssl x509 -in "$CERT_SOURCE" -noout -checkhost "$SERVER_ADDRESS" >/dev/null \
        || die 'certificate does not cover the server DNS name'
    fi
    install -m 0644 "$CERT_SOURCE" "$CERT_FILE"
    install -m 0640 "$KEY_SOURCE" "$KEY_FILE"
    TLS_INSECURE=0
    return
  fi

  san=$(certificate_san)
  openssl ecparam -genkey -name prime256v1 -out "$work_dir/key.pem"
  openssl req -new -x509 -key "$work_dir/key.pem" -sha256 -days "$SELF_SIGNED_DAYS" \
    -out "$work_dir/cert.pem" -subj "/CN=$SERVER_ADDRESS" -addext "subjectAltName=$san"
  install -m 0644 "$work_dir/cert.pem" "$CERT_FILE"
  install -m 0640 "$work_dir/key.pem" "$KEY_FILE"
  TLS_INSECURE=1
}

render_server_config() {
  output=$1
  case "$PROTOCOL" in
    anytls)
      cat >"$output" <<EOF
{"log":{"level":"info","timestamp":true},"inbounds":[{"type":"anytls","tag":"anytls-in","listen":"$LISTEN_ADDRESS","listen_port":$LISTEN_PORT,"users":[{"name":"$USERNAME","password":"$PASSWORD"}],"tls":{"enabled":true,"certificate_path":"$CERT_FILE","key_path":"$KEY_FILE"}}],"outbounds":[{"type":"direct","tag":"direct"}]}
EOF
      ;;
    ss2022)
      cat >"$output" <<EOF
{"log":{"level":"info","timestamp":true},"inbounds":[{"type":"shadowsocks","tag":"ss2022-in","listen":"$LISTEN_ADDRESS","listen_port":$LISTEN_PORT,"method":"$SS_METHOD","password":"$PASSWORD"}],"outbounds":[{"type":"direct","tag":"direct"}]}
EOF
      ;;
    vless-reality)
      cat >"$output" <<EOF
{"log":{"level":"info","timestamp":true},"inbounds":[{"type":"vless","tag":"vless-reality-in","listen":"$LISTEN_ADDRESS","listen_port":$LISTEN_PORT,"users":[{"name":"$USERNAME","uuid":"$UUID","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"$REALITY_SERVER","reality":{"enabled":true,"handshake":{"server":"$REALITY_SERVER","server_port":$REALITY_PORT},"private_key":"$REALITY_PRIVATE_KEY","short_id":["$SHORT_ID"]}}}],"outbounds":[{"type":"direct","tag":"direct"}]}
EOF
      ;;
    socks5)
      cat >"$output" <<EOF
{"log":{"level":"info","timestamp":true},"inbounds":[{"type":"socks","tag":"socks-in","listen":"$LISTEN_ADDRESS","listen_port":$LISTEN_PORT,"users":[{"username":"$USERNAME","password":"$PASSWORD"}]}],"outbounds":[{"type":"direct","tag":"direct"}]}
EOF
      ;;
  esac
}

ss_password_uri() {
  printf '%s' "$PASSWORD" | sed 's/%/%25/g; s/+/%2B/g; s|/|%2F|g; s/=/%3D/g'
}

render_client_file() {
  case "$PROTOCOL" in
    anytls)
      if is_ipv4 "$SERVER_ADDRESS"; then query="insecure=$TLS_INSECURE"; else query="sni=$SERVER_ADDRESS&insecure=$TLS_INSECURE"; fi
      insecure_json=false
      [ "$TLS_INSECURE" -eq 0 ] || insecure_json=true
      cat >"$CLIENT_FILE" <<EOF
Protocol: AnyTLS
Address: $SERVER_ADDRESS
Port: $LISTEN_PORT
Password: $PASSWORD
URI: anytls://$PASSWORD@$SERVER_ADDRESS:$LISTEN_PORT/?$query#AnyTLS
Client JSON:
{"type":"anytls","tag":"proxy","server":"$SERVER_ADDRESS","server_port":$LISTEN_PORT,"password":"$PASSWORD","tls":{"enabled":true,"server_name":"$SERVER_ADDRESS","insecure":$insecure_json}}
EOF
      ;;
    ss2022)
      encoded_password=$(ss_password_uri)
      cat >"$CLIENT_FILE" <<EOF
Protocol: Shadowsocks 2022
Address: $SERVER_ADDRESS
Port: $LISTEN_PORT
Method: $SS_METHOD
Password: $PASSWORD
URI: ss://$SS_METHOD:$encoded_password@$SERVER_ADDRESS:$LISTEN_PORT#SS2022
Client JSON:
{"type":"shadowsocks","tag":"proxy","server":"$SERVER_ADDRESS","server_port":$LISTEN_PORT,"method":"$SS_METHOD","password":"$PASSWORD"}
EOF
      ;;
    vless-reality)
      cat >"$CLIENT_FILE" <<EOF
Protocol: VLESS + REALITY
Address: $SERVER_ADDRESS
Port: $LISTEN_PORT
UUID: $UUID
Flow: xtls-rprx-vision
Server name: $REALITY_SERVER
REALITY public key: $REALITY_PUBLIC_KEY
Short ID: $SHORT_ID
Compatibility URI: vless://$UUID@$SERVER_ADDRESS:$LISTEN_PORT?encryption=none&security=reality&sni=$REALITY_SERVER&fp=chrome&pbk=$REALITY_PUBLIC_KEY&sid=$SHORT_ID&type=tcp&flow=xtls-rprx-vision#VLESS-Reality
Client JSON:
{"type":"vless","tag":"proxy","server":"$SERVER_ADDRESS","server_port":$LISTEN_PORT,"uuid":"$UUID","flow":"xtls-rprx-vision","tls":{"enabled":true,"server_name":"$REALITY_SERVER","reality":{"enabled":true,"public_key":"$REALITY_PUBLIC_KEY","short_id":"$SHORT_ID"}}}
EOF
      ;;
    socks5)
      cat >"$CLIENT_FILE" <<EOF
Protocol: SOCKS5
Address: $SERVER_ADDRESS
Port: $LISTEN_PORT
Username: $USERNAME
Password: $PASSWORD
Compatibility URI: socks5://$USERNAME:$PASSWORD@$SERVER_ADDRESS:$LISTEN_PORT
Client JSON:
{"type":"socks","tag":"proxy","server":"$SERVER_ADDRESS","server_port":$LISTEN_PORT,"username":"$USERNAME","password":"$PASSWORD"}
EOF
      ;;
  esac
  chmod 0600 "$CLIENT_FILE"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --protocol) [ "$#" -ge 2 ] || die '--protocol requires a value'; PROTOCOL=$2; shift 2 ;;
    --server-address) [ "$#" -ge 2 ] || die '--server-address requires a value'; SERVER_ADDRESS=$2; shift 2 ;;
    --port) [ "$#" -ge 2 ] || die '--port requires a value'; LISTEN_PORT=$2; shift 2 ;;
    --listen) [ "$#" -ge 2 ] || die '--listen requires a value'; LISTEN_ADDRESS=$2; shift 2 ;;
    --username) [ "$#" -ge 2 ] || die '--username requires a value'; USERNAME=$2; shift 2 ;;
    --password) [ "$#" -ge 2 ] || die '--password requires a value'; PASSWORD=$2; shift 2 ;;
    --ss-method) [ "$#" -ge 2 ] || die '--ss-method requires a value'; SS_METHOD=$2; shift 2 ;;
    --reality-server) [ "$#" -ge 2 ] || die '--reality-server requires a value'; REALITY_SERVER=$2; shift 2 ;;
    --reality-port) [ "$#" -ge 2 ] || die '--reality-port requires a value'; REALITY_PORT=$2; shift 2 ;;
    --cert) [ "$#" -ge 2 ] || die '--cert requires a value'; CERT_SOURCE=$2; shift 2 ;;
    --key) [ "$#" -ge 2 ] || die '--key requires a value'; KEY_SOURCE=$2; shift 2 ;;
    --self-signed-days) [ "$#" -ge 2 ] || die '--self-signed-days requires a value'; SELF_SIGNED_DAYS=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

validate_arguments
detect_platform

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Dry run passed.\nPlatform: %s\nProtocol: %s\nListen: %s:%s\nPublic address: %s\n' \
    "$PLATFORM" "$PROTOCOL" "$LISTEN_ADDRESS" "$LISTEN_PORT" "$SERVER_ADDRESS"
  exit 0
fi

managed=0
[ -r "$STATE_FILE" ] && managed=1
existing=0
[ -s "$CONFIG_FILE" ] && existing=1
if [ "$existing" -eq 1 ] && [ "$managed" -eq 0 ] && [ "$FORCE" -ne 1 ]; then
  die "unmanaged configuration exists at $CONFIG_FILE; rerun with --force to replace it"
fi

info 'Installing sing-box and required packages'
install_packages
version_supported || die 'sing-box 1.12.0 or newer is required'
generate_credentials

timestamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
backup=$BACKUP_ROOT/$timestamp
work=$(mktemp -d /tmp/sing-box-installer.XXXXXX)
was_active=0
was_enabled=0
rollback=0
service_active && was_active=1 || true
service_enabled && was_enabled=1 || true

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$rollback" -eq 1 ]; then
    printf 'Installation failed; restoring previous files and service state.\n' >&2
    service_active && service_stop >/dev/null 2>&1 || true
    rm -f "$CONFIG_FILE" "$CERT_FILE" "$KEY_FILE" "$STATE_FILE" "$CLIENT_FILE"
    [ ! -f "$backup/config.json" ] || install -m 0640 "$backup/config.json" "$CONFIG_FILE"
    [ ! -f "$backup/cert.pem" ] || install -m 0644 "$backup/cert.pem" "$CERT_FILE"
    [ ! -f "$backup/key.pem" ] || install -m 0640 "$backup/key.pem" "$KEY_FILE"
    [ ! -f "$backup/state" ] || install -m 0600 "$backup/state" "$STATE_FILE"
    [ ! -f "$backup/client.txt" ] || install -m 0600 "$backup/client.txt" "$CLIENT_FILE"
    [ "$was_enabled" -eq 1 ] || service_disable
    [ "$was_active" -eq 0 ] || service_start_without_enable >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

install -d -m 0755 "$CONFIG_DIR" "$BACKUP_ROOT" "$STATE_DIR" /var/lib/sing-box
install -d -m 0700 "$backup"
[ ! -f "$CONFIG_FILE" ] || cp -p "$CONFIG_FILE" "$backup/config.json"
[ ! -f "$CERT_FILE" ] || cp -p "$CERT_FILE" "$backup/cert.pem"
[ ! -f "$KEY_FILE" ] || cp -p "$KEY_FILE" "$backup/key.pem"
[ ! -f "$STATE_FILE" ] || cp -p "$STATE_FILE" "$backup/state"
[ ! -f "$CLIENT_FILE" ] || cp -p "$CLIENT_FILE" "$backup/client.txt"
rollback=1

[ "$was_active" -eq 0 ] || service_stop
if ss -ltn "( sport = :$LISTEN_PORT )" | grep -q LISTEN; then die "TCP port $LISTEN_PORT is in use"; fi
if [ "$PROTOCOL" = ss2022 ] || [ "$PROTOCOL" = socks5 ]; then
  if ss -lun "( sport = :$LISTEN_PORT )" | grep -q UNCONN; then die "UDP port $LISTEN_PORT is in use"; fi
fi

TLS_INSECURE=0
[ "$PROTOCOL" != anytls ] || install_anytls_certificate "$work"
render_server_config "$work/config.json"
sing-box check -c "$work/config.json"
install -m 0640 "$work/config.json" "$CONFIG_FILE"

if getent group sing-box >/dev/null 2>&1; then
  chown root:sing-box "$CONFIG_FILE"
  [ ! -f "$KEY_FILE" ] || chown root:sing-box "$KEY_FILE"
fi

cat >"$STATE_FILE" <<EOF
installer_version=$VERSION
platform=$PLATFORM
protocol=$PROTOCOL
server_address=$SERVER_ADDRESS
listen_address=$LISTEN_ADDRESS
listen_port=$LISTEN_PORT
installed_at=$timestamp
EOF
chmod 0600 "$STATE_FILE"
render_client_file

service_start
sing-box check -c "$CONFIG_FILE"
ss -ltnp "( sport = :$LISTEN_PORT )" | grep -q sing-box || die "sing-box is not listening on TCP port $LISTEN_PORT"

rollback=0
trap - EXIT HUP INT TERM
rm -rf "$work"

printf '\nInstallation completed.\nProtocol: %s\nListen: %s:%s\nClient details: %s\nConfiguration: %s\nBackup: %s\n' \
  "$PROTOCOL" "$LISTEN_ADDRESS" "$LISTEN_PORT" "$CLIENT_FILE" "$CONFIG_FILE" "$backup"
cat "$CLIENT_FILE"
