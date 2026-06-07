# Elasticsearch 8.15.5 — 2-Node TLS Cluster on Minikube

## Overview

A production-style 2-node Elasticsearch 8.15.5 cluster on Kubernetes (minikube) with xpack security (TLS on HTTP + transport), per-node auto-generated certificates, headless Service for stable DNS-based peer discovery, and Kibana connected as `kibana_system` user.

---

## deploy.sh Flow — End-to-End Timeline

```
deploy.sh
   │
   ├── Phase 0: Infrastructure ─────────────────────────────────────────────
   │   │
   │   ├── namespace.yaml   ──>  Namespace "elk" created
   │   ├── secrets.yaml     ──>  Secret "elastic-credentials" (elastic/kibana passwords)
   │   ├── rbac.yaml        ──>  ServiceAccount + Role + RoleBinding for bootstrap
   │   ├── headless-service.yaml ──>  Service "elasticsearch" (ClusterIP: None, :9200/:9300)
   │   └── configmap.yaml   ──>  ConfigMap "elasticsearch-config"
   │
   ├── Phase 1: Bootstrap Job ──────────────────────────────────────────────
   │   │
   │   ├── bootstrap-job.yaml applied
   │   │   ├── cert-generator container:
   │   │   │   ├── elasticsearch-certutil ca  ──>  ca.crt + ca.key
   │   │   │   ├── instances.yml (elasticsearch-0, elasticsearch-1 DNS/IP SANs)
   │   │   │   ├── elasticsearch-certutil cert ──>  per-node .crt + .key
   │   │   │   └── cp files → /shared/ (emptyDir)
   │   │   └── secret-creator container:
   │   │       ├── kubectl delete secret elastic-certs --ignore-not-found
   │   │       └── kubectl create secret generic elastic-certs
   │   │           ├── ca.crt
   │   │           ├── ca.key
   │   │           ├── elasticsearch-0.crt / .key
   │   │           └── elasticsearch-1.crt / .key
   │   └── kubectl wait --for=condition=complete job/elastic-bootstrap
   │
   ├── Phase 2: StatefulSet ────────────────────────────────────────────────
   │   │
   │   ├── statefulset.yaml applied
   │   │   │
   │   │   └── Kubernetes creates PVCs: elasticsearch-data-elasticsearch-{0,1}
   │   │       └── hostPath provisioner creates PVs on minikube nodes
   │   │
   │   ├── [pod: elasticsearch-0]  ──────────────────────
   │   │   ├── PVC bound to PV on minikube node
   │   │   ├── init: fix-permissions (wipe data, chown)
   │   │   ├── init: copy-certs (hostname → elasticsearch-0.crt → es.crt)
   │   │   └── main: elasticsearch starts
   │   │       ├── ELASTIC_PASSWORD from Secret → elastic user password
   │   │       ├── ES generates auto-configuration keystore
   │   │       ├── node.name = elasticsearch-0
   │   │       ├── discovery.seed_hosts = [...]
   │   │       ├── cluster.initial_master_nodes = [elasticsearch-0, elasticsearch-1]
   │   │       ├── TLS enabled on HTTP + transport
   │   │       ├── ES waits for discovery (no other nodes yet)
   │   │       ├── ES starts election with initial_master_nodes
   │   │       ├── elasticsearch-0 elected as first master
   │   │       ├── cluster formed (single node, yellow)
   │   │       ├── readiness probe returns 401 → pod Ready
   │   │       └── pod becomes 1/1
   │   │
   │   └── [pod: elasticsearch-1]  ──────────────────────
   │       ├── (waits for elasticsearch-0 to be Ready — OrderedReady)
   │       ├── PVC bound to PV on minikube-m02 node
   │       ├── init: fix-permissions (wipe data, chown)
   │       ├── init: copy-certs (hostname → elasticsearch-1.crt → es.crt)
   │       ├── main: elasticsearch starts
   │       │   ├── DNS resolves elasticsearch-0.elasticsearch → IP
   │       │   ├── Transport TLS handshake with mutual cert verification
   │       │   ├── Joins cluster, master adds to voting configuration
   │       │   ├── Shards replicated → cluster green
   │       │   └── readiness probe returns 401 → pod Ready
   │       └── pod becomes 1/1
   │
   ├── Phase 2b: Password Verification ──────────────────────────────────────
   │   ├── curl to elasticsearch-0 with elastic:elastic123
   │   ├── If HTTP 200: password OK (ES honoured ELASTIC_PASSWORD)
   │   └── If not 200: elasticsearch-reset-password -b, update Secret
   │
   ├── Phase 3: Set kibana_system Password ──────────────────────────────────
   │   ├── set-password-job.yaml applied
   │   ├── Pod waits for ES 401 (up) then 200 (cluster healthy)
   │   └── POST /_security/user/kibana_system/_password
   │
   ├── Phase 4: Deploy Kibana ───────────────────────────────────────────────
   │   ├── kibana-service.yaml (NodePort :5601)
   │   ├── kibana.yaml applied
   │   │   ├── Mounts ca.crt from elastic-certs Secret
   │   │   ├── Connects to https://elasticsearch:9200
   │   │   ├── Authenticates as kibana_system
   │   │   └── Rollout waits for ready
   │   └── kubectl rollout status deployment/kibana
   │
   ├── Phase 5: Restart Kibana ──────────────────────────────────────────────
   │   ├── kubectl rollout restart deployment/kibana
   │   └── kubectl rollout status (fresh creds, no stale auth token)
   │
   └── Phase 6: CronJob ────────────────────────────────────────────────────
       └── cert-rotation-cronjob.yaml (placeholder: monthly rotation)
```

