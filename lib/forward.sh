#!/bin/sh

SB_FORWARD_CHAIN_DNAT=SB_DNAT
SB_FORWARD_CHAIN_SNAT=SB_SNAT
SB_FORWARD_CHAIN_FILTER=SB_FORWARD
SB_FORWARD_SYNC_LOCK=${SB_FORWARD_SYNC_LOCK:-/run/lock/sb-forward-sync.lock}
SB_FORWARD_SYSCTL_FILE=${SB_FORWARD_SYSCTL_FILE:-/etc/sysctl.d/99-sb-forward.conf}

forward_config_file() {
  printf '%s/%s.json\n' "$SB_FORWARD_DIR" "$1"
}

forward_list_names() {
  find "$SB_FORWARD_DIR" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null \
    | sed 's|.*/||; s/\.json$//' | sort
}

forward_resolve_ipv4() {
  fw_resolve_host=$1
  if is_ipv4 "$fw_resolve_host"; then
    printf '%s\n' "$fw_resolve_host"
    return 0
  fi
  getent ahosts "$fw_resolve_host" 2>/dev/null \
    | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}'
}

forward_protocols_json() {
  case "$1" in
    tcp) printf '["tcp"]\n' ;;
    udp) printf '["udp"]\n' ;;
    both) printf '["tcp","udp"]\n' ;;
    *) return 1 ;;
  esac
}

forward_port_conflicts() {
  fw_conflict_port=$1
  fw_conflict_protocol=$2
  fw_conflict_except=${3:-}
  for fw_conflict_file in "$SB_FORWARD_DIR"/*.json; do
    [ -f "$fw_conflict_file" ] || continue
    [ "$(jq -r '.name' "$fw_conflict_file")" = "$fw_conflict_except" ] && continue
    [ "$(jq -r '.listen_port' "$fw_conflict_file")" = "$fw_conflict_port" ] || continue
    jq -e --arg protocol "$fw_conflict_protocol" '.protocols | index($protocol) != null' "$fw_conflict_file" >/dev/null && return 0
  done
  return 1
}

forward_ensure_chains() {
  iptables -t nat -N "$SB_FORWARD_CHAIN_DNAT" 2>/dev/null || true
  iptables -t nat -N "$SB_FORWARD_CHAIN_SNAT" 2>/dev/null || true
  iptables -N "$SB_FORWARD_CHAIN_FILTER" 2>/dev/null || true
  iptables -t nat -C PREROUTING -j "$SB_FORWARD_CHAIN_DNAT" 2>/dev/null || iptables -t nat -I PREROUTING 1 -j "$SB_FORWARD_CHAIN_DNAT"
  iptables -t nat -C POSTROUTING -j "$SB_FORWARD_CHAIN_SNAT" 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j "$SB_FORWARD_CHAIN_SNAT"
  iptables -C FORWARD -j "$SB_FORWARD_CHAIN_FILTER" 2>/dev/null || iptables -I FORWARD 1 -j "$SB_FORWARD_CHAIN_FILTER"
}

forward_apply_plan() {
  fw_plan_file=$1
  forward_ensure_chains || return 1
  iptables -t nat -F "$SB_FORWARD_CHAIN_DNAT" || return 1
  iptables -t nat -F "$SB_FORWARD_CHAIN_SNAT" || return 1
  iptables -F "$SB_FORWARD_CHAIN_FILTER" || return 1

  while IFS='|' read -r fw_plan_config fw_plan_ip; do
    [ -n "$fw_plan_config" ] || continue
    fw_plan_listen=$(jq -r '.listen_port' "$fw_plan_config")
    fw_plan_target=$(jq -r '.target.port' "$fw_plan_config")
    for fw_plan_protocol in $(jq -r '.protocols[]' "$fw_plan_config"); do
      iptables -t nat -A "$SB_FORWARD_CHAIN_DNAT" -p "$fw_plan_protocol" --dport "$fw_plan_listen" -j DNAT --to-destination "$fw_plan_ip:$fw_plan_target" || return 1
      iptables -t nat -A "$SB_FORWARD_CHAIN_SNAT" -p "$fw_plan_protocol" -d "$fw_plan_ip" --dport "$fw_plan_target" -j MASQUERADE || return 1
      iptables -A "$SB_FORWARD_CHAIN_FILTER" -p "$fw_plan_protocol" -d "$fw_plan_ip" --dport "$fw_plan_target" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT || return 1
      iptables -A "$SB_FORWARD_CHAIN_FILTER" -p "$fw_plan_protocol" -s "$fw_plan_ip" --sport "$fw_plan_target" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
    done
  done <"$fw_plan_file"
}

forward_enable_kernel() {
  install -d -m 0755 "$(dirname "$SB_FORWARD_SYSCTL_FILE")"
  printf 'net.ipv4.ip_forward=1\n' >"$SB_FORWARD_SYSCTL_FILE"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

forward_install_scheduler() {
  [ "${SB_FORWARD_SKIP_SCHEDULER:-0}" != 1 ] || return 0
  if [ "$SB_PLATFORM" = alpine ]; then
    install -d -m 0755 /etc/periodic /etc/init.d
    fw_cron_line='*/5 * * * * /usr/local/bin/sb forward sync --quiet >/dev/null 2>&1'
    touch /etc/crontabs/root
    grep -Fqx "$fw_cron_line" /etc/crontabs/root || printf '%s\n' "$fw_cron_line" >>/etc/crontabs/root
    cat >/etc/init.d/sb-forward <<'EOF'
#!/sbin/openrc-run
description="Restore sb dynamic port forwarding"
depend() { need net; after firewall; }
start() {
  ebegin "Applying sb port forwarding rules"
  /usr/local/bin/sb forward sync --quiet
  eend $?
}
EOF
    chmod 0755 /etc/init.d/sb-forward
    rc-update add sb-forward default 9>&- >/dev/null 2>&1 || true
    rc-update add crond default 9>&- >/dev/null 2>&1 || true
    rc-service crond start 9>&- >/dev/null 2>&1 || true
  else
    cat >/etc/systemd/system/sb-forward-sync.service <<'EOF'
[Unit]
Description=Synchronize sb dynamic port forwarding
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sb forward sync --quiet
EOF
    cat >/etc/systemd/system/sb-forward-sync.timer <<'EOF'
[Unit]
Description=Refresh sb dynamic port forwarding every five minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload 9>&-
    systemctl enable --now sb-forward-sync.timer 9>&-
  fi
}

