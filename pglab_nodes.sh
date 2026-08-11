#!/usr/bin/env bash
# Control all 6 postnode VMs via pglab CLI.
# - start_cluster: boot VMs + start patroni on every node + force leader election
# - stop_cluster:  stop patroni + halt VMs (state preserved)
# - start_leader:  re-elect a leader from currently running replicas
# - stop_leader:   stop patroni on the current leader (forces failover)
# - start_replica <n>: start patroni on postnode<n> (joins as replica)
# - stop_replica  <n>: stop patroni on postnode<n>
# - status:        show cluster
set -euo pipefail

cd "$(dirname "$0")"

# Source cluster.conf so DB_NODES, LB_VMS, NODE_IP_* are available.
CONF="$(cd "$(dirname "$0")" && pwd)/vagrant-configs/cluster.conf"
# shellcheck disable=SC1090
. "$CONF"

# Verify we're in the right vagrant environment: DB_NODES must be non-empty
# and the first node must look like a valid identifier.
if [ "${#DB_NODES[@]}" -eq 0 ] || [ -z "${DB_NODES[0]:-}" ]; then
  echo "ERROR: cluster.conf has empty DB_NODES." >&2
  echo "       Run this script from the pglab cluster dir." >&2
  exit 1
fi

# DB_NODES, ETCD_NODES come from cluster.conf.
PGLAB=./pglab
VAGRANT_DIR="$(pwd)"

ssh_node() {
  local node="$1"; shift
  ( cd "$VAGRANT_DIR" && vagrant ssh "$node" -c "$*" )
}

running_nodes() {
  for n in "${DB_NODES[@]}"; do
    if $PGLAB status 2>/dev/null | grep -q "^| $n " ; then
      echo "$n"
    fi
  done
}

find_leader() {
  # Role column is the 4th '|'-separated field: "| <member> | <host> | <Role> | <State> | ..."
  # Capture to a temp file to avoid SIGPIPE (141) terminating the calling script
  # under `set -o pipefail` when the producer (./pglab) keeps writing while awk
  # has already exited.
  local _status _out
  _out="$("$PGLAB" status 2>/dev/null || true)"
  printf '%s\n' "$_out" | awk -F'|' '/Leader|Replica/ && NF>=5 {
    role=$4; gsub(/ /,"",role);
    if (role=="Leader") { gsub(/ /,"",$2); print $2; exit(0) }
  }'
}

find_replicas() {
  local _out
  _out="$("$PGLAB" status 2>/dev/null || true)"
  printf '%s\n' "$_out" | awk -F'|' '/Leader|Replica/ && NF>=5 {
    role=$4; gsub(/ /,"",role);
    if (role=="Replica") { gsub(/ /,"",$2); print $2 }
  }' | xargs
}

# Vagrant VM name is just the short name (whatever cluster.conf calls it).
vm_name() {
  echo "$1"
}

# ---------- subcommands ----------

cmd_start_cluster() {
  echo "==> Booting all VMs"
  $PGLAB up

  echo "==> Starting Patroni on all ${#DB_NODES[@]} DB nodes"
  for n in "${DB_NODES[@]}"; do
    ssh_node "$n" "sudo systemctl enable --now patroni" || echo "  ! $n: patroni start failed"
  done

  echo "==> Waiting for cluster to converge"
  sleep 10
  $PGLAB status

  echo "==> Forcing leader election from ${DB_NODES[0]}"
  PROBE="${DB_NODES[0]}"
  ssh_node "$PROBE" "sudo -u postgres patronictl -c /etc/patroni.yml reinit $PROBE --force" || true
  sleep 5
  $PGLAB status
}

cmd_stop_cluster() {
  echo "==> Stopping Patroni on all ${#DB_NODES[@]} DB nodes"
  for n in "${DB_NODES[@]}"; do
    ssh_node "$n" "sudo systemctl stop patroni" 2>/dev/null || true
  done
  echo "==> Halting all VMs (state preserved)"
  $PGLAB down
  $PGLAB status
}

