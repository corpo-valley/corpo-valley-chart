# Scaling

This chart packages a real platform with both **stateless** and **stateful**
components. The stateless ones scale by changing one number in `values.yaml`.
The stateful ones don't — they require real HA work that is out of scope for
Phase 1. This doc names each component and its scaling path.

## TL;DR for a 100-user deployment

```yaml
# values.yaml additions
scale:
  hydra: 2
  oathkeeper: 2
  portal: 2
  mcpGateway: 2
  giteaRunner: 3
  # leave kratos: 1 (see note), keto: 1, cloudflared: 1

resources:
  oryPostgres:
    requests: { cpu: 1, memory: 2Gi }
    limits:   { cpu: 2, memory: 4Gi }
```

Then bump the cluster: a 2-VM topology with 8 dedicated vCPU / 32 GiB total
(e.g. 2× Hetzner CCX23) handles 100 active users with ~50% headroom. Beyond
~300 active users, add a third node — see "Cluster-side scaling" below.

## Stateless components

These run as replicated Deployments. Scale via `scale.<name>` in
`values.yaml`. All workloads behind k8s Services with round-robin endpoints,
no session affinity, no per-pod state.

### `portal` ✅ scales freely
- Holds no in-memory session state — Kratos cookies validate per-request,
  every replica reads the same Postgres.
- `strategy: RollingUpdate` once `scale.portal > 1` (Recreate is the default
  to avoid pod-cap pressure on a single-node cluster).
- **Recommended**: 2 for HA, 3 if portal CPU shows up in dashboards.
- **Caveat**: each replica caches the sealed-secrets controller's public
  cert for 1h. Cert rotation propagates lazily; tenant secret-seal attempts
  retry within the cache window.

### `mcp-gateway` ✅ scales freely
- Reverse proxies to per-project `/mcp` Services. No state.
- **Recommended**: 2 for HA. CPU is low; one replica handles a lot.

### `ory-hydra` ✅ scales freely
- Tokens + clients in Postgres. Every replica is interchangeable.
- **Recommended**: 2.

### `ory-keto` ✅ scales freely
- Relation tuples in Postgres. Check requests are read-only and idempotent.
- **Recommended**: 1 is fine for 100 users — check latency is microseconds;
  bump to 2 only if you want HA across an oathkeeper rolling restart.

### `ory-oathkeeper` ✅ scales freely
- Rules from ConfigMap, no state. Every replica identical.
- **Recommended**: 2 for HA — without it, a 5–10s 502 gap appears in the
  Gitea wildcard during pod rollouts.

### `cloudflared` ⚠️ scales but rarely needed
- The Cloudflare tunnel daemon itself maintains ~4 QUIC links to the edge
  per connector, so a single replica is already 4-way HA at the transport
  level. Adding replicas adds redundancy against connector pod death.
- **Recommended**: 1. Bump to 2 only if you've seen the connector die.

### `gitea-runner` ✅ scales freely
- StatefulSet — each replica gets its own data PVC and registers with Gitea
  under a unique name (`metadata.name`). N replicas = N concurrent jobs.
- **Recommended**: 3 for a 100-user team. Heavy semgrep + osv-scanner builds
  peak at ~3 GiB per pod; budget for that.

### `ory-kratos` ⚠️ technically scales, has a caveat
- The chart runs `serve all --watch-courier`, which means **every replica
  runs the courier worker**. The workers race on the Kratos courier
  Postgres outbox; a row-level lock dedupes sends, so this is safe but
  inefficient with N > 1.
- **Recommended**: keep at 1.
- **If you really need HA**: Phase 2 work — split into two deployments,
  one running `serve all --watch-courier=false` with replicas: N, plus
  one `kratos courier watch` with replicas: 1. Not exposed in the chart yet.

## Stateful components — single-replica by design

These hold local state on RWO storage. Scaling them is not a values change
— it's a real HA rewrite. The chart hardcodes `replicas: 1` and leaves a
comment on each.

### `ory-postgres` 🔴 single-replica
- One Postgres carries kratos + hydra + keto + portal databases.
- Vertical scaling is fine: bump `resources.oryPostgres.requests/limits`
  and `storage.oryPostgres`. The Hetzner default (1 CPU / 2 GiB) handles
  100 users comfortably; 4 CPU / 8 GiB takes you to ~500.
