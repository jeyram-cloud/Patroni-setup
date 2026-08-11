#!/usr/bin/env bash
# ----------------------------------------------------------
# haproxy-setup.sh — installs HAProxy on haproxy1/haproxy2
# No arguments — both nodes get the same backend set.
# Backend list is built from ../vagrant-configs/cluster.conf.
# ----------------------------------------------------------
set -euo pipefail

CONF="/tmp/cluster.conf"
# shellcheck disable=SC1090
. "${CONF}"

echo "==== haproxy-setup.sh on $(hostname) ===="

dnf install -y haproxy

# Build "server <name> <ip>:5432 maxconn 300 check port 8008" lines.
BACKEND_SERVERS=""
for n in "${DB_NODES[@]}"; do
  ip_var="NODE_IP_${n}"
  eval "_ip=\"\${${ip_var}:-}\""
  BACKEND_SERVERS="${BACKEND_SERVERS}    server ${n} ${_ip}:${PG_LISTEN_PORT} maxconn 300 check port 8008
"
done

cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log         127.0.0.1 local2
    chroot      /var/lib/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     4000
    user        haproxy
    group       haproxy
    daemon
    stats socket /var/lib/haproxy/stats

defaults
    mode                    tcp
    log                     global
    option                  tcplog
    option                  dontlognull
    retries                 3
    timeout connect         10s
    timeout client          1m
    timeout server          1m

frontend pg_write_front
    bind *:${VIP_PORT_WRITE}
    default_backend pg_write_back

frontend pg_read_front
    bind *:${VIP_PORT_READ}
    default_backend pg_read_back

backend pg_write_back
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
${BACKEND_SERVERS}
backend pg_read_back
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
${BACKEND_SERVERS}
listen stats
    bind *:8080
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats realm HAProxy\\ Statistics
    stats auth ${HAPROXY_STATS_USER}:${HAPROXY_STATS_PASSWORD}
EOF

systemctl enable --now haproxy
systemctl status haproxy --no-pager

echo "==== haproxy-setup.sh complete ===="
