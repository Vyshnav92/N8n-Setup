# Operations Guide

Day-2 tasks for the platform. Every change goes through Git. Argo CD applies `main` automatically and reverts manual edits in the cluster (`selfHeal: true`).

## Change workflow

1. Create a branch and make the change.
2. Open a pull request. CI lints, schema-validates, renders every chart and runs the security scans.
3. Merge to `main`. Argo CD syncs within its polling interval. To sync immediately, use the Argo CD UI or `argocd app sync <app>`.

## Sealing a secret

Secrets are committed only as SealedSecrets. To create or rotate one:

```bash
kubectl create secret generic n8n-smtp-credentials \
  --namespace n8n \
  --from-literal=username='...' \
  --from-literal=password='...' \
  --dry-run=client -o yaml \
| kubeseal --format yaml > deploy/base/sealed-n8n-smtp-credentials.yaml
```

- `kubeseal` uses the in-cluster controller (`sealed-secrets-controller` in `kube-system`) by default.
- Seal for the namespace where the Secret is consumed. `redis-cluster-auth` exists in both `n8n` and `redis-ha`, so seal it twice.
- **Never change `N8N_ENCRYPTION_KEY`** on a running installation. It encrypts every stored credential.
- After a rotation, run `ops/keys-backup.sh` so the off-cluster backup stays current.

## Upgrading components

### n8n

The n8n chart version appears in three places, and the task-runner tag must match the chart's n8n version:

| File | Field |
|---|---|
| `argocd/apps/n8n.yaml` | `targetRevision` |
| `.github/workflows/ci.yaml` | `--version` in the *Lint Helm chart* and *Render n8n chart* steps |
| `deploy/n8n-values.yaml` | `taskRunners.image.tag`, which must equal the chart's `appVersion` plus `-distroless` |

Before you merge:

- Read the chart's `UPGRADING.md` for breaking value changes.
- Take an on-demand base backup (see [Useful commands](#useful-commands)).

### Platform charts

Bump `targetRevision` in the matching `argocd/apps/*.yaml`. The CI job `render-charts` renders the new version with the values Argo CD uses and fails if the chart is missing or no longer validates.

### Rebuild-time versions

Argo CD, Sealed Secrets and kube-prometheus-stack are pinned in `dr/versions.env`. Running `./ops/dr-up.sh preflight` confirms every pinned chart still exists in its registry.

## Removing a resource

Every Application runs with `prune: false`, so deleting a file from Git does **not** delete the object in the cluster. This is deliberate: it protects the database and its volumes. To remove something:

1. Delete the file and merge.
2. Delete the object by hand: `kubectl delete <kind> <name> -n <namespace>`.
3. Check that Argo CD shows the Application as `Synced`.

## Scaling settings

| Component | File | Setting |
|---|---|---|
| Workers | `deploy/n8n-values.yaml` | `keda.worker.minReplicaCount` / `maxReplicaCount`, `listLength` (jobs waiting per worker) |
| Webhook processors | `deploy/n8n-values.yaml` | `hpa.webhookProcessor.*` |
| Concurrency per worker | `deploy/n8n-values.yaml` | `N8N_CONCURRENCY_PRODUCTION_LIMIT` |
| PostgreSQL | `deploy/base/postgres-cluster.yaml` | `instances`, `resources`, `storage.size` |
| PgBouncer | `deploy/base/postgres-pooler.yaml` | `instances`, `default_pool_size`, `max_client_conn` |
| Redis | `argocd/apps/redis-ha.yaml` | `cluster.nodes`, `persistence.size`, resources |

The VPA object `n8n-main` publishes resource recommendations without applying them:

```bash
kubectl -n n8n describe vpa n8n-main
```

## Useful commands

```bash
# GitOps status
kubectl -n argocd get applications

# n8n workloads and autoscalers
kubectl -n n8n get deploy,hpa,scaledobject,pdb

# PostgreSQL cluster health (needs the cnpg kubectl plugin)
kubectl cnpg status n8n-db -n n8n

# Backups
kubectl -n n8n get backups,scheduledbackups
kubectl cnpg backup n8n-db -n n8n --method plugin --plugin-name barman-cloud.cloudnative-pg.io   # on demand

# Redis cluster state
kubectl -n redis-ha get secret redis-cluster-auth -o jsonpath='{.data.redis-password}' | base64 -d \
| kubectl -n redis-ha exec -i redis-ha-redis-cluster-0 -- \
    sh -c 'IFS= read -r REDISCLI_AUTH; export REDISCLI_AUTH; redis-cli cluster info'

# Open the UI
kubectl -n n8n port-forward svc/nginx-proxy 8443:443

# Active alerts
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090
# then open http://localhost:9090/alerts
```

## Accepted CI exceptions

The Trivy scan of the rendered n8n chart ignores two checks, listed in the CI workflow:

| Check | Reason |
|---|---|
| `KSV-0014` (read-only root filesystem) | n8n writes to its home directory and `/tmp` at runtime. The chart deliberately does not support a read-only root filesystem |
| `KSV-0118` (default security context) | The chart's security context is accepted as is for this proof of concept |

Review both when the chart is upgraded.
