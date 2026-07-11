#!/bin/sh

command_migrate() {
  [ "$#" -ge 1 ] || die 'usage: sb migrate CONFIG --public-address HOST [options]'
  mg_source=$1; shift
  [ -r "$mg_source" ] || die 'migration source is not readable'
  mg_public_address=$(manager_server_address); mg_public_port=; mg_name=; mg_reality_public=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --public-address) [ "$#" -ge 2 ] || die '--public-address requires a value'; mg_public_address=$2; shift 2 ;;
      --public-port) [ "$#" -ge 2 ] || die '--public-port requires a value'; mg_public_port=$2; shift 2 ;;
      --name) [ "$#" -ge 2 ] || die '--name requires a value'; mg_name=$2; shift 2 ;;
      --reality-public-key) [ "$#" -ge 2 ] || die '--reality-public-key requires a value'; mg_reality_public=$2; shift 2 ;;
      *) die "unknown migrate option: $1" ;;
    esac
  done
  jq -e '.inbounds | length >= 1' "$mg_source" >/dev/null || die 'source has no inbound'
  mg_type=$(jq -r '.inbounds[0].type' "$mg_source")
  mg_listen=$(jq -r '.inbounds[0].listen // "0.0.0.0"' "$mg_source")
  mg_port=$(jq -r '.inbounds[0].listen_port' "$mg_source")
  [ -n "$mg_public_port" ] || mg_public_port=$mg_port
  case "$mg_type" in anytls) mg_protocol=anytls ;; shadowsocks) mg_protocol=ss2022 ;; socks) mg_protocol=socks5 ;; vless) mg_protocol=vless-reality ;; *) die "unsupported legacy inbound: $mg_type" ;; esac
  [ -n "$mg_name" ] || mg_name="migrated-$mg_protocol-$mg_port"
  validate_name "$mg_name" || die 'invalid migrated node name'
  node_exists "$mg_name" && die 'target node already exists'
  mg_work=$(mktemp -d /tmp/sb-migrate.XXXXXX); mg_meta=$mg_work/meta.json; mg_config=$mg_work/config.json; mg_certs=$mg_work/certs; mg_now=$(timestamp)
  case "$mg_protocol" in
    anytls)
      mg_user=$(jq -r '.inbounds[0].users[0].name // "default"' "$mg_source"); mg_password=$(jq -r '.inbounds[0].users[0].password' "$mg_source")
      mg_cert=$(jq -r '.inbounds[0].tls.certificate_path' "$mg_source"); mg_key=$(jq -r '.inbounds[0].tls.key_path' "$mg_source")
      [ -r "$mg_cert" ] && [ -r "$mg_key" ] || die 'legacy AnyTLS certificate/key cannot be read'
      install -d -m 0700 "$mg_certs"; install -m 0644 "$mg_cert" "$mg_certs/cert.pem"; install -m 0640 "$mg_key" "$mg_certs/key.pem"
      jq -n --arg name "$mg_name" --arg address "$mg_listen" --argjson port "$mg_port" --arg public "$mg_public_address" --argjson public_port "$mg_public_port" --arg user "$mg_user" --arg password "$mg_password" --arg now "$mg_now" \
        '{schema:1,name:$name,protocol:"anytls",enabled:true,listen:{address:$address,port:$port,transports:["tcp"]},public:{address:$public,port:$public_port},credentials:{username:$user,password:$password},tls:{mode:"self-signed",insecure:true},created_at:$now,updated_at:$now}' >"$mg_meta"
      ;;
    ss2022)
      mg_method=$(jq -r '.inbounds[0].method' "$mg_source"); mg_password=$(jq -r '.inbounds[0].password' "$mg_source")
      jq -n --arg name "$mg_name" --arg address "$mg_listen" --argjson port "$mg_port" --arg public "$mg_public_address" --argjson public_port "$mg_public_port" --arg method "$mg_method" --arg password "$mg_password" --arg now "$mg_now" \
        '{schema:1,name:$name,protocol:"ss2022",enabled:true,listen:{address:$address,port:$port,transports:["tcp","udp"]},public:{address:$public,port:$public_port},credentials:{method:$method,password:$password},created_at:$now,updated_at:$now}' >"$mg_meta"
      ;;
    socks5)
      mg_user=$(jq -r '.inbounds[0].users[0].username' "$mg_source"); mg_password=$(jq -r '.inbounds[0].users[0].password' "$mg_source")
      jq -n --arg name "$mg_name" --arg address "$mg_listen" --argjson port "$mg_port" --arg public "$mg_public_address" --argjson public_port "$mg_public_port" --arg user "$mg_user" --arg password "$mg_password" --arg now "$mg_now" \
        '{schema:1,name:$name,protocol:"socks5",enabled:true,listen:{address:$address,port:$port,transports:["tcp","udp"]},public:{address:$public,port:$public_port},credentials:{username:$user,password:$password},created_at:$now,updated_at:$now}' >"$mg_meta"
      ;;
    vless-reality)
      [ -n "$mg_reality_public" ] || die '--reality-public-key is required for legacy VLESS REALITY migration'
      mg_user=$(jq -r '.inbounds[0].users[0].name // "default"' "$mg_source"); mg_uuid=$(jq -r '.inbounds[0].users[0].uuid' "$mg_source")
      mg_server=$(jq -r '.inbounds[0].tls.reality.handshake.server' "$mg_source"); mg_server_port=$(jq -r '.inbounds[0].tls.reality.handshake.server_port' "$mg_source")
      mg_private=$(jq -r '.inbounds[0].tls.reality.private_key' "$mg_source"); mg_short=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$mg_source")
      jq -n --arg name "$mg_name" --arg address "$mg_listen" --argjson port "$mg_port" --arg public "$mg_public_address" --argjson public_port "$mg_public_port" --arg user "$mg_user" --arg uuid "$mg_uuid" --arg server "$mg_server" --argjson server_port "$mg_server_port" --arg private "$mg_private" --arg public_key "$mg_reality_public" --arg short "$mg_short" --arg now "$mg_now" \
        '{schema:1,name:$name,protocol:"vless-reality",enabled:true,listen:{address:$address,port:$port,transports:["tcp"]},public:{address:$public,port:$public_port},credentials:{username:$user,uuid:$uuid},reality:{server:$server,port:$server_port,private_key:$private,public_key:$public_key,short_id:$short},created_at:$now,updated_at:$now}' >"$mg_meta"
      ;;
  esac
  protocol_render "$mg_meta" "$mg_config"
  commit_node_change "$mg_name" "$mg_config" "$mg_meta" "$mg_certs" migrate
  rm -rf "$mg_work"
  info "Migrated node: $mg_name"
}
