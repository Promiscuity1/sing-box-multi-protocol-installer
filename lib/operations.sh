#!/bin/sh

command_enable() {
  [ "$#" -eq 1 ] || die 'node name is required'
  op_name=$1; op_meta=$(node_meta_file "$op_name")
  [ -f "$op_meta" ] || die "node not found: $op_name"
  [ "$(jq -r 'if has("enabled") then .enabled else true end' "$op_meta")" = false ] || { info 'Node is already enabled.'; return; }
  op_work=$(mktemp -d /tmp/sb-enable.XXXXXX)
  jq '.enabled=true | .updated_at=(now|todate)' "$op_meta" >"$op_work/meta.json"
  protocol_render "$op_work/meta.json" "$op_work/config.json"
  commit_node_change "$op_name" "$op_work/config.json" "$op_work/meta.json" '' enable
  rm -rf "$op_work"
  info "Node enabled: $op_name"
}

command_disable() {
  [ "$#" -eq 1 ] || die 'node name is required'
  op_name=$1; op_meta=$(node_meta_file "$op_name")
  [ -f "$op_meta" ] || die "node not found: $op_name"
  [ "$(jq -r 'if has("enabled") then .enabled else true end' "$op_meta")" != false ] || { info 'Node is already disabled.'; return; }
  op_work=$(mktemp -d /tmp/sb-disable.XXXXXX)
  jq '.enabled=false | .updated_at=(now|todate)' "$op_meta" >"$op_work/meta.json"
  : >"$op_work/empty"
  commit_node_change "$op_name" "$op_work/empty" "$op_work/meta.json" '' disable
  rm -rf "$op_work"
  info "Node disabled: $op_name"
}

command_rotate() {
  [ "$#" -eq 1 ] || die 'node name is required'
  op_name=$1; op_meta=$(node_meta_file "$op_name")
  [ -f "$op_meta" ] || die "node not found: $op_name"
  op_protocol=$(jq -r '.protocol' "$op_meta")
  op_work=$(mktemp -d /tmp/sb-rotate.XXXXXX)
  cp "$op_meta" "$op_work/meta.json"
  case "$op_protocol" in
    anytls|socks5|hysteria2|trojan)
      op_password=$(sing-box generate rand --base64 32)
      jq --arg password "$op_password" '.credentials.password=$password | .updated_at=(now|todate)' "$op_work/meta.json" >"$op_work/new.json"
      ;;
    ss2022)
      op_method=$(jq -r '.credentials.method' "$op_meta"); op_bytes=$(ss_key_bytes "$op_method"); op_password=$(sing-box generate rand --base64 "$op_bytes")
      jq --arg password "$op_password" '.credentials.password=$password | .updated_at=(now|todate)' "$op_work/meta.json" >"$op_work/new.json"
      ;;
    vless-reality)
      op_uuid=$(sing-box generate uuid); op_keys=$(sing-box generate reality-keypair)
      op_private=$(printf '%s\n' "$op_keys" | awk -F': ' '/PrivateKey/{print $2;exit}'); op_public=$(printf '%s\n' "$op_keys" | awk -F': ' '/PublicKey/{print $2;exit}'); op_short=$(openssl rand -hex 8)
      jq --arg uuid "$op_uuid" --arg private "$op_private" --arg public "$op_public" --arg short "$op_short" '.credentials.uuid=$uuid | .reality.private_key=$private | .reality.public_key=$public | .reality.short_id=$short | .updated_at=(now|todate)' "$op_work/meta.json" >"$op_work/new.json"
      ;;
    tuic)
      op_uuid=$(sing-box generate uuid); op_password=$(sing-box generate rand --base64 32)
      jq --arg uuid "$op_uuid" --arg password "$op_password" '.credentials.uuid=$uuid | .credentials.password=$password | .updated_at=(now|todate)' "$op_work/meta.json" >"$op_work/new.json"
      ;;
    vmess|vless-tls)
      op_uuid=$(sing-box generate uuid)
      jq --arg uuid "$op_uuid" '.credentials.uuid=$uuid | .updated_at=(now|todate)' "$op_work/meta.json" >"$op_work/new.json"
      ;;
    *) rm -rf "$op_work"; die 'credential rotation is not implemented for this protocol' ;;
  esac
  mv "$op_work/new.json" "$op_work/meta.json"
  protocol_render "$op_work/meta.json" "$op_work/config.json"
  commit_node_change "$op_name" "$op_work/config.json" "$op_work/meta.json" '' rotate
  rm -rf "$op_work"
  info "Credentials rotated: $op_name"
  command_info "$op_name"
}

