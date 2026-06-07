# Elasticsearch 8.15.5 — 2-Node TLS Cluster on Minikube

## Overview

A production-style 2-node Elasticsearch 8.15.5 cluster on Kubernetes (minikube)
with:
- xpack security (TLS on HTTP + transport)
- Per-node auto-generated certificates
- Headless Service for stable DNS-based discovery
- Kibana connected as `kibana_system` user
- Monthly cert rotation CronJob (placeholder)

## Architecture

```
┌───────────────────────────────────────────────────────────────────────────────────┐
│                              ./deploy.sh                                          │
│                                                                                   │
│  ┌──────────┐ ┌────────────┐ ┌────────────┐ ┌──────────────┐ ┌────────────────┐   │
│  │ Phase 0  │ │ Phase 1    │ │ Phase 2    │ │ Phase 3      │ │ Phase 4 + 5    │   │
│  │ Infra    │ │ Bootstrap  │ │ StatefulSet│ │ Set Password │ │ Kibana +       │   │
│  │          │ │ Job        │ │ + Verify   │ │              │ │ Restart        │   │
│  └────┬─────┘ └─────┬──────┘ └─────┬──────┘ └──────┬───────┘ └───────┬────────┘   │
│       │             │              │               │                 │            │
│       ▼             ▼              ▼               ▼                 ▼            │
│  ┌──────────┐ ┌──────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐     │
│  │namespace │ │certutil  │ │ ES pods      │ │ kibana_system│ │ Kibana       │     │
│  │secrets   │ │CA+node   │ │ start fresh  │ │ password set │ │ deploy +     │     │
│  │RBAC      │ │certs     │ │(data wiped)  │ │ via API      │ │ restart      │     │
│  │service   │ │          │ │              │ │              │ │              │     │
│  │configmap │ │k8s Secret│ │pwd verified  │ │              │ │              │     │
│  └──────────┘ └──────────┘ └──────┬───────┘ └──────────────┘ └──────────────┘     │
│                                   │                                               │
│                                   ▼                                               │
│                           ┌────────────────┐                                      │
│                           │ Headless       │                                      │
│                           │ Service        │                                      │
│                           │ elasticsearch  │                                      │
│                           │ :9200, :9300   │                                      │
│                           └────────────────┘                                      │
└───────────────────────────────────────────────────────────────────────────────────┘
```

### Certificate Flow

```
elasticsearch-certutil (Bootstrap Job)
        │
        ├──> ca.zip ──> ca.crt + ca.key
        │
        ├──> instances.yml (elasticsearch-0, elasticsearch-1 DNS/IP)
        │
        └──> certs.zip ──> elasticsearch-0.crt + .key
                           elasticsearch-1.crt + .key
                                  │
                                  ▼
                        kubectl create secret generic elastic-certs
                                  │
                    ┌─────────────┴──────────┐
                    │                         │
                    ▼                         ▼
            StatefulSet Pods           Kibana Pod
            (copy-certs init)          (mounts ca.crt only)
                    │
                    ▼
            /usr/share/elasticsearch/config/certs/
              ca.crt  es.crt  es.key
```

### Password Flow

```
secrets.yaml (static passwords)
     │
     ├── elastic-password: elastic123
     └── kibana-password: kibana123
              │
              ▼
      Secret "elastic-credentials"
              │
     ┌────────┴──────────────┐
     │                       │
     ▼                       ▼
StatefulSet env          set-password Job
ELASTIC_PASSWORD         │
                         ├──> Wait for 401 (ES up)
                         ├──> Wait for 200 (cluster healthy)
                         └──> POST _security/user/kibana_system/_password

                         Kibana Deployment
                         ELASTICSEARCH_PASSWORD from same secret
```

## Deployment

```bash
# Prerequisites: minikube running, kubectl configured
./deploy.sh
```

The script runs 6 phases sequentially:

| Phase | Resource | Waits For | Purpose |
|-------|----------|-----------|---------|
| 0     | namespace, secrets, RBAC, service, configmap | — | Infrastructure |
| 1     | bootstrap-job | completion | Generate TLS certs, create `elastic-certs` Secret |
| 2     | statefulset | all pods ready (5m timeout) | Start 2 ES nodes with `cluster.initial_master_nodes` for bootstrap |
| 2b    | — | — | Verify elastic password; reset via `elasticsearch-reset-password` if ES auto-generated a different one. Updates k8s secret if changed. |
| 3     | set-password-job | completion (5m timeout) | Set `kibana_system` password via API |
| 4     | kibana-service, kibana | rollout ready (3m timeout) | Deploy Kibana |
| 5     | kibana restart | rollout ready (3m timeout) | Restart Kibana so it picks up fresh `kibana_system` credentials |

