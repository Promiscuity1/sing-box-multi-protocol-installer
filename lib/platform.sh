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
  if [ "$SB_PLATFORM" = alpine ]; then rc-service sb-sing-box status >/dev/null 2>&1; else systemctl is-active --quiet sb-sing-box; fi
}

service_enabled() {
  if [ "$SB_PLATFORM" = alpine ]; then
    rc-update show default | grep -Eq '^[[:space:]]*sb-sing-box([[:space:]]|$)'
  else
    systemctl is-enabled --quiet sb-sing-box
  fi
}

service_start() {
  if [ "$SB_PLATFORM" = alpine ]; then rc-service sb-sing-box start; else systemctl start sb-sing-box; fi
}

service_stop() {
  if [ "$SB_PLATFORM" = alpine ]; then rc-service sb-sing-box stop; else systemctl stop sb-sing-box; fi
}

service_restart() {
  if [ "$SB_PLATFORM" = alpine ]; then rc-service sb-sing-box restart; else systemctl restart sb-sing-box; fi
}

service_enable() {
  if [ "$SB_PLATFORM" = alpine ]; then rc-update add sb-sing-box default; else systemctl enable sb-sing-box; fi
}

service_disable() {
  if [ "$SB_PLATFORM" = alpine ]; then rc-update del sb-sing-box default; else systemctl disable sb-sing-box; fi
}

service_status() {
  if [ "$SB_PLATFORM" = alpine ]; then
    rc-service sb-sing-box status
  else
    systemctl status sb-sing-box --no-pager
  fi
}

service_logs() {
  if [ "$SB_PLATFORM" = alpine ]; then
    tail -n "${1:-100}" /var/log/sing-box.log 2>/dev/null || say 'No sing-box log file found.'
  else
    journalctl -u sb-sing-box -n "${1:-100}" --no-pager
  fi
}
