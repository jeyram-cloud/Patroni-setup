<div align="center">

# pgvms — 6-node Patroni HA Cluster for PostgreSQL 16

[![Buy on Amazon](https://img.shields.io/badge/Buy%20on%20Amazon-1098155890-orange?style=for-the-badge&logo=amazon)](https://www.amazon.com/dp/1098155890/ref=tsm_1_fb_lk)
[![Buy on Amazon](https://img.shields.io/badge/Buy%20on%20Amazon-9355519362-orange?style=for-the-badge&logo=amazon)](https://www.amazon.com/dp/9355519362)
[![Read on Medium](https://img.shields.io/badge/Read%20on%20Medium-%40jramcloud1-black?style=for-the-badge&logo=medium)](https://medium.com/@jramcloud1/about)

</div>

A single-shot, **clone-and-run** setup that takes you from a clean macOS host
to a fully working 6-node PostgreSQL HA cluster, with HAProxy + Keepalived
for zero-downtime failover and a 3-node etcd cluster for leader election.

Everything is driven by a **single config file** (`vagrant-configs/cluster.conf`)
so you can move the cluster to a different subnet, change hostnames, swap
ports, or rotate credentials by editing exactly one file.

> 📚 **Author**: Jeyaram Ayyalusamy — [About me on Medium](https://medium.com/@jramcloud1/about)
>
> | Book 1 | Book 2 |
> |--------|--------|
> | [Hands-On MySQL Administration](https://www.amazon.com/dp/1098155890/ref=tsm_1_fb_lk) | [Mastering Amazon Relational Database Service for MySQL](https://www.amazon.com/dp/9355519362) |

---

## Table of contents

1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [Quick start](#quick-start)
4. [Connecting to the cluster](#connecting-to-the-cluster)
5. [Operating the cluster](#operating-the-cluster)
6. [Customizing IPs / hostnames / credentials](#customizing-ips--hostnames--credentials)
7. [Failover testing](#failover-testing)
8. [Rebuilding from scratch](#rebuilding-from-scratch)
9. [File layout](#file-layout)
10. [Troubleshooting](#troubleshooting)

---

## Architecture

```
                         ┌──────────────────────────┐
                         │  keepalived VIP          │
                         │  192.168.50.150          │
                         │  MASTER = pghaproxy1     │
                         │  BACKUP = pghaproxy2     │
                         └────────────┬─────────────┘
                                      │  VRRP unicast
              ┌───────────────────────┼───────────────────────┐
              │                       │                       │
   ┌──────────▼──────────┐    ┌───────▼────────┐    ┌─────────▼────────┐
   │ pghaproxy1          │    │ pghaproxy2     │    │ (more HA pairs)  │
   │ 192.168.50.160      │    │ 192.168.50.131 │    │                  │
   │ HAProxy 5000/5001   │    │ HAProxy 5000   │    │                  │
   │ keepalived MASTER   │    │ keepalived BACK│    │                  │
   └─────────┬───────────┘    └────────┬───────┘    └──────────────────┘
             │  health check GET /primary, /replica (port 8008)
             ▼
   ┌───────────────────────────────────────────────────────────────┐
   │  Patroni cluster "pg-cluster"  (DCS: etcd on postnode1..3)     │
   │                                                                │
   │  postnode1  192.168.32.170  ◄── initial leader (bootstrap)     │
   │  postnode2  192.168.32.171                                    │
   │  postnode3  192.168.32.172                                    │
   │  postnode4  192.168.32.173                                    │
   │  postnode5  192.168.32.174                                    │
   │  postnode6  192.168.32.175                                    │
   └───────────────────────────────────────────────────────────────┘
```

| Layer | Count | Composed of |
|---|---|---|
| PostgreSQL 16 + Patroni | 6 | `postnode1`..`postnode6` |
| etcd (DCS) | 3 | `postnode1`..`postnode3` |
| HAProxy (TCP) | 2 | `pghaproxy1`, `pghaproxy2` |
| Keepalived VIP | 1 | `192.168.50.150` (floating) |

### Ports

| Port | Where | Purpose |
|---|---|---|
| 5000/tcp | VIP | HAProxy write side → current Patroni leader |
| 5001/tcp | VIP | HAProxy read side → round-robin over replicas |
| 5432/tcp | each postnode | PostgreSQL |
| 8008/tcp | each postnode | Patroni REST (`GET /primary`, `GET /replica`) |
| 2379/tcp | postnode1..3 | etcd client |
| 2380/tcp | postnode1..3 | etcd peer |
| 8080/tcp | pghaproxy1/2 | HAProxy stats (admin / admin@123) |

---

## Prerequisites

Verified on:

- macOS Apple Silicon (M1/M2/M3) or Intel
- [Vagrant](https://www.vagrantup.com/downloads) ≥ 2.4
- [VirtualBox](https://www.virtualbox.org/wiki/Downloads) ≥ 7 (Intel) or ≥ 7.0.14 (Apple Silicon)
- (Optional) `postgresql@16` from Homebrew on the host for `pglab console`

Resource budget for the lab (all 8 VMs at once):

| VM | vCPU | RAM |
|---|---|---|
| postnode1..6 | 2 | 16 GB **each** |
| pghaproxy1, pghaproxy2 | 1 | 1 GB **each** |

That's **~13 vCPUs and ~98 GB RAM** recommended. You can drop the
`v.memory` / `v.cpus` lines in `Vagrantfile` on smaller machines — Postgres
will still start, just with less headroom.

---

## Quick start

```bash
git clone <your-repo>/pgvms.git
cd pgvms

# One-shot: teardown (no-op first time) + full deploy (~25 min)
./pglab reset

# Verify
./pglab status
./pglab test        # optional HA failover sanity check
```

`pglab reset` is the only command you need for a fresh build. It runs
`teardown.sh` (safe no-op if nothing exists) followed by `cluster-deploy.sh`
which performs every step in order.

---

## Connecting to the cluster

```bash
# Write endpoint — always lands on the current leader
PGPASSWORD='Admin@123' psql -h 192.168.50.150 -p 5000 -U admin -d postgres

# Read endpoint — round-robin over replicas
PGPASSWORD='Admin@123' psql -h 192.168.50.150 -p 5001 -U admin -d postgres

# Direct access to a specific node
PGPASSWORD='Admin@123' psql -h 192.168.32.170 -p 5432 -U admin -d postgres

# Patroni REST — health / leader info
curl -s http://192.168.32.170:8008/primary
curl -s http://192.168.32.170:8008/patroni

# HAProxy stats
open http://192.168.50.160:8080/stats     # admin / admin@123
```

`pglab console` opens a psql session to the write endpoint for you:

```bash
./pglab console                                # interactive
./pglab console -c 'SELECT pg_is_in_recovery()' # one-shot
```

---

## Operating the cluster

```
pglab <command> [args]

LIFECYCLE
  pglab up            boot all VMs (vagrant up)
  pglab down          halt VMs (state preserved)
  pglab deploy        full provisioning (post-teardown)
  pglab teardown      destroy VMs + clean host-only networks
  pglab reset         teardown + deploy from scratch

INSPECTION
  pglab status        VM state + etcd + Patroni + HAProxy + VIP
  pglab test          HA failover test (stop leader, verify replica)
  pglab console       open psql via VIP
  pglab ssh <node>    ssh into a node
  pglab logs <node> [service]   tail journalctl

FINE GRAINED (uses pglab_nodes.sh)
  ./pglab_nodes.sh start_cluster
  ./pglab_nodes.sh stop_cluster
  ./pglab_nodes.sh start_leader [postnodeN]
  ./pglab_nodes.sh stop_leader
  ./pglab_nodes.sh start_replica postnodeN
  ./pglab_nodes.sh stop_replica  postnodeN
  ./pglab_nodes.sh restart_all
  ./pglab_nodes.sh wipe_cluster
```

---

## Customizing IPs / hostnames / credentials

**Edit exactly one file:** `vagrant-configs/cluster.conf`.

Every script in this repo (Vagrantfile, pglab, all setup scripts) sources
that file. Once you change it, do a fresh `pglab reset` so the new IPs end
up in `/etc/hosts` on every VM and in the Vagrant host-only network.

```bash
# vagrant-configs/cluster.conf

DB_NODES=(postnode1 postnode2 postnode3 postnode4 postnode5 postnode6)
NODE_IP_postnode1="192.168.32.170"   # ← change these
NODE_IP_postnode2="192.168.32.171"
NODE_IP_postnode3="192.168.32.172"
NODE_IP_postnode4="192.168.32.173"
NODE_IP_postnode5="192.168.32.174"
NODE_IP_postnode6="192.168.32.175"

LB_VMS=(haproxy1 haproxy2)
NODE_IP_haproxy1="192.168.50.160"
NODE_IP_haproxy2="192.168.50.131"

VIP_WRITE="192.168.50.150"           # ← change the VIP
VIP_PORT_WRITE="5000"
VIP_PORT_READ="5001"

PG_SUPERUSER_PASSWORD="Postgres@123"  # ← change passwords
PG_ADMIN_PASSWORD="Admin@123"
PG_REPL_PASSWORD="Replicator@123"
HAPROXY_STATS_PASSWORD="admin@123"
KEEPALIVED_AUTH="pgcluster"
```

After editing:

```bash
./pglab reset         # rebuilds VMs with the new layout
```

### Example: move to a 10.0.0.x subnet

```bash
# In vagrant-configs/cluster.conf
NODE_IP_postnode1="10.0.0.170"
NODE_IP_postnode2="10.0.0.171"
NODE_IP_postnode3="10.0.0.172"
NODE_IP_postnode4="10.0.0.173"
NODE_IP_postnode5="10.0.0.174"
NODE_IP_postnode6="10.0.0.175"
NODE_IP_haproxy1="10.0.10.160"
NODE_IP_haproxy2="10.0.10.131"
VIP_WRITE="10.0.10.150"
DB_SUBNET="10.0.0.0/16"

./pglab reset
```

> ⚠️ DB_SUBNET is used in `pg_hba.conf` to allow md5 auth. Make sure it
> covers every node IP, otherwise replication will fail.

---

## Failover testing

```bash
./pglab test
```

This is a 7-step automated test:

1. Discover the current leader via Patroni REST
2. Stop Patroni on the leader
3. Wait ~35 s for the TTL-based election
4. Print the new cluster state — a replica should now be Leader
5. Run a write through the VIP to confirm the new leader is reachable
6. Restart Patroni on the original leader (it rejoins as a replica)
7. Print the final cluster state (everything should be green)

The whole thing runs in ~1 minute and is safe to repeat.

---

## Rebuilding from scratch

```bash
# Drop VMs + host-only networks
./pglab teardown

# Optionally remove the box image to force a fresh download
REMOVE_BOX=1 ./pglab teardown

# Full rebuild
./pglab deploy
```

`cluster-deploy.sh` is idempotent — re-running it on a partially-failed
deploy will pick up where it left off. The only step that is *not* safe to
re-run mid-setup is the etcd cluster bootstrap, which is why `cluster-deploy.sh`
will print a warning if you re-run it after the etcd phase has already
completed.

---

## File layout

```
pgvms/
├── Vagrantfile                       parse cluster.conf → define 8 VMs
├── pglab                             single entry-point CLI (thin wrapper)
├── pglab_nodes.sh                    per-node controls (start/stop individual)
├── teardown.sh                       destroy VMs + host-only networks
├── README.md                         this file
└── vagrant-configs/
    ├── cluster.conf                  ★ single source of truth (IPs, hosts, ports, passwords)
    ├── cluster-deploy.sh             full provisioning driver
    ├── run-all.sh                    step-by-step runner (alternative to cluster-deploy.sh)
    ├── common-setup.sh               dnf + SELinux + /etc/hosts + chrony
    ├── etcd-setup.sh                 3-node etcd cluster
    ├── pg-setup.sh                   PostgreSQL 16 + Patroni
    ├── haproxy-setup.sh              HAProxy config (backends built from cluster.conf)
    └── keepalived-setup.sh           VIP failover between haproxy1/2
```

---

## Troubleshooting

### `./pglab status` reports "no leader"

The most common cause is that postnode1's data dir was pre-populated by
a previous `initdb` (e.g. by `postgresql-16-setup initdb`). Patroni sees
what looks like a valid cluster and refuses to bootstrap — leaving the
DCS leader key unset forever.

Fix:

```bash
./pglab_nodes.sh restart_all
```

If that doesn't work, do a full clean rebuild:

```bash
./pglab reset
```

### VIP unreachable from a host on a different subnet

The VIP is bound to vboxnet — it only exists on the host that runs
VirtualBox. To reach it from another physical machine, port-forward
on your router or use a public_network bridge in the Vagrantfile.

### `etcd` panics with "tocommit out of range"

Means an etcd node was restarted without clearing its data dir. `etcd-setup.sh`
auto-wipes the data dir on each run, so a clean `./pglab reset` will resolve
this.

### Postgres connection from outside the cluster

Postgres only listens on the host-only network. To reach it from the host
you can either:

- use the VIP (`192.168.50.150:5000`), or
- SSH-tunnel: `vagrant ssh postnode1 -- sudo -u postgres psql -h 127.0.0.1`

### `pglab console` complains "no host psql"

Install postgres on the host:

```bash
brew install postgresql@16
export PATH="/usr/local/opt/postgresql@16/bin:$PATH"
```

(or on Apple Silicon: `brew install postgresql@16` → `/opt/homebrew/opt/postgresql@16/bin`).

Otherwise pglab will fall back to running psql inside postnode1.

---

## Default credentials

| Role | Username | Password |
|---|---|---|
| PostgreSQL superuser | `postgres` | `Postgres@123` |
| Admin user (post-bootstrap) | `admin` | `Admin@123` |
| Replication user | `replicator` | `Replicator@123` |
| HAProxy stats | `admin` | `admin@123` |
| Keepalived | — | `pgcluster` |
| vagrant ssh user | `vagrant` | (key-based) |

> 🔐 These are baked into `cluster.conf` for a self-contained lab. **Edit
> `cluster.conf` before publishing the repo if you intend to host it
> somewhere public.**

---

## License

This project is provided as-is for lab / educational use. No warranty.
PostgreSQL, Patroni, etcd, HAProxy, and Keepalived are governed by their
respective upstream licenses.
