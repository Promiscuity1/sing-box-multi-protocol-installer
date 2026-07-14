#!/bin/sh
set -eu

apt-get update
apt-get install -y --no-install-recommends systemd

mock_systemctl=/usr/local/bin/systemctl
test ! -e "$mock_systemctl"
trap 'rm -f "$mock_systemctl"' EXIT INT TERM
cp /bin/true "$mock_systemctl"
test "$(command -v systemctl)" = "$mock_systemctl"

sh ./install.sh --server-address 203.0.113.10

test "$(stat -c '%U:%G' /etc/sing-box)" = 'root:sing-box'
su -s /bin/sh -c 'test -r /etc/sing-box/config.json && sing-box check -c /etc/sing-box/config.json -C /etc/sing-box/conf.d' sing-box