### What deploy.sh handles automatically

| Issue | How deploy.sh / static config fixes it |
|-------|----------------------------------------|
| GC thrashing (256m heap) | `statefulset.yaml` sets `ES_JAVA_OPTS: -Xms512m -Xmx512m -XX:+AlwaysPreTouch` |
| OOMKilled (1Gi limit) | `statefulset.yaml` sets memory request 1Gi, limit 2Gi |
| Stale cluster state on PVC | `fix-permissions` init container runs `rm -rf` on data directory every start |
| `cluster.initial_master_nodes` warning | Env var is kept in YAML for bootstrap; the warning is cosmetic. Optional manual removal post-deploy. |
| `ELASTIC_PASSWORD` not honoured | Phase 2b verifies auth; resets via `elasticsearch-reset-password -b` if needed, updates k8s Secret |
| `publishNotReadyAddresses` | `headless-service.yaml` omits the field (defaults to `false`) |
| Kibana stale auth token | Phase 5 rolls out restart after password job completes |

## Access

```bash
# Elasticsearch (from within cluster / exec)
kubectl exec -n elk elasticsearch-0 -- curl -sk -u "elastic:elastic123" \
  "https://localhost:9200/_cluster/health?pretty"

# Kibana via port-forward
kubectl port-forward -n elk svc/kibana 5601:5601
# Then open http://localhost:5601

# Kibana via NodePort
minikube service kibana -n elk
```

## Issues Encountered & Resolutions

### 1. Heap too small → GC thrashing → readiness timeout

**Symptom:** Pod starts but readiness probe never succeeds (exits after 60
failures = 5 min). Logs show `[gc] overhead, spent 1s collecting in the last
1.2s` (57% GC). DNS resolution failures like `failed to resolve host
[elasticsearch-1.elasticsearch]` appear — these are *symptoms* of a node that
cannot participate in elections due to GC, not the root cause.

**Root cause:** Default heap is 256MB (minikube cgroup limit of 1GB → ES JVM
uses ~256m by default). At 57% GC overhead the node cannot respond to cluster
coordination pings, gets excluded, and DNS becomes irrelevant.

**Fix:** Set `ES_JAVA_OPTS: "-Xms512m -Xmx512m -XX:+AlwaysPreTouch"`.

**Debug:**
```bash
kubectl logs -n elk elasticsearch-0 --tail 50 | grep -E "gc|overhead|elected|discovery"
```

---

### 2. Memory limit too tight → OOMKilled (exit 137)

**Symptom:** Pod crashes with `Exit Code: 137, Reason: OOMKilled` after running
for ~90 seconds. Cluster was forming (elected master, nodes joining, shard
recovery starting) then killed.

**Root cause:** 512m heap + `AlwaysPreTouch` = 512MB physically committed at
startup. JVM overhead (metaspace, threads, code cache) + direct memory
(netty/Lucene) pushes total above the container limit.

With 1Gi limit:
- 512m heap (pre-touched) + ~300-400m JVM/native overhead = ~800-900m
- Shard recovery adds temporary memory pressure → exceeds 1Gi

**Fix:** Raise container memory:
- request: `768Mi → 1Gi`
- limit: `1Gi → 2Gi`

**Debug:**
```bash
kubectl describe pod -n elk elasticsearch-1 | grep -E "Reason:|Exit Code:"
kubectl logs -n elk elasticsearch-1 --tail 30
# Exit code 137 = SIGKILL = OOM
```

---

### 3. Stale cluster state on PVC after delete (automated in deploy.sh)

**Symptom:** Even after `kubectl delete pvc`, the new pod picks up the old
cluster UUID and node IDs. Old `voting_configuration` references a master node
ID that no longer exists. The warning shows an unexpected master node ID.

**Root cause:** minikube uses hostPath provisioner. Deleting a PVC removes the
Kubernetes claim object but the underlying host directory (`/tmp/hostpath-pv/…`)
is **not** cleaned. The new pod mounts the same directory and finds the old
`node.lock` and `nodes/` files.

