#!/usr/bin/env bash
# ----------------------------------------------------------
# cluster-deploy.sh — runs on the macOS host.
# Boots the 6-node Patroni HA cluster from scratch.
#
# What this deploys:
#   * 6 PostgreSQL 16 + Patroni nodes (postnode1..postnode6)
#   * 3-node etcd cluster (postnode1..postnode3)
#   * 2-node HAProxy set (haproxy1, haproxy2)
#   * Keepalived VIP (defined in cluster.conf -> VIP_WRITE)
#     -> pghaproxy1 MASTER / pghaproxy2 BACKUP
#
# Idempotent: safe to re-run after partial failures.
# Fresh-from-scratch: combine with `bash teardown.sh` first.
#
# Sequence mirrors the working manual procedure from the session:
#   1) vagrant up                                  (boots all 8 VMs)
#   2) wait for SSH                                (avoids upload races)
#   3) upload provisioner scripts
#   4) common-setup.sh on every node               (deps, /etc/hosts, sysctl, SELinux)
#   5) etcd-setup.sh on ETCD_NODES                 (fresh 3-member etcd cluster)
#   6) etcd cluster health check                   (quorum before Patroni)
#   7) pg-setup.sh on DB_NODES                     (first DB_NODE bootstraps; rest rejoin)
#   8) haproxy-setup.sh on LB_VMS                  (TCP VIP_PORT_WRITE=write, VIP_PORT_READ=read)
#   9) keepalived-setup.sh on LB_VMS               (VIP_WRITE -> MASTER/BACKUP)
#  10) cluster status
# ----------------------------------------------------------
set -euo pipefail

# Source cluster.conf — single source of truth for IPs, hostnames, ports.
CONF="$(cd "$(dirname "$0")" && pwd)/cluster.conf"
# shellcheck disable=SC1090
. "${CONF}"

# Anchor everything to the script's directory (the vagrant-configs/ folder).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# DB_NODES, LB_VMS, ETCD_NODES, NODE_IP_<n>, VIP_*, ETCD_ENDPOINTS, etc.
# come from cluster.conf.

# Mapping from Vagrant VM name -> internal hostname (for /etc/hosts).
# Implemented as a lookup function for bash 3.2 (macOS default) compatibility
# because `declare -A` requires bash 4+.
host_for() {
  case "$1" in
    haproxy1) echo "${NODE_HOST_haproxy1:-pghaproxy1}" ;;
    haproxy2) echo "${NODE_HOST_haproxy2:-pghaproxy2}" ;;
    *)        echo "$1" ;;
  esac
}

upload() {
  local node="$1" src="$2"
  echo "  → upload $src -> $node:/tmp/"
  vagrant upload "$src" "/tmp/" "$node" >/dev/null
}

run_on() {
  local node="$1" cmd="$2"
  echo "  → $node: $cmd"
  vagrant ssh "$node" -c "sudo bash -c '$cmd'"
}

# ----------------------------------------------------------------
# 1) vagrant up
# ----------------------------------------------------------------
echo "==== 1) vagrant up ===="
vagrant up

# ----------------------------------------------------------------
# 2) wait for SSH on every node (avoids upload races)
# ----------------------------------------------------------------
echo
echo "==== 2) wait for SSH on every node ===="
for n in "${DB_NODES[@]}" "${LB_VMS[@]}"; do
  for i in $(seq 1 60); do
    if vagrant ssh "$n" -c 'true' >/dev/null 2>&1; then
      echo "  $n: reachable"
      break
    fi
    sleep 2
    if [ "$i" = "60" ]; then
      echo "  $n: NOT reachable after 120s — aborting" >&2
      exit 1
    fi
  done
done

# ----------------------------------------------------------------
# 3) upload provisioner scripts
# ----------------------------------------------------------------
echo
echo "==== 3) copy provisioner scripts to every node ===="
for n in "${DB_NODES[@]}" "${LB_VMS[@]}"; do
  for f in common-setup.sh etcd-setup.sh pg-setup.sh haproxy-setup.sh keepalived-setup.sh; do
    upload "$n" "$SCRIPT_DIR/$f"
  done
done

# ----------------------------------------------------------------
# 4) common-setup.sh on every node
# ----------------------------------------------------------------
echo
echo "==== 4) common-setup on all nodes ===="
for n in "${DB_NODES[@]}" "${LB_VMS[@]}"; do
  HN="$(host_for "$n")"
  run_on "$n" "bash /tmp/common-setup.sh $HN"
done

# ----------------------------------------------------------------
# 5) etcd on postnode1/2/3
#    Each node wipes its data dir if not healthy, so the cluster forms
#    fresh from --initial-cluster-state=new.
# ----------------------------------------------------------------
echo
echo "==== 5) etcd on postnode1/2/3 ===="
for n in "${ETCD_NODES[@]}"; do
  run_on "$n" "bash /tmp/etcd-setup.sh $n"
  sleep 5
done

# Use the first etcd node as the probe target.
ETCD_PROBE="${ETCD_NODES[0]}"
ETCD_PROBE_IP_VAR="NODE_IP_${ETCD_PROBE}"
ETCD_PROBE_IP="${!ETCD_PROBE_IP_VAR}"

