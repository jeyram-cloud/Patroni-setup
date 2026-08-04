#!/usr/bin/env bash
# ----------------------------------------------------------
# pg-setup.sh — installs PostgreSQL 16 and Patroni on postnodes
# Argument: $1 = node shortname (postnode1..postnode6)
#
# Reads IP/hostname from ../vagrant-configs/cluster.conf.
# ----------------------------------------------------------
set -euo pipefail

CONF="/tmp/cluster.conf"
# shellcheck disable=SC1090
. "${CONF}"

NODE="${1:-postnode1}"
IP_VAR="NODE_IP_${NODE}"
IP="${!IP_VAR:-}"
if [ -z "${IP}" ]; then
  echo "pg-setup.sh: unknown node '${NODE}' (not in cluster.conf)" >&2
  exit 1
fi

echo "==== pg-setup.sh on ${NODE} (${IP}) ===="

# 1. PostgreSQL 16 from PGDG
# Detect arch — aarch64 needs the aarch64-specific repo RPM and GPG key
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64)
    PGDG_REPO="https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-aarch64/pgdg-redhat-repo-latest.noarch.rpm"
    PGDG_KEY_URL="https://yum.postgresql.org/keys/PGDG-RPM-GPG-KEY-AARCH64-RHEL"
    PGDG_KEY_FILE="/etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-AARCH64-RHEL"
    ;;
  x86_64|amd64)
    PGDG_REPO="https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
    PGDG_KEY_URL="https://yum.postgresql.org/keys/PGDG-RPM-GPG-KEY-RHEL"
    PGDG_KEY_FILE="/etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-RHEL"
    ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

# Fetch the correct key and import it BEFORE installing the repo RPM
curl -fsSL -o "$PGDG_KEY_FILE" "$PGDG_KEY_URL"
rpm --import "$PGDG_KEY_FILE"

dnf install -y "$PGDG_REPO"
dnf -qy module disable postgresql
dnf install -y postgresql16-server postgresql16-contrib

# 2. Patroni user + dirs
useradd -r -s /bin/false patroni || true
mkdir -p /etc/patroni /var/lib/patroni /var/log/patroni
chown -R patroni:patroni /etc/patroni /var/lib/patroni /var/log/patroni

# 3. Patroni via pip
pip3 install --upgrade pip
pip3 install "patroni[etcd3]" psycopg2-binary

# 4. /etc/patroni/patroni.yml
cat > /etc/patroni/patroni.yml <<EOF
scope: pg-cluster
namespace: /service/
name: ${NODE}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${IP}:8008

etcd:
  hosts:
$(for n in "${ETCD_NODES[@]}"; do ip_var="NODE_IP_${n}"; echo "    - ${!ip_var}:2379"; done)

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: "on"
        logging_collector: "on"
  initdb:
    - encoding: UTF8
    - data-checksums

postgresql:
  listen: 0.0.0.0:${PG_LISTEN_PORT}
  connect_address: ${IP}:${PG_LISTEN_PORT}
  data_dir: /var/lib/pgsql/16/data
  bin_dir: /usr/pgsql-16/bin
  pgpass: /tmp/pgpass0
  authentication:
    superuser:
      username: ${PG_SUPERUSER}
      password: "${PG_SUPERUSER_PASSWORD}"
    replication:
      username: ${PG_REPL_USER}
      password: "${PG_REPL_PASSWORD}"
    rewind:
      username: ${PG_SUPERUSER}
      password: "${PG_SUPERUSER_PASSWORD}"
  parameters:
    unix_socket_directories: '/tmp'
  pg_hba:
    - local   all   all                 trust
    - host    all   all   127.0.0.1/32  md5
    - host    all   all   ${DB_SUBNET} md5
    - host    replication ${PG_REPL_USER} 127.0.0.1/32 md5
    - host    replication ${PG_REPL_USER} ${DB_SUBNET} md5
  post_bootstrap:
    script: /usr/local/bin/patroni-post-bootstrap.sh
    threshold: 30

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

chown -R postgres:postgres /etc/patroni
chmod 644 /etc/patroni/patroni.yml

# post_bootstrap script: creates the admin user on the freshly bootstrapped primary.
# Use the local socket (trust) to avoid the chicken-and-egg of needing a password
# before it has been set. Patroni is configured to set the postgres password via
# the DCS, but only AFTER the first bootstrap completes — so during post_bootstrap
# the role still has no password. The local socket is `local all all trust` and
# does not require one.
cat > /usr/local/bin/patroni-post-bootstrap.sh <<PEOF
#!/usr/bin/env bash
set -euo pipefail
# Use local socket (trust on \`local all all\`) — no password needed.
PSQL="/usr/pgsql-16/bin/psql -U ${PG_SUPERUSER} -d ${PG_DATABASE} -tAc"
# Make sure postgres itself has a password (matches what patroni.yml says).
\$PSQL -c "ALTER USER ${PG_SUPERUSER} WITH PASSWORD '${PG_SUPERUSER_PASSWORD}';" >/dev/null || true
\$PSQL -c "SELECT 1 FROM pg_roles WHERE rolname='${PG_ADMIN_USER}'" | grep -q 1 || \
  \$PSQL -c "CREATE USER ${PG_ADMIN_USER} WITH SUPERUSER PASSWORD '${PG_ADMIN_PASSWORD}';"
exit 0
PEOF
chmod 755 /usr/local/bin/patroni-post-bootstrap.sh

# 5. systemd unit (patroni must run as the postgres user so it can read its config and own data dir)
cat > /etc/systemd/system/patroni.service <<'EOF'
[Unit]
Description=Patroni - PostgreSQL HA
After=network.target etcd.service
Wants=etcd.service

[Service]
Type=simple
User=postgres
Group=postgres
Environment=PATRONI_ETCD3_HOSTS=${ETCD_ENDPOINTS}
Environment=ETCDCTL_API=3
ExecStart=/usr/local/bin/patroni /etc/patroni/patroni.yml
Restart=on-failure
RestartSec=10s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# CRITICAL: Always wipe any pre-existing data dir BEFORE systemd starts patroni.
# If a previous Patroni run left data with a different system_id, the new
# Patroni refuses to join the cluster ("system ID mismatch"). Patroni runs
# `initdb` itself on a fresh empty data dir, which is what we want.
rm -rf /var/lib/pgsql/16/data
mkdir -p /var/lib/pgsql/16/data
chown -R postgres:postgres /var/lib/pgsql/16/data
chmod 700 /var/lib/pgsql/16/data

# postgresql-16.service must NEVER manage the cluster — Patroni does it via
# `pg_ctl` calls. Disable it so it cannot race with Patroni for the data dir.
systemctl disable --now postgresql-16 || true

systemctl enable --now patroni

# 6. Wait for Patroni to actually take over its data dir (initdb can take a while
# on the first node which bootstraps as leader).
echo "  waiting for patroni to initialize the cluster..."
for i in $(seq 1 30); do
  if su - postgres -c "/usr/local/bin/patronictl -c /etc/patroni/patroni.yml list 2>/dev/null" | grep -qE "${NODE}"; then
    echo "  patroni sees ${NODE} in the cluster"
    break
  fi
  sleep 3
  if [ "$i" = "30" ]; then
    echo "  WARN: patroni did not list ${NODE} within 90s — check 'journalctl -u patroni'"
  fi
done

echo "==== pg-setup.sh complete on ${NODE} ===="
