# Backup and Disaster Recovery

This runbook covers what is backed up, where it is stored, and how to rebuild the whole platform on a new, empty Kubernetes cluster.

## What must survive a cluster loss

| Asset | Why it matters | Where it is kept | How |
|---|---|---|---|
| PostgreSQL data | Workflows, credentials, execution history | S3 bucket `n8n-pitr-backup`, prefix `n8n/` | Barman Cloud plugin: continuous WAL archiving and a daily base backup |
| Sealed Secrets private keys | Decrypt every `sealed-*.yaml` in Git | Off-cluster remote `gdrive:n8n-dr`, age-encrypted | `ops/keys-backup.sh` |
| `N8N_ENCRYPTION_KEY` | Decrypts the credentials stored in the database | Same remote, age-encrypted, and inside the `n8n-secrets` SealedSecret | `ops/keys-backup.sh` |
| Platform configuration | Everything else | This Git repository | Argo CD |

> Restoring the database without the **same** `N8N_ENCRYPTION_KEY` produces an n8n instance whose stored credentials cannot be decrypted. The DR script refuses to continue if the key in Git does not match the backup.

### Database backup details

These settings live in `deploy/base/objectstore.yaml` and `deploy/base/scheduled-backup.yaml`:

| Setting | Value |
|---|---|
| WAL archiving | Continuous, zstd compression, AES-256 server-side encryption, 2 parallel uploads |
| Base backups | Daily at 21:00 UTC (02:30 IST). One more is taken as soon as the schedule is created |
| Retention | 14 days, which is also the point-in-time recovery window |
| Monitoring | Alerts `PostgresWalArchiveBacklog`, `PostgresBackupFailed` and `PostgresNoRecentBaseBackup` |

**Recovery point:** a WAL segment is archived when it fills, or after CloudNativePG's archive timeout of 5 minutes by default. In the worst case you lose the last few minutes of committed data.

---

## Routine: back up the keys

Run this after the first install, after every Sealed Secrets key rotation (about every 30 days), and after changing `n8n-secrets`:

```bash
AGE_RECIPIENT=age1...your-public-key ./ops/keys-backup.sh
```

The script needs `kubectl`, `jq`, `age`, and `rclone` with a remote named `gdrive`.

It uploads two files: `sealing-keys-YYYYMMDD.json.age` and `n8n-secrets-YYYYMMDD.json.age`. The age **private** key never touches the cluster. Store it separately, for example in a password manager.

---

## Full rebuild: `ops/dr-up.sh`

### Inputs

| Input | Default location | Override |
|---|---|---|
| age identity (private key) | `../age-key.txt`, next to the repository folder | `AGE_IDENTITY=/path` |
| rclone configuration with the `gdrive` remote | `../rclone.conf` | `RCLONE_CONFIG=/path` |
| Pinned platform versions | `dr/versions.env` | edit the file |
| kubectl context | current context | point it at the **new** cluster |

Optional environment variables:

| Variable | Purpose |
|---|---|
| `TARGET_TIME=2026-10-29T08:00:00Z` | Restore to a moment in time. The default is the end of the archive |
| `SOURCE_SERVER=n8n-db` | S3 folder to restore from. Needed after an earlier real DR run created a new folder |
| `BACKUP_DATE=YYYYMMDD` | Which key backup to use. The default is the newest matching pair |
| `START_N8N=0` | Restore PostgreSQL and Redis but leave n8n stopped |
| `MONITORING_VALUES`, `ALERTMANAGER_VALUES` | Extra Helm values for kube-prometheus-stack |

### Commands

```bash
./ops/dr-up.sh preflight        # read-only: tools, inputs, backups decrypt, cluster empty, charts still published
./ops/dr-up.sh                  # DRILL: full rebuild, does not archive to S3
./ops/dr-up.sh --real           # REAL: the new cluster archives to a new S3 folder
./ops/dr-up.sh verify           # post-recovery checks only
./ops/dr-up.sh clean            # remove leftovers of a failed drill (refuses on a cluster that archives WAL)

./ops/dr-up.sh 2>&1 | tee dr.log   # keep a log
```

The script asks you to type the kubectl context name before it changes anything. Real mode also asks you to type `REAL`. Every step checks what already exists, so after a failure you fix the cause and run the script again.