---

## Pod Startup Sequence — Detailed

```
StatefulSet "elasticsearch" (replicas: 2, serviceName: "elasticsearch")
  Pod Management Policy: OrderedReady
  ├── Pod elasticsearch-0 created
  │   │
  │   ├── Step 1: PVC binding
  │   │   └── volumeClaimTemplates "elasticsearch-data" → PVC created
  │   │       └── StorageClass (hostPath) → PV provisioned on minikube node
  │   │
  │   ├── Step 2: Init container "fix-permissions"
  │   │   ├── rm -rf /usr/share/elasticsearch/data/*
  │   │   ├── mkdir -p data
  │   │   ├── chown -R 1000:0 data
  │   │   └── chmod -R 775 data
  │   │   └── Mount: elasticsearch-data (PVC)
  │   │
  │   ├── Step 3: Init container "copy-certs"
  │   │   ├── NODE_NAME=$(hostname)  →  "elasticsearch-0"
  │   │   ├── cp /certs-secret/ca.crt           → /elastic-certs/ca.crt
  │   │   ├── cp /certs-secret/elasticsearch-0.crt → /elastic-certs/es.crt
  │   │   ├── cp /certs-secret/elasticsearch-0.key  → /elastic-certs/es.key
  │   │   ├── chmod 640 /elastic-certs/*
  │   │   └── chown 1000:0 /elastic-certs/*
  │   │   └── Mounts:
  │   │       ├── elastic-certs-secret (Secret "elastic-certs" → /certs-secret)
  │   │       └── elastic-certs (emptyDir → /elastic-certs)
  │   │
  │   └── Step 4: Main container "elasticsearch"
  │       ├── Env: ELASTIC_PASSWORD from Secret "elastic-credentials"
  │       ├── Env: node.name = "elasticsearch-0" (from metadata.name)
  │       ├── Env: cluster.name = "elk-cluster"
  │       ├── Env: discovery.seed_hosts = "elasticsearch-0.elasticsearch,..."
  │       ├── Env: network.publish_host = podIP
  │       ├── Env: cluster.initial_master_nodes = "elasticsearch-0,elasticsearch-1"
  │       ├── Env: ES_JAVA_OPTS = -Xms512m -Xmx512m -XX:+AlwaysPreTouch
  │       ├── Env: xpack.security.* = TLS enabled (HTTP + transport)
  │       ├── Mounts:
  │       │   ├── elasticsearch-data (PVC) → /usr/share/elasticsearch/data
  │       │   └── elastic-certs (emptyDir) → /usr/share/elasticsearch/config/certs
  │       │       ├── ca.crt, es.crt, es.key  (placed by copy-certs init)
  │       └── Readiness probe: curl -sk https://localhost:9200 → expect 401
  │
  4── Pod elasticsearch-1 created (after elasticsearch-0 is 1/1 Ready)
      └── Same steps, except:
          ├── copy-certs picks elasticsearch-1.crt / elasticsearch-1.key
          ├── PVC bound to PV on different minikube node
          └── ES discovers elasticsearch-0 via DNS and joins the cluster
```

---

## Master Election — How It Works

```
Elasticsearch uses a consensus-based election protocol (based on Zen Discovery).

┌─────────────────────────────────────────────────────────────────────┐
│                      Master Election Flow                           │
│                                                                     │
│  1. Node starts with cluster.initial_master_nodes set               │
│     └── Only used for the VERY FIRST election (cluster bootstrap)   │
│                                                                     │
│  2. elasticsearch-0:                                                │
│     ├── No existing cluster state (fresh data dir)                  │
│     ├── Looks at initial_master_nodes: [elasticsearch-0, es-1]      │
│     ├── Checks if it can form a quorum (needs ≥2 votes)             │
│     ├── Since es-1 isn't up yet, it waits briefly                   │
│     └── After a timeout, es-0 elects itself as master               │
│         (initial_master_nodes means "I expect these nodes")         │
│                                                                     │
│  3. elasticsearch-0 becomes master:                                 │
│     ├── Creates cluster UUID, writes to data directory              │
│     ├── Sets voting configuration: [elasticsearch-0]                │
│     └── Opens HTTP (9200) and transport (9300) ports                │
│                                                                     │
│  4. elasticsearch-1 starts, joins:                                  │
│     ├── DNS resolves elasticsearch-0.elasticsearch → IP             │
│     ├── Transport TLS handshake (mutual cert verification)          │
│     ├── Sends join request to master                                │
│     ├── Master adds es-1 to cluster state                           │
│     ├── Voting configuration expands: [elasticsearch-0, es-1]       │
│     └── Shards (from template) are replicated to es-1               │
│                                                                     │
│  5. Subsequent restarts:                                            │
│     ├── cluster.initial_master_nodes is IGNORED                     │
│     ├── Nodes read cluster UUID from data directory                 │
│     ├── They find the master via discovery.seed_hosts DNS lookup    │
│     ├── Or if master is down, hold a new election                   │
│     └── Warning about initial_master_nodes is cosmetic              │
│                                                                     │
│  Key Point: initial_master_nodes is REQUIRED only for the           │
│  very first bootstrap. After the cluster is formed, ES uses         │
│  the persisted cluster state for all subsequent elections.          │
└─────────────────────────────────────────────────────────────────────┘

What happens if initial_master_nodes is NOT set on first boot?
  ├── Each node waits for an existing cluster to discover
  ├── Timeout after ~30s, each node tries to form its own cluster
  ├── Split-brain: two one-node clusters (cannot merge later)
  └── This is why initial_master_nodes is mandatory for bootstrap
```

---

## Persistent Volume (PV) Lifecycle

```
volumeClaimTemplates (in StatefulSet spec)
         │
         ├── Template name: "elasticsearch-data"
         ├── accessModes: ReadWriteOnce
         └── storage: 1Gi
                  │
                  ▼
         PVC created per pod:
         elasticsearch-data-elasticsearch-0
         elasticsearch-data-elasticsearch-1
                  │
                  ▼
         hostPath Provisioner (minikube default)
                  │
                  ├── Creates PV on the minikube node where pod is scheduled
                  ├── PV backed by: /tmp/hostpath-provisioner/elk/<pvc-name>/
                  └── PV is node-local (NOT shared storage)
                           │
                           ▼
                  Pod mounts PVC as:
                  /usr/share/elasticsearch/data/
                           │
                           ├── elasticsearch-0: data on minikube control-plane
                           └── elasticsearch-1: data on minikube-m02 worker
                                    │
                                    ▼
                  On redeploy (kubectl delete + apply):
                  ├── PVC deleted → Kubernetes removes the PVC object
                  ├── BUT hostPath directory persists on minikube node
                  ├── New pod gets same PVC name → reuses old PV/directory
                  ├── Old node.lock and nodes/ cause cluster UUID conflict
                  └── Fix: init container "fix-permissions" runs rm -rf data/*
```

---