# Build the etcd endpoint list (http://ip:2379,...) from cluster.conf.
ETCDCTL_ENDPOINTS=""
for n in "${ETCD_NODES[@]}"; do
  ip_var="NODE_IP_${n}"
  ETCDCTL_ENDPOINTS="${ETCDCTL_ENDPOINTS}http://${!ip_var}:2379,"
done
ETCDCTL_ENDPOINTS="${ETCDCTL_ENDPOINTS%,}"

# Confirm etcd quorum BEFORE moving on to Patroni.
echo
echo "==== 6) etcd cluster health check ===="
for i in $(seq 1 30); do
  if run_on "${ETCD_PROBE}" "export PATH=/usr/local/bin:/usr/bin:/bin && /usr/local/bin/etcdctl endpoint health --endpoints=${ETCDCTL_ENDPOINTS}" 2>/dev/null | grep -q "is healthy"; then
    echo "  etcd cluster is healthy"
    break
  fi
  echo "  waiting for etcd quorum (attempt $i/30)..."
  sleep 3
  if [ "$i" = "30" ]; then
    echo "  WARN: etcd cluster not healthy after 90s — Patroni may fail to bootstrap"
  fi
done

# ----------------------------------------------------------------
# 7) pg-setup.sh on all postnodes (in order)
#    postnode1 first so it bootstraps as the initial leader.
#    Nodes 2..6 will auto-wipe their data dir and rejoin.
# ----------------------------------------------------------------
echo
echo "==== 7) postgres+patroni on all postnodes (in order) ===="
# CRITICAL: postnode1 must bootstrap as the initial leader, and nodes 2..6 must
# see a healthy leader on postnode1 before they join. pg-setup.sh wipes the
# local data dir, then `systemctl enable --now patroni` triggers an initdb.
# For postnode1 that initdb is the cluster bootstrap (no leader key in etcd);
# for nodes 2..6 the same initdb is local-only and the replica is registered
# via Patroni's DCS once a leader key exists.
for n in "${DB_NODES[@]}"; do
  echo "  provisioning ${n}..."
  run_on "$n" "bash /tmp/pg-setup.sh $n"
  if [ "$n" = "postnode1" ]; then
    # Give postnode1 extra time to elect itself as the initial leader and
    # initialize the cluster. Subsequent nodes will not bootstrap successfully
    # if postnode1 hasn't claimed the leader lock yet.
    echo "  waiting for postnode1 to acquire the leader lock..."
    for i in $(seq 1 30); do
      if vagrant ssh postnode1 -c "sudo /usr/local/bin/patronictl -c /etc/patroni/patroni.yml list 2>/dev/null" | grep -q "Leader"; then
        echo "  postnode1 is Leader"
        break
      fi
      sleep 3
      if [ "$i" = "30" ]; then
        echo "  WARN: postnode1 did not become Leader within 90s — replicas may fail to register"
      fi
    done
  else
    sleep 5
  fi
done

# ----------------------------------------------------------------
# 8) haproxy on haproxy1/2
# ----------------------------------------------------------------
echo
echo "==== 8) haproxy on haproxy1/2 ===="
for n in "${LB_VMS[@]}"; do
  run_on "$n" "bash /tmp/haproxy-setup.sh"
done

# ----------------------------------------------------------------
# 9) keepalived on haproxy1/2 (haproxy1 first as MASTER)
# ----------------------------------------------------------------
echo
echo "==== 9) keepalived on haproxy1/2 (haproxy1 first as MASTER) ===="
run_on haproxy1 "bash /tmp/keepalived-setup.sh haproxy1"
sleep 5
run_on haproxy2 "bash /tmp/keepalived-setup.sh haproxy2"
sleep 5

# ----------------------------------------------------------------
# 10) cluster status
# ----------------------------------------------------------------
echo
echo "==== 10) cluster status ===="
vagrant ssh postnode1 -- sudo /usr/local/bin/patronictl -c /etc/patroni/patroni.yml list 2>&1 | sed 's/^/  /' || true
echo
echo "  VIP check from host:"
if /usr/bin/nc -z -w 2 "${VIP_WRITE}" "${VIP_PORT_WRITE}" 2>/dev/null; then
  echo "    ${VIP_WRITE}:${VIP_PORT_WRITE} (write) -> reachable"
else
  echo "    ${VIP_WRITE}:${VIP_PORT_WRITE} (write) -> NOT reachable (VIP may still be transitioning)"
fi
if /usr/bin/nc -z -w 2 "${VIP_READ}" "${VIP_PORT_READ}" 2>/dev/null; then
  echo "    ${VIP_READ}:${VIP_PORT_READ} (read)  -> reachable"
else
  echo "    ${VIP_READ}:${VIP_PORT_READ} (read)  -> NOT reachable (VIP may still be transitioning)"
fi

echo
echo "================================================================"
echo "  DEPLOY COMPLETE"
echo "  Connect via:  PGPASSWORD='${PG_ADMIN_PASSWORD}' /usr/local/opt/postgresql@16/bin/psql -h ${VIP_WRITE} -p ${VIP_PORT_WRITE} -U ${PG_ADMIN_USER} -d ${PG_DATABASE}"
echo "================================================================"
