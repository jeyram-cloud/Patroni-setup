#!/usr/bin/env bash
# ----------------------------------------------------------
# run-all.sh — runs every *.sh script in this directory (vagrant-configs/)
# in a fixed order, from a single command.
#
# Order:
#   1) teardown.sh                            (only if --teardown is passed)
#   2) cluster-deploy.sh                      (vagrant up + provisioning)
#   3) common-setup.sh <node>                 (per-node dependency setup)
#   4) etcd-setup.sh <postnode1|postnode2|postnode3>
#   5) pg-setup.sh <postnode1..postnode6>
#   6) haproxy-setup.sh                       (haproxy1 + haproxy2)
#   7) keepalived-setup.sh <haproxy1|haproxy2>
#
# USAGE
#   ./run-all.sh                  normal full deploy (idempotent)
#   ./run-all.sh --teardown       teardown + redeploy from scratch
#   ./run-all.sh --steps 1 3 5    run only specific steps (comma list also ok)
#   ./run-all.sh --list           list the steps and what they do
#   ./run-all.sh --help           full help
# ----------------------------------------------------------
set -euo pipefail

# Source cluster.conf — single source of truth for IPs, hostnames, ports.
CONF="$(cd "$(dirname "$0")" && pwd)/cluster.conf"
# shellcheck disable=SC1090
. "${CONF}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DO_TEARDOWN=0
STEPS_ARG=""

usage() {
  cat <<EOF
run-all.sh — run every provisioner script in vagrant-configs/ in order

USAGE
  ./run-all.sh                     full deploy (~25 min, idempotent)
  ./run-all.sh --teardown          teardown.sh + then full deploy
  ./run-all.sh --steps 1,3,5       run only specific steps (comma-separated)
  ./run-all.sh --list              list the steps and what they do
  ./run-all.sh --help              this help

STEPS
  1) cluster-deploy.sh         vagrant up + run all provisioners
  2) common-setup.sh <node>    per-node deps + /etc/hosts + sysctl
  3) etcd-setup.sh <node>      3-member etcd cluster (postnode1..3)
  4) pg-setup.sh <node>        PostgreSQL 16 + Patroni (postnode1..6)
  5) haproxy-setup.sh          HAProxy on haproxy1/2
  6) keepalived-setup.sh <n>   Keepalived VIP on haproxy1/2

DEFAULT CREDENTIALS (handed off from setup scripts)
  ${PG_SUPERUSER} / ${PG_SUPERUSER_PASSWORD}       PostgreSQL superuser
  ${PG_ADMIN_USER} / ${PG_ADMIN_PASSWORD}          PostgreSQL admin (post-bootstrap)
  ${PG_REPL_USER} / ${PG_REPL_PASSWORD}            replication user
  ${HAPROXY_STATS_USER} / ${HAPROXY_STATS_PASSWORD} HAProxy stats
  ${KEEPALIVED_AUTH}                                keepalived shared auth

CONNECT
  ${VIP_WRITE}:${VIP_PORT_WRITE}  write    -> current Patroni leader
  ${VIP_READ}:${VIP_PORT_READ}    read     -> round-robin over replicas
EOF
}

list_steps() {
  printf '%-3s %-30s %s\n' ID STEP-NAME DESCRIPTION
  printf '%-3s %-30s %s\n' "1)" "cluster-deploy.sh" "vagrant up + run all provisioners"
  printf '%-3s %-30s %s\n' "2)" "common-setup.sh"   "per-node deps, /etc/hosts, sysctl, SELinux"
  printf '%-3s %-30s %s\n' "3)" "etcd-setup.sh"     "3-member etcd cluster on postnode1..3"
  printf '%-3s %-30s %s\n' "4)" "pg-setup.sh"       "PostgreSQL 16 + Patroni on postnode1..6"
  printf '%-3s %-30s %s\n' "5)" "haproxy-setup.sh"  "HAProxy on haproxy1/2"
  printf '%-3s %-30s %s\n' "6)" "keepalived-setup.sh" "Keepalived VIP on haproxy1/2"
}

# ----------------------------------------------------------------
# Parse args
# ----------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --teardown) DO_TEARDOWN=1; shift ;;
    --steps)    STEPS_ARG="${2:-}"; shift 2 ;;
    --list)     list_steps; exit 0 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# Translate "1,3,5" or "1 3 5" into a normalized list of step numbers.