## Certificate Lifecycle

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Certificate Creation & Flow                             │
│                                                                             │
│  Bootstrap Job (elastic-bootstrap)                                          │
│  ┌──────────────────────────────────────────────┐                           │
│  │ Container 1: cert-generator                  │                           │
│  │                                              │                           │
│  │  1. elasticsearch-certutil ca                │                           │
│  │     └── ca.zip ──> ca.crt (public) + ca.key  │                           │
│  │                                    (private) │                           │
│  │                                              │                           │
│  │  2. instances.yml written with:              │                           │
│  │     elasticsearch-0: DNS SANs include        │                           │
│  │       ├── elasticsearch (service-level)      │                           │
│  │       ├── elasticsearch-0.elasticsearch      │                           │
│  │       ├── elasticsearch-0.elasticsearch.elk  │                           │
│  │       ├── localhost                          │                           │
│  │       └── IP: 127.0.0.1                      │                           │
│  │     elasticsearch-1: same pattern            │                           │
│  │                                              │                           │
│  │  3. elasticsearch-certutil cert              │                           │
│  │     ├── --ca-cert ca.crt --ca-key ca.key     │                           │
│  │     ├── --in instances.yml                   │                           │
│  │     └── certs.zip ──> per-node .crt + .key   │                           │
│  │                                              │                           │
│  │  4. cp files → /shared/ (emptyDir)           │                           │
│  │     ├── ca.crt / ca.key                      │                           │
│  │     ├── elasticsearch-0.crt / .key           │                           │
│  │     └── elasticsearch-1.crt / .key           │                           │
│  └──────────────────┬───────────────────────────┘                           │
│                     │ emptyDir volume "shared-certs"                        │
│  ┌──────────────────▼───────────────────────────┐                           │
│  │ Container 2: secret-creator                  │                           │
│  │                                              │                           │
│  │  kubectl create secret generic elastic-certs │                           │
│  │    --from-file=/shared/ca.crt                │                           │
│  │    --from-file=/shared/ca.key                │                           │
│  │    --from-file=/shared/elasticsearch-0.crt   │                           │
│  │    --from-file=/shared/elasticsearch-0.key   │                           │
│  │    --from-file=/shared/elasticsearch-1.crt   │                           │
│  │    --from-file=/shared/elasticsearch-1.key   │                           │
│  └──────────────────────────────────────────────┘                           │
│                                                                             │
│  Secret "elastic-certs" stored in etcd (kubernetes)                         │
│                                                                             │
│  StatefulSet Pods:                                                          │
│  ┌───────────────────────────────────────────────┐                          │
│  │ Secret volume mount:                          │                          │
│  │   elastic-certs-secret → /certs-secret/       │                          │
│  │   ├── All 6 files available (read-only)       │                          │
│  │                                               │                          │
│  │  Init: copy-certs                             │                          │
│  │   ├── $(hostname) = "elasticsearch-0" or "1"  │                          │
│  │   ├── cp /certs-secret/ca.crt /elastic-certs/ │                          │
│  │   ├── cp /certs-secret/${HOSTNAME}.crt        │                          │
│  │   │   └── renamed to es.crt                   │                          │
│  │   ├── cp /certs-secret/${HOSTNAME}.key        │                          │
│  │   │   └── renamed to es.key                   │                          │
│  │   └── chmod 640, chown 1000:0                 │                          │
│  │                                               │                          │
│  │  emptyDir: elastic-certs → /elastic-certs/    │                          │
│  │   ├── ca.crt, es.crt, es.key (per-node copy)  │                          │
│  │                                               │                          │
│  │  Main container mounts:                       │                          │
│  │   /elastic-certs → /usr/share/elasticsearch/  │                          │
│  │                      config/certs/            │                          │
│  │   ES env vars reference these paths:          │                          │
│  │   ├── xpack.security.http.ssl.key             │                          │
│  │   ├── xpack.security.http.ssl.certificate     │                          │
│  │   ├── xpack.security.http.ssl.certificate_auth│                          │
│  │   ├── xpack.security.transport.ssl.*          │                          │
│  │   └── All point to /usr/share/.../certs/*     │                          │
│  └───────────────────────────────────────────────┘                          │
│                                                                             │
│  Kibana Pod:                                                                │
│  ┌───────────────────────────────────────────────┐                          │
│  │ Mounts ca.crt ONLY from elastic-certs Secret  │                          │
│  │   /usr/share/kibana/config/certs/ca.crt       │                          │
│  │                                               │                          │
│  │ Env: ELASTICSEARCH_SSL_CERTIFICATEAUTHORITIES │                          │
│  │   = "config/certs/ca.crt"                     │                          │
│  │ Kibana uses this to verify ES's TLS cert      │                          │
│  └───────────────────────────────────────────────┘                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Volume Mounts Summary

### StatefulSet Pod (elasticsearch-N)

```
Pod Volumes:
  elasticsearch-data (PVC)          → /usr/share/elasticsearch/data/
      │                                  │
      │                                  └── ES data (indices, cluster state)
      │                                      Persisted across restarts
      │
  elastic-certs-secret (Secret)     → /certs-secret/
  │    (mounted by init container)       │
  │                                     └── All 6 cert files
  │                                         Read by copy-certs init
  │
  elastic-certs (emptyDir)          → /elastic-certs/  (init)
      │                              → /usr/share/elasticsearch/config/certs/ (main)
                                        │
                                        └── ca.crt, es.crt, es.key
                                            Written by copy-certs init
                                            Read by ES main container
```

### Kibana Pod

```
Pod Volumes:
  elastic-certs (Secret, items: ca.crt)  → /usr/share/kibana/config/certs/
                                              │
                                              └── ca.crt only
                                                  Used to verify ES TLS
```

---

## RBAC Model

```
ServiceAccount: elastic-bootstrap (namespace: elk)
       │
       │  Used by: bootstrap-job (secret-creator container)
       │
       ▼
Role: elastic-bootstrap
  ├── apiGroups: [""]
  ├── resources: ["secrets"]
  └── verbs: ["get", "create", "update", "patch", "delete"]
       │
       │  Needed because secret-creator runs:
       │    kubectl delete secret elastic-certs
       │    kubectl create secret generic elastic-certs
       │
       ▼
RoleBinding: elastic-bootstrap
  ├── subjects: [kind: ServiceAccount, name: elastic-bootstrap]
  └── roleRef: [kind: Role, name: elastic-bootstrap]
```

Why two containers in the bootstrap job?
- Container 1 (cert-generator) uses the ES official image (has elasticsearch-certutil). Does NOT need RBAC.
- Container 2 (secret-creator) uses bitnami/kubectl (lightweight, has kubectl binary). NEEDS RBAC to create Secrets.

---

## Headless Service — DNS Discovery

```
Service: elasticsearch (ClusterIP: None)

DNS entries created by Kubernetes:
  elasticsearch-0.elasticsearch.elk.svc.cluster.local  →  Pod IP of es-0
  elasticsearch-1.elasticsearch.elk.svc.cluster.local  →  Pod IP of es-1

Shorthand (within same namespace):
  elasticsearch-0.elasticsearch  →  es-0 IP
  elasticsearch-1.elasticsearch  →  es-1 IP

Used by ES for:
  discovery.seed_hosts: "elasticsearch-0.elasticsearch,elasticsearch-1.elasticsearch"

IMPORTANT: No publishNotReadyAddresses (defaults to false)
  └── DNS only returns IPs for Ready pods
  └── Works correctly with OrderedReady pod management
```

---

## Deployment

```bash
# Prerequisites: minikube running, kubectl configured
./deploy.sh
```

The script runs 6 phases sequentially:

| Phase | Command | Waits For | What Happens |
|-------|---------|-----------|--------------|
| 0 | `kubectl apply -f *.yaml` | — | Namespace, secrets, RBAC, headless service, configmap created |
| 1 | `kubectl apply -f bootstrap-job.yaml` | Job completion (3m) | TLS certs generated, `elastic-certs` Secret created in k8s |
| 2 | `kubectl apply -f statefulset.yaml` | All pods Ready (5m) | 2 ES nodes start with init containers, form cluster |
| 2b | `kubectl exec curl ...` | — | Verify elastic password; auto-reset if ES overrode it |
| 3 | `kubectl apply -f set-password-job.yaml` | Job completion (5m) | `kibana_system` password set via Security API |
| 4 | `kubectl apply -f kibana-*.yaml` | Rollout ready (3m) | Kibana deployed and exposed on NodePort |
| 5 | `kubectl rollout restart deploy/kibana` | Rollout ready (3m) | Kibana restarts with fresh credentials |
| 6 | `kubectl apply -f cert-rotation-cronjob.yaml` | — | Placeholder CronJob for monthly cert rotation |

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
| YAML doc separator missing | `rbac.yaml` uses `---` between ServiceAccount / Role / RoleBinding |

---

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

---

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates `elk` namespace |
| `secrets.yaml` | Static passwords for `elastic` and `kibana_system` |
| `rbac.yaml` | ServiceAccount + Role + RoleBinding for bootstrap job to create/delete Secrets |
| `headless-service.yaml` | DNS-based peer discovery (`elasticsearch-0.elasticsearch`) |
| `configmap.yaml` | Cluster-level config (`cluster.name: minikube-es`) |
| `bootstrap-job.yaml` | 2-container Job: cert-generator (elasticsearch-certutil) + secret-creator (kubectl) |
| `statefulset.yaml` | 2-replica ES with TLS (HTTP + transport), security, resource limits, init containers, PVCs |
| `set-password-job.yaml` | Sets `kibana_system` password after cluster is healthy |
| `kibana-service.yaml` | NodePort service exposing Kibana on :5601 |
| `kibana.yaml` | Kibana Deployment connected to ES with TLS + kibana_system auth |
| `cert-rotation-cronjob.yaml` | Monthly cert rotation (placeholder) |
| `deploy.sh` | Orchestrates all phases in order |

---

## Issues Encountered & Resolutions

### 1. YAML document separator missing in multi-resource files

**Symptom:** `kubectl apply -f rbac.yaml` fails with:
```
Error from server (BadRequest): error when creating "rbac.yaml": RoleBinding
in version "v1" cannot be handled as a RoleBinding: strict decoding error:
unknown field "rules"
```

**Root cause:** When multiple Kubernetes resources are defined in a single YAML file, they must be separated by a line containing only `---` (the YAML document separator). Without it, kubectl's strict decoder treats the entire file as one YAML document and validates all content against the first `kind` encountered. In this case, the `rules` field from the `Role` bleeds into the `RoleBinding` document, which does not accept that field.

**Fix:** `---` is present on its own line between every resource group in `rbac.yaml` (ServiceAccount, Role, RoleBinding).

---

### 2. Heap too small → GC thrashing → readiness timeout

**Symptom:** Pod starts but readiness probe never succeeds (exits after 60 failures = 5 min). Logs show `[gc] overhead, spent 1s collecting in the last 1.2s` (57% GC). DNS resolution failures like `failed to resolve host [elasticsearch-1.elasticsearch]` appear — these are *symptoms* of a node that cannot participate in elections due to GC, not the root cause.

**Root cause:** Default heap is 256MB (minikube cgroup limit of 1GB → ES JVM uses ~256m by default). At 57% GC overhead the node cannot respond to cluster coordination pings, gets excluded, and DNS becomes irrelevant.

**Fix:** Set `ES_JAVA_OPTS: "-Xms512m -Xmx512m -XX:+AlwaysPreTouch"`.

**Debug:**
```bash
kubectl logs -n elk elasticsearch-0 --tail 50 | grep -E "gc|overhead|elected|discovery"
```

---

### 3. Memory limit too tight → OOMKilled (exit 137)

**Symptom:** Pod crashes with `Exit Code: 137, Reason: OOMKilled` after running for ~90 seconds. Cluster was forming (elected master, nodes joining, shard recovery starting) then killed.

**Root cause:** 512m heap + `AlwaysPreTouch` = 512MB physically committed at startup. JVM overhead (metaspace, threads, code cache) + direct memory (netty/Lucene) pushes total above the container limit.

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

### 4. Stale cluster state on PVC after delete (automated in deploy.sh)

**Symptom:** Even after `kubectl delete pvc`, the new pod picks up the old cluster UUID and node IDs. Old `voting_configuration` references a master node ID that no longer exists. The warning shows an unexpected master node ID.

**Root cause:** minikube uses hostPath provisioner. Deleting a PVC removes the Kubernetes claim object but the underlying host directory (`/tmp/hostpath-pv/…`) is **not** cleaned. The new pod mounts the same directory and finds the old `node.lock` and `nodes/` files.

**Fix (automated):** The `fix-permissions` init container in `statefulset.yaml` now runs `rm -rf /usr/share/elasticsearch/data/* /usr/share/elasticsearch/data/.*` on every pod start, ensuring the data directory is always clean before ES starts. This is safe because:
- With `OrderedReady` pod management, pods restart one at a time; the remaining node holds the cluster state and data, which gets replicated to the restarting pod.
- On a fresh deployment both pods start empty and form a new cluster.

**Manual alternative** (if you need to clean hostPath directly):
```bash
minikube ssh "sudo rm -rf /tmp/hostpath-provisioner/elk/"
minikube ssh -n minikube-m02 "sudo rm -rf /tmp/hostpath-provisioner/elk/"
```

---

### 5. `cluster.initial_master_nodes` not removed after bootstrap

**Symptom:** Log warning on every startup:
```
this node is locked into cluster UUID […] but cluster.initial_master_nodes is
set to […]; remove this setting to avoid possible data loss
```

**Root cause:** The env var `cluster.initial_master_nodes` is set in the StatefulSet and never removed. It is **required** for the very first bootstrap of a new cluster, but produces warnings on subsequent restarts.

**Status:** The env var is intentionally kept in `statefulset.yaml` because it is mandatory for initial cluster formation. The warning is cosmetic and does not affect functionality. If you want to suppress it, remove the env var from `statefulset.yaml` after the first deployment:

```bash
# After all nodes have joined at least once:
kubectl set env statefulset/elasticsearch -n elk "cluster.initial_master_nodes-"
# This triggers a rolling restart; pods will start without the warning.
```

---

### 6. `ELASTIC_PASSWORD` env var not honoured (automated in deploy.sh)

**Symptom:** After fresh deployment, authenticating as `elastic` user with the password from the secret fails:
```json
{"error":{"root_cause":[{"type":"security_exception",
  "reason":"unable to authenticate user [elastic] for REST request […]"}]}}
```

**Root cause:** Elasticsearch 8.x auto-configuration during first boot may generate a random password for the `elastic` user and store it in the keystore, ignoring the `ELASTIC_PASSWORD` environment variable. This depends on whether the node detects it is in "auto-configuration" mode (no pre-existing `elasticsearch.keystore`).

**Fix (automated in deploy.sh Phase 2b):**
1. After all ES pods are Ready, `deploy.sh` runs `curl -u "elastic:${PASSWORD}"` and checks for HTTP 200.
2. If auth fails, it runs `elasticsearch-reset-password -u elastic -b` (batch mode) inside the pod, captures the generated password, and updates the `elastic-credentials` k8s Secret so all subsequent phases use the correct password.

**To verify manually:**
```bash
kubectl exec -n elk elasticsearch-0 -- curl -sk -u "elastic:elastic123" \
  "https://localhost:9200/"
```

---

### 7. `publishNotReadyAddresses: true` on headless service

**Issue:** The original headless service had `publishNotReadyAddresses: true`, which makes DNS return IPs for pods that are not yet Ready. This interferes with the StatefulSet `OrderedReady` pod management policy, allowing a not-yet-ready pod to be discovered before it can actually serve traffic.

**Fix:** Remove `publishNotReadyAddresses` (defaults to `false`). With `OrderedReady`, pods start sequentially: pod-0 must be Ready before pod-1 begins. DNS only resolves Ready pods.

---

### 8. Kibana monitoring auth error after deployment (automated in deploy.sh)

**Symptom:** Kibana logs show:
```
unable to authenticate user [kibana_system] for REST request
[/_monitoring/bulk?system_id=kibana&system_api_version=7&interval=10000ms]
```

**Root cause:** The `set-password-job` runs AFTER the StatefulSet is ready, but Kibana may have already started and cached an invalid auth token before the password was set.

**Fix (automated in deploy.sh Phase 5):** After the password job completes, `deploy.sh` waits for Kibana to roll out, then runs:
```bash
kubectl rollout restart deployment -n elk kibana
```
and waits for the new rollout to complete. This ensures Kibana picks up the fresh `kibana_system` credentials before any monitoring uploads.

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

# Check cluster health
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

---

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
