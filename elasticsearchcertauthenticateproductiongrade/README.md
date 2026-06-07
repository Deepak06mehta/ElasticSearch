# Elasticsearch 8.17 — Production-Grade Cluster on Minikube (2 Nodes)

## Architecture

```
Podman VM (6 GB)
│
└── Minikube (2 nodes, 4 GB memory)
     │
     ├── Node 1 (minikube) ──────────────────────────────
     │    ├── Control Plane
     │    ├── Elasticsearch Master + Data  (roles: master, data)
     │    ├── Vault        (secrets engine + k8s auth)
     │    └── cert-manager (TLS certificates)
     │
     └── Node 2 (minikube-m02) ──────────────────────────
          ├── Elasticsearch Ingest  (roles: ingest)
          ├── Kibana
          └── Longhorn    (storage, numberOfReplicas: 1)
```

### Resource Budget (Optimized)

| Component | RAM (Request / Limit) |
|-----------|----------------------|
| Minikube Control Plane | ~700 MB |
| Elasticsearch Master+Data | 512 Mi / 1 Gi |
| Elasticsearch Ingest | 256 Mi / 512 Mi |
| Vault | 128 Mi / 256 Mi |
| cert-manager | 64 Mi / 128 Mi |
| Kibana | 256 Mi / 512 Mi |
| Longhorn | 192 Mi / 384 Mi (3 components) |
| External Secrets Operator | 32 Mi / 64 Mi |
| **Total (requests/limits)** | **~2.1 Gi / ~3.8 Gi** |

Fits comfortably within 4 GB allocated to Minikube (down from original 10 GB, saving ~6 GB).

---

## Key Improvements Over `elasticsearchcertauthenticate`

| Improvement | Before | After |
|-------------|--------|-------|
| Certificate management | `bootstrap-job.yaml` (elasticsearch-certutil) + `cert-rotation-cronjob.yaml` | **cert-manager** ClusterIssuer + Certificate (auto-renewal, production pattern) |
| Secrets storage | Static `secrets.yaml` with hardcoded passwords | **Vault** (KV v2) + **External Secrets Operator** syncs to k8s Secrets |
| Elasticsearch roles | 2x master+data (StatefulSet, 2 replicas) | **master+data** on Node 1, **ingest** on Node 2 (separate StatefulSets) |
| Storage | hostPath provisioner (node-local, lost on node failure) | **Longhorn** (replicated, persistent, numberOfReplicas=1 for dev) |
| Memory efficiency | 2 identical nodes with 512m heap each | Master+data: 256m heap. Ingest: 192m heap. Total ~1 Gi savings |
| Node topology | Random scheduling | Explicit **nodeSelector** labels enforce architecture layout |

---

## Prerequisites

```bash
# Start Minikube with 2 nodes (4 GB RAM is sufficient for the optimized setup):
minikube stop
minikube delete --all --purge

minikube start \
  --driver=podman \
  --nodes=2 \
  --cpus=4 \
  --memory=4096 \
  --disk-size=20g \
  --kubernetes-version=v1.35.1

minikube addons enable metrics-server
minikube addons enable dashboard
minikube addons enable ingress
minikube addons enable storage-provisioner
minikube addons enable default-storageclass

# Verify
kubectl get nodes
kubectl get pods -A
```

Required tooling on the host:
- `kubectl`
- `helm`
- `jq`

---

## Deployment

```bash
chmod +x deploy.sh
./deploy.sh
```

### Phases

