#!/usr/bin/env bash
# ----------------------------------------------------------
# keepalived-setup.sh — VIP between haproxy1/haproxy2
# Argument: $1 = node shortname (haproxy1|haproxy2)
# Reads VIP / peer IPs / credentials from ../vagrant-configs/cluster.conf.
# ----------------------------------------------------------
set -euo pipefail

CONF="$(cd "$(dirname "$0")" && pwd)/cluster.conf"
# shellcheck disable=SC1090
. "${CONF}"

NODE="${1:-haproxy1}"
case "$NODE" in
  haproxy1)
    STATE="MASTER"
    PRIO="${KEEPALIVED_PRIORITY_MASTER}"
    IP_VAR="NODE_IP_haproxy1"
    PEER_VAR="NODE_IP_haproxy2"
    ;;
  haproxy2)
    STATE="BACKUP"
    PRIO="${KEEPALIVED_PRIORITY_BACKUP}"
    IP_VAR="NODE_IP_haproxy2"
    PEER_VAR="NODE_IP_haproxy1"
    ;;
  *) echo "keepalived-setup.sh: unknown node $NODE"; exit 1 ;;
esac
IP="${!IP_VAR}"
PEER="${!PEER_VAR}"

echo "==== keepalived-setup.sh on ${NODE} (${IP}) state=${STATE} peer=${PEER} ===="

dnf install -y keepalived

# Health check
cat > /etc/keepalived/check_haproxy.sh <<'EOF'
#!/bin/bash
if pgrep -x haproxy > /dev/null; then
    exit 0
else
    systemctl start haproxy
    sleep 2
    pgrep -x haproxy > /dev/null && exit 0 || exit 1
fi
EOF
chmod +x /etc/keepalived/check_haproxy.sh

# Detect private NIC (typically enp0s8 or eth1 on AlmaLinux 9)
NIC="$(ip -br link | awk '$2=="UP"{print $1}' | grep -v lo | sort | tail -n1)"
echo "Detected NIC for VIP: ${NIC}"

cat > /etc/keepalived/keepalived.conf <<EOF
vrrp_script check_haproxy {
    script "/etc/keepalived/check_haproxy.sh"
    interval 2
    weight  -20
    fall     3
    rise     2
}

vrrp_instance PG_VIP {
    state ${STATE}
    interface ${NIC}
    virtual_router_id ${KEEPALIVED_ROUTER_ID}
    priority ${PRIO}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${KEEPALIVED_AUTH}
    }
    unicast_src_ip ${IP}
    unicast_peer {
        ${PEER}
    }
    virtual_ipaddress {
        ${VIP_WRITE}/24
    }
    track_script {
        check_haproxy
    }
    notify_master "/bin/echo '${NODE} is MASTER' | logger -t keepalived"
    notify_backup "/bin/echo '${NODE} is BACKUP' | logger -t keepalived"
    notify_fault   "/bin/echo '${NODE} FAULT'       | logger -t keepalived"
}
EOF

systemctl enable --now keepalived
sleep 3
ip addr show "${NIC}" | grep "${VIP_WRITE}" || echo "VIP not yet on ${NIC} (expected if peer is MASTER)"

echo "==== keepalived-setup.sh complete on ${NODE} ===="