**Fix (automated):** The `fix-permissions` init container in `statefulset.yaml`
now runs `rm -rf /usr/share/elasticsearch/data/* /usr/share/elasticsearch/data/.*`
on every pod start, ensuring the data directory is always clean before ES starts.
This is safe because:
- With `OrderedReady` pod management, pods restart one at a time; the remaining
  node holds the cluster state and data, which gets replicated to the restarting
  pod.
- On a fresh deployment both pods start empty and form a new cluster.

**Manual alternative** (if you need to clean hostPath directly):
```bash
minikube ssh "sudo rm -rf /tmp/hostpath-provisioner/elk/"
minikube ssh -n minikube-m02 "sudo rm -rf /tmp/hostpath-provisioner/elk/"
```

---

### 4. `cluster.initial_master_nodes` not removed after bootstrap

**Symptom:** Log warning on every startup:
```
this node is locked into cluster UUID […] but cluster.initial_master_nodes is
set to […]; remove this setting to avoid possible data loss
```

**Root cause:** The env var `cluster.initial_master_nodes` is set in the
StatefulSet and never removed. It is **required** for the very first bootstrap
of a new cluster, but produces warnings on subsequent restarts.

**Status:** The env var is intentionally kept in `statefulset.yaml` because it
is mandatory for initial cluster formation. The warning is cosmetic and does
not affect functionality. If you want to suppress it, remove the env var from
`statefulset.yaml` after the first deployment:

```bash
# After all nodes have joined at least once:
kubectl set env statefulset/elasticsearch -n elk "cluster.initial_master_nodes-"
# This triggers a rolling restart; pods will start without the warning.
```

---

### 5. `ELASTIC_PASSWORD` env var not honoured (automated in deploy.sh)

**Symptom:** After fresh deployment, authenticating as `elastic` user with
the password from the secret fails:
```json
{"error":{"root_cause":[{"type":"security_exception",
  "reason":"unable to authenticate user [elastic] for REST request […]"}]}}
```

**Root cause:** Elasticsearch 8.x auto-configuration during first boot may
generate a random password for the `elastic` user and store it in the keystore,
ignoring the `ELASTIC_PASSWORD` environment variable. This depends on whether
the node detects it is in "auto-configuration" mode (no pre-existing
`elasticsearch.keystore`).

**Fix (automated in deploy.sh Phase 2b):**
1. After all ES pods are Ready, `deploy.sh` runs `curl -u "elastic:${PASSWORD}"`
   and checks for HTTP 200.
2. If auth fails, it runs `elasticsearch-reset-password -u elastic -b` (batch
   mode) inside the pod, captures the generated password, and updates the
   `elastic-credentials` k8s Secret so all subsequent phases use the correct
   password.

**To verify manually:**
```bash
kubectl exec -n elk elasticsearch-0 -- curl -sk -u "elastic:elastic123" \
  "https://localhost:9200/"
```

---

### 6. `publishNotReadyAddresses: true` on headless service

**Issue:** The original headless service had `publishNotReadyAddresses: true`,
which makes DNS return IPs for pods that are not yet Ready. This interferes
with the StatefulSet `OrderedReady` pod management policy, allowing a
not-yet-ready pod to be discovered before it can actually serve traffic.

**Fix:** Remove `publishNotReadyAddresses` (defaults to `false`). With
`OrderedReady`, pods start sequentially: pod-0 must be Ready before pod-1
begins. DNS only resolves Ready pods.

---

### 7. YAML document separator missing in multi-resource files

**Symptom:** `kubectl apply -f rbac.yaml` fails with:
```
Error from server (BadRequest): error when creating "rbac.yaml": RoleBinding
in version "v1" cannot be handled as a RoleBinding: strict decoding error:
unknown field "rules"
```

**Root cause:** When multiple Kubernetes resources are defined in a single YAML
file, they must be separated by a line containing only `---` (the YAML document
separator). Without it, kubectl's strict decoder treats the entire file as one
YAML document and validates all content against the first `kind` encountered.
In this case, the `rules` field from the `Role` bleeds into the `RoleBinding`
document, which does not accept that field.

**Fix:** Ensure `---` is present on its own line between every resource group
in `rbac.yaml` (ServiceAccount, Role, RoleBinding).

---

### 8. Kibana monitoring auth error after deployment (automated in deploy.sh)

**Symptom:** Kibana logs show:
```
unable to authenticate user [kibana_system] for REST request
[/_monitoring/bulk?system_id=kibana&system_api_version=7&interval=10000ms]
```

**Root cause:** The `set-password-job` runs AFTER the StatefulSet is ready, but
Kibana may have already started and cached an invalid auth token before the
password was set.

