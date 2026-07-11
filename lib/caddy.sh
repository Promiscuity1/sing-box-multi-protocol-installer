#!/bin/sh

CADDY_DIR=/etc/caddy
CADDY_FILE=$CADDY_DIR/Caddyfile
CADDY_SB_FILE=$CADDY_DIR/sb-managed.caddy

caddy_install() {
  if command -v caddy >/dev/null 2>&1; then return; fi
  if [ "$SB_PLATFORM" = alpine ]; then
    apk add --no-cache caddy
  else
    apt-get update
    apt-get install -y --no-install-recommends caddy
  fi
}

caddy_sync() {
  caddy_nodes=$(for meta in "$SB_NODE_DIR"/*.json; do [ -f "$meta" ] || continue; jq -e 'select(.enabled != false and .tls.mode == "caddy")' "$meta" >/dev/null 2>&1 && printf '%s\n' "$meta"; done)
  if [ -z "$caddy_nodes" ]; then
    [ ! -f "$CADDY_SB_FILE" ] || { rm -f "$CADDY_SB_FILE"; command -v caddy >/dev/null 2>&1 && caddy reload --config "$CADDY_FILE" >/dev/null 2>&1 || true; }
    return
  fi
  caddy_install
  install -d -m 0755 "$CADDY_DIR"
  [ -f "$CADDY_FILE" ] || : >"$CADDY_FILE"
  grep -Fq 'import /etc/caddy/sb-managed.caddy' "$CADDY_FILE" || printf '\nimport /etc/caddy/sb-managed.caddy\n' >>"$CADDY_FILE"
  tmp=$(mktemp /tmp/sb-caddy.XXXXXX)
  domains=$(printf '%s\n' "$caddy_nodes" | while read -r meta; do jq -r '.public.address' "$meta"; done | sort -u)
  for domain in $domains; do
    printf '%s {\n' "$domain" >>"$tmp"
    printf '%s\n' "$caddy_nodes" | while read -r meta; do
      [ "$(jq -r '.public.address' "$meta")" = "$domain" ] || continue
      name=$(jq -r '.name' "$meta")
      path=$(jq -r '.transport.path' "$meta")
      port=$(jq -r '.listen.port' "$meta")
      transport=$(jq -r '.transport.type' "$meta")
      printf '    @%s path %s*\n' "$name" "$path" >>"$tmp"
      if [ "$transport" = h2 ] || [ "$transport" = http ]; then
        printf '    reverse_proxy @%s h2c://127.0.0.1:%s\n' "$name" "$port" >>"$tmp"
      else
        printf '    reverse_proxy @%s 127.0.0.1:%s\n' "$name" "$port" >>"$tmp"
      fi
    done
    printf '}\n\n' >>"$tmp"
  done
  install -m 0644 "$tmp" "$CADDY_SB_FILE"
  rm -f "$tmp"
  caddy validate --config "$CADDY_FILE"
  if [ "$SB_PLATFORM" = alpine ]; then rc-update add caddy default; rc-service caddy restart || rc-service caddy start; else systemctl enable --now caddy; systemctl reload caddy; fi
}

caddy_status() {
  command -v caddy >/dev/null 2>&1 || { say 'Caddy is not installed.'; return; }
  if [ "$SB_PLATFORM" = alpine ]; then rc-service caddy status; else systemctl status caddy --no-pager; fi
}

caddy_logs() {
  if [ "$SB_PLATFORM" = alpine ]; then tail -n "${1:-100}" /var/log/caddy.log 2>/dev/null || true; else journalctl -u caddy -n "${1:-100}" --no-pager; fi
}