| Phase | Step | What Happens |
|-------|------|--------------|
| 0 | Label nodes | `master-data=true` on Node 1, `ingest=true` on Node 2 |
| 1 | Namespace | Creates `elk` namespace |
| 2 | cert-manager | Helm install with CRDs in `cert-manager` namespace |
| 3 | ClusterIssuer | Self-signed CA → CA Certificate → Elasticsearch node Certificate |
| 4 | Vault | Helm install (dev mode, unsealed, root token: `root`) |
| 5 | Configure Vault | KV secrets engine enabled, elastic/kibana passwords stored, k8s auth configured for ESO |
| 6 | External Secrets | Helm install in `external-secrets` namespace |
| 7 | SecretStore + ExternalSecret | ClusterSecretStore → Vault (k8s auth), ExternalSecret syncs to `elastic-credentials` k8s Secret |
| 8 | Longhorn | Helm install with `defaultReplicaCount: 1` (required for 2-node dev) |
| 9 | ES Config & Services | ConfigMap, headless services for master-data, ingest, and unified `elasticsearch` |
| 10 | ES master-data | StatefulSet (1 replica, roles: master, data), Longhorn PVC, cert-manager TLS |
| 11 | ES ingest | StatefulSet (1 replica, roles: ingest), cert-manager TLS |
| 12 | Password verify | Checks elastic password from Vault, resets via CLI if ES auto-generated a different one |
| 13 | kibana_system password | Job POSTs to ES Security API to set the password |
| 14 | Kibana | Deployment + NodePort service, restart to clear stale auth tokens |

---

## Uninstall

```bash
chmod +x uninstall.sh
./uninstall.sh
```

Removes in reverse order: ES StatefulSets → PVCs → Kibana → ESO resources → cert-manager resources → Longhorn → ESO operator → Vault → cert-manager → namespace → node labels.

---

## Access

```bash
# Elasticsearch health
kubectl exec -n elk es-master-data-0 -- \
  curl -sk -u "elastic:elastic123" \
  https://localhost:9200/_cluster/health?pretty

# Kibana (port-forward)
kubectl port-forward -n elk svc/kibana 5601:5601
# Open http://localhost:5601

# Minikube dashboard
minikube dashboard
```

---

## Certificate Flow (cert-manager)

```
selfsigned-issuer (ClusterIssuer)
  │
  ├── Certificate: es-ca
  │   └── Secret: es-ca-secret (CA private key + cert)
  │
  ▼
es-ca-issuer (ClusterIssuer) ← uses es-ca-secret as CA
  │
  ├── Certificate: es-node
  │   └── Secret: elastic-certs (tls.crt + tls.key + ca.crt)
  │       ├── Mounted in es-master-data-0 → /usr/share/elasticsearch/config/certs/
  │       ├── Mounted in es-ingest-0      → /usr/share/elasticsearch/config/certs/
  │       └── Mounted in kibana           → /usr/share/kibana/config/certs/ca.crt
  │
  └── Auto-renewal: cert-manager renews before expiry, updates Secret
```

No bootstrap job needed. No cert-rotation CronJob needed.

---

## Secrets Flow (Vault + External Secrets Operator)

```
Vault (dev mode, http://vault.elk:8200)
  │
  ├── secret/elasticsearch
  │   ├── elastic-password: elastic123
  │   └── kibana-password:  kibana123
  │
  └── auth/kubernetes/role/external-secrets
       └── bound to ServiceAccount external-secrets in namespace external-secrets
                    │
                    ▼
External Secrets Operator (namespace: external-secrets)
  │
  ├── ClusterSecretStore: vault-backend (k8s auth → Vault)
  │
  └── ExternalSecret: elastic-credentials (namespace: elk)
       └── Syncs secret/elasticsearch → k8s Secret "elastic-credentials"
                    │
                    ▼
elk namespace:
  Secret: elastic-credentials
    ├── elastic-password → used by es-master-data-0 (ELASTIC_PASSWORD env)
    └── kibana-password  → used by kibana (ELASTICSEARCH_PASSWORD env)
```

No static `secrets.yaml` file. Secrets are created by ESO, not committed to the repo.

---

## Longhorn Configuration

For a 2-node Minikube cluster, Longhorn is configured with:

- `defaultReplicaCount: 1` — only 1 replica per volume (avoids scheduling conflicts)
- No replica auto-balance
- Reduced resource requests/limits on all components

Without `numberOfReplicas: 1`, Longhorn would try to place 3 replicas of each volume across a 2-node cluster, causing continuous scheduling failures.

