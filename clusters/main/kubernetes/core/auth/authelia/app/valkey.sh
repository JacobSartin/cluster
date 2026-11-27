#!/bin/sh
set -eu

master_name=authelia
domain=authelia-valkey
name="$(hostname)"
self="${name}.${domain}"
ordinal="${name##*-}"
pods="authelia-valkey-0 authelia-valkey-1 authelia-valkey-2"
export REDISCLI_AUTH="$VALKEY_PASSWORD"

log() {
  echo "valkey.sh: $*" >&2
}

query() {
  host="$1"
  port="$2"
  shift 2
  valkey-cli -h "$host" -p "$port" --raw "$@" 2>/dev/null | head -n 1 || true
}

peers() {
  for pod in $pods; do
    if [ "$pod" != "$name" ]; then
      echo "${pod}.${domain}"
    fi
  done
}

find_primary() {
  for peer in $(peers); do
    if [ "$(query "$peer" 6379 ROLE)" = master ]; then
      echo "$peer"
      return
    fi
  done
}

any_peer_up() {
  for peer in $(peers); do
    if [ "$(query "$peer" 6379 PING)" = PONG ]; then
      return 0
    fi
  done
  return 1
}

server() {
  # Wait for peer promotion before serving an empty dataset.
  deadline=$(($(date +%s) + ordinal * 60))
  while :; do
    primary="$(find_primary)"
    if [ -n "$primary" ]; then
      log "replicating from $primary"
      set -- --replicaof "$primary" 6379
      break
    fi
    if ! any_peer_up && [ "$(date +%s)" -ge "$deadline" ]; then
      log "no other Valkey is running; starting as primary"
      set --
      break
    fi
    sleep 2
  done

  exec valkey-server \
    --port 6379 \
    --dir /data \
    --save "" \
    --appendonly no \
    --requirepass "$VALKEY_PASSWORD" \
    --masterauth "$VALKEY_PASSWORD" \
    --replica-announce-ip "$self" \
    "$@"
}

sentinel() {
  # Preserve Sentinel's rewritten configuration across restarts.
  conf=/data/sentinel.conf
  if [ ! -f "$conf" ]; then
    primary=""
    while [ -z "$primary" ]; do
      if [ "$(query 127.0.0.1 6379 ROLE)" = master ]; then
        primary="$self"
      else
        primary="$(find_primary)"
      fi
      if [ -z "$primary" ]; then
        sleep 2
      fi
    done
    log "monitoring $primary"
    cat >"$conf" <<EOF
port 26379
dir /data
requirepass "$VALKEY_PASSWORD"
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel announce-ip "$self"
sentinel monitor $master_name $primary 6379 2
sentinel auth-pass $master_name "$VALKEY_PASSWORD"
sentinel down-after-milliseconds $master_name 5000
sentinel failover-timeout $master_name 60000
sentinel parallel-syncs $master_name 1
EOF
  fi
  exec valkey-server "$conf" --sentinel
}

info_field() {
  valkey-cli -h "$1" -p 6379 INFO replication 2>/dev/null | tr -d '\r' | sed -n "s/^$2://p"
}

sentinel_primary() {
  for host in 127.0.0.1 $(peers); do
    primary="$(query "$host" 26379 SENTINEL get-master-addr-by-name "$master_name")"
    if [ -n "$primary" ]; then
      echo "$primary"
      return
    fi
  done
}

ready() {
  case "$(info_field 127.0.0.1 role)" in
    master) return 0 ;;
    slave)
      [ "$(info_field 127.0.0.1 master_link_status)" = up ] &&
        [ "$(info_field 127.0.0.1 master_host)" = "$(sentinel_primary)" ]
      return
      ;;
  esac
  return 1
}

replicas_settled() {
  known="$(valkey-cli -h "$1" -p 26379 --raw SENTINEL REPLICAS "$master_name" 2>/dev/null |
    awk 'NR % 2 == 1 { key = $0; next } key == "ip" { ip = $0 } key == "flags" { print ip " " $0 }')"
  for peer in $(peers); do
    if [ "$(query "$peer" 6379 PING)" != PONG ]; then
      continue
    fi
    if [ "$(info_field "$peer" master_host)" != "$self" ] ||
      [ "$(info_field "$peer" master_link_status)" != up ] ||
      ! echo "$known" | grep -qx "$peer slave"; then
      return 1
    fi
  done
}

replicas_caught_up() {
  offset="$(info_field 127.0.0.1 master_repl_offset)"
  lagging="$(valkey-cli -h 127.0.0.1 -p 6379 INFO replication 2>/dev/null | tr -d '\r' |
    grep '^slave[0-9]*:' | grep -v "offset=${offset}," || true)"
  [ -z "$lagging" ]
}

# Forced failover requires replicas to catch up first.
pre_stop() {
  if [ "$(query 127.0.0.1 6379 ROLE)" != master ]; then
    return 0
  fi
  sentinel=""
  for peer in $(peers); do
    if [ "$(query "$peer" 26379 PING)" = PONG ]; then
      sentinel="$peer"
      break
    fi
  done
  if [ -z "$sentinel" ]; then
    log "no peer Sentinel is running; stopping as primary"
    return 0
  fi

  i=0
  until replicas_settled "$sentinel"; do
    if [ "$i" -ge 20 ]; then
      log "replicas did not settle; stopping as primary and leaving failover to the Sentinels"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done

  valkey-cli -h 127.0.0.1 -p 6379 CLIENT PAUSE 15000 WRITE >/dev/null
  i=0
  until replicas_caught_up; do
    if [ "$i" -ge 50 ]; then
      log "replicas did not catch up; stopping as primary and leaving failover to the Sentinels"
      valkey-cli -h 127.0.0.1 -p 6379 CLIENT UNPAUSE >/dev/null
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done

  if [ "$(query "$sentinel" 26379 SENTINEL FAILOVER "$master_name")" != OK ]; then
    log "$sentinel refused the failover; stopping as primary"
    valkey-cli -h 127.0.0.1 -p 6379 CLIENT UNPAUSE >/dev/null
    return 0
  fi
  log "failover started by $sentinel"
  i=0
  while [ "$i" -lt 15 ] && [ "$(query 127.0.0.1 6379 ROLE)" = master ]; do
    sleep 1
    i=$((i + 1))
  done
  valkey-cli -h 127.0.0.1 -p 6379 CLIENT UNPAUSE >/dev/null
}

case "${1:-}" in
  server) server ;;
  sentinel) sentinel ;;
  ready) ready ;;
  pre-stop) pre_stop ;;
  *)
    echo "usage: $0 server|sentinel|ready|pre-stop" >&2
    exit 2
    ;;
esac