forward_remove_scheduler() {
  if [ "$SB_PLATFORM" = alpine ]; then
    fw_cron_line='*/5 * * * * /usr/local/bin/sb forward sync --quiet >/dev/null 2>&1'
    if [ -f /etc/crontabs/root ]; then
      grep -Fvx "$fw_cron_line" /etc/crontabs/root >/etc/crontabs/root.sb-tmp || true
      mv /etc/crontabs/root.sb-tmp /etc/crontabs/root
    fi
    rc-update del sb-forward default 9>&- >/dev/null 2>&1 || true
    rm -f /etc/init.d/sb-forward
  else
    systemctl disable --now sb-forward-sync.timer 9>&- >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/sb-forward-sync.service /etc/systemd/system/sb-forward-sync.timer
    systemctl daemon-reload 9>&-
  fi
}

forward_clear_rules() {
  iptables -t nat -D PREROUTING -j "$SB_FORWARD_CHAIN_DNAT" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -j "$SB_FORWARD_CHAIN_SNAT" 2>/dev/null || true
  iptables -D FORWARD -j "$SB_FORWARD_CHAIN_FILTER" 2>/dev/null || true
  iptables -t nat -F "$SB_FORWARD_CHAIN_DNAT" 2>/dev/null || true
  iptables -t nat -X "$SB_FORWARD_CHAIN_DNAT" 2>/dev/null || true
  iptables -t nat -F "$SB_FORWARD_CHAIN_SNAT" 2>/dev/null || true
  iptables -t nat -X "$SB_FORWARD_CHAIN_SNAT" 2>/dev/null || true
  iptables -F "$SB_FORWARD_CHAIN_FILTER" 2>/dev/null || true
  iptables -X "$SB_FORWARD_CHAIN_FILTER" 2>/dev/null || true
}