**Fix (automated in deploy.sh Phase 5):** After the password job completes,
`deploy.sh` waits for Kibana to roll out, then runs:
```bash
kubectl rollout restart deployment -n elk kibana
```
and waits for the new rollout to complete. This ensures Kibana picks up the
fresh `kibana_system` credentials before any monitoring uploads.

---

## Debugging Cheat Sheet

```bash
# Check pod status
kubectl get pods -n elk -o wide

# Check StatefulSet status
kubectl get statefulset -n elk elasticsearch

# View elasticsearch-0 logs (last 30 lines)
kubectl logs -n elk elasticsearch-0 --tail 30

# View elasticsearch-1 logs
kubectl logs -n elk elasticsearch-1 --tail 30

# Describe pod for OOM/error details
kubectl describe pod -n elk elasticsearch-1 | grep -E "Reason:|Exit Code:|State:"

# Check OOM events
kubectl get events -n elk --sort-by='.lastTimestamp' | tail -20

# Cluster health
kubectl exec -n elk elasticsearch-0 -- curl -sk -u "elastic:elastic123" \
  "https://localhost:9200/_cluster/health?pretty"

# List nodes
kubectl exec -n elk elasticsearch-0 -- curl -sk -u "elastic:elastic123" \
  "https://localhost:9200/_cat/nodes?v"

# Verify elastic user password
kubectl exec -n elk elasticsearch-0 -- curl -sk -u "elastic:elastic123" \
  "https://localhost:9200/"

# Check secret values
kubectl get secret -n elk elastic-credentials -o json | \
  jq -r '.data["elastic-password"]' | base64 -d

kubectl get secret -n elk elastic-credentials -o json | \
  jq -r '.data["kibana-password"]' | base64 -d

# Verify kibana_system password
kubectl exec -n elk elasticsearch-0 -- curl -sk \
  -u "kibana_system:$(kubectl get secret -n elk elastic-credentials \
  -o json | jq -r '.data["kibana-password"]' | base64 -d)" \
  "https://localhost:9200/"

# Tail all Elasticsearch logs for real-time debugging
kubectl logs -n elk elasticsearch-0 -f

# Check resource usage
kubectl top pods -n elk  # requires metrics-server
kubectl describe nodes | grep -A5 -E "(Name:|memory.*[0-9]+\%)"

# Wipe stale cluster data (when PVC cleanup isn't enough)
kubectl exec -n elk elasticsearch-0 -- rm -rf /usr/share/elasticsearch/data/*
kubectl exec -n elk elasticsearch-1 -- rm -rf /usr/share/elasticsearch/data/*
# Then delete pods to restart fresh
kubectl delete pod -n elk elasticsearch-0 elasticsearch-1 --force --grace-period=0
```

## Troubleshooting Common Scenarios

### Pod stuck in CrashLoopBackOff

1. Check exit code via `kubectl describe pod`
2. Exit 137 = OOM → increase memory limits
3. Exit 1 or 143 = process error → check logs
4. Readiness probe failing → `kubectl logs` for GC warnings

### Cluster not forming (both nodes Running but no master)

Check logs for:
- `failed to resolve host` → DNS issue with headless service
- `not elected as master` → GC/network issues
- `Node not connected` → transport TLS mismatch or pod not reachable

### Auth not working

1. Verify the password from the secret matches what was set
2. Check if ES is in auto-configuration mode (random generated password)
3. Reset password via the API or `elasticsearch-reset-password`

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates `elk` namespace |
| `secrets.yaml` | Static passwords for `elastic` and `kibana_system` |
| `rbac.yaml` | ServiceAccount, Role, and RoleBinding for bootstrap job to create Secrets |
| `headless-service.yaml` | DNS-based peer discovery (`elasticsearch-0.elasticsearch`) |
| `configmap.yaml` | Cluster-level config (minimal) |
| `bootstrap-job.yaml` | 2-container Job: cert-generator + secret-creator |
| `statefulset.yaml` | 2-replica ES with TLS, security, resource limits |
| `set-password-job.yaml` | Sets `kibana_system` password after cluster is healthy |
| `kibana-service.yaml` | NodePort service exposing Kibana on :5601 |
| `kibana.yaml` | Kibana Deployment connected to ES |
| `cert-rotation-cronjob.yaml` | Monthly cert rotation (placeholder) |
| `deploy.sh` | Orchestrates all phases in order |