---

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates `elk` namespace |
| `cert-manager/cluster-issuer.yaml` | Self-signed ClusterIssuer + CA Certificate + CA-based ClusterIssuer |
| `cert-manager/certificate.yaml` | Elasticsearch node Certificate with multi-SAN DNS |
| `vault/vault-values.yaml` | Helm values for Vault dev mode (minimal resources) |
| `vault/configure-vault-job.yaml` | Job: enable KV, store secrets, configure k8s auth, create ESO policy |
| `external-secrets/secret-store.yaml` | ClusterSecretStore pointing to Vault with k8s auth |
| `external-secrets/external-secret.yaml` | ExternalSecret syncing Vault paths to k8s Secret |
| `elasticsearch/configmap.yaml` | cluster.name for all ES nodes |
| `elasticsearch/headless-service.yaml` | Headless services: es-master-data, es-ingest, elasticsearch |
| `elasticsearch/master-data-statefulset.yaml` | StatefulSet (roles: master, data), Longhorn PVC, cert-manager TLS |
| `elasticsearch/ingest-statefulset.yaml` | StatefulSet (roles: ingest), cert-manager TLS |
| `kibana/deployment.yaml` | Kibana Deployment with cert-manager CA + ESO credentials |
| `kibana/service.yaml` | NodePort service for Kibana |
| `longhorn/values.yaml` | Helm values (single replica, reduced resources) |
| `set-kibana-password-job.yaml` | Job: set kibana_system password via ES Security API |
| `deploy.sh` | Orchestrates all 14 phases |
| `uninstall.sh` | Reverses every phase in safe order |

---

## Troubleshooting

### Pod stuck in CrashLoopBackOff

```bash
kubectl describe pod -n elk <pod-name> | grep -E "Reason:|Exit Code:|State:"
kubectl logs -n elk <pod-name> --tail 30
```

Exit 137 = OOM → check `kubectl top pod -n elk` and increase memory limits if needed (defaults are tuned for minimum resource usage).
Exit 1 = process error → check logs.

### Elasticsearch not forming cluster

```bash
# Check master-data logs
kubectl logs -n elk es-master-data-0 --tail 30 | grep -E "elected|discovery|master|join"
# Check ingest logs
kubectl logs -n elk es-ingest-0 --tail 30 | grep -E "elected|discovery|master|join"
```

Common causes:
- DNS resolution failure (headless service not matching serviceName)
- TLS cert mismatch (SANs don't include DNS names)
- Memory/GC thrashing (check for GC warnings in logs)

### Secret not syncing from Vault

```bash
# Check ESO status
kubectl get externalsecret -n elk
kubectl describe externalsecret elastic-credentials -n elk

# Check SecretStore status
kubectl get clustersecretstore vault-backend
kubectl describe clustersecretstore vault-backend

# Verify Vault is reachable
kubectl exec -n elk deploy/vault -- wget -qO- http://vault:8200/v1/sys/health

# Verify secret exists in Vault
kubectl exec -n elk deploy/vault -- vault kv get secret/elasticsearch
```

### Longhorn volumes stuck

```bash
kubectl get volumes -n longhorn-system
kubectl describe volume <name> -n longhorn-system
```

For 2-node setup, ensure `defaultReplicaCount: 1`. If volumes are stuck with 3 replicas, update the setting and detach/reattach.

### cert-manager Certificate not ready

```bash
kubectl describe certificate -n elk es-node
kubectl describe clusterissuer es-ca-issuer
kubectl get secret -n elk es-ca-secret -o yaml
```

### Debugging cheat sheet

```bash
# All resources
kubectl get all -n elk
kubectl get pvc -n elk
kubectl get secrets -n elk
kubectl get events -n elk --sort-by='.lastTimestamp' | tail -20

# Resource usage
kubectl top pods -n elk
kubectl top pods -n longhorn-system
kubectl top nodes

# Elasticsearch cluster health
kubectl exec -n elk es-master-data-0 -- \
  curl -sk -u "elastic:elastic123" \
  https://localhost:9200/_cluster/health?pretty

# Elasticsearch nodes info
kubectl exec -n elk es-master-data-0 -- \
  curl -sk -u "elastic:elastic123" \
  https://localhost:9200/_cat/nodes?v

# Elasticsearch node roles
kubectl exec -n elk es-master-data-0 -- \
  curl -sk -u "elastic:elastic123" \
  "https://localhost:9200/_cat/nodes?v=true&h=name,nodeRole,ip,heapCurrent,ramPercent,version"
```