command_forward_sync() {
  require_command iptables
  require_command iptables-save
  require_command iptables-restore
  require_command sysctl
  require_command getent
  fw_quiet=0
  [ "${1:-}" != --quiet ] || fw_quiet=1
  install -d -m 0755 /run/lock
  exec 8>"$SB_FORWARD_SYNC_LOCK"
  if ! flock -n 8; then
    [ "$fw_quiet" -eq 1 ] && return 0
    warn '另一个端口转发同步任务正在运行'
    return 1
  fi

  install -d -m 0700 "$SB_FORWARD_DIR"
  fw_work=$(mktemp -d /tmp/sb-forward-sync.XXXXXX)
  fw_plan=$fw_work/plan
  : >"$fw_plan"
  for fw_config in "$SB_FORWARD_DIR"/*.json; do
    [ -f "$fw_config" ] || continue
    [ "$(jq -r 'if has("enabled") then .enabled else true end' "$fw_config")" != false ] || continue
    fw_host=$(jq -r '.target.host' "$fw_config")
    fw_ip=$(forward_resolve_ipv4 "$fw_host" || true)
    if [ -z "$fw_ip" ]; then
      fw_ip=$(jq -r '.resolved_ip // empty' "$fw_config")
      [ -n "$fw_ip" ] || { warn "无法解析目标域名且没有历史 IP: $fw_host"; rm -rf "$fw_work"; return 1; }
      [ "$fw_quiet" -eq 1 ] || warn "DNS 解析失败，继续使用上次 IP: $fw_host -> $fw_ip"
    fi
    printf '%s|%s\n' "$fw_config" "$fw_ip" >>"$fw_plan"
  done

  fw_backup=$fw_work/iptables.save
  iptables-save >"$fw_backup" || { rm -rf "$fw_work"; warn '无法备份当前 iptables 规则'; return 1; }
  forward_enable_kernel || { rm -rf "$fw_work"; warn '无法启用 IPv4 转发'; return 1; }
  if ! forward_apply_plan "$fw_plan"; then
    iptables-restore <"$fw_backup" || true
    rm -rf "$fw_work"
    warn '应用端口转发规则失败，已恢复原防火墙状态'
    return 1
  fi

  while IFS='|' read -r fw_config fw_ip; do
    [ -n "$fw_config" ] || continue
    jq --arg ip "$fw_ip" --arg updated "$(timestamp)" '.resolved_ip=$ip | .updated_at=$updated' "$fw_config" >"$fw_config.tmp"
    mv "$fw_config.tmp" "$fw_config"
  done <"$fw_plan"
  rm -rf "$fw_work"
  [ "$fw_quiet" -eq 1 ] || info '端口转发规则已同步'
}

command_forward_add() {
  fw_name=; fw_listen=; fw_host=; fw_target=; fw_protocol=both
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) [ "$#" -ge 2 ] || die '--name 需要参数'; fw_name=$2; shift 2 ;;
      --listen-port|--port) [ "$#" -ge 2 ] || die '--listen-port 需要参数'; fw_listen=$2; shift 2 ;;
      --target-host) [ "$#" -ge 2 ] || die '--target-host 需要参数'; fw_host=$2; shift 2 ;;
      --target-port) [ "$#" -ge 2 ] || die '--target-port 需要参数'; fw_target=$2; shift 2 ;;
      --protocol) [ "$#" -ge 2 ] || die '--protocol 需要参数'; fw_protocol=$2; shift 2 ;;
      *) die "未知的端口转发参数: $1" ;;
    esac
  done
  [ -n "$fw_listen" ] || die '必须指定本机监听端口'
  [ -n "$fw_host" ] || die '必须指定目标域名或 IP'
  [ -n "$fw_target" ] || fw_target=$fw_listen
  [ -n "$fw_name" ] || fw_name="forward-$fw_listen"
  validate_name "$fw_name" || die '转发规则名称无效'
  validate_port "$fw_listen" || die '本机监听端口无效'
  validate_port "$fw_target" || die '目标端口无效'
  validate_host "$fw_host" || die '目标域名或 IP 无效'
  fw_protocols=$(forward_protocols_json "$fw_protocol") || die '协议必须是 tcp、udp 或 both'
  [ ! -f "$(forward_config_file "$fw_name")" ] || die "转发规则已存在: $fw_name"
  port_in_metadata "$fw_listen" '' && die "该端口已被 sing-box 节点使用: $fw_listen"
  for fw_check_protocol in $(printf '%s' "$fw_protocols" | jq -r '.[]'); do
    forward_port_conflicts "$fw_listen" "$fw_check_protocol" '' && die "该端口和协议已有转发规则: $fw_listen/$fw_check_protocol"
  done

  install -d -m 0700 "$SB_FORWARD_DIR"
  fw_file=$(forward_config_file "$fw_name")
  jq -n --arg name "$fw_name" --argjson listen "$fw_listen" --arg host "$fw_host" --argjson target "$fw_target" --argjson protocols "$fw_protocols" --arg now "$(timestamp)" \
    '{schema:1,name:$name,enabled:true,listen_port:$listen,target:{host:$host,port:$target},protocols:$protocols,resolved_ip:"",created_at:$now,updated_at:$now}' >"$fw_file"
  chmod 0600 "$fw_file"
  if ! command_forward_sync; then rm -f "$fw_file"; return 1; fi
  forward_install_scheduler
  info "端口转发已添加: $fw_name"
}

command_forward_list() {
  printf '%-4s %-20s %-8s %-24s %-22s %-8s\n' 序号 名称 协议 本机端口 目标地址 状态
  fw_index=1
  for fw_name in $(forward_list_names); do
    fw_file=$(forward_config_file "$fw_name")
    fw_protocol=$(jq -r '.protocols|join("+")' "$fw_file")
    fw_listen=$(jq -r '.listen_port' "$fw_file")
    fw_target=$(jq -r '.target.host+":"+(.target.port|tostring)' "$fw_file")
    fw_enabled=$(jq -r 'if .enabled == false then "禁用" else "启用" end' "$fw_file")
    printf '%-4s %-20s %-8s %-24s %-22s %-8s\n' "$fw_index" "$fw_name" "$fw_protocol" "$fw_listen" "$fw_target" "$fw_enabled"
    fw_index=$((fw_index + 1))
  done
}

command_forward_set_enabled() {
  fw_enabled_value=$1; fw_name=$2; fw_file=$(forward_config_file "$fw_name")
  [ -f "$fw_file" ] || die "转发规则不存在: $fw_name"
  jq --argjson enabled "$fw_enabled_value" --arg updated "$(timestamp)" '.enabled=$enabled | .updated_at=$updated' "$fw_file" >"$fw_file.tmp"
  mv "$fw_file.tmp" "$fw_file"
  command_forward_sync
}

command_forward_delete() {
  [ "$#" -eq 1 ] || die '必须指定转发规则名称'
  fw_name=$1; fw_file=$(forward_config_file "$fw_name")
  [ -f "$fw_file" ] || die "转发规则不存在: $fw_name"
  fw_backup=$(mktemp /tmp/sb-forward-delete.XXXXXX)
  cp "$fw_file" "$fw_backup"
  rm -f "$fw_file"
  if ! command_forward_sync; then cp "$fw_backup" "$fw_file"; rm -f "$fw_backup"; return 1; fi
  rm -f "$fw_backup"
  if [ -z "$(forward_list_names)" ]; then forward_remove_scheduler; fi
  info "端口转发已删除: $fw_name"
}

command_forward_status() {
  say 'IPv4 转发状态:'
  sysctl net.ipv4.ip_forward
  say 'DNAT 规则:'
  iptables -t nat -L "$SB_FORWARD_CHAIN_DNAT" -n -v --line-numbers 2>/dev/null || say '尚未创建规则'
}

command_forward() {
  fw_action=${1:-list}; [ "$#" -eq 0 ] || shift
  case "$fw_action" in
    add) command_forward_add "$@" ;;
    list|ls) command_forward_list ;;
    sync) command_forward_sync "$@" ;;
    enable) [ "$#" -eq 1 ] || die '必须指定转发规则名称'; command_forward_set_enabled true "$1" ;;
    disable) [ "$#" -eq 1 ] || die '必须指定转发规则名称'; command_forward_set_enabled false "$1" ;;
    delete|del) command_forward_delete "$@" ;;
    status) command_forward_status ;;
    install-scheduler) forward_install_scheduler ;;
    *) die '用法: sb forward add|list|sync|enable|disable|delete|status' ;;
  esac
}

forward_uninstall() {
  forward_remove_scheduler
  forward_clear_rules
}