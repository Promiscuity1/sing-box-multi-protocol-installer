#!/bin/sh

detect_platform() {
  [ -r /etc/os-release ] || die 'cannot identify operating system'
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    alpine) SB_PLATFORM=alpine ;;
    debian|ubuntu) SB_PLATFORM=systemd ;;
    *) die 'supported systems: Alpine, Debian, Ubuntu' ;;
  esac
}

service_active() {
  if [ "$SB_PLATFORM" = alpine ]; then rc-service sb-sing-box status 9>&- >/dev/null 2>&1; else systemctl is-active --quiet sb-sing-box 9>&-; fi
}

service_enabled() {
  if [ "$SB_PLATFORM" = alpine ]; then
    rc-update show default 9>&- | grep -Eq '^[[:space:]]*sb-sing-box([[:space:]]|$)'
  else
    systemctl is-enabled --quiet sb-sing-box 9>&-
  fi
}

service_start() {
  if [ "$SB_PLATFORM" = alpine ]; then rc-service sb-sing-box start 9>&-; else systemctl start sb-sing-box 9>&-; fi
}

service_stop() {
  if [ "$SB_PLATFORM" = alpine ]; then rc-service sb-sing-box stop 9>&-; else systemctl stop sb-sing-box 9>&-; fi
}

service_restart() {
  if [ "$SB_PLATFORM" = alpine ]; then rc-service sb-sing-box restart 9>&-; else systemctl restart sb-sing-box 9>&-; fi
}

service_enable() {
  if [ "$SB_PLATFORM" = alpine ]; then rc-update add sb-sing-box default 9>&-; else systemctl enable sb-sing-box 9>&-; fi
}

service_disable() {
  if [ "$SB_PLATFORM" = alpine ]; then rc-update del sb-sing-box default 9>&-; else systemctl disable sb-sing-box 9>&-; fi
}

service_status() {
  if [ "$SB_PLATFORM" = alpine ]; then
    rc-service sb-sing-box status 9>&-
  else
    systemctl status sb-sing-box --no-pager 9>&-
  fi
}

service_logs() {
  if [ "$SB_PLATFORM" = alpine ]; then
    tail -n "${1:-100}" /var/log/sing-box.log 2>/dev/null || say 'No sing-box log file found.'
  else
    journalctl -u sb-sing-box -n "${1:-100}" --no-pager
  fi
}
