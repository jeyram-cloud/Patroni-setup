#!/usr/bin/env bash
# ----------------------------------------------------------
# common-setup.sh — applied to EVERY node (DB and LB)
# Argument: $1 = short hostname (e.g. postnode1, pghaproxy1)
# Reads /etc/hosts block from ../vagrant-configs/cluster.conf.
# ----------------------------------------------------------
set -euo pipefail

CONF="$(cd "$(dirname "$0")" && pwd)/cluster.conf"
# shellcheck disable=SC1090
. "${CONF}"

NODE_NAME="${1:-$(hostname)}"
LOG="/var/log/common-setup.log"
exec > >(tee -a "$LOG") 2>&1

echo "==== common-setup.sh on ${NODE_NAME} @ $(date) ===="

# 1. Repos & packages
dnf install -y epel-release
dnf install -y vim tmux net-tools bind-utils policycoreutils-python-utils \
               rsync python3 python3-pip python3-devel gcc make \
               libpq-devel openssl-devel jq chrony

# 2. Disable firewall (private lab only)
systemctl disable --now firewalld || true

# 3. SELinux permissive
setenforce 0 || true
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

# 4. Time sync
systemctl enable --now chronyd

# 5. /etc/hosts — add all cluster members
cat > /etc/hosts <<EOF
127.0.0.1   localhost
${HOSTS_ENTRIES}
EOF

# 6. Set hostname consistently
hostnamectl set-hostname "${NODE_NAME}"

# 7. A bit of sysctl for Patroni/PG
cat > /etc/sysctl.d/99-pg-ha.conf <<'EOF'
vm.swappiness = 1
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.core.somaxconn = 4096
fs.file-max = 2097152
EOF
sysctl --system

echo "==== common-setup.sh complete ===="
