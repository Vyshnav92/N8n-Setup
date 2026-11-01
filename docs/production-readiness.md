# Production-Readiness Review

**Scope:** every manifest, Helm values file, Argo CD application, CI workflow and ops script in this repository.
**Reviewed against:** n8n chart `1.15.0` (n8n `2.42.4`) and the chart versions pinned in `argocd/apps/`.
**Date:** November 2026

## Verdict

**Strong proof of concept. Not yet production-ready.**

The foundations are at production standard: GitOps delivery, sealed secrets, point-in-time database recovery, a scripted and tested disaster-recovery rebuild, queue-mode scaling, network policies and CI security gates.

Five items block a production rollout:

1. There is no external entry point and no real hostname.
2. Redis runs on unmaintained images.
3. A default from the n8n chart blocks node drains.
4. The request path has single points of failure.
5. Monitoring configuration is not managed in Git.

Each fix is contained. None requires redesigning the architecture.

---

## What is already production-grade

| Area | Evidence |
|---|---|
| GitOps | App-of-apps, every chart version pinned, self-heal on, `prune: false` enforced by CI to protect stateful data |
| Secrets | Sealed Secrets only. CI blocks plaintext `Secret` manifests. gitleaks scans the full history |
| Database HA | CloudNativePG with primary and streaming replica, automatic failover, PgBouncer pooling, TLS with CA verification |
| Backups | Continuous WAL archiving and daily base backups to S3, compressed and encrypted, 14-day point-in-time recovery |
| Disaster recovery | `ops/dr-up.sh`: preflight checks, a safe drill mode that cannot touch the production archive, idempotent steps, post-recovery verification |
| Scaling | Queue mode. KEDA scales workers on queue depth. HPA scales webhook processors. Argo CD ignores replica counts so the autoscalers own them |
| Isolation | Code nodes run in distroless, non-root task-runner sidecars. High-risk nodes are disabled. Env access from nodes is blocked. SSRF protection is on |
| Network | Default-deny ingress, explicit allow rules per component, `/metrics` not exposed through the proxy |
| Least privilege | No RBAC and no service-account token for n8n pods. Capabilities dropped |
| Alerting | 17 alerts covering availability, scaling, data stores, backup freshness and node capacity |
| CI | yamllint, kubeconform (including CRDs), helm lint and render, Trivy (blocking), shellcheck, gitleaks, repository policy rules |

---

## Findings

Priority levels:

- **P1** must be fixed before production.
- **P2** should be fixed before or soon after go-live.
- **P3** is hardening and hygiene.

### P1: blockers

#### P1-1. No external entry point or real hostname

- **Where:** `deploy/base/nginx-proxy.yaml`, `deploy/n8n-values.yaml`
- **Finding:** The `nginx-proxy` Service is `ClusterIP` and is reached only through `kubectl port-forward`. `webhook.url` and `editor.url` are `https://localhost:8443`, and the HTTP-to-HTTPS redirect is hard-coded to `localhost:8443`. The TLS certificate is a static, manually sealed secret with no renewal.
- **Impact:** External systems cannot call webhooks. Webhook URLs shown in the editor point to localhost. The certificate will expire silently.
- **Recommendation:**
  - Expose the proxy through an Ingress, the Gateway API or a LoadBalancer, with a real DNS name.
  - Issue the certificate through cert-manager (already installed) using ACME or the corporate CA.
  - Set both n8n URLs to the public hostname.
  - Redirect to `https://$host$request_uri`.

#### P1-2. Redis uses unmaintained images

- **Where:** `argocd/apps/redis-ha.yaml`
- **Finding:** The image is `bitnamilegacy/redis-cluster` with `global.security.allowInsecureImages: true`. Bitnami moved its free images to the `bitnamilegacy` repository, which no longer receives updates. The release also uses `resourcesPreset: nano` (around 100m CPU and 128Mi memory per node), 1Gi volumes and no TLS.
- **Impact:** The queue backend receives no security patches. Undersized nodes risk OOM kills under load, and losing Redis stops all executions.
- **Recommendation:**
  - Move to a maintained Redis or Valkey distribution, through an operator or an actively maintained chart.
  - Set explicit resource requests and limits sized from load testing.
  - Enable TLS if internal policy requires encryption in transit.

#### P1-3. The n8n chart's default PDB blocks node drains

- **Where:** `deploy/n8n-values.yaml`, which does not set `pdb`
- **Finding:** Chart `1.15.0` defaults to `pdb.enabled: true` with `minAvailable: 1`. It renders a PodDisruptionBudget `n8n-main` for a Deployment that has exactly one replica.
- **Impact:** The eviction API can never evict the main pod. `kubectl drain`, node upgrades and cluster-autoscaler scale-down hang on the node that runs main.
- **Recommendation:** Set `pdb.enabled: false` and accept a short restart of main during maintenance. The alternative is multi-main, which requires an n8n Enterprise licence. Worker and webhook-processor PDBs are already defined in `deploy/base/`.

#### P1-4. Single points of failure on the request path

- **Where:** `deploy/base/nginx-proxy.yaml` (`replicas: 1`), `deploy/base/postgres-pooler.yaml` (`instances: 1`)
- **Finding:** Every request passes through one proxy pod, and every database connection passes through one PgBouncer pod. Neither has a PDB or a topology spread. n8n main is also a single replica, but that is a licensing constraint (see P1-3).
- **Impact:** One pod restart or node failure causes a full outage of the UI and webhooks, or of all database access, even though PostgreSQL itself has a standby.
- **Recommendation:** Run at least 2 replicas of each, with a PodDisruptionBudget and `topologySpreadConstraints` across nodes. Add a liveness probe to the proxy.

#### P1-5. Monitoring stack and alert routing are not in Git

- **Where:** `ops/dr-up.sh` step 3, `.gitignore` (`alertmanager-values.yaml`)
- **Finding:** kube-prometheus-stack is installed by a `helm upgrade --install` inside the DR script, not by Argo CD. Alertmanager receivers live in a local, git-ignored file.
- **Impact:** Monitoring configuration drifts from Git. A rebuild without that local file loses alert delivery, so alerts fire but reach nobody. The DR script warns about this but cannot fix it.
- **Recommendation:** Add an Argo CD Application for kube-prometheus-stack with its values in Git. Store the Alertmanager configuration as a SealedSecret.

### P2: should fix

#### P2-1. Database sizing and durability

- **Where:** `deploy/base/postgres-cluster.yaml`, `deploy/n8n-values.yaml`
- **Findings:**
  - Storage is 2Gi, and `N8N_DEFAULT_BINARY_DATA_MODE=database` stores every binary payload inside PostgreSQL.
  - No `storageClass` is set.
  - Replication is asynchronous, with a single standby.
  - The PostgreSQL image is implicit: the operator default, which changes with operator upgrades.
- **Impact:** The disk fills quickly under real workloads. A failover can lose the most recently committed transactions. A database version can change during an operator upgrade.
- **Recommendation:**
  - Size the volume from expected execution volume, and use a StorageClass that allows volume expansion.
  - Run 3 instances.
  - If no committed data may be lost (RPO of zero), enable synchronous replication (`minSyncReplicas: 1`).
  - Pin `imageName`.
  - Consider external object storage for binary data where the n8n licence allows it.

#### P2-2. Alert timing is too sensitive

- **Where:** `deploy/base/prometheus-rules.yaml`
- **Finding:** `N8nComponentDown`, `PodCrashLooping`, `PostgresNotReady` and `RedisClusterDegraded` use `for: 10s`. `NodeMemoryHigh` uses `for: 30s`.
- **Impact:** Normal rollouts, pod restarts and database switchovers will page on-call. This leads to alert fatigue.
- **Recommendation:** Use 2 to 5 minutes for critical alerts and 10 to 15 minutes for warnings. Route `critical` and `warning` to different receivers.

#### P2-3. Replicas can land on the same node

- **Where:** `deploy/n8n-values.yaml`
- **Finding:** The chart adds no anti-affinity or topology spread for workers or webhook processors unless multi-main is enabled.
- **Impact:** One node failure can remove every replica of a component, despite the PDBs.
- **Recommendation:** Set `affinity` or `nodePlacement` values to spread each component across nodes (and zones, where available).

#### P2-4. The logical-dump restore path is orphaned

- **Where:** `ops/pg-restore-job.yaml`, `deploy/base/sealed-s3-backup.yaml`
- **Finding:** The job restores `pg_dump` archives from the `n8n-backup-v1` bucket, but the CronJob that produced those dumps has been removed.
- **Impact:** Running the job would restore an outdated dump. It also adds a confusing second DR path.
- **Recommendation:** Decide on one of two options. Either reinstate the dump CronJob as an independent second backup layer, which is worthwhile protection against archive corruption. Or remove the job and the `s3-backup` secret. Point-in-time recovery is the primary path either way.

#### P2-5. Argo CD governance and environments

- **Where:** `argocd/apps/*.yaml`, `bootstrap/root.yaml`
- **Findings:**
  - Every Application uses the `default` AppProject, which is unrestricted.
  - Git sources track `main` directly.
  - There is one environment, with no overlays.
- **Impact:** Any change merged to `main` reaches the cluster immediately. There is no staging gate. The Applications are not limited in which repositories, namespaces or cluster-scoped resources they may manage.
- **Recommendation:**
  - Create a dedicated AppProject that restricts source repositories, destinations and cluster resources.
  - Introduce per-environment overlays (Kustomize, or values files per environment).
  - Promote changes through tags or environment branches.
  - Protect `main` with required reviews and required CI checks.

#### P2-6. Key backups are manual and stored in a personal location

- **Where:** `ops/keys-backup.sh`
- **Finding:** Sealing keys and the n8n encryption key are uploaded by hand, through rclone, to a Google Drive remote.
- **Impact:** Sealed Secrets generates a new key about every 30 days. A missed manual run means newer secrets cannot be decrypted after a rebuild. A personal drive is also not an acceptable custody location for production keys.
- **Recommendation:**
  - Store the backups in organisation-owned storage, such as an S3 bucket with KMS or a secrets manager.
  - Run the backup on a schedule.
  - Alert when the newest backup is older than the key-rotation period.

#### P2-7. Settings for local clusters only

- **Where:** `argocd/apps/metrics-server.yaml`
- **Finding:** metrics-server runs with `--kubelet-insecure-tls`.
- **Impact:** metrics-server does not verify the kubelet's identity. This is acceptable on kind or minikube, not on a production cluster.
- **Recommendation:** Remove the flag, or use the managed provider's metrics-server.

### P3: hardening and hygiene

| ID | Where | Finding | Recommendation |
|---|---|---|---|
| P3-1 | `deploy/base/namespace.yaml` | Pod Security is `warn` and `audit` only. n8n chart pods do not set `seccompProfile` or `runAsNonRoot`, so `enforce: restricted` would reject them today | Set those fields (through values or a mutating policy), then switch to `enforce` |
| P3-2 | `deploy/base/networkpolicies.yaml` | Only ingress is restricted | Add egress allow-lists for PostgreSQL, PgBouncer, Redis and the proxy. n8n itself needs open outbound access for workflows |
| P3-3 | All images | Images are pinned by tag, not by digest. `nginx-unprivileged:1.28-alpine` floats across patch releases | Pin by digest and let Renovate or Dependabot propose updates |
| P3-4 | `deploy/n8n-values.yaml` | SMTP uses a personal Gmail account. Bucket names and topology are visible in a public repository | Use an organisational mail relay. Consider making the repository private. Sealed values stay safe while the private key is protected |
| P3-5 | `deploy/n8n-values.yaml` | The task-runner image tag is pinned separately from the chart's n8n version. Both are `2.42.4` today, which is correct | Bump both together on every chart upgrade. A comment in the values file now says so |
| P3-6 | `deploy/base/nginx-proxy.yaml` | The webhook rate limit is per pod, so the effective limit grows with the replica count | Decide whether the limit should be global. If so, enforce it at the ingress layer |
| P3-7 | `.github/workflows/ci.yaml` | `trivy-action@v0.36.0` bundles an older Trivy, and some newer checks are skipped | Update the action regularly |

---

## Suggested sequence

| Phase | Items | Outcome |
|---|---|---|
| 1. Go-live blockers | P1-1 to P1-5 | Reachable, patched, drainable and observable |
| 2. Resilience | P2-1 to P2-4, P2-7 | Survives a node loss and fails over without noise |
| 3. Governance | P2-5, P2-6 | Controlled change promotion and key custody |
| 4. Hardening | P3 items | Defence in depth |
