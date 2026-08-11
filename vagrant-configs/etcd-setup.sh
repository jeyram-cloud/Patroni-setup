#!/usr/bin/env bash
# ----------------------------------------------------------
# etcd-setup.sh — installs and configures etcd
# Argument: $1 = node shortname (postnode1|postnode2|postnode3)
#
# All 3 etcd nodes use the SAME 3-member --initial-cluster and SAME --initial-cluster-token.
# They MUST come up within a short window so the cluster can form.
# --initial-cluster-state=new means "this is a brand new cluster; bootstrap from scratch".
# If postnode1 starts first it will block waiting for peers — that's fine; when postnode2/3
# join within the election timeout, the cluster forms.
# ----------------------------------------------------------
set -euo pipefail

CONF="/tmp/cluster.conf"
# shellcheck disable=SC1090
. "${CONF}"

NODE="${1:-postnode1}"
IP_VAR="NODE_IP_${NODE}"
IP="${!IP_VAR:-}"
if [ -z "${IP}" ]; then
  echo "etcd-setup.sh: unknown node '${NODE}' (not in cluster.conf)" >&2
  exit 1
fi

echo "==== etcd-setup.sh on ${NODE} (${IP}) ===="

# etcd is NOT in AlmaLinux 9 base / EPEL on aarch64, so install from upstream tarball.
ETCD_VER="${ETCD_VER:-3.5.21}"
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) ETCD_ARCH="arm64" ;;
  x86_64|amd64)  ETCD_ARCH="amd64" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

if ! command -v etcd >/dev/null 2>&1 || ! PATH=/usr/local/bin:/usr/bin:/bin command -v etcd >/dev/null 2>&1; then
  cd /tmp
  curl -fsSL -o etcd.tar.gz \
    "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VER}/etcd-v${ETCD_VER}-linux-${ETCD_ARCH}.tar.gz"
  tar -xzf etcd.tar.gz
  install -m 0755 "etcd-v${ETCD_VER}-linux-${ETCD_ARCH}/etcd"      /usr/local/bin/etcd
  install -m 0755 "etcd-v${ETCD_VER}-linux-${ETCD_ARCH}/etcdctl"   /usr/local/bin/etcdctl
  install -m 0755 "etcd-v${ETCD_VER}-linux-${ETCD_ARCH}/etcdutl"   /usr/local/bin/etcdutl
  rm -rf etcd.tar.gz "etcd-v${ETCD_VER}-linux-${ETCD_ARCH}"
fi

# `sudo` may strip /usr/local/bin from PATH; force it so the systemd unit can find the binary
export PATH=/usr/local/bin:/usr/bin:/bin
hash -r
/usr/local/bin/etcd --version
/usr/local/bin/etcdctl version

mkdir -p /etc/etcd

# Use a deterministic cluster token so all 3 nodes agree.
CLUSTER_TOKEN="${ETCD_CLUSTER_TOKEN}"

# Build the 3-member initial cluster string from cluster.conf.
INITIAL_CLUSTER=""
for n in "${ETCD_NODES[@]}"; do
  nip_var="NODE_IP_${n}"
  eval "_ip=\"\${${nip_var}:-}\""
  INITIAL_CLUSTER="${INITIAL_CLUSTER}${n}=http://${_ip}:2380,"
done
INITIAL_CLUSTER="${INITIAL_CLUSTER%,}"
INITIAL_CLUSTER_STATE="new"

cat > /etc/etcd/etcd.conf <<EOF
ETCD_NAME="${NODE}"
ETCD_LISTEN_CLIENT_URLS="http://${IP}:2379,http://127.0.0.1:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://${IP}:2379"
ETCD_LISTEN_PEER_URLS="http://${IP}:2380"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${IP}:2380"
ETCD_INITIAL_CLUSTER="${INITIAL_CLUSTER}"
ETCD_INITIAL_CLUSTER_TOKEN="${CLUSTER_TOKEN}"
ETCD_INITIAL_CLUSTER_STATE="${INITIAL_CLUSTER_STATE}"
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
EOF

# Provide a systemd unit that passes flags directly.
# --enable-v2=true is REQUIRED because python-etcd (which `patroni[etcd3]` installs)
#       only speaks the v2 protocol.
mkdir -p /var/lib/etcd/default.etcd
chown -R root:root /var/lib/etcd /etc/etcd

cat > /etc/systemd/system/etcd.service <<EOF
[Unit]
Description=etcd (cluster datastore for Patroni)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=ETCD_UNSUPPORTED_ARCH=aarch64
ExecStart=/usr/local/bin/etcd --name=${NODE} --data-dir=/var/lib/etcd/default.etcd --listen-client-urls=http://${IP}:2379,http://127.0.0.1:2379 --advertise-client-urls=http://${IP}:2379 --listen-peer-urls=http://${IP}:2380 --initial-advertise-peer-urls=http://${IP}:2380 --initial-cluster=${INITIAL_CLUSTER} --initial-cluster-token=${CLUSTER_TOKEN} --initial-cluster-state=${INITIAL_CLUSTER_STATE} --enable-v2=true
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# If etcd is already running healthy, don't wipe data. Otherwise, wipe for a fresh bootstrap.
if /usr/local/bin/etcdctl --endpoints=http://${IP}:2379 endpoint health >/dev/null 2>&1; then
  echo "etcd already healthy on ${NODE} — keeping existing data dir"
else
  echo "etcd not healthy on ${NODE} — wiping data dir for fresh bootstrap"
  rm -rf /var/lib/etcd/default.etcd
  mkdir -p /var/lib/etcd/default.etcd
  chmod 700 /var/lib/etcd/default.etcd
fi

systemctl daemon-reload
systemctl enable etcd
systemctl restart etcd

# Give it a moment to come up, then show status.
sleep 8
export PATH=/usr/local/bin:/usr/bin:/bin
/usr/local/bin/etcdctl --endpoints=http://${IP}:2379 member list 2>&1 | head -10 || true
echo ""
/usr/local/bin/etcdctl --endpoints=http://${IP}:2379 endpoint health 2>&1 | head -5 || true
echo "==== etcd-setup.sh complete on ${NODE} ===="