cmd_start_leader() {
  local target="${1:-${DB_NODES[0]}}"
  echo "==> Ensuring VMs are up"
  $PGLAB up

  echo "==> Starting Patroni on $target and waiting for quorum"
  ssh_node "$target" "sudo systemctl enable --now patroni"
  sleep 8
  $PGLAB status

  echo "==> Reinitialising $target as the leader"
  ssh_node "$target" "sudo -u postgres patronictl -c /etc/patroni.yml reinit $target --force"
  sleep 5
  $PGLAB status
}

cmd_stop_leader() {
  local leader
  leader="$(find_leader)"
  if [[ -z "$leader" ]]; then
    echo "!! No leader currently in cluster"
    exit 1
  fi
  echo "==> Current leader: $leader — stopping Patroni (triggers auto-failover)"
  ssh_node "$leader" "sudo systemctl stop patroni"
  sleep 5
  $PGLAB status
}

cmd_start_replica() {
  local n="${1:?usage: start_replica <node>}"
  echo "==> Booting VMs and starting Patroni on $n"
  $PGLAB up
  ssh_node "$n" "sudo systemctl enable --now patroni"
  sleep 6
  $PGLAB status
}

cmd_stop_replica() {
  local n="${1:?usage: stop_replica <node>}"
  echo "==> Stopping Patroni on $n"
  ssh_node "$n" "sudo systemctl stop patroni" || true
  sleep 3
  $PGLAB status
}

cmd_status() {
  $PGLAB status
}

cmd_restart_all() {
  echo "==> Restarting all ${#DB_NODES[@]} DB nodes (stop patroni, start patroni, force leader)"
  for n in "${DB_NODES[@]}"; do
    if ! ssh_node "$n" "sudo systemctl restart patroni" 2>/dev/null; then
      ssh_node "$n" "sudo systemctl enable --now patroni"
    fi
  done
  sleep 8
  $PGLAB status
  echo "==> Re-electing ${DB_NODES[0]} as leader"
  PROBE="${DB_NODES[0]}"
  ssh_node "$PROBE" "sudo -u postgres patronictl -c /etc/patroni.yml reinit $PROBE --force" || true
  sleep 5
  $PGLAB status
}

cmd_wipe_cluster() {
  echo "!! WARNING: this destroys all VMs and host-only networks"
  read -rp "Type 'yes' to continue: " ans
  [[ "$ans" == "yes" ]] || { echo "aborted"; exit 1; }
  echo "==> Stopping patroni on all nodes"
  for n in "${DB_NODES[@]}"; do
    ssh_node "$n" "sudo systemctl stop patroni" 2>/dev/null || true
  done
  echo "==> Tearing down all VMs + networks"
  $PGLAB teardown
  echo "==> Full clean deploy (~25 min)"
  $PGLAB deploy
  $PGLAB status
}

# ---------- dispatch ----------

case "${1:-status}" in
  start_cluster)       cmd_start_cluster ;;
  stop_cluster)        cmd_stop_cluster ;;
  start_leader)        cmd_start_leader "${2:-${DB_NODES[0]}}" ;;
  stop_leader)         cmd_stop_leader ;;
  start_replica)       cmd_start_replica "${2:?need node name}" ;;
  stop_replica)        cmd_stop_replica "${2:?need node name}" ;;
  status)              cmd_status ;;
  restart_all)          cmd_restart_all ;;
  wipe_cluster)         cmd_wipe_cluster ;;
  *)
    cat <<EOF
Usage: $0 <command> [args]
  start_cluster                 boot all VMs + start patroni on every node + force election
  stop_cluster                  stop patroni on all nodes + halt VMs
  start_leader [node]           start a specific node and force it to be leader (default: ${DB_NODES[0]:-first DB node})
  stop_leader                   stop patroni on the current leader (auto-failover)
  start_replica <node>          start patroni on a single node (joins as replica)
  stop_replica  <node>          stop patroni on a single node
  restart_all                   restart patroni on every node + force leader
  wipe_cluster                  teardown + redeploy (DESTROYS all VMs, ~25 min)
  status                        show pglab status
EOF
    exit 2 ;;
esac