- Horizontal HA needs an operator + streaming replication: CloudNativePG
  (recommended), Zalando postgres-operator, or Crunchy. None are
  drop-in — switching means migrating data + reconfiguring Kratos/Hydra/
  Keto DSNs to point at the operator's HA endpoint. Phase 2.
- **Backup**: not chart-managed. The `backups.enabled: false` placeholder
  in values.yaml is where this will live. Until then, run a manual
  `pg_dump` CronJob and ship the output to S3-compatible storage (e.g.
  Hetzner Object Storage or Backblaze B2).

### `gitea` 🔴 single-replica (SQLite)
- The chart deploys Gitea with `GITEA__database__DB_TYPE: sqlite3` on a 10
  GiB PVC. Gitea + SQLite cannot run >1 replica.
- Vertical: bump `resources.gitea` and `storage.gitea`.
- HA: switch to `DB_TYPE: postgres` (point at ory-postgres or a separate
  PG), add a Redis cache for session, scale to N. The git data itself
  still has to be shared — Gitea has a `repository.STORAGE_TYPE: minio`
  mode but it's not battle-tested. Realistically, HA Gitea = an external
  storage backend and is a serious project. Phase 2.

### `cv-registry` 🔴 single-replica
- `docker/distribution:2.8.3` on an RWO PVC. Multiple replicas can't share
  RWO; pushes would clobber.
- Vertical: bump `storage.registry` (the default 50 GiB fills quickly under
  100 users × 10 image tags × ~200 MiB).
- HA: switch the backend to S3 (Hetzner Object Storage works; it's
  S3-compatible). The registry can run N replicas with `storage:
  s3:...` config. Phase 2.
- **Image garbage-collection**: not chart-managed. Add a CronJob running
  `registry garbage-collect /etc/docker/registry/config.yml` weekly to
  reclaim blob storage.

## Cluster-side scaling

The chart sizes pods; the cluster has to hold them.

| User count | Cluster shape | Why |
|---|---|---|
| < 25 | 1× CCX23 (4 vCPU / 16 GiB) | Single-node fits the platform + a handful of projects |
| 25–100 | 2× CCX23 (8 vCPU / 32 GiB total) | server + agent, current default |
| 100–300 | 3× CCX23 (12 vCPU / 48 GiB) | Adds genuine HA — losing the agent isn't fatal; losing the server still is |
| 300+ | k3s → kubeadm/k0s, 3 control-plane + 3+ workers | etcd HA, Postgres operator with replicas, registry on S3 — the Phase 2 rewrite |

The **default kubelet pod cap is 110 pods/node**. At 200 active projects
(~3 pods each + platform overhead), one node hits the cap. On k3s, raise it
with `--kubelet-arg=max-pods=250` in the k3s install args; on other distros,
set `--max-pods=250` (or higher) on every kubelet.

## What's NOT a scaling problem

- **Storage class.** `hcloud-volumes` is RWO. RWO is fine for every chart
  component because none of them need shared storage. (Postgres, Gitea
  SQLite, and the registry all want one writer.)
- **Cloudflare tunnel.** Single connector with 4 QUIC links is already HA
  at the network layer. Don't optimize until you see actual outage data.
- **NetworkPolicies.** Bound by the CNI, not pod count. k3s ships flannel
  which doesn't enforce them by default; the chart's NetworkPolicies are
  silently ignored on k3s without Calico. **Worth knowing**: on a real
  multi-tenant deployment, install Calico or Cilium so the policies
  actually fire. On microk8s (current corpo-valley.com) Calico is the
  default — they work there.

## When to re-architect

The chart works fine for hundreds of users. Past that, the SPOF list above
(Postgres, Gitea, Registry) is the wall. Hitting it isn't a chart change —
it's a separate "HA milestone" that ships:

- CloudNativePG operator + 3-replica PG cluster
- Gitea on PG + Redis + S3
- Registry on Hetzner Object Storage (S3-compat)
- Daily pg_dump → object storage CronJob
- Sealed-secrets master-key auto-backup
- A `backups.enabled: true` toggle in the chart that turns on the CronJobs

That's the work the `backups.enabled` placeholder in `values.yaml` will
eventually drive.
