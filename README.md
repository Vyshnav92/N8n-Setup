# n8n on Kubernetes: GitOps Platform (Proof of Concept)

[![ci](https://github.com/Vyshnav92/N8n-Setup/actions/workflows/ci.yaml/badge.svg?branch=main)](https://github.com/Vyshnav92/N8n-Setup/actions/workflows/ci.yaml)

A highly available, self-hosted [n8n](https://n8n.io) workflow-automation platform on Kubernetes, delivered entirely through GitOps with Argo CD.

The repository covers the full lifecycle: install, scaling, security hardening, monitoring and alerting, point-in-time database recovery, and a scripted rebuild of the whole platform on an empty cluster.

> **Status: proof of concept.** 

---

## Contents

- [Architecture](#architecture)
- [Components and versions](#components-and-versions)
- [Repository layout](#repository-layout)
- [How deployment works](#how-deployment-works)
- [Getting started](#getting-started)
- [Secrets](#secrets)
- [Backup and disaster recovery](#backup-and-disaster-recovery)
- [Observability](#observability)
- [Security](#security)
- [Continuous integration](#continuous-integration)
- [Further documentation](#further-documentation)

---

## Architecture

n8n runs in **queue mode**. The work is split across three roles that scale independently:

| Role | What it does | Scaling |
|---|---|---|
| **Main** | Editor UI, REST API, triggers and schedules, test webhooks | 1 replica |
| **Webhook processors** | Handle production webhook calls (`/webhook/*`) and enqueue executions | HPA on CPU, 2 to 3 replicas |
| **Workers** | Pull executions from the Redis queue and run them. Each worker has an isolated task-runner sidecar for Code nodes | KEDA on queue depth, 2 to 4 replicas |


<img width="1220" height="730" alt="image" src="https://github.com/user-attachments/assets/6eec91dd-5228-4b33-b706-f525dfea6ef8" />


### Request flow

1. All traffic enters through **nginx-proxy**, which terminates TLS and redirects HTTP to HTTPS.
2. Production webhooks (`/webhook/`, `/webhook-waiting/`) go to the **webhook processors**. They are rate-limited to 20 requests per second per client IP, with a burst of 40.
3. Everything else, including the editor, the API, WebSocket push and test webhooks, goes to **main**.
4. Main and the webhook processors put executions on the **Redis Cluster** queue (BullMQ). **Workers** pick them up.
5. Every n8n process connects to **PostgreSQL** through the **PgBouncer pooler**. The connection uses TLS and verifies the cluster CA.
6. `/metrics` is blocked at the proxy. Prometheus scrapes the pods directly.

### Platform services

These are installed by Argo CD from pinned Helm charts:

- **CloudNativePG** runs PostgreSQL with streaming replication, automatic failover and connection pooling.
- **Barman Cloud plugin** archives WAL continuously and takes base backups to S3, which enables point-in-time recovery.
- **cert-manager** is required by the Barman Cloud plugin to issue its internal mTLS certificates.
- **KEDA** scales workers from the length of the Redis wait list.
- **metrics-server** provides CPU metrics for the webhook-processor HPA.
- **Vertical Pod Autoscaler** runs in recommendation-only mode for main, to guide resource sizing.

---

## Components and versions

Every chart and image version is set explicitly. CI fails on `:latest` tags.

| Component | Delivered by | Version |
|---|---|---|
| n8n (official Helm chart) | Argo CD, `argocd/apps/n8n.yaml` | chart `1.15.0` (n8n `2.42.4`) |
| n8n task runners | n8n values | `n8nio/runners:2.42.4-distroless` |
| CloudNativePG operator | Argo CD | chart `0.29.1` |
| Barman Cloud plugin | Argo CD | chart `0.8.1` |
| cert-manager | Argo CD | chart `1.21.2` |
| KEDA | Argo CD | chart `2.21.0` |
| Redis Cluster (Bitnami) | Argo CD | chart `13.0.4` (Redis `8.2.1`) |
| metrics-server | Argo CD | chart `3.14.0` |
| Vertical Pod Autoscaler (Fairwinds) | Argo CD | chart `5.1.0` |
| nginx reverse proxy | `deploy/base/nginx-proxy.yaml` | `nginx-unprivileged:1.28-alpine` |
| Argo CD | `ops/dr-up.sh` | `v3.5.6` |
| Sealed Secrets controller | `ops/dr-up.sh` | `v0.40.0` |
| kube-prometheus-stack | `ops/dr-up.sh` | chart `92.10.0` |

Versions used to rebuild the cluster live in [`dr/versions.env`](dr/versions.env).

---

## Repository layout

```text
.
├── bootstrap/
│   └── root.yaml               # Argo CD "app of apps": the single entry point
├── argocd/
│   └── apps/                   # One Argo CD Application per component
│       ├── n8n.yaml            #   n8n Helm chart + values from deploy/n8n-values.yaml
│       ├── n8n-base.yaml       #   everything in deploy/base
│       ├── cnpg-operator.yaml
│       ├── plugin-barman-cloud.yaml
│       ├── cert-manager.yaml
│       ├── redis-ha.yaml
│       ├── keda.yaml
│       ├── metrics-server.yaml
│       └── vpa.yaml
├── deploy/
│   ├── n8n-values.yaml         # Helm values for the n8n chart
│   └── base/                   # Plain manifests synced by the n8n-base app
│       ├── namespace.yaml                 # namespace + Pod Security labels
│       ├── postgres-cluster.yaml          # CloudNativePG cluster
│       ├── postgres-pooler.yaml           # PgBouncer
│       ├── objectstore.yaml               # S3 target for WAL + base backups
│       ├── scheduled-backup.yaml          # daily base backup
│       ├── nginx-proxy.yaml               # TLS reverse proxy
│       ├── networkpolicies.yaml           # default deny + allow rules
│       ├── pdb-*.yaml                     # disruption budgets
│       ├── keda-trigger-auth.yaml         # KEDA auth to Redis
│       ├── vpa-n8n-main.yaml              # sizing recommendations
│       ├── *monitor.yaml                  # Prometheus scrape config
│       ├── prometheus-rules.yaml          # alert rules
│       └── sealed-*.yaml                  # encrypted secrets (Sealed Secrets)
├── ops/                        # Operator tooling. Not synced by Argo CD.
│   ├── dr-up.sh                # rebuild the platform on an empty cluster
│   ├── keys-backup.sh          # back up the sealing keys and the n8n encryption key
│   ├── keys-restore.sh         # restore the sealing keys
├── dr/
│   └── versions.env            # pinned versions used during rebuild
├── docs/                       # runbooks and the production-readiness review
└── .github/workflows/ci.yaml   # validation, policy and security checks
```

---

## How deployment works

The repository uses the Argo CD **app-of-apps** pattern:

```text
bootstrap/root.yaml  ──►  argocd/apps/*.yaml  ──►  Helm charts (pinned versions)
                                                └─►  deploy/base/*.yaml
                                                └─►  deploy/n8n-values.yaml
```

- `root` watches `argocd/apps/`. Adding a file there adds a component.
- Every Application has `selfHeal: true`. Manual changes in the cluster are reverted to what Git says.
- Every Application has **`prune: false` on purpose**. Deleting a file from Git must never delete a database or its volumes. CI enforces this rule. Removing a resource is a deliberate, manual step.
- The `n8n` Application ignores `spec.replicas` on Deployments, so HPA and KEDA own the replica counts and Argo CD does not fight them.

---

## Getting started

### Prerequisites

- Kubernetes 1.28 or newer, with exactly one default StorageClass
- About 6 CPU cores and 12 GiB of allocatable memory for the full platform, including monitoring
- `kubectl`, `helm`, `kubeseal`, `jq`
- An S3 bucket and credentials for the PostgreSQL WAL archive

### Option A: rebuild from backups (recommended)

[`ops/dr-up.sh`](ops/dr-up.sh) builds the whole platform on an empty cluster, in dependency order. It restores the Sealed Secrets keys and the database, then runs post-install checks:

```bash
./ops/dr-up.sh preflight     # read-only checks: tools, backups, cluster, registries
./ops/dr-up.sh               # drill: full rebuild, never writes to the production archive
./ops/dr-up.sh verify        # post-install health checks only
```

See [docs/disaster-recovery.md](docs/disaster-recovery.md) for inputs, modes and the hand-over to GitOps.

### Option B: fresh install

1. Install the Sealed Secrets controller, Argo CD and kube-prometheus-stack, using the versions in `dr/versions.env`.
2. The sealed secrets in `deploy/base/` can only be decrypted by the controller key they were sealed with. Either restore that key with `ops/keys-restore.sh`, or re-seal every secret for the new controller. The steps are in [docs/operations.md](docs/operations.md#sealing-a-secret).
3. Apply the root application. Argo CD installs everything else:

   ```bash
   kubectl apply -f bootstrap/root.yaml
   kubectl -n argocd get applications -w
   ```

### Accessing n8n

The proxy is a cluster-internal service in this proof of concept. Reach it with a port-forward:

```bash
kubectl -n n8n port-forward svc/nginx-proxy 8443:443
# then open https://localhost:8443
```

---

## Secrets

No plaintext secret is ever committed. Every credential is a [Sealed Secret](https://github.com/bitnami-labs/sealed-secrets), encrypted with the cluster's public key. Only the controller in the cluster can decrypt it. CI rejects any plain `kind: Secret` manifest and scans the full Git history with gitleaks.

| Secret | Namespace | Used by |
|---|---|---|
| `n8n-secrets` | n8n | n8n: encryption key and host settings |
| `n8n-runner-token` | n8n | auth between n8n and its task runners |
| `n8n-smtp-credentials` | n8n | outgoing email (invites, password resets) |
| `redis-cluster-auth` | n8n, redis-ha | Redis password for n8n, KEDA and Redis itself |
| `nginx-tls` | n8n | TLS certificate for the proxy |
| `pg-wal-s3` | n8n | S3 credentials for WAL archiving and base backups |

CloudNativePG generates the database credentials (`n8n-db-app`) and the CA (`n8n-db-ca`) itself. They are not stored in Git.

**Two keys must survive a cluster loss:** the Sealed Secrets private keys, and `N8N_ENCRYPTION_KEY`, without which stored n8n credentials cannot be decrypted. `ops/keys-backup.sh` encrypts both with [age](https://age-encryption.org) and uploads them off-cluster.

---

## Backup and disaster recovery

| Layer | Mechanism | Retention |
|---|---|---|
| PostgreSQL | Continuous WAL archiving to S3 (compressed, AES-256 server-side encryption) | 14 days |
| PostgreSQL | Daily base backup at 21:00 UTC, plus one as soon as the schedule is created | 14 days |
| Secrets | age-encrypted export of sealing keys and the n8n encryption key | manual, dated files |
| Configuration | This Git repository | Git history |

Together these allow **point-in-time recovery** to any moment in the last 14 days. `ops/dr-up.sh` turns that into one command and supports two modes:

- **Drill** (default): restores into a separate cluster without archiving. It can never write to the production backup archive.
- **Real** (`--real`): the restored cluster starts a new archive folder in the same bucket, so the old timeline stays intact.

Full runbook: [docs/disaster-recovery.md](docs/disaster-recovery.md).

---

## Observability

Prometheus Operator resources live in `deploy/base/`:

- **ServiceMonitor** for n8n main and the webhook processors. Queue, event-bus, workflow and node-type metrics are enabled.
- **PodMonitors** for the workers and for PostgreSQL (CloudNativePG exporter).
- **PrometheusRule** `n8n-backup-alerts` with 17 alerts in five groups:

| Group | Covers |
|---|---|
| Availability | components down or missing, degraded rollouts, crash loops, OOM kills, scrape targets down |
| Scaling | autoscaler at its maximum or unable to scale, containers near their memory limit |
| Data stores | PostgreSQL not ready or missing, Redis cluster missing nodes |
| Backups | WAL archive backlog, failed base backup, no successful base backup in 36 hours |
| Node capacity | node memory above 80%, with the top n8n pods in the alert text |

---

## Security

- **Network:** default-deny ingress in the `n8n` namespace. Explicit allow rules for the proxy, n8n, PgBouncer, PostgreSQL and Prometheus. Redis accepts connections only from n8n, KEDA and its own cluster members.
- **Pod Security:** the namespace is labelled for the `restricted` profile (warn and audit). Workload containers drop all Linux capabilities and disallow privilege escalation. The proxy runs non-root with a read-only root filesystem.
- **Least privilege:** n8n pods get no Kubernetes RBAC and no mounted service-account token.
- **Code isolation:** Code-node execution runs in a separate, distroless, non-root task-runner sidecar.
- **n8n hardening:** shell, file-system and other high-risk nodes are disabled. Environment variable access from nodes is blocked. SSRF protection is on. Telemetry is off. Invitations are email-only.
- **Data in transit:** n8n to PostgreSQL uses TLS with CA verification. The proxy terminates HTTPS.
- **Data at rest:** backups are compressed and encrypted server-side in S3. Secrets in Git are sealed.

---

## Continuous integration

[`.github/workflows/ci.yaml`](.github/workflows/ci.yaml) runs on every push and pull request to `main`:

| Check | Tooling |
|---|---|
| YAML lint | yamllint |
| Schema validation of plain manifests, including CRDs | kubeconform with the CRDs-catalog schemas |
| n8n chart lint and render with our values | helm lint, helm template, kubeconform |
| Render every pinned chart with the values Argo CD uses | helm template, kubeconform |
| Misconfiguration scan of the repo and the rendered n8n chart | Trivy (HIGH and CRITICAL block the build) |
| Policy: no plaintext Secrets, no `:latest` tags, no `prune: true` | grep rules |
| Shell scripts | shellcheck, `bash -n` |
| Secret leaks across the full history | gitleaks |

---

## Further documentation

| Document | Purpose |
|---|---|
|  |
| [docs/disaster-recovery.md](docs/disaster-recovery.md) | Backup design and the step-by-step recovery runbook |
| [docs/operations.md](docs/operations.md) | Day-2 tasks: sealing secrets, upgrades, scaling, useful commands |
