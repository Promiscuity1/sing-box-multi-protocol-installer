#!/bin/sh
set -eu

mock_dir=$(mktemp -d /root/sb-systemctl.XXXXXX)
trap 'rm -rf "$mock_dir"' EXIT INT TERM
cp /bin/true "$mock_dir/systemctl"
apt-get update
apt-get install -y --no-install-recommends systemd

PATH="$mock_dir:$PATH" sh ./install.sh --server-address 203.0.113.10

test "$(stat -c '%U:%G' /etc/sing-box)" = 'root:sing-box'
su -s /bin/sh -c 'test -r /etc/sing-box/config.json && sing-box check -c /etc/sing-box/config.json -C /etc/sing-box/conf.d' sing-box