### Drill mode compared with real mode

| | Drill (default) | Real (`--real`) |
|---|---|---|
| Use when | Testing the procedure while production is running | Production is lost |
| WAL archiving on the restored database | **Off**, so it cannot write to the production archive | On, to a **new** folder `n8n-db-drYYYYMMDDHHMM` |
| Daily `ScheduledBackup` | Not applied | Applied, and a first base backup is taken immediately |
| `root` app and Git-managed PostgreSQL cluster | Not applied | Hand-over steps printed at the end |
| Risk | The restored n8n runs **active** workflows next to production. Use `START_N8N=0` to avoid this | None beyond the outage itself |

### What the script does

| Step | Action |
|---|---|
| Preflight | Checks tools and inputs. Downloads and decrypts both key backups. Checks the Kubernetes version, the default StorageClass, capacity, network reach, and that every pinned chart is still published |
| 1 | Restores the Sealed Secrets keys, then installs the controller, so the keys exist before the controller starts |
| 2 | Installs Argo CD and registers the OCI Helm registries |
| 3 | Installs kube-prometheus-stack, which provides the monitoring CRDs |
| 4 | Applies the platform apps (cert-manager, CloudNativePG, Barman Cloud plugin, KEDA, VPA, metrics-server) and waits until they are healthy |
| 5 | Syncs `deploy/base` **without** the PostgreSQL Cluster. Checks that every SealedSecret decrypts and that `N8N_ENCRYPTION_KEY` matches the backup |
| 6 | Creates the PostgreSQL cluster in **recovery** mode from the S3 archive, optionally to `TARGET_TIME`. Checks that workflows exist |
| 7 | Starts Redis, waits for the pooler, then starts n8n |
| 8 | Real mode only: takes a first base backup into the new archive folder |
| Post-checks | Argo CD health, secrets, pods, replication, TLS, WAL archiving, Redis cluster state, KEDA, `/healthz` and `/healthz/readiness` through the proxy, NetworkPolicies, alert rules, Prometheus targets |

### Checks you do by hand (about 2 minutes)

1. Run `kubectl -n n8n port-forward svc/nginx-proxy 8443:443`, open <https://localhost:8443> and log in.
2. Open a stored credential and run a workflow that uses it. This proves the encryption key is correct.
3. Run a workflow and watch a worker pick it up and finish it.

### Real mode: hand the cluster back to GitOps

At the end, the script prints these steps with the actual folder names filled in:

1. In `deploy/base/postgres-cluster.yaml`, set `serverName: <new folder>` under `spec.plugins[].parameters`.
2. In `argocd/apps/n8n-base.yaml`, add an `ignoreDifferences` entry for `/spec/bootstrap` and `/spec/externalClusters` of the `Cluster`, and add `RespectIgnoreDifferences=true` to the sync options.
3. Commit, push, and run `kubectl apply -f bootstrap/root.yaml`.
4. Record the old and new archive folder names. The next recovery uses `SOURCE_SERVER=<newest folder>`.

---

## Partial procedures

### Restore only the Sealed Secrets keys

Use this on a new cluster after the controller is installed and before Argo CD syncs:

```bash
AGE_IDENTITY=~/age-key.txt ./ops/keys-restore.sh                                    # newest backup
AGE_IDENTITY=~/age-key.txt ./ops/keys-restore.sh sealing-keys-20261024.json.age     # a specific backup
DRY_RUN=1 AGE_IDENTITY=~/age-key.txt ./ops/keys-restore.sh                          # validate only
```

### Restore a logical dump (legacy)

`ops/pg-restore-job.yaml` restores the newest `pg_dump` archive from the `n8n-backup-v1` bucket. It refuses to overwrite a database that already contains workflows unless `ALLOW_OVERWRITE` is set to `"true"`.

> The CronJob that produced these dumps has been removed, so the newest dump may be old. Prefer point-in-time recovery. See P2-4 in [production-readiness.md](production-readiness.md).

---

## Recommended drill cadence

- **Monthly:** `./ops/dr-up.sh preflight` against a scratch cluster. This confirms that the backups decrypt and every pinned chart still exists.
- **Quarterly:** a full drill with `START_N8N=0`, recording the total time (the script prints it) as the measured recovery time.
- **After every key rotation:** `ops/keys-backup.sh`.
