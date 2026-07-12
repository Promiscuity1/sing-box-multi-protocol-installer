#!/bin/sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-forward-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/etc/sing-box/nodes" "$TEST_ROOT/etc/sing-box/conf.d" "$TEST_ROOT/etc/sing-box/certs" "$TEST_ROOT/etc/sing-box/backups" "$TEST_ROOT/etc/sing-box/forwards"

cat >"$TEST_ROOT/bin/iptables" <<'EOF'
#!/bin/sh
printf 'iptables %s\n' "$*" >>"$FW_LOG"
exit 0
EOF
cat >"$TEST_ROOT/bin/iptables-save" <<'EOF'
#!/bin/sh
printf '*filter\nCOMMIT\n'
EOF
cat >"$TEST_ROOT/bin/iptables-restore" <<'EOF'
#!/bin/sh
cat >/dev/null
EOF
cat >"$TEST_ROOT/bin/sysctl" <<'EOF'
#!/bin/sh
printf 'sysctl %s\n' "$*" >>"$FW_LOG"
EOF
cat >"$TEST_ROOT/bin/getent" <<'EOF'
#!/bin/sh
[ "${FW_DNS_FAIL:-0}" != 1 ] || exit 2
printf '%s STREAM target.example\n' "${FW_DNS_IP:-198.51.100.42}"
EOF
cat >"$TEST_ROOT/bin/sing-box" <<'EOF'
#!/bin/sh
case "${1:-}" in
  version) printf 'sing-box version 1.13.14\n' ;;
  check) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TEST_ROOT/bin"/*

printf '%s\n' '{"log":{"level":"error"},"outbounds":[{"type":"direct","tag":"direct"}]}' >"$TEST_ROOT/etc/sing-box/config.json"
printf '%s\n' '{"schema":1,"manager_version":"test","server_address":"203.0.113.10"}' >"$TEST_ROOT/etc/sing-box/manager.json"

export PATH="$TEST_ROOT/bin:$PATH"
export SB_PATH=$PATH
export FW_LOG=$TEST_ROOT/iptables.log
export SB_HOME=$TEST_ROOT/etc/sing-box
export SB_LIB_DIR=$REPO_DIR/lib
export SB_LOCK_FILE=$TEST_ROOT/manager.lock
export SB_FORWARD_SYNC_LOCK=$TEST_ROOT/forward.lock
export SB_FORWARD_SYSCTL_FILE=$TEST_ROOT/sysctl.d/99-sb-forward.conf
export SB_FORWARD_SKIP_SCHEDULER=1

run_sb() { sh "$REPO_DIR/sb" "$@"; }

run_sb forward add --name dynamic-test --listen-port 30009 --target-host target.example --target-port 30009 --protocol both >/dev/null
config=$SB_HOME/forwards/dynamic-test.json
[ -f "$config" ]
[ "$(jq -r '.resolved_ip' "$config")" = 198.51.100.42 ]
grep -Fq -- '-p tcp --dport 30009 -j DNAT --to-destination 198.51.100.42:30009' "$FW_LOG"
grep -Fq -- '-p udp --dport 30009 -j DNAT --to-destination 198.51.100.42:30009' "$FW_LOG"
grep -Fq -- '-d 198.51.100.42 --dport 30009 -j MASQUERADE' "$FW_LOG"
[ "$(cat "$SB_FORWARD_SYSCTL_FILE")" = 'net.ipv4.ip_forward=1' ]

: >"$FW_LOG"
FW_DNS_IP=198.51.100.77 run_sb forward sync --quiet
[ "$(jq -r '.resolved_ip' "$config")" = 198.51.100.77 ]
grep -Fq -- '--to-destination 198.51.100.77:30009' "$FW_LOG"

FW_DNS_FAIL=1 run_sb forward sync --quiet
[ "$(jq -r '.resolved_ip' "$config")" = 198.51.100.77 ]

run_sb forward disable dynamic-test >/dev/null
[ "$(jq -r '.enabled' "$config")" = false ]
run_sb forward enable dynamic-test >/dev/null
[ "$(jq -r '.enabled' "$config")" = true ]
run_sb forward list | grep -Fq 'target.example:30009'
run_sb forward delete dynamic-test >/dev/null
[ ! -f "$config" ]

printf 'Dynamic forwarding integration test passed.\n'