# Elasticsearch 8.17 — Production-Grade Cluster on Minikube (2 Nodes)

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Network Communication Model](#network-communication-model)
3. [Flow Diagram: deploy.sh Execution Phases](#flow-diagram-deploysh-execution-phases)
4. [Sequence Diagram: Component Interaction](#sequence-diagram-component-interaction)
5. [How YAML Files Execute (Step by Step)](#how-yaml-files-execute-step-by-step)
6. [Component Details & Communication Paths](#component-details--communication-paths)
7. [Resource Budget](#resource-budget)
8. [Prerequisites](#prerequisites)
9. [Deployment](#deployment)
10. [Uninstall](#uninstall)
11. [Access](#access)
12. [Debugging Cheat Sheet](#debugging-cheat-sheet)
13. [Troubleshooting Guide](#troubleshooting-guide)
14. [Issues Encountered and Fixed](#issues-encountered-and-fixed)
15. [Files Reference](#files-reference)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                        Podman VM (6 GB RAM, 4 CPUs)                          │
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐   │
│  │                        Minikube Cluster                               │   │
│  │  Kubernetes v1.35.1 — Calico CNI — CoreDNS — 2 Nodes                  │   │
│  │                                                                       │   │
│  │  ┌──────────────────────────────┐  ┌──────────────────────────────┐   │   │
│  │  │  Node 1: minikube            │  │  Node 2: minikube-m02        │   │   │
│  │  │  IP: 192.168.49.2            │  │  IP: 192.168.49.3            │   │   │
│  │  │                              │  │                              │   │   │
│  │  │  ┌──────────────────────┐    │  │  ┌──────────────────────┐    │   │   │
│  │  │  │ Control Plane        │    │  │  │                      │    │   │   │
│  │  │  │ (kube-apiserver,     │    │  │  │  es-ingest-0         │    │   │   │
│  │  │  │  etcd, scheduler,    │    │  │  │  └ Roles: ingest     │    │   │   │
│  │  │  │  controller-manager) │    │  │  │  └ IP: 10.244.1.x    │    │   │   │
│  │  │  │  └ ~500 MB RAM       │    │  │  │  └ Port 9200 (HTTP)  │    │   │   │
│  │  │  └──────────────────────┘    │  │  │  └ Port 9300 (Trns)  │    │   │   │
│  │  │                              │  │  │                      │    │   │   │
│  │  │  ┌──────────────────────┐    │  │  │  ┌──────────────────┐│    │   │   │
│  │  │  │ es-master-data-0     │    │  │  │  │ kibana-xxx       ││    │   │   │
│  │  │  │  └ Roles: master,data│    │  │  │  │  └ Port 5601     ││    │   │   │
│  │  │  │  └ IP: 10.244.0.x    │    │  │  │  └──────────────────┘│    │   │   │
│  │  │  │  └ Port 9200 (HTTP)  │    │  │  │                      │    │   │   │
│  │  │  │  └ Port 9300 (Trns)  │    │  │  │  ┌──────────────────┐│    │   │   │
│  │  │  └──────────────────────┘    │  │  │  │ vault-0          ││    │   │   │
│  │  │                              │  │  │  │  └ Port 8200     ││    │   │   │
│  │  │  ┌──────────────────────┐    │  │  │  └──────────────────┘│    │   │   │
│  │  │  │ cert-manager pods     │   │  │  │                      │    │   │   │
│  │  │  │  └ cert-manager       │   │  │  └──────────────────────┘    │   │   │
│  │  │  │  └ cainjector         │   │  │                              │   │   │
│  │  │  │  └ webhook            │   │  │                              │   │   │
│  │  │  └──────────────────────┘    │  │                              │   │   │
│  │  │                              │  │                              │   │   │
│  │  └──────────────────────────────┘  └──────────────────────────────┘   │   │
│  │                                                                       │   │
│  │  External Secrets Operator ── namespace: external-secrets             │   │
│  │  OpenEBS LocalPV           ── namespace: openebs                      │   │
│  └───────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  MacBook Host: kubectl port-forward → http://localhost:5601 (Kibana)         │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Component Purpose

| Component | Purpose | Why It's Needed |
|-----------|---------|-----------------|
| **Elasticsearch Master+Data** | Cluster management (master) + data storage (data) | The brain and memory of the cluster — manages state and stores all indexed documents |
| **Elasticsearch Ingest** | Document pre-processing (ingest pipelines) | Offloads CPU-heavy pipeline processing from the master+data node |
| **Kibana** | Web UI for data visualization | User-facing dashboard for querying and visualizing Elasticsearch data |
| **Vault** | Secrets management (passwords, API keys) | Stores elasticsearch credentials securely instead of hardcoding them in YAML files |
| **cert-manager** | Automated TLS certificate creation/renewal | Creates and manages the CA and node certificates for encrypted communication |
| **External Secrets Operator** | Syncs secrets from Vault to Kubernetes Secrets | Reads passwords from Vault and creates Kubernetes Secrets that pods can consume |
| **OpenEBS LocalPV** | Local persistent storage (hostPath) | Provides PersistentVolumes for Elasticsearch data without requiring iSCSI/NFS |

---

## Network Communication Model

### How Pods Communicate

```
Pod-to-Pod Communication (East-West traffic):
  All pods communicate over the cluster's CNI network (Calico in minikube).
  Each pod gets a unique IP from the 10.244.0.0/16 range.
  Traffic between pods is routed by the CNI plugin, regardless of which node
  they are on.

  Example: es-ingest-0 (10.244.1.x on Node 2) talks to
           es-master-data-0 (10.244.0.x on Node 1) over port 9300.
           The packet: Node 2 → Node 1's CNI bridge → pod's veth pair.

  DNS Resolution:
    Pods use CoreDNS (cluster DNS) to resolve service names.
    A pod in namespace 'elk' can reach a service as:
      - Short name: <service>          (resolves within same namespace)
      - Full FQDN:  <service>.<ns>.svc.cluster.local

    Example: Kibana connects to "https://elasticsearch:9200"
             → CoreDNS resolves elasticsearch.elk.svc.cluster.local
             → returns IPs of all ES pods (round-robin or all A records)
```

### Detailed Communication Paths

```
1. KIBANA → ELASTICSEARCH (HTTP, Port 9200, HTTPS)
   ┌──────────┐     DNS: elasticsearch.elk.svc       ┌──────────────────┐
   │  Kibana  │ ──── https://elasticsearch:9200 ──→  │  ES master-data  │
   │  Node 2  │     Auth: kibana_system/kibana123    │  or ingest pod   │
   └──────────┘     TLS: verify with ca.crt          └──────────────────┘
   Port-forward on host: kubectl port-forward ... 5601:5601

2. INGEST NODE → MASTER NODE (Transport, Port 9300, mTLS)
   ┌──────────┐     DNS: es-master-data-0.es-master-data   ┌──────────────────┐
   │ es-ingest│ ──── discovery.seed_hosts ───────────────→ │ es-master-data-0 │
   │ Node 2   │     Port 9300 (mutual TLS)                 │ Node 1           │
   └──────────┘     Join request → cluster state sync      └──────────────────┘

3. ESO → VAULT (HTTP, Port 8200)
   ┌──────────────────┐     http://vault.elk.svc:8200       ┌──────────┐
   │ ESO (external-   │ ──── POST /v1/auth/kubernetes/login │  Vault   │
   │ secrets ns)      │     POST /v1/secret/data/elastic    │  Node 2  │
   └──────────────────┘     Auth: JWT → Vault token         └──────────┘

4. cert-manager → KUBE-APISERVER (HTTPS, Port 443)
   ┌──────────────┐     Creates/reads Certificate CRDs      ┌───────────────┐
   │ cert-manager │ ←─────────────────────────────────────→ │ kube-apiserver│
   │ cert-manager │     Watches Certificate resources       │ Node 1        │
   │ namespace    │     Creates Secrets (elastic-certs)     └───────────────┘
   └──────────────┘

5. SET-KIBANA-PASSWORD JOB → ELASTICSEARCH (HTTPS, Port 9200)
   ┌──────────────────┐     POST /_security/user/            ┌──────────────────┐
   │ set-kibana-pwd   │ ──── kibana_system/_password ──────→ │  elasticsearch   │
   │ Job (elk ns)     │     Auth: elastic/elastic123         │  service         │
   └──────────────────┘                                      └──────────────────┘

6. CONFIGURE-VAULT JOB → VAULT + KUBE-APISERVER
   ┌──────────────────┐     POST /v1/sys/mounts/secret       ┌──────────┐
   │ configure-vault  │ ──── POST /v1/auth/kubernetes/config→│  Vault   │
   │ Job (elk ns)     │     POST /v1/sys/auth/kubernetes     └──────────┘
   └──────────────────┘
         │
         │  POST /apis/authentication.k8s.io/v1/tokenreviews
         ▼
   ┌───────────────┐
   │ kube-apiserver│
   │ Node 1        │
   └───────────────┘

7. KUBERNETES API (Internal)
   All components interact with kube-apiserver (kubernetes.default.svc:443):
   - Pods: read Secrets, ConfigMaps via service account tokens
   - cert-manager: CRUD Certificate/ClusterIssuer CRDs
   - ESO: CRUD ExternalSecret/SecretStore CRDs
   - Vault: TokenReview API (validate JWT tokens for k8s auth)
```

### Node-to-Node Traffic

```
Node 1 (minikube)                                    Node 2 (minikube-m02)
┌──────────────────────────────┐                    ┌──────────────────────────┐
│  es-master-data-0            │    Port 9300       │  es-ingest-0             │
│  10.244.0.16                 │◄══════════════════►│  10.244.1.38             │
│  (master + data)             │   mTLS encrypted   │  (ingest only)           │
└──────────────────────────────┘                    └──────────────────────────┘
         │                                                    │
         │   Port 8200                                        │
         │   ┌───────────────────────────────────────────────►│  vault-0
         │   │   ESO reads secrets from Vault                 │  10.244.1.32
         │   │   Port 8200 (HTTP)                             └──────────────────────
         │   │
         │   │   Port 9200 (HTTPS)
         │   ├───────────────────────────────────────────────►│  kibana-xxx
         │   │   Kibana queries ES                            │  10.244.1.41
         │   │                                                └──────────────────────
         │   │
         ▼   ▼
   ┌─────────────────────┐
   │ kube-apiserver      │  Port 443 (HTTPS)
   │ 10.96.0.1 (service) │◄── All components interact with API server
   │ Node 1              │
   └─────────────────────┘
```

### Port Summary

| Port | Protocol | Used By | Purpose |
|------|----------|---------|---------|
| 9200 | HTTPS | All ES pods | Elasticsearch REST API (document CRUD, search, cluster health) |
| 9300 | TLS (mTLS) | ES pods | Inter-node transport (cluster formation, shard replication) |
| 5601 | HTTP | Kibana | Kibana web UI (port-forward from host) |
| 8200 | HTTP | Vault | Vault API (secrets read/write, auth) |
| 8201 | HTTP | Vault | Vault cluster port (not used in dev/standalone mode) |
| 443 | HTTPS | All | Kubernetes API server |

---

## Flow Diagram: deploy.sh Execution Phases

```
Phase 0: Label Nodes
  ┌─────────────────────────────────────────────────────────────────────┐
  │  kubectl label node minikube      node-role.kubernetes.io/          │
  │  kubectl label node minikube-m02  master-data=true / ingest=true    │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
Phase 1: Create Namespace
  ┌─────────────────────────────────────────────────────────────────────┐
  │  namespace.yaml → Creates 'elk' namespace                           │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
Phase 2: Install OpenEBS LocalPV
  ┌─────────────────────────────────────────────────────────────────────┐
  │  helm install openebs/openebs --values openebs/values.yaml          │
  │  → Creates 'openebs-hostpath' StorageClass                          │
  │  → Deploys openebs-localpv-provisioner pod                          │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
Phase 3: Install cert-manager
  ┌─────────────────────────────────────────────────────────────────────┐
  │  helm install jetstack/cert-manager → namespace: cert-manager       │
  │  → Deploys cert-manager, cainjector, webhook pods                   │
  │  → Installs CRDs (Certificate, ClusterIssuer, etc.)                 │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
Phase 4: Create TLS Certificates
  ┌─────────────────────────────────────────────────────────────────────┐
  │  Step A: cluster-issuer.yaml → ClusterIssuers (selfsigned, es-ca)   │
  │  Step B: ca-certificate.yaml   → CA cert in cert-manager namespace  │
  │  Step C: certificate.yaml     → Node cert in elk namespace          │
  │  Result: Secret 'elastic-certs' in elk namespace (tls.crt+key+ca)   │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
Phase 5: Install Vault
  ┌─────────────────────────────────────────────────────────────────────┐
  │  helm install hashicorp/vault --values vault/vault-values.yaml      │
  │  → Deploys vault-0 pod (dev mode, auto-unsealed, in-memory)         │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
Phase 6: Configure Vault
  ┌─────────────────────────────────────────────────────────────────────┐
  │  configure-vault-job.yaml → Job runs once:                          │
  │  1. Enable KV v2 engine at path 'secret/'                           │
  │  2. Store elasticsearch passwords (elastic123, kibana123)           │
  │  3. Enable Kubernetes auth method                                   │
  │  4. Configure k8s auth (full FQDN, disable_local_ca_jwt=false)      │
  │  5. Create role 'external-secrets' with read policy                 │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
Phase 7: Install External Secrets Operator
  ┌─────────────────────────────────────────────────────────────────────┐
  │  helm install external-secrets/external-secrets                     │
  │  → Deploys ESO in 'external-secrets' namespace                      │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
Phase 8: Create SecretStore + ExternalSecret
  ┌─────────────────────────────────────────────────────────────────────┐
  │  secret-store.yaml  → ClusterSecretStore (points to Vault)          │
  │  external-secret.yaml → ExternalSecret (maps Vault keys → k8s Sec)  │
  │  Result: Secret 'elastic-credentials' in elk namespace              │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
Phase 9: Deploy ConfigMap & Services
  ┌─────────────────────────────────────────────────────────────────────┐
  │  configmap.yaml → cluster.name = production-es                      │
  │  headless-service.yaml → 3 services: es-master-data, es-ingest,     │
  │                           elasticsearch (all ClusterIP: None)       │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
Phase 10: Deploy ES Master-Data
  ┌─────────────────────────────────────────────────────────────────────┐
  │  master-data-statefulset.yaml → StatefulSet (roles: master, data)   │
  │  → Pod es-master-data-0 on Node 1 (minikube)                        │
  │  → PVC elasticsearch-data-es-master-data-0 (openebs-hostpath, 1Gi)  │
  │  → Reads elastic-certs Secret (TLS)                                 │
  │  → Reads elastic-credentials Secret (password)                      │
  │  → Bootstraps cluster (initial_master_nodes)                        │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
Phase 11: Deploy ES Ingest
  ┌─────────────────────────────────────────────────────────────────────┐
  │  ingest-statefulset.yaml → StatefulSet (roles: ingest)              │
  │  → Pod es-ingest-0 on Node 2 (minikube-m02)                         │
  │  → Discovers master via DNS: es-master-data-0.es-master-data        │
  │  → Sends join request over transport (port 9300, mTLS)              │
  │  → Receives cluster state, starts processing pipelines              │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
Phase 12: Verify Elastic Password
  ┌─────────────────────────────────────────────────────────────────────┐
  │  Check if elastic:${VAULT_PASSWORD} works against ES API            │
  │  If not → reset password via elasticsearch-reset-password CLI       │
  │  → Update elastic-credentials Secret with actual password           │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
Phase 13: Set kibana_system Password
  ┌─────────────────────────────────────────────────────────────────────┐
  │  set-kibana-password-job.yaml → Job runs once:                      │
  │  1. Wait for ES HTTP 401 (security layer up)                        │
  │  2. Wait for cluster health 200 (cluster ready)                     │
  │  3. POST /_security/user/kibana_system/_password with kibana123     │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
Phase 14: Deploy Kibana
  ┌─────────────────────────────────────────────────────────────────────┐
  │  service.yaml → NodePort service on port 5601                       │
  │  deployment.yaml → Kibana pod on Node 2 (minikube-m02)              │
  │  → Connects to https://elasticsearch:9200 with kibana_system        │
  │  → Verifies TLS with ca.crt                                         │
  │  → Exposes web UI on port 5601                                      │
  │  → Rollout restart (clear stale auth tokens)                        │
  └─────────────────────────┬───────────────────────────────────────────┘
                            │
                            ▼
                    DEPLOYMENT COMPLETE
                  Cluster health: GREEN
                   2 nodes, 30+ shards
```

---

## Sequence Diagram: Component Interaction

```
NOTE: Time flows from top to bottom. Arrows represent network calls.

PART 1: DEPLOYMENT ORCHESTRATION (deploy.sh)

deploy.sh              kube-apiserver        cert-manager         Vault
   │                        │                    │                  │
   │──Phase 0: label nodes─→│                    │                  │
   │──Phase 1: namespace────│                    │                  │
   │──Phase 2: OpenEBS──────│(helm install)      │                  │
   │──Phase 3: cert-manager─│(helm install)      │                  │
   │                        │                    │                  │
   │──Phase 4a: ClusterIssuer───────────────────→│                  │
   │                        │                    │                  │
   │──Phase 4b: CA Cert─────│(Certificate CRD)──→│                  │
   │                        │                    │──creates Secret──│
   │                        │                    │  es-ca-secret    │
   │                        │                    │                  │
   │──Phase 4c: Node Cert───│(Certificate CRD)──→│                  │
   │                        │                    │──creates Secret──│
   │                        │                    │  elastic-certs   │
   │                        │                    │                  │
   │──Phase 5: Vault────────│(helm install)──────│─────────────────→│
   │──Phase 6: Vault Config─│(Job apply)─────────│─────────────────→│
   │                        │                    │                  │
   │──Phase 7: ESO──────────│(helm install)      │                  │
   │──Phase 8: SecretStore──│(CRD apply)         │                  │
   │                        │                    │                  │
   │──Phase 9: ES Config────│(ConfigMap+Service) │                  │
   │──Phase 10: ES Master───│(StatefulSet apply) │                  │
   │                        │                    │                  │

PART 2: ELASTICSEARCH BOOTSTRAP

es-master-data-0      kube-apiserver        CoreDNS           es-ingest-0
   │                        │                  │                  │
   │  Pod starts on Node 1  │                  │                  │
   │──reads elastic-certs──→│                  │                  │
   │──reads ConfigMap──────→│                  │                  │
   │──reads Secret─────────→│                  │                  │
   │                        │                  │                  │
   │  Bootstraps cluster    │                  │                  │
   │  (initial_master_nodes)│                  │                  │
   │  HTTP API on 9200      │                  │                  │
   │  Transport on 9300     │                  │                  │
   │                        │                  │                  │
   │  [5 min later]         │                  │                  │
   │  Readiness probe:      │                  │                  │
   │  curl localhost:9200   │                  │                  │
   │  → 401 (Unauthorized)  │                  │                  │
   │  → Pod becomes Ready   │                  │                  │
   │                        │                  │                  │
   │                        │                  │   es-ingest-0 starts on Node 2
   │                        │                  │   │
   │                        │                  │   │──DNS lookup─────→ │
   │                        │  es-master-data-0│   │  es-master-data-0 │
   │◄───────────────────────│──es-master-data──│◄──│   .es-master-data │
   │  Returns pod IP        │ A record         │   │                   │
   │  (10.244.0.16)         │                  │   │                   │
   │                        │                  │   │──TCP connect─────→│
   │◄──────────────────────────────────────────────────────────────────│
   │  Port 9300 (mTLS)     │                   │   │  Join request     │
   │  Certificate exchange │                   │   │                   │
   │  Verify both certs    │                   │   │                   │
   │  signed by same CA    │                   │   │                   │
   │                       │                   │   │                   │
   │──Send cluster state──→│────────────────── │───│  State applied    │
   │                       │                   │   │  Node joins       │
   │                       │                   │   │  HTTP API on 9200 │
   │                       │                   │   │  → Ready          │
   │                       │                   │   │                   │

PART 3: SECRETS MANAGEMENT

Vault                 kube-apiserver        ESO               elastic-credentials
  │                        │                  │                  │
  │  Secrets stored in     │                  │                  │
  │  /secret/elasticsearch │                  │                  │
  │  elastic-password=xxx  │                  │                  │
  │  kibana-password=xxx   │                  │                  │
  │                        │                  │                  │
  │  Auth configured:      │                  │                  │
  │  /auth/kubernetes      │                  │                  │
  │  role: external-secrets│                  │                  │
  │  bound to SA:          │                  │                  │
  │  external-secrets/     │                  │                  │
  │  external-secrets      │                  │                  │
  │                        │                  │                  │
  │                        │                  │  Watches ExternalSecret CRD
  │                        │                  │  │
  │                        │                  │  │──Kubernetes auth───→│
  │                        │  TokenReview     │  │  JWT + role         │
  │                        │◄─────────────────│──│                     │
  │                        │  Validate JWT    │  │                     │
  │                        │──response───────→│  │                     │
  │◄──────────────────────────────────────────│──│  Login with role    │
  │  Return Vault token    │                  │  │                     │
  │──Send Vault token─────→│──────────────────│──│                     │
  │  + read secret/data/   │                  │  │                     │
  │  elasticsearch         │                  │  │                     │
  │──Return {elastic-xxx, ─│──────────────────│──│                     │
  │  kibana-xxx}           │                  │  │                     │
  │                        │                  │  │──Create Secret──────│
  │                        │                  │  │  elastic-credentials│
  │                        │                  │  │  in elk namespace   │

PART 4: KIBANA ACCESS FROM HOST

Kibana              Elasticsearch         MacBook Host
  │                        │                  │
  │  Start on Node 2       │                  │
  │──Connect to───────────→│                  │
  │  https://elasticsearch:│                  │
  │  9200                  │                  │
  │  Auth: kibana_system/  │                  │
  │  kibana123             │                  │
  │  Verify TLS with ca.crt│                  │
  │  │                     │                  │
  │◄─Return cluster state──│                  │
  │  │                     │                  │
  │  Kibana web UI ready   │                  │
  │  on port 5601          │                  │
  │                        │                  │
  │                        │                  │  kubectl port-forward
  │                        │                  │  svc/kibana 5601:5601
  │  [Port-forward tunnel] │                  │──Creates tunnel───────→│
  │◄──────────────────────────────────────────│──  localhost:5601      │
  │                        │                  │  │                     │
  │  Browser request       │                  │  │                     │
  │◄──────────────────────────────────────────│──  GET / HTTP/1.1      │
  │  → HTTP 302 redirect   │                  │  │                     │
  │  → Login page          │                  │  │                     │
```

---

## How YAML Files Execute (Step by Step)

### Namespace (`namespace.yaml`)

```
Applied by: deploy.sh Phase 1 (kubectl apply)
Effect: Creates the 'elk' namespace.
What happens: Kubernetes API server registers the namespace. All subsequent
resources (pods, services, secrets) will be created in this namespace.
```

### ConfigMap (`elasticsearch/configmap.yaml`)

```
Applied by: deploy.sh Phase 9 (kubectl apply)
Effect: Creates a ConfigMap named 'elasticsearch-config' in elk namespace.
Content: cluster.name = production-es
How it's used: Each ES pod reads this via env var:
  env:
    - name: cluster.name
      valueFrom:
        configMapKeyRef:
          name: elasticsearch-config
          key: cluster.name
When ES starts, it reads the env var and sets cluster.name = "production-es".
All nodes must share this name to form a cluster.
```

### Headless Services (`elasticsearch/headless-service.yaml`)

```
Applied by: deploy.sh Phase 9 (kubectl apply)
Effect: Creates 3 headless services:

1. es-master-data (ClusterIP: None)
   - Selector: app=elasticsearch, role=master-data
   - Purpose: DNS-based discovery for master-data StatefulSet
   - DNS created for each pod: es-master-data-0.es-master-data

2. es-ingest (ClusterIP: None)
   - Selector: app=elasticsearch, role=ingest
   - Purpose: DNS-based discovery for ingest StatefulSet
   - DNS created: es-ingest-0.es-ingest

3. elasticsearch (ClusterIP: None)
   - Selector: app=elasticsearch (ALL ES pods)
   - Purpose: Generic endpoint for Kibana and Jobs
   - DNS: elasticsearch (resolves to all ES pod IPs)

Why headless?
  Normal ClusterIP services give you a single virtual IP (load balancer).
  Headless services give you direct DNS A/AAAA records for each pod IP.
  ES needs direct pod IPs for transport communication (port 9300).
```

### ClusterIssuers (`cert-manager/cluster-issuer.yaml`)

```
Applied by: deploy.sh Phase 4a (kubectl apply)
Effect: Creates 2 cluster-scoped issuers:

1. selfsigned-issuer (type: SelfSigned)
   - Can sign ANY certificate without an external CA
   - Only used to bootstrap the CA certificate
   - Security: Self-signed certs are NOT trusted by browsers or clients.
     They are only an intermediate step — clients trust the CA cert, not
     the self-signed root.

2. es-ca-issuer (type: CA)
   - Signs certificates using the CA key pair in Secret 'es-ca-secret'
   - Used to sign the actual Elasticsearch node certificate
   - Reads es-ca-secret from cert-manager namespace (must be there — Issue #1)

Both are ClusterIssuers (not Issuers) because:
  - They need to issue certificates in multiple namespaces (cert-manager, elk)
  - They are cluster-scoped and usable from any namespace
```

### CA Certificate (`cert-manager/ca-certificate.yaml`)

```
Applied by: deploy.sh Phase 4b (kubectl apply)
Effect: Creates a Certificate resource in cert-manager namespace.

What happens inside cert-manager:
  1. cert-manager watches for Certificate resources
  2. Detects 'es-ca' Certificate in cert-manager namespace
  3. Generates an ECDSA P-256 key pair (private + public)
  4. Creates a Certificate Signing Request (CSR)
  5. Submits CSR to selfsigned-issuer (ClusterIssuer)
  6. selfsigned-issuer signs the CSR → returns signed certificate
  7. cert-manager stores the result in Secret 'es-ca-secret':
     - tls.crt: the signed CA certificate
     - tls.key: the CA private key
     - ca.crt: same as tls.crt (self-signed CA)
  8. This Secret is now usable by es-ca-issuer

Why ECDSA P-256 for CA?
  ECDSA is faster for signing operations than RSA.
  P-256 provides equivalent security to RSA 3072.
  The CA only signs a few certificates, so performance doesn't matter much,
  but ECDSA is the modern best practice.
```

### Node Certificate (`cert-manager/certificate.yaml`)

```
Applied by: deploy.sh Phase 4c (kubectl apply)
Effect: Creates a Certificate resource in elk namespace.

What happens inside cert-manager:
  1. Detects 'es-node' Certificate in elk namespace
  2. Generates RSA 2048 key pair (compatible with all ES features)
  3. Creates CSR with all the DNS SANs listed in dnsNames
  4. Submits CSR to es-ca-issuer (CA-based ClusterIssuer)
  5. es-ca-issuer validates the request, signs with its CA key
  6. cert-manager stores result in Secret 'elastic-certs' in elk namespace:
     - tls.crt: the signed node certificate
     - tls.key: the node private key
     - ca.crt: the CA certificate (from es-ca-secret)
  7. This Secret is mounted into each ES pod as TLS files

Why RSA 2048 for node certs (not ECDSA)?
  Some Elasticsearch features (PKCS#11 tokens, certain HSM integrations)
  work better with RSA. RSA 2048 is the most widely compatible option.

DNS SANs explanation:
  The certificate must be valid for ALL DNS names that clients use to
  connect. This includes:
  - Service names: elasticsearch, elasticsearch.elk.svc.cluster.local
  - Pod DNS: es-master-data-0.es-master-data (for transport discovery)
  - Pod DNS: es-ingest-0.es-ingest (for transport discovery)
  - Wildcards: *.elasticsearch (future pods)
  - localhost: for readiness probes
```

### Vault Helm Values (`vault/vault-values.yaml`)

```
Applied by: deploy.sh Phase 5 (helm install)
Effect: Deploys Vault in dev mode.

What happens:
  1. Helm creates a StatefulSet with 1 replica (vault-0)
  2. Vault starts in dev mode:
     - Automatically unsealed (no manual unseal step)
     - In-memory storage (data lost on restart)
     - Root token = "root"
     - TLS disabled (HTTP only)
  3. Service 'vault' is created (ClusterIP, port 8200)
  4. Vault is ready to accept API calls

Dev mode vs Production:
  Dev mode:    Auto-unsealed, in-memory, HTTP, root token="root"
  Production:  Must be unsealed manually, HA setup with Consul/Raft, HTTPS,
               no hardcoded root token

Why dev mode?
  For local development, dev mode removes all operational complexity.
  Production Vault setup requires: unsealing, HA configuration, TLS certs,
  audit logging, etc. — all unnecessary for a dev Elasticsearch cluster.
```

### Configure Vault Job (`vault/configure-vault-job.yaml`)

```
Applied by: deploy.sh Phase 6 (kubectl apply)
Effect: Runs a one-time Job that configures Vault.

The Job does 7 things in order:

Step 1: Wait for Vault
  ┌─────────────────────────────────────────────────────────────────────┐
  │  until vault status → ok                                            │
  │  This loops until Vault's /v1/sys/health returns 200                │
  └─────────────────────────────────────────────────────────────────────┘

Step 2: Enable KV v2 engine
  ┌─────────────────────────────────────────────────────────────────────┐
  │  vault secrets enable -path=secret kv-v2                            │
  │  Mounts the KV v2 engine at the "secret/" path.                     │
  │  Now secrets can be stored at paths like secret/elasticsearch.      │
  │  2>/dev/null || true = ignore "already enabled" errors.             │
  └─────────────────────────────────────────────────────────────────────┘

Step 3: Store credentials
  ┌─────────────────────────────────────────────────────────────────────┐
  │  vault kv put secret/elasticsearch \                                │
  │    elastic-password=elastic123 \                                    │
  │    kibana-password=kibana123                                        │
  │  Writes the passwords to Vault. KV v2 stores them as versioned      │
  │  key-value pairs. Reading requires: secret/data/elasticsearch       │
  └─────────────────────────────────────────────────────────────────────┘

Step 4: Enable Kubernetes auth
  ┌─────────────────────────────────────────────────────────────────────┐
  │  vault auth enable kubernetes                                       │
  │  Mounts the Kubernetes auth method. Now Vault can accept            │
  │  Kubernetes service account JWTs for authentication.                │
  └─────────────────────────────────────────────────────────────────────┘

Step 5: Configure Kubernetes auth
  ┌─────────────────────────────────────────────────────────────────────┐
  │  vault write auth/kubernetes/config \                               │
  │    kubernetes_host="https://kubernetes.default.svc.cluster.local"   │
  │    disable_local_ca_jwt=false                                       │
  │                                                                     │
  │  kubernetes_host: The API server URL. Must be the FULL FQDN         │
  │    (5 domain parts) because Vault's resolver fails with 3-part      │
  │    DNS names (Issue #2).                                            │
  │                                                                     │
  │  disable_local_ca_jwt=false: Vault uses ITS OWN service account     │
  │    JWT (mounted at /var/run/secrets/kubernetes.io/serviceaccount/   │
  │    token) to call the TokenReview API. This avoids needing to       │
  │    manage a separate token_reviewer_jwt.                            │
  └─────────────────────────────────────────────────────────────────────┘

Step 6: Create ESO role
  ┌─────────────────────────────────────────────────────────────────────┐
  │  vault write auth/kubernetes/role/external-secrets \                │
  │    bound_service_account_names=external-secrets \                   │
  │    bound_service_account_namespaces=external-secrets \              │
  │    policies=eso-es-policy \                                         │
  │    ttl=1h                                                           │
  │                                                                     │
  │  bound_service_account_names: Only the SA named "external-secrets"  │
  │  in the "external-secrets" namespace can authenticate.              │
  │                                                                     │
  │  policies: When this SA authenticates, it gets the eso-es-policy    │
  │  which grants read access to secret/data/elasticsearch.             │
  │                                                                     │
  │  ttl=1h: The Vault token expires in 1 hour. ESO automatically       │
  │  re-authenticates before expiry.                                    │
  └─────────────────────────────────────────────────────────────────────┘

Step 7: Create read policy
  ┌─────────────────────────────────────────────────────────────────────┐
  │  path "secret/data/elasticsearch" { capabilities = ["read"] }       │
  │  Grants READ-only access to the elasticsearch secrets.              │
  │  Note: KV v2 requires "data" in the path (secret/data/, not         │
  │  just secret/). This is a common mistake.                           │
  └─────────────────────────────────────────────────────────────────────┘
```

### SecretStore + ExternalSecret (`external-secrets/`)

```
Applied by: deploy.sh Phase 8 (kubectl apply)
Effect: Creates ESO resources to sync Vault → k8s Secret.

ClusterSecretStore (vault-backend):
  ┌─────────────────────────────────────────────────────────────────────┐
  │  Defines HOW to connect to Vault:                                   │
  │  - URL: http://vault.elk.svc:8200                                   │
  │  - Path: secret (KV v2 mount point)                                 │
  │  - Auth: Kubernetes (SA JWT → Vault login → token)                  │
  │  - Role: external-secrets                                           │
  │  - SA: external-secrets/external-secrets                            │
  └─────────────────────────────────────────────────────────────────────┘

  When ESO starts, it:
  1. Reads the SecretStore config
  2. Watches for ExternalSecret resources that reference it

ExternalSecret (elastic-credentials):
  ┌─────────────────────────────────────────────────────────────────────┐
  │  Defines WHAT to sync:                                              │
  │  Reads from Vault: secret/data/elasticsearch                        │
  │    - property: elastic-password → k8s key: elastic-password         │
  │    - property: kibana-password  → k8s key: kibana-password          │
  │  Writes to k8s Secret: elastic-credentials in elk namespace         │
  │  Refresh interval: 1 hour                                           │
  └─────────────────────────────────────────────────────────────────────┘

  Sync flow:
  1. ESO detects ExternalSecret 'elastic-credentials'
  2. ESO reads ClusterSecretStore 'vault-backend'
  3. ESO reads its own SA JWT token (from /var/run/secrets/...)
  4. ESO calls Vault: POST /v1/auth/kubernetes/login
     Body: { role: "external-secrets", jwt: "<token>" }
  5. Vault calls Kubernetes TokenReview API to validate the JWT
  6. If valid, Vault returns a Vault token (with eso-es-policy)
  7. ESO calls Vault: GET /v1/secret/data/elasticsearch
     Header: X-Vault-Token: <token>
  8. Vault returns: { elastic-password: "elastic123", kibana-password: "kibana123" }
  9. ESO creates k8s Secret 'elastic-credentials' in elk namespace
  10. ESO refreshes every 1 hour (or on Vault secret change)
```

### Master-Data StatefulSet (`elasticsearch/master-data-statefulset.yaml`)

```
Applied by: deploy.sh Phase 10 (kubectl apply)
Effect: Creates the primary Elasticsearch node.

Pod startup sequence:
  1. initContainer: fix-permissions
     - Clears and re-creates /usr/share/elasticsearch/data/
     - Sets owner:group = 1000:0 (elasticsearch user)
     - Sets permissions = 775

  2. initContainer: prepare-certs
     - Copies TLS certs from Secret volume to emptyDir
     - Sets owner:group = 1000:0
     - Sets permissions = 640

  3. mainContainer: elasticsearch
     a. Reads env vars (cluster.name, node.roles, etc.)
     b. Reads cluster.name from ConfigMap
     c. Reads ELASTIC_PASSWORD from Secret
     d. Configures TLS paths from env vars
     e. Starts JVM with -Xms256m -Xmx256m -XX:+AlwaysPreTouch
     f. Initializes plugins (x-pack security, etc.)
     g. Bootstraps cluster (cluster.initial_master_nodes = es-master-data-0)
     h. Opens HTTP port 9200 (HTTPS with TLS)
     i. Opens Transport port 9300 (TLS with mTLS)
     j. Readiness probe: curl https://localhost:9200 → expects 401
     k. Pod becomes Ready

  What the pod has access to:
    - PVC: /usr/share/elasticsearch/data/ (persistent, 1Gi OpenEBS hostPath)
    - Secret: elastic-certs → /certs/ (TLS files)
    - Secret: elastic-credentials → env.ELASTIC_PASSWORD
    - ConfigMap: elasticsearch-config → env.cluster.name
```

### Ingest StatefulSet (`elasticsearch/ingest-statefulset.yaml`)

```
Applied by: deploy.sh Phase 11 (kubectl apply)
Effect: Creates the Elasticsearch ingest node.

Pod startup sequence:
  1. initContainer: prepare-certs (same as master-data)

  2. mainContainer: elasticsearch
     a. Reads env vars (roles=ingest only — no master, no data)
     b. discovery.seed_hosts = "es-master-data-0.es-master-data"
     c. Starts JVM with -Xms384m -Xmx384m (no AlwaysPreTouch)
     d. Configures TLS (same cert Secret as master-data)
     e. Resolves DNS: es-master-data-0.es-master-data → IP of master
     f. Sends join request over port 9300 with mTLS
     g. Master verifies the certificate (must be signed by same CA)
     h. Master accepts join, sends cluster state
     i. Ingest node applies cluster state
     j. Opens HTTP port 9200 and Transport port 9300
     k. Readiness probe passes (401 on localhost:9200)
     l. Pod becomes Ready

  Discovery flow (if this fails, see Issue #8):
    1. Pod starts, reads discovery.seed_hosts
    2. Calls CoreDNS: A-record lookup for es-master-data-0.es-master-data
    3. CoreDNS responds with: 10.244.0.16 (master-data pod IP)
    4. Pod opens TCP connection to 10.244.0.16:9300
    5. mTLS handshake: both sides present certs, verify against CA
    6. Ingest sends JoinRequest to master
    7. Master responds with initial cluster state
    8. Ingest becomes a full member of the cluster
```

### Kibana Deployment (`kibana/deployment.yaml`)

```
Applied by: deploy.sh Phase 14 (kubectl apply)
Effect: Deploys Kibana web UI.

Pod startup sequence:
  1. Container starts, reads env vars:
     - ELASTICSEARCH_HOSTS = "https://elasticsearch:9200"
     - ELASTICSEARCH_USERNAME = "kibana_system"
     - ELASTICSEARCH_PASSWORD = from Secret elastic-credentials
     - ELASTICSEARCH_SSL_CERTIFICATEAUTHORITIES = config/certs/ca.crt

  2. Kibana connects to ES:
     - DNS: elasticsearch → CoreDNS → ES pod IPs
     - HTTPS on port 9200 with TLS verification
     - Auth: kibana_system / kibana123

  3. Kibana loads 170+ plugins (takes 60-120 seconds)

  4. Kibana web UI becomes available on port 5601

  5. Port-forward from host: kubectl port-forward → localhost:5601

  Why rollout restart after deployment?
    Kibana caches the ES password at startup. If the password was just set
    (Phase 13), Kibana might have started with a different password. The
    restart ensures it reads the correct password from the Secret.
```

### Set Kibana Password Job (`set-kibana-password-job.yaml`)

```
Applied by: deploy.sh Phase 13 (kubectl apply)
Effect: Sets the kibana_system user password in Elasticsearch.

Job execution:
  1. Wait for HTTP 401 from ES (security layer is up)
  2. Wait for cluster health 200 (cluster is ready)
  3. POST to _security/user/kibana_system/_password
     Auth: elastic / elastic123
     Body: { "password": "kibana123" }
  4. If HTTP 200 → success, Job completes
  5. If not 200 → Job fails, can be re-run

Why is this needed?
  ES 8.x auto-configures kibana_system with a random password on first boot.
  We need to change it to our managed password (from Vault) so that Kibana
  can authenticate. If we skip this, Kibana gets "authentication failed".
```

---

## Component Details & Communication Paths

### How TLS Certificates Flow

```
1. cert-manager is installed (Helm)

2. selfsigned-issuer ClusterIssuer is created
   └── Type: SelfSigned — can sign any cert without external CA

3. es-ca Certificate is created in cert-manager namespace
   └── Uses selfsigned-issuer to sign
   └── Result: Secret 'es-ca-secret' in cert-manager namespace
       ├── tls.crt (CA certificate — public key)
       └── tls.key (CA private key)

4. es-ca-issuer ClusterIssuer is created
   └── Type: CA — references Secret 'es-ca-secret'
   └── Must be in cert-manager namespace (Issue #1)

5. es-node Certificate is created in elk namespace
   └── Uses es-ca-issuer to sign
   └── Result: Secret 'elastic-certs' in elk namespace
       ├── tls.crt (node certificate — signed by CA)
       ├── tls.key (node private key)
       └── ca.crt (CA cert — for verification)

6. Secret 'elastic-certs' is mounted into:
   - es-master-data-0: /usr/share/elasticsearch/config/certs/
     ├── es.crt   (from tls.crt, copied by init container)
     ├── es.key   (from tls.key, copied by init container)
     └── ca.crt   (from ca.crt, copied by init container)
   
   - es-ingest-0: same mount path (same Secret)

   - kibana: /usr/share/kibana/config/certs/
     └── ca.crt   (only CA cert — Kibana doesn't need client cert)

7. Elasticsearch configures:
   - HTTP TLS (port 9200): uses es.crt + es.key, verifies with ca.crt
   - Transport TLS (port 9300): uses es.crt + es.key, mutual verification
   - verification_mode=certificate: checks cert is signed by our CA
   - client_authentication=required (transport only): mTLS — both sides
     present certificates
```

### How Secrets Flow (Vault → K8s Secret)

```
1. Vault is installed (Helm, dev mode)

2. configure-vault Job runs:
   ├── Enables KV v2 at path "secret/"
   ├── Stores: secret/elasticsearch
   │   ├── elastic-password = "elastic123"
   │   └── kibana-password  = "kibana123"
   ├── Enables Kubernetes auth at path "kubernetes/"
   ├── Configures k8s auth: kubernetes_host=..., disable_local_ca_jwt=false
   ├── Creates role "external-secrets" for SA external-secrets/external-secrets
   └── Creates policy "eso-es-policy" with read on secret/data/elasticsearch

3. External Secrets Operator is installed (Helm)

4. ClusterSecretStore 'vault-backend' is created:
   └── Points to http://vault.elk.svc:8200, path=secret, auth=k8s

5. ExternalSecret 'elastic-credentials' is created:
   └── References ClusterSecretStore 'vault-backend'
   └── Maps: vault:elasticsearch/elastic-password → k8s:elastic-password
   └── Maps: vault:elasticsearch/kibana-password  → k8s:kibana-password

6. ESO syncs:
   └── Authenticates to Vault (SA JWT → Vault token)
   └── Reads secret/data/elasticsearch
   └── Creates k8s Secret 'elastic-credentials' in elk namespace:
       ├── elastic-password (base64: ZWxhc3RpYzEyMw==)
       └── kibana-password  (base64: a2liYW5hMTIz)

7. Pods consume the Secret:
   - es-master-data-0: env.ELASTIC_PASSWORD from secretKeyRef
   - es-ingest-0: env.ELASTIC_PASSWORD from secretKeyRef
   - kibana: env.ELASTICSEARCH_PASSWORD from secretKeyRef
   - set-kibana-password Job: reads both passwords as env vars
```

### How Elasticsearch Cluster Forms

```
1. es-master-data-0 starts on Node 1
   ├── Has cluster.initial_master_nodes = "es-master-data-0"
   ├── Nobody else is in the cluster, so it elects itself as master
   ├── Cluster state: version 1, term 1, master = es-master-data-0
   └── Opens HTTP (9200) and Transport (9300)

2. es-ingest-0 starts on Node 2 (several minutes later)
   ├── discovery.seed_hosts = "es-master-data-0.es-master-data"
   ├── Resolves DNS → 10.244.0.16 (master-data pod IP)
   ├── Connects to 10.244.0.16:9300
   ├── mTLS handshake:
   │   ├── Both sides present their certificates
   │   ├── Both sides verify the cert is signed by the same CA
   │   ├── If verification fails → connection rejected → node stuck joining
   └── If verification passes:
       ├── Ingest sends JoinRequest to master
       ├── Master accepts, adds es-ingest-0 to cluster membership
       ├── Master sends updated cluster state to ingest
       └── Ingest applies state, opens its own HTTP + Transport ports

3. Cluster is formed: 2 nodes (1 master+data, 1 ingest)
   ├── Cluster health: GREEN (all shards assigned)
   ├── Master-data handles: cluster management, shard allocation, data storage
   └── Ingest handles: document pre-processing (ingest pipelines)
```

---

## Resource Budget

| Component | Namespace | Replicas | RAM Request | RAM Limit | CPU Request | CPU Limit |
|-----------|-----------|----------|-------------|-----------|-------------|-----------|
| Minikube Control Plane | kube-system | 1 | ~500 MB (fixed) | ~500 MB | - | - |
| es-master-data-0 | elk | 1 | 512 Mi | 1 Gi | 150m | 300m |
| es-ingest-0 | elk | 1 | 512 Mi | 1 Gi | 150m | 300m |
| kibana | elk | 1 | 512 Mi | 1 Gi | 150m | 300m |
| vault-0 | elk | 1 | 128 Mi | 256 Mi | 50m | 100m |
| cert-manager | cert-manager | 1 | 64 Mi | 128 Mi | - | - |
| cert-manager-cainjector | cert-manager | 1 | 32 Mi | 64 Mi | - | - |
| cert-manager-webhook | cert-manager | 1 | 32 Mi | 64 Mi | - | - |
| external-secrets | external-secrets | 1 | 32 Mi | 64 Mi | - | - |
| openebs-localpv-provisioner | openebs | 1 | 32 Mi | 64 Mi | 25m | 50m |
| **Total** | | | **~1.8 Gi** | **~3.7 Gi** | | |

Additional overhead (not listed):
- CoreDNS: ~20 Mi
- Calico CNI: ~50 Mi per node
- kube-proxy: ~30 Mi per node
- OS + container runtime: ~300 Mi per node

**Total cluster requirement: ~4 Gi RAM minimum** (fits within the 6 Gi allocation)

---

## Prerequisites

```bash
# Start Minikube with 2 nodes (6 GB RAM recommended):
minikube stop
minikube delete --all --purge

minikube start \
  --driver=podman \
  --nodes=2 \
  --cpus=4 \
  --memory=6144 \
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
- `kubectl` (any version matching cluster)
- `helm` (v3+)
- `jq`

---

## Deployment

```bash
chmod +x deploy.sh
./deploy.sh
```

Expected run time: **15-20 minutes** (most time is waiting for ES pods to start).

---

## Uninstall

```bash
chmod +x uninstall.sh
./uninstall.sh
```

Removes in reverse order: ES StatefulSets → PVCs → Kibana → ESO resources → cert-manager resources → ESO operator → Vault → OpenEBS → cert-manager → namespace → node labels.

---

## Access

```bash
# Elasticsearch health (must authenticate)
ELASTIC_PWD=$(kubectl get secret -n elk elastic-credentials -o jsonpath='{.data.elastic-password}' | base64 -d)
kubectl exec -n elk es-master-data-0 -- \
  curl -sk -u "elastic:${ELASTIC_PWD}" \
  https://localhost:9200/_cluster/health?pretty

# Expected output:
# {
#   "cluster_name" : "production-es",
#   "status" : "green",
#   "number_of_nodes" : 2,
#   "active_shards_percent_as_number" : 100.0
# }

# Kibana (port-forward)
kubectl port-forward -n elk svc/kibana 5601:5601
# Open http://localhost:5601 in browser

# Or use minikube service tunnel:
minikube service kibana -n elk --url

# Minikube dashboard
minikube dashboard
```

---

## Debugging Cheat Sheet

```bash
# ==========================================
# POD STATUS AND LOGS
# ==========================================

# All running pods
kubectl get pods -n elk -o wide

# Pod details (reasons, exit codes, events)
kubectl describe pod -n elk <pod-name> | grep -E "State:|Reason:|Exit Code:|Message:"

# Tail recent logs
kubectl logs -n elk <pod-name> --tail 50

# Stream logs in real-time
kubectl logs -n elk <pod-name> -f

# All events sorted by time
kubectl get events -n elk --sort-by='.lastTimestamp' | tail -30

# ==========================================
# RESOURCE USAGE
# ==========================================

# Pod resource usage (requires metrics-server)
kubectl top pods -n elk

# Node resource usage
kubectl top nodes

# ==========================================
# ELASTICSEARCH
# ==========================================

# Cluster health
kubectl exec -n elk es-master-data-0 -- \
  curl -sk -u "elastic:${ELASTIC_PWD}" \
  https://localhost:9200/_cluster/health?pretty

# Node list with roles
kubectl exec -n elk es-master-data-0 -- \
  curl -sk -u "elastic:${ELASTIC_PWD}" \
  "https://localhost:9200/_cat/nodes?v=true&h=name,nodeRole,ip,version"

# All indices
kubectl exec -n elk es-master-data-0 -- \
  curl -sk -u "elastic:${ELASTIC_PWD}" \
  "https://localhost:9200/_cat/indices?v"

# ==========================================
# CERT-MANAGER CERTIFICATES
# ==========================================

# All certificates in all namespaces
kubectl get certificates -A

# Certificate details
kubectl describe certificate -n elk es-node

# ClusterIssuer status
kubectl describe clusterissuer es-ca-issuer

# TLS Secret contents
kubectl get secret -n elk elastic-certs -o yaml

# ==========================================
# VAULT
# ==========================================

# Check vault health
kubectl exec -n elk vault-0 -- vault status

# Read stored secrets
kubectl exec -n elk vault-0 -- vault kv get secret/elasticsearch

# Check auth config
kubectl exec -n elk vault-0 -- vault read auth/kubernetes/config

# Test auth manually
JWT=$(kubectl create token external-secrets -n external-secrets --duration=1h)
kubectl exec -n elk vault-0 -- vault write auth/kubernetes/login \
  role=external-secrets jwt="$JWT"

# ==========================================
# EXTERNAL SECRETS OPERATOR
# ==========================================

# Check SecretStore status
kubectl describe clustersecretstore vault-backend

# Check ExternalSecret status
kubectl describe externalsecret -n elk elastic-credentials

# Verify synced secret exists
kubectl get secret -n elk elastic-credentials -o yaml

# List all ESO resources
kubectl get externalsecrets -A
kubectl get clustersecretstores

# ==========================================
# DNS AND NETWORK
# ==========================================

# Test DNS resolution from a pod
kubectl exec -n elk es-ingest-0 -- \
  nslookup elasticsearch

# Test DNS of headless service
kubectl exec -n elk es-ingest-0 -- \
  nslookup es-master-data-0.es-master-data

# Test TCP connectivity
kubectl exec -n elk es-ingest-0 -- \
  timeout 5 bash -c 'echo > /dev/tcp/es-master-data-0.es-master-data/9300 && echo "OK"'

# ==========================================
# STORAGE
# ==========================================

# List PVCs
kubectl get pvc -n elk

# List OpenEBS volumes
kubectl get pv | grep openebs

# Storage classes
kubectl get sc

# ==========================================
# CLEANUP (without running uninstall.sh)
# ==========================================

# Delete a specific failed pod
kubectl delete pod <pod-name> -n elk

# Force delete a stuck pod
kubectl delete pod <pod-name> -n elk --force --grace-period=0

# Re-apply a StatefulSet after changes
kubectl apply -f elasticsearch/ingest-statefulset.yaml
```

---

## Troubleshooting Guide

### Pod stuck in CrashLoopBackOff

```bash
# Find out why
kubectl describe pod -n elk <pod-name> | grep -E "Reason:|Exit Code:|State:"
kubectl logs -n elk <pod-name> --tail 30

# Common exit codes:
#   Exit 137 = OOMKilled (out of memory) → increase limits
#   Exit 134 = SIGABRT (Node.js/Kibana OOM) → increase limits
#   Exit 1   = Application error → check logs
#   Exit 143 = SIGTERM (graceful shutdown) → normal for restarts
```

### Elasticsearch not forming cluster

```bash
# Check master-data logs for cluster formation
kubectl logs -n elk es-master-data-0 --tail 50 | grep -E "elected|discovery|master|join"

# Check ingest logs for join attempts
kubectl logs -n elk es-ingest-0 --tail 50 | grep -E "elected|discovery|master|join|discovered"

# Test DNS resolution from ingest pod
kubectl exec -n elk es-ingest-0 -- nslookup es-master-data-0.es-master-data

# Test TCP to master transport port
kubectl exec -n elk es-ingest-0 -- timeout 5 bash -c \
  'echo > /dev/tcp/es-master-data-0.es-master-data/9300 && echo "OK"'

# Check if master is healthy
ELASTIC_PWD=$(kubectl get secret -n elk elastic-credentials -o jsonpath='{.data.elastic-password}' | base64 -d)
kubectl exec -n elk es-master-data-0 -- \
  curl -sk -u "elastic:${ELASTIC_PWD}" https://localhost:9200/_cluster/health?pretty
```

### Secret not syncing from Vault

```bash
# Check ESO status
kubectl get externalsecret -n elk
kubectl describe externalsecret elastic-credentials -n elk

# Check SecretStore status
kubectl get clustersecretstore vault-backend
kubectl describe clustersecretstore vault-backend

# Check Vault reachability
kubectl exec -n elk vault-0 -- wget -qO- http://vault:8200/v1/sys/health

# Check secret exists in Vault
kubectl exec -n elk vault-0 -- vault kv get secret/elasticsearch

# Check Vault auth configuration
kubectl exec -n elk vault-0 -- vault read auth/kubernetes/config

# Test Vault authentication with ESO's SA
JWT=$(kubectl create token external-secrets -n external-secrets --duration=1h)
kubectl exec -n elk vault-0 -- vault write auth/kubernetes/login \
  role=external-secrets jwt="$JWT"

# If all above works, restart ESO pod
kubectl rollout restart deployment external-secrets -n external-secrets
```

### Kibana not accessible

```bash
# Check if kibana pod is running
kubectl get pods -n elk | grep kibana

# Check kibana logs for errors
kubectl logs deployment/kibana -n elk --tail 30

# Check if kibana is listening (test from another pod)
kubectl exec -n elk es-ingest-0 -- curl -s -o /dev/null -w "%{http_code}" \
  http://kibana:5601 2>/dev/null || echo "Kibana not reachable"

# Check port-forward
kubectl port-forward -n elk svc/kibana 5601:5601

# If Kibana shows "Kibana server is not ready yet":
#   → Wait 1-2 minutes (it's still loading plugins)
#   → Check ES connectivity: kubectl logs deployment/kibana -n elk
#   → Look for "ecs_authentication_failed" → wrong password → re-run set-kibana-password job

# Reset port-forward after pod restart
pkill -f "kubectl port-forward.*5601" 2>/dev/null || true
kubectl port-forward -n elk svc/kibana 5601:5601
```

### PVC stuck in Pending

```bash
# Check PVC status
kubectl describe pvc elasticsearch-data-es-ingest-0 -n elk

# Look for events:
#   WaitForFirstConsumer: normal — will bind when pod is scheduled
#   ProvisioningFailed: storage class not found or misconfigured

# If stuck in WaitForFirstConsumer:
#   → The pod hasn't started yet (maybe another issue blocking it)
#   → Check pod status: kubectl get pods -n elk

# If storage class not found:
kubectl get sc
# Should show: openebs-hostpath   openebs.io/local   WaitForFirstConsumer

# If openebs-hostpath is missing:
kubectl get pods -n openebs
# openebs-localpv-provisioner should be Running
```

### cert-manager Certificate not ready

```bash
# Check certificate status
kubectl describe certificate -n elk es-node

# Check ClusterIssuer status
kubectl describe clusterissuer es-ca-issuer

# Check if CA secret exists
kubectl get secret es-ca-secret -n cert-manager
# If not found: es-ca Certificate failed or is in wrong namespace

# Check CA certificate in cert-manager namespace
kubectl describe certificate -n cert-manager es-ca

# Common errors:
#   "secrets 'es-ca-secret' not found" → CA cert in wrong namespace (see Issue #1)
#   "issuer not found" → ClusterIssuer not created before Certificate
#   "timeout waiting for condition" → cert-manager pod not ready
```

---

## Issues Encountered and Fixed During Deployment

### Issue 1: CA Secret Namespace Mismatch (ClusterIssuer)

**Problem:** The `es-ca-issuer` ClusterIssuer failed with `ErrGetKeyPair: secrets "es-ca-secret" not found`. For `ClusterIssuer` with `ca` type, the referenced secret must be in the **same namespace as cert-manager** (`cert-manager`), not in the consuming namespace (`elk`).

**Root Cause:** The original design had all certificates in the `elk` namespace. But `es-ca-issuer` is a `ClusterIssuer` — when it references `ca.secretName: es-ca-secret`, cert-manager's controller (running in `cert-manager` namespace) looks for the secret in its own namespace, not in `elk`.

**Debugging:**
```bash
kubectl describe clusterissuer es-ca-issuer
# → Message: Error getting keypair for CA issuer: secrets "es-ca-secret" not found
kubectl get secret es-ca-secret -n elk         # exists
kubectl get secret es-ca-secret -n cert-manager # doesn't exist
```

**Fix:** Split the CA certificate creation into a separate file (`ca-certificate.yaml`) with namespace `cert-manager`:
- `cluster-issuer.yaml` — only the two ClusterIssuers (`selfsigned-issuer`, `es-ca-issuer`)
- `ca-certificate.yaml` — the `es-ca` Certificate in namespace `cert-manager`

**Verification:**
```bash
kubectl get certificates -A
# NAMESPACE      NAME     READY   SECRET          AGE
# cert-manager   es-ca    True    es-ca-secret    ...
# elk            es-node  True    elastic-certs   ...

kubectl describe clusterissuer es-ca-issuer | grep -E "Message:|Reason:|Status:"
# → Message: Signing CA verified
# → Status: True
```

---

### Issue 2: Vault Kubernetes Auth Login Failure

**Problem:** The `configure-vault` job succeeded, but ESO's ClusterSecretStore showed `StoreValidationFailed: error calling Vault server: Error making API request`. Two root causes:
1. The `token_reviewer_jwt` was manually set, but Vault should use its own SA JWT instead
2. DNS name `kubernetes.default.svc` (3 dots) doesn't resolve with `ndots:5` — needs the full `kubernetes.default.svc.cluster.local`

**Root Cause 1:** Setting `disable_local_ca_jwt=false` tells Vault to read its own pod's SA token from `/var/run/secrets/kubernetes.io/serviceaccount/token`. This token has the `system:auth-delegator` ClusterRole, so it can call TokenReview. When `disable_local_ca_jwt=true`, you must provide a `token_reviewer_jwt` explicitly — if that token expires or doesn't have the right permissions, auth fails.

**Root Cause 2:** Vault's DNS resolver uses `ndots:5` (from `/etc/resolv.conf`). A DNS name with fewer than 5 dots (e.g. `kubernetes.default.svc` has 3 dots) is tried first with the search domains appended (e.g. `kubernetes.default.svc.elk.svc.cluster.local`), which may not resolve. With 5 dots (`kubernetes.default.svc.cluster.local`), it's tried as an absolute name first.

**Debugging:**
```bash
kubectl exec vault-0 -n elk -- vault read auth/kubernetes/config
# → token_reviewer_jwt_set: true (should be false to use own SA)

kubectl exec vault-0 -n elk -- nslookup kubernetes.default.svc
# → NXDOMAIN (fails because fewer than 5 dots with ndots:5)

kubectl exec vault-0 -n elk -- nslookup kubernetes.default.svc.cluster.local
# → resolves to 10.96.0.1 (success)

# Manual auth test:
JWT=$(kubectl create token external-secrets -n external-secrets --duration=1h)
kubectl exec vault-0 -n elk -- vault write auth/kubernetes/login role=external-secrets jwt="$JWT"
# Before fix → permission denied
# After fix  → returns client_token
```

**Fix:**
- Set `disable_local_ca_jwt=false` in the Vault k8s auth config (so Vault uses its own SA JWT)
- Use `kubernetes_host=https://kubernetes.default.svc.cluster.local:443` (full DNS with 5 dots)
- Removed explicit `token_reviewer_jwt` and `kubernetes_ca_cert` from the config

**Verification:**
```bash
kubectl describe clustersecretstore vault-backend
# → Message: store validated, Status: True

kubectl get secret elastic-credentials -n elk
# → synced from Vault (exists with the correct keys)
```

---

### Issue 3: ESO CRD API Version Mismatch

**Problem:** External Secrets Operator v2.6.0 uses `external-secrets.io/v1` (not `v1beta1`). Applying `SecretStore` and `ExternalSecret` with `apiVersion: v1beta1` gave `no matches for kind "ClusterSecretStore"`.

**Debugging:**
```bash
kubectl apply -f external-secrets/secret-store.yaml
# → error: no matches for kind "ClusterSecretStore" in version "external-secrets.io/v1beta1"

kubectl api-resources | grep externalsecret
# → externalsecrets     es           external-secrets.io/v1           true
# Note: v1beta1 was removed in favor of v1
```

**Fix:** Updated both files from `v1beta1` to `v1`:
- `external-secrets/secret-store.yaml`: `apiVersion: external-secrets.io/v1`
- `external-secrets/external-secret.yaml`: `apiVersion: external-secrets.io/v1`

**Verification:**
```bash
kubectl apply -f external-secrets/secret-store.yaml
kubectl apply -f external-secrets/external-secret.yaml
# → Both created successfully
kubectl get clustersecretstores
# → vault-backend   Valid   ValidClusterSecretStore
```

---

### Issue 4: Longhorn Requires open-iscsi on Host

**Problem:** Longhorn managers crashed with `failed to execute: iscsiadm: No such file or directory`. Minikube nodes (Docker/Podman driver) don't have `open-iscsi` installed, and `sudo` requires a password (can't be scripted).

**Debugging:**
```bash
kubectl get pods -n longhorn-system
# → longhorn-manager-*  CrashLoopBackOff
kubectl logs -n longhorn-system longhorn-manager-* | grep iscsiadm
# → failed to execute: iscsiadm: No such file or directory
```

**Fix:** Replaced Longhorn with **OpenEBS LocalPV**. OpenEBS LocalPV uses hostPath (no kernel modules, no iSCSI). It's just a directory on the node: `/var/openebs/local/<pv-name>/`. Zero dependencies.

**Key differences:**
| Feature | Longhorn | OpenEBS LocalPV |
|---------|----------|-----------------|
| Storage type | Replicated block storage (3 copies) | Local hostPath (1 copy) |
| Kernel deps | Requires open-iscsi | None |
| RAM usage | ~200-500 Mi per node | ~15 Mi per cluster |
| Data safety | Replicated (survives node loss) | Single copy (lost if node fails) |
| Setup complexity | High (requires iscsiadm + sudo) | Zero (just helm install) |

**Verification:**
```bash
kubectl get pods -n openebs
# → openebs-localpv-provisioner   Running
kubectl get sc openebs-hostpath
# → NAME               PROVISIONER          BINDINGMODE
# → openebs-hostpath   openebs.io/local     WaitForFirstConsumer
```

---

### Issue 5: Ingest Node OOMKilled

**Problem:** ES ingest node was OOMKilled with only 768Mi memory limit. The `-XX:+AlwaysPreTouch` flag (baked into the ES Docker image) pre-commits all heap pages at startup, using significant RSS. With 192m heap + AlwaysPreTouch, the node used ~350m RSS before any real work started. Under load, it ran out of memory.

**Debugging:**
```bash
kubectl describe pod es-ingest-0 -n elk | grep -E "State:|Reason:"
# → State: Terminated, Reason: OOMKilled, Exit Code: 137

kubectl logs es-ingest-0 -n elk | grep -o '"message":"[^"]*"' | tail -5
# → Contains "[gc] overhead, spent [1.4s] collecting in the last [2.6s]"
# → Node is spending 54% of its time in garbage collection
```

**Fix:**
- Removed `AlwaysPreTouch` from ingest node's JVM options (kept it on master-data where it's beneficial)
- Actually, the deeper issue was the 192m heap being too small for ES 8.17. Even without AlwaysPreTouch, the node spent >50% time in GC. The fix was increasing heap to 384m.

**Verification:**
```bash
kubectl logs es-ingest-0 -n elk | grep heap
# → heap size [384mb]
kubectl describe pod es-ingest-0 -n elk | grep -A2 "State:"
# → State: Running (not Terminated)

# Check for GC warnings:
kubectl logs es-ingest-0 -n elk | grep "gc.*overhead" | tail -3
# → Should be infrequent or absent with 384m heap
```

---

### Issue 6: Readiness Probe Timeout

**Problem:** The default `timeoutSeconds` for readiness probes is 1 second, which is too short for curl with TLS handshake on constrained resources. The `initialDelaySeconds` of 15s was also insufficient — ES takes 2-3 minutes to start with minimal heap.

**Debugging:**
```bash
kubectl describe pod es-master-data-0 -n elk | grep -A5 "Readiness"
# → With defaults: timeoutSeconds=1, initialDelaySeconds=15, periodSeconds=5
# → Pod was restarting because probe kept failing within 1s timeout

# Simulate the probe timing:
kubectl exec -n elk es-master-data-0 -- time curl -sk https://localhost:9200 -o /dev/null
# → real 0m3.2s (TLS handshake alone took >3 seconds on cold start)
```

**Fix:** Updated both StatefulSets:
- `initialDelaySeconds: 30` (from 15) — wait 30s before first probe
- `timeoutSeconds: 5` (from default 1) — give curl 5s for TLS handshake
- `periodSeconds: 10` (from 5) — check every 10s instead of every 5s
- `failureThreshold: 30` — allow 30 failures (30 × 10s = 300s = 5 minutes) before marking pod Unready

**Verification:**
```bash
kubectl describe pod es-master-data-0 -n elk | grep -A10 "Readiness"
# → Shows the updated values: 30s initial, 5s timeout, 10s period
# → Pod stays Running (not restarting)
```

---

### Issue 7: Force-Deleted Pod StatefulSet Reconciliation

**Problem:** Force-deleting a StatefulSet pod (`--force --grace-period=0`) can leave the old pod in `Terminating` state and prevent the new pod from starting. Also, `kubectl apply` after force-delete may not trigger a new pod creation if the template is unchanged.

**Root Cause:** StatefulSet guarantees "at most one pod with a given identity". If the old `es-ingest-0` is still in `Terminating` state (stuck on some finalizer), the StatefulSet controller won't create a new `es-ingest-0`. Force-deleting bypasses the graceful shutdown, and the old pod's volumes might still be mounted.

**Fix:** After force-deleting, always `kubectl apply` the updated manifest. The StatefulSet controller will detect the change and create a new pod. If the old pod is stuck in `Terminating`, delete it with:
```bash
kubectl delete pod es-ingest-0 -n elk --force --grace-period=0 --wait=true
# Then re-apply:
kubectl apply -f elasticsearch/ingest-statefulset.yaml
```

**Prevention:** Prefer `kubectl delete pod <name> -n elk --wait=true` (graceful) over `--force`. Re-apply the manifest after any StatefulSet pod deletion.

**Verification:**
```bash
kubectl get pods -n elk -o wide | grep es-ingest
# → es-ingest-0 is Running, AGE shows it was recreated
```

---

### Issue 8: Ingest Node GC Thrashing (Heap Too Small)

**Problem:** ES 8.17 ingest node with 192m heap spent >50% of time in garbage collection. The node started, joined the cluster, but never became Ready because GC thrashing prevented it from responding to the readiness probe (HTTP requests timed out).

**Debugging:**
```bash
kubectl logs es-ingest-0 -n elk | grep "gc.*overhead"
# → [gc][17] overhead, spent [604ms] collecting in the last [1s]  (60% GC time)
# → [gc][19] overhead, spent [1.3s] collecting in the last [1.6s] (81% GC time)

kubectl logs es-ingest-0 -n elk | grep "heap size"
# → heap size [192mb]

# Compare with master-data (256m heap, no GC issues):
kubectl logs es-master-data-0 -n elk | grep "gc.*overhead"
# → No GC overhead warnings
```

**Root Cause:** Elasticsearch 8.17 loads 170+ plugins by default. Even with many disabled (ml, watcher, monitoring, profiling), the remaining plugins consume significant heap. 192m is insufficient for the JVM + ES core + plugins + ingest pipelines. ES 8.x minimum recommended heap is 256m (master-data) and 384m (ingest).

**Fix:**
- Increased ingest heap from `-Xms192m -Xmx192m` to `-Xms384m -Xmx384m`
- Removed `-XX:+AlwaysPreTouch` — with 384m heap, pre-committing only adds unnecessary RSS pressure
- Increased pod memory limit from 768Mi to 1Gi

**Verification:**
```bash
kubectl logs es-ingest-0 -n elk | grep "heap size"
# → heap size [384mb]

kubectl logs es-ingest-0 -n elk | grep "gc.*overhead" | tail -3
# → Infrequent or absent (no more GC thrashing)

kubectl get pods -n elk | grep es-ingest
# → es-ingest-0   Running (not CrashLoopBackOff)
```

---

### Issue 9: Kibana OOM (JavaScript Heap Out of Memory)

**Problem:** Kibana crashed with `FATAL ERROR: Ineffective mark-compacts near heap limit Allocation failed - JavaScript heap out of memory`. The Node.js process running Kibana 8.17 with 170+ plugins exhausted the available memory.

**Debugging:**
```bash
kubectl describe pod kibana-... -n elk | grep -E "State:|Reason:|Exit Code:"
# → State: Terminated, Reason: Error, Exit Code: 134 (SIGABRT)

kubectl logs deployment/kibana -n elk | grep -A5 "FATAL ERROR"
# → FATAL ERROR: Ineffective mark-compacts near heap limit Allocation failed
# → JavaScript heap out of memory
```

**Root Cause:** Kibana runs on Node.js 20.15.1. With 512Mi memory limit, the V8 engine's max heap size is approximately 384Mi (Node.js overhead + V8 heap overhead). Kibana 8.17 loads 170+ plugins at startup, each consuming memory for:
- Plugin code (JavaScript modules)
- Saved objects (index patterns, dashboards)
- Task manager queues
- HTTP server connections
- APM agent (monitoring)

The total exceeds 384Mi, causing the V8 garbage collector to run continuously until heap exhaustion.

**Fix:**
- Increased Kibana memory limit from 512Mi to 1Gi
- Increased request from 256Mi to 512Mi

**Verification:**
```bash
kubectl describe deployment kibana -n elk | grep -A2 "Limits"
# → memory: 1Gi

kubectl logs deployment/kibana -n elk | grep "FATAL ERROR"
# → No output (no more OOM)

curl -s -o /dev/null -w "%{http_code}" http://localhost:5601
# → 302 (Kibana is running and redirecting to login)
```

---

### Issue 10: Minikube Service Tunnel Requires Foreground Process

**Problem:** `minikube service kibana -n elk --url` starts a tunnel that only works while the command is running in the foreground. The URL (`http://127.0.0.1:54660`) changes each time the tunnel restarts.

**Root Cause:** When using Docker/Podman drivers on macOS, minikube runs inside a VM. Services are not directly accessible on the host's network. The `minikube service` command opens a tunnel from the host to the VM, but it's a temporary SSH-like tunnel that must stay running.

**Fix:** Documented `kubectl port-forward` as the primary access method:
```bash
kubectl port-forward -n elk svc/kibana 5601:5601
# Port 5601 is the standard Kibana port (no random port guessing)
```

**Verification:**
```bash
kubectl port-forward -n elk svc/kibana 5601:5601 &
sleep 2
curl -s -o /dev/null -w "%{http_code}" http://localhost:5601
# → 302 (Kibana accessible)
```

---

## Files Reference

| File | Purpose | Applied By |
|------|---------|------------|
| `namespace.yaml` | Creates `elk` namespace for all Elastic Stack resources | Phase 1 (kubectl) |
| `cert-manager/cluster-issuer.yaml` | Self-signed ClusterIssuer + CA-based ClusterIssuer | Phase 4a (kubectl) |
| `cert-manager/ca-certificate.yaml` | CA Certificate in cert-manager namespace (bootstraps trust) | Phase 4b (kubectl) |
| `cert-manager/certificate.yaml` | Elasticsearch node Certificate with multi-SAN DNS | Phase 4c (kubectl) |
| `vault/vault-values.yaml` | Helm values for Vault dev mode (minimal resources, auto-unsealed) | Phase 5 (helm) |
| `vault/configure-vault-job.yaml` | Job: enable KV, store secrets, configure k8s auth, create ESO policy | Phase 6 (kubectl) |
| `external-secrets/secret-store.yaml` | ClusterSecretStore pointing to Vault with k8s auth | Phase 8 (kubectl) |
| `external-secrets/external-secret.yaml` | ExternalSecret syncing Vault paths to k8s Secret | Phase 8 (kubectl) |
| `elasticsearch/configmap.yaml` | cluster.name for all ES nodes | Phase 9 (kubectl) |
| `elasticsearch/headless-service.yaml` | 3 headless services: es-master-data, es-ingest, elasticsearch | Phase 9 (kubectl) |
| `elasticsearch/master-data-statefulset.yaml` | StatefulSet (roles: master, data), OpenEBS PVC, cert-manager TLS | Phase 10 (kubectl) |
| `elasticsearch/ingest-statefulset.yaml` | StatefulSet (roles: ingest), OpenEBS PVC, cert-manager TLS | Phase 11 (kubectl) |
| `kibana/deployment.yaml` | Kibana Deployment with cert-manager CA + ESO credentials | Phase 14 (kubectl) |
| `kibana/service.yaml` | NodePort service for Kibana | Phase 14 (kubectl) |
| `openebs/values.yaml` | Helm values (LocalPV only, no NDM, minimal resources) | Phase 2 (helm) |
| `set-kibana-password-job.yaml` | Job: set kibana_system password via ES Security API | Phase 13 (kubectl) |
| `deploy.sh` | Orchestrates all 14 phases | — |
| `uninstall.sh` | Reverses every phase in safe order | — |