command_export() {
  op_output=
  op_all=0
  while [ "$#" -gt 0 ]; do
    case "$1" in --all) op_all=1 ;; --output) [ "$#" -ge 2 ] || die '--output requires a path'; op_output=$2; shift ;; *) break ;; esac
    shift
  done
  op_tmp=$(mktemp /tmp/sb-export.XXXXXX)
  if [ "$op_all" -eq 1 ] || [ "$#" -eq 0 ]; then op_names=$(list_node_names); else op_names="$*"; fi
  for op_name in $op_names; do
    [ -f "$(node_meta_file "$op_name")" ] || die "node not found: $op_name"
    protocol_share_uri "$(node_meta_file "$op_name")" >>"$op_tmp"
  done
  if [ -n "$op_output" ]; then install -m 0600 "$op_tmp" "$op_output"; info "Export written: $op_output"; else cat "$op_tmp"; fi
  rm -f "$op_tmp"
}

command_snapshot() {
  op_id=${1:-$(timestamp)-$$}
  op_dir=$SB_HOME/releases/$op_id
  [ ! -e "$op_dir" ] || die "release already exists: $op_id"
  install -d -m 0700 "$op_dir"
  cp "$SB_BASE_CONFIG" "$op_dir/config.json"
  cp "$SB_MANAGER_CONFIG" "$op_dir/manager.json"
  cp -R "$SB_CONF_DIR" "$SB_NODE_DIR" "$SB_CERT_DIR" "$op_dir/"
  sing-box check -c "$op_dir/config.json" -C "$op_dir/conf.d"
  info "Release snapshot: $op_id"
}

command_rollback_release() {
  [ "$#" -eq 1 ] || die 'release id is required'
  op_dir=$SB_HOME/releases/$1
  [ -d "$op_dir" ] || die 'release not found'
  sing-box check -c "$op_dir/config.json" -C "$op_dir/conf.d"
  command_snapshot "before-rollback-$(timestamp)-$$"
  rm -rf "$SB_CONF_DIR" "$SB_NODE_DIR" "$SB_CERT_DIR"
  cp "$op_dir/config.json" "$SB_BASE_CONFIG"; cp "$op_dir/manager.json" "$SB_MANAGER_CONFIG"
  cp -R "$op_dir/conf.d" "$SB_CONF_DIR"; cp -R "$op_dir/nodes" "$SB_NODE_DIR"; cp -R "$op_dir/certs" "$SB_CERT_DIR"
  restart_and_verify
  info "Rolled back to release: $1"
}

command_doctor() {
  say "sing-box: $(sing-box version | head -n 1)"
  say "platform: $SB_PLATFORM"
  service_active && say 'service: active' || say 'service: inactive'
  command_check || true
  for op_name in $(list_node_names); do
    op_meta=$(node_meta_file "$op_name")
    op_enabled=$(jq -r 'if has("enabled") then .enabled else true end' "$op_meta")
    op_protocol=$(jq -r '.protocol' "$op_meta")
    op_listen=$(jq -r '.listen.address+":"+(.listen.port|tostring)' "$op_meta")
    op_public=$(jq -r '.public.address+":"+(.public.port|tostring)' "$op_meta")
    op_transports=$(jq -r '.listen.transports|join(",")' "$op_meta")
    say "$op_name [$op_protocol] enabled=$op_enabled listen=$op_listen public=$op_public transport=$op_transports"
    op_domain=$(jq -r '.public.address' "$op_meta"); getent ahosts "$op_domain" 2>/dev/null | head -n 1 || warn "DNS lookup failed: $op_domain"
  done
  if command -v ufw >/dev/null 2>&1; then ufw status; fi
  if command -v nft >/dev/null 2>&1; then nft list ruleset 2>/dev/null | head -n 40; elif command -v iptables >/dev/null 2>&1; then iptables -S | head -n 40; fi
}

command_bbr() {
  op_action=${1:-status}; op_file=/etc/sysctl.d/99-sb-bbr.conf
  case "$op_action" in
    status) sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true ;;
    enable) modprobe tcp_bbr 2>/dev/null || true; grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control || die 'BBR is not supported by this kernel'; printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >"$op_file"; sysctl -p "$op_file" ;;
    disable) rm -f "$op_file"; sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true ;;
    *) die 'usage: sb bbr status|enable|disable' ;;
  esac
}

command_dns() {
  say 'Resolvers:'; cat /etc/resolv.conf
  for op_name in $(list_node_names); do op_host=$(jq -r '.public.address' "$(node_meta_file "$op_name")"); say "$op_name: $op_host"; getent ahosts "$op_host" 2>/dev/null | head -n 3 || true; done
}
