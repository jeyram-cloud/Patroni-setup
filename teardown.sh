#!/usr/bin/env bash
# ----------------------------------------------------------
# teardown.sh — completely removes the 6-node Patroni HA cluster
#
# What this does:
#   1) Halts and deletes all Vagrant VMs (vagrant destroy -f)
#   2) Removes stale VirtualBox host-only networks (vagrantnet-vbox1/2)
#   3) Optionally removes the upstream Vagrant box image
#
# This is idempotent: safe to run even if VMs are already gone.
# After this, run `./vagrant-configs/cluster-deploy.sh` to rebuild from scratch.
# ----------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"

# Source cluster.conf so DB_NODES, LB_VMS, NODE_IP_* are available.
CONF="$(cd "$(dirname "$0")" && pwd)/vagrant-configs/cluster.conf"
# shellcheck disable=SC1090
. "$CONF"

PGVMS_ROOT="$(pwd)"
# DB_NODES, LB_VMS now come from cluster.conf.

echo "================================================================"
echo "  PG HA Cluster — FULL TEARDOWN"
echo "  ${PGVMS_ROOT}"
echo "================================================================"
echo

# ----------------------------------------------------------------
# 1) vagrant destroy — every VM, force
# ----------------------------------------------------------------
echo "==== 1) vagrant destroy (all nodes) ===="
# Both VM names (postnode*) and short hostnames (pghaproxy*) need to be destroyed.
ALL_VMS=("${DB_NODES[@]}" "${NODE_HOST_haproxy1:-pghaproxy1}" "${NODE_HOST_haproxy2:-pghaproxy2}")

# Try vagrant destroy first (covers the Vagrant-managed names).
vagrant destroy -f 2>&1 | sed 's/^/  /' || true

# Belt-and-suspenders: any remaining VMs with these names hang around in VBox only.
if command -v VBoxManage >/dev/null 2>&1; then
  for vm in "${ALL_VMS[@]}"; do
    if VBoxManage list vms 2>/dev/null | awk -v n="${vm}" '{for(i=1;i<=NF;i++) if($i ~ "\""n"\"") {print; exit}}' | grep -q "${vm}"; then
      echo "  VBox has residual VM '${vm}' — poweroff + unregister"
      VBoxManage controlvm "${vm}" poweroff 2>/dev/null || true
      VBoxManage unregistervm "${vm}" --delete 2>&1 | sed 's/^/    /' || true
    fi
  done
fi

# ----------------------------------------------------------------
# 2) Remove stale VirtualBox host-only networks
#    Without this, the next `vagrant up` may fail with
#    "The name of host only network is already in use".
# ----------------------------------------------------------------
echo
echo "==== 2) remove stale VirtualBox host-only networks ===="
if ! command -v VBoxManage >/dev/null 2>&1; then
  echo "  VBoxManage not found; skipping host-only network cleanup."
else
  vbox_remove_hostonly_if() {
    local target_name="$1"
    local hif
    hif=$(VBoxManage list hostonlyifs 2>/dev/null | awk -v t="${target_name}" '
      /Name:/ { nm=$2; found = (nm == t) ? 1 : 0 }
      found && /VBoxNetworkAdapter:/ { print $2; found=0 }
    ')
    if [ -n "${hif:-}" ]; then
      echo "  removing ${target_name} (${hif})"
      VBoxManage hostonlyif remove "${hif}" 2>&1 | sed 's/^/    /' || true
    else
      echo "  ${target_name} not present (ok)"
    fi
  }

  vbox_remove_hostonly_if "vagrantnet-vbox1"
  vbox_remove_hostonly_if "vagrantnet-vbox2"

  # Sweep any other vagrantnet-* interfaces that may have leaked.
  for hif in $(VBoxManage list hostonlyifs 2>/dev/null | awk -v p="vagrantnet-" '
    /Name:/ { nm=$2; want = (nm ~ p) ? 1 : 0 }
    want && /VBoxNetworkAdapter:/ { print $2; want=0 }
  '); do
    echo "  removing stray vagrantnet if: ${hif}"
    VBoxManage hostonlyif remove "${hif}" 2>&1 | sed 's/^/    /' || true
  done
fi

# ----------------------------------------------------------------
# 3) Optional: remove the Bento box image
# ----------------------------------------------------------------
echo
echo "==== 3) Box image cleanup ===="
if [ "${REMOVE_BOX:-0}" = "1" ]; then
  if vagrant box list 2>/dev/null | grep -q "bento/almalinux-9"; then
    echo "  REMOVE_BOX=1 set, removing bento/almalinux-9"
    vagrant box remove bento/almalinux-9 --force 2>&1 | sed 's/^/    /' || true
  else
    echo "  bento/almalinux-9 not present"
  fi
else
  echo "  keeping bento/almalinux-9 (set REMOVE_BOX=1 to delete)"
fi

echo
echo "================================================================"
echo "  TEARDOWN COMPLETE"
echo "  Next: bash vagrant-configs/cluster-deploy.sh"
echo "================================================================"