if [ -n "$STEPS_ARG" ]; then
  STEPS="$(echo "$STEPS_ARG" | tr ',' ' ')"
else
  STEPS="1"
fi

want() {
  local n="$1"
  for x in $STEPS; do
    [ "$x" = "$n" ] && return 0
  done
  return 1
}

# ----------------------------------------------------------------
# Pre-flight: cd into the project root so vagrant finds the Vagrantfile.
# ----------------------------------------------------------------
cd "$PROJ_ROOT"

# ----------------------------------------------------------------
# Step 0 (optional): teardown
# ----------------------------------------------------------------
if [ "$DO_TEARDOWN" = "1" ]; then
  echo "==== 0) teardown.sh (--teardown) ===="
  bash "$PROJ_ROOT/teardown.sh"
fi

# ----------------------------------------------------------------
# Step 1: cluster-deploy.sh
# ----------------------------------------------------------------
if want 1; then
  echo "==== 1) cluster-deploy.sh ===="
  bash "$SCRIPT_DIR/cluster-deploy.sh"
fi

# ----------------------------------------------------------------
# Step 2: common-setup.sh on every node
# ----------------------------------------------------------------
if want 2; then
  echo "==== 2) common-setup.sh on every node ===="
  # DB_NODES, LB_VMS come from cluster.conf.
  # bash 3.2 (macOS default) has no associative arrays — use a function.
  host_for() {
    case "$1" in
      haproxy1) echo "${NODE_HOST_haproxy1:-pghaproxy1}" ;;
      haproxy2) echo "${NODE_HOST_haproxy2:-pghaproxy2}" ;;
      *)        echo "$1" ;;
    esac
  }
  for n in "${DB_NODES[@]}" "${LB_VMS[@]}"; do
    HN="$(host_for "$n")"
    vagrant ssh "$n" -c "sudo bash -c 'bash /tmp/common-setup.sh $HN'"
  done
fi

# ----------------------------------------------------------------
# Step 3: etcd-setup.sh on first 3 ETCD_NODES
# ----------------------------------------------------------------
if want 3; then
  echo "==== 3) etcd-setup.sh on ETCD_NODES ===="
  for n in "${ETCD_NODES[@]}"; do
    vagrant ssh "$n" -c "sudo bash -c 'bash /tmp/etcd-setup.sh $n'"
    sleep 5
  done
fi

# ----------------------------------------------------------------
# Step 4: pg-setup.sh on all DB_NODES
# ----------------------------------------------------------------
if want 4; then
  echo "==== 4) pg-setup.sh on all DB_NODES ===="
  for n in "${DB_NODES[@]}"; do
    vagrant ssh "$n" -c "sudo bash -c 'bash /tmp/pg-setup.sh $n'"
    sleep 5
  done
fi

# ----------------------------------------------------------------
# Step 5: haproxy-setup.sh on haproxy1/2
# ----------------------------------------------------------------
if want 5; then
  echo "==== 5) haproxy-setup.sh on haproxy1/2 ===="
  for n in haproxy1 haproxy2; do
    vagrant ssh "$n" -c "sudo bash -c 'bash /tmp/haproxy-setup.sh'"
  done
fi

# ----------------------------------------------------------------
# Step 6: keepalived-setup.sh on haproxy1/2
# ----------------------------------------------------------------
if want 6; then
  echo "==== 6) keepalived-setup.sh on haproxy1/2 ===="
  vagrant ssh haproxy1 -c "sudo bash -c 'bash /tmp/keepalived-setup.sh haproxy1'"
  sleep 5
  vagrant ssh haproxy2 -c "sudo bash -c 'bash /tmp/keepalived-setup.sh haproxy2'"
fi

echo
echo "==== run-all.sh complete ===="
echo "Verify:  vagrant ssh ${PROBE_NODE:-${DB_NODES[0]}} -- sudo /usr/local/bin/patronictl -c /etc/patroni/patroni.yml list"
echo "Connect: PGPASSWORD='${PG_ADMIN_PASSWORD}' psql -h ${VIP_WRITE} -p ${VIP_PORT_WRITE} -U ${PG_ADMIN_USER} -d ${PG_DATABASE}"
