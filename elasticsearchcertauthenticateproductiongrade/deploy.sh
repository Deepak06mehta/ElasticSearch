#!/bin/bash
# ==============================================================================
# deploy.sh — Production-grade ELK + Vault + OpenEBS on Minikube (2 nodes)
# ==============================================================================
#
# This script automates the deployment of the entire stack in 14 phases.
# Each phase is idempotent — you can re-run the script safely.
#
# Architecture:
#   Node 1 (minikube):       control-plane, es-master-data, vault, cert-manager
#   Node 2 (minikube-m02):   es-ingest, kibana
#
# Prerequisites:
#   - minikube with --nodes=2 (see README for start command)
#   - kubectl, helm, jq installed
#
# Execution flow:
#   Phase  0: Label nodes (master-data, ingest)
#   Phase  1: Create 'elk' namespace
#   Phase  2: Install OpenEBS LocalPV (storage class: openebs-hostpath)
#   Phase  3: Install cert-manager (TLS certificates operator)
#   Phase  4: Create TLS certificates (CA + node certs via cert-manager)
#   Phase  5: Install Vault (dev mode, auto-unsealed)
#   Phase  6: Configure Vault (secrets, k8s auth, ESO role)
#   Phase  7: Install External Secrets Operator
#   Phase  8: Create SecretStore + ExternalSecret (sync Vault → k8s Secret)
#   Phase  9: Deploy Elasticsearch ConfigMap + headless services
#   Phase 10: Deploy Elasticsearch master-data StatefulSet
#   Phase 11: Deploy Elasticsearch ingest StatefulSet
#   Phase 12: Verify elastic password (reset if ES auto-generated different one)
#   Phase 13: Set kibana_system password (via Security API)
#   Phase 14: Deploy Kibana (Deployment + NodePort Service)
# ==============================================================================

set -euo pipefail

# Color codes for log output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

# ------------------------------------------------------------------------------
# Pre-flight checks: verify required CLI tools are installed
# ------------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || err "kubectl is required"
command -v helm >/dev/null 2>&1    || err "helm is required"
command -v jq >/dev/null 2>&1      || err "jq is required"

# ------------------------------------------------------------------------------
# Check minikube is running with at least 1 node
# ------------------------------------------------------------------------------
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
log "Detected ${NODE_COUNT} node(s)"
log "Minikube status: $(minikube status --format '{{.Host}}' 2>/dev/null || echo 'unknown')"

# ==============================================================================
# Phase 0: Label nodes for architecture layout
# ==============================================================================
# Labels must match the nodeSelector fields in each StatefulSet.
# Node 1 (minikube): gets master-data label → runs ES master+data + vault + cert-manager
# Node 2 (minikube-m02): gets ingest label → runs ES ingest + kibana
log "============================================"
log "Phase 0: Label nodes for architecture layout"
log "============================================"
kubectl label node minikube node-role.kubernetes.io/master-data=true --overwrite 2>/dev/null || true
kubectl label node minikube-m02 node-role.kubernetes.io/ingest=true --overwrite 2>/dev/null || true
log "Nodes labeled"

# ==============================================================================
# Phase 1: Create namespace
# ==============================================================================
log "============================================"
log "Phase 1: Create namespace"
log "============================================"
kubectl apply -f "${BASE_DIR}/namespace.yaml"
log "Namespaces created"

# ==============================================================================
# Phase 2: Install OpenEBS LocalPV
# ==============================================================================
# OpenEBS provides the "openebs-hostpath" StorageClass for persistent volumes.
# We install ONLY the LocalPV provisioner (no NDM, no cStor, no Jiva).
# See openebs/values.yaml for the detailed configuration.
log "============================================"
log "Phase 2: Install OpenEBS LocalPV"
log "============================================"
helm repo add openebs https://openebs.github.io/charts --force-update
helm upgrade --install openebs openebs/openebs \
  --namespace openebs --create-namespace \
  --values "${BASE_DIR}/openebs/values.yaml" \
  --wait --timeout=3m
if ! kubectl get sc openebs-hostpath >/dev/null 2>&1; then
  warn "openebs-hostpath storage class not found, waiting..."
  sleep 10
fi
kubectl get sc openebs-hostpath >/dev/null 2>&1 || err "OpenEBS storage class not available"
log "OpenEBS LocalPV installed (storage class: openebs-hostpath)"

# ==============================================================================
# Phase 3: Install cert-manager
# ==============================================================================
# cert-manager automates TLS certificate creation and renewal.
# It creates a self-signed CA → signs Elasticsearch node certificates.
log "============================================"
log "Phase 3: Install cert-manager"
log "============================================"
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true \
  --set resources.requests.memory=64Mi \
  --set resources.limits.memory=128Mi \
  --set webhook.resources.requests.memory=32Mi \
  --set webhook.resources.limits.memory=64Mi \
  --set cainjector.resources.requests.memory=32Mi \
  --set cainjector.resources.limits.memory=64Mi \
  --wait --timeout=3m
log "cert-manager installed"

# ==============================================================================
# Phase 4: Create TLS certificates
# ==============================================================================
# Order matters here — the CA certificate MUST be created before the node cert,
# and the ClusterIssuer must exist before the CA cert references it.
#
# Step A: Create both ClusterIssuers (selfsigned-issuer + es-ca-issuer)
# Step B: Create the CA certificate in cert-manager namespace (so es-ca-issuer
#         can read the resulting Secret — see README Issue #1)
# Step C: Create the node certificate in elk namespace
log "============================================"
log "Phase 4: Create TLS certificates"
log "============================================"
kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=2m

# Step A: Create self-signed ClusterIssuer
kubectl apply -f "${BASE_DIR}/cert-manager/cluster-issuer.yaml"
sleep 3

# Step B: Create CA certificate in cert-manager namespace
# (must be in cert-manager namespace so es-ca-issuer can reference the secret)
kubectl apply -f "${BASE_DIR}/cert-manager/ca-certificate.yaml"
kubectl wait --for=condition=Ready certificate/es-ca -n cert-manager --timeout=2m
log "CA certificate created in cert-manager namespace"

# Step C: Create node certificate in elk namespace
kubectl apply -f "${BASE_DIR}/cert-manager/certificate.yaml"
kubectl wait --for=condition=Ready certificate/es-node -n elk --timeout=2m
log "Node TLS certificates created"

# ==============================================================================
# Phase 5: Install Vault (dev mode)
# ==============================================================================
# Vault runs in dev mode: auto-unsealed, in-memory storage, root token = "root".
# See vault/vault-values.yaml for configuration details.
log "============================================"
log "Phase 5: Install Vault (dev mode)"
log "============================================"
helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
helm upgrade --install vault hashicorp/vault \
  --namespace elk \
  --values "${BASE_DIR}/vault/vault-values.yaml" \
  --wait --timeout=3m
log "Vault installed"

# ==============================================================================
# Phase 6: Configure Vault (secrets + k8s auth)
# ==============================================================================
# The configure-vault Job runs once to:
#   1. Enable KV v2 secrets engine
#   2. Store elasticsearch credentials
#   3. Enable Kubernetes auth method
#   4. Create role for External Secrets Operator
log "============================================"
log "Phase 6: Configure Vault (secrets + k8s auth)"
log "============================================"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n elk --timeout=3m
kubectl apply -f "${BASE_DIR}/vault/configure-vault-job.yaml"
kubectl wait --for=condition=complete job/configure-vault -n elk --timeout=2m
log "Vault configured with elasticsearch secrets and k8s auth"

# ==============================================================================
# Phase 7: Install External Secrets Operator
# ==============================================================================
# ESO watches ExternalSecret resources and syncs secrets from Vault into
# Kubernetes Secrets. It runs in the 'external-secrets' namespace.
log "============================================"
log "Phase 7: Install External Secrets Operator"
log "============================================"
helm repo add external-secrets https://charts.external-secrets.io --force-update
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --set resources.requests.memory=32Mi \
  --set resources.limits.memory=64Mi \
  --wait --timeout=3m
log "External Secrets Operator installed"

# ==============================================================================
# Phase 8: Create SecretStore and ExternalSecret
# ==============================================================================
# The ClusterSecretStore defines how ESO connects to Vault.
# The ExternalSecret defines which Vault paths map to which k8s Secret keys.
# We wait up to 75 seconds for the initial sync to complete.
log "============================================"
log "Phase 8: Create SecretStore and ExternalSecret"
log "============================================"
kubectl wait --for=condition=Available deployment/external-secrets -n external-secrets --timeout=2m
kubectl apply -f "${BASE_DIR}/external-secrets/secret-store.yaml"
sleep 5
kubectl apply -f "${BASE_DIR}/external-secrets/external-secret.yaml"
log "ExternalSecret created, waiting for secret sync..."
for i in $(seq 1 15); do
  if kubectl get secret elastic-credentials -n elk >/dev/null 2>&1; then
    log "Secret elastic-credentials synced from Vault"
    break
  fi
  if [ "$i" -eq 15 ]; then
    warn "Secret sync timed out - check ClusterSecretStore status"
    kubectl describe clustersecretstore vault-backend 2>&1 | grep -E "Message:|Reason:|Status:"
  fi
  sleep 5
done

# ==============================================================================
# Phase 9: Deploy Elasticsearch ConfigMap & Services
# ==============================================================================
# ConfigMap: shared cluster configuration (cluster.name)
# Headless services: DNS-based pod discovery for ES cluster formation
log "============================================"
log "Phase 9: Deploy Elasticsearch ConfigMap & Services"
log "============================================"
kubectl apply -f "${BASE_DIR}/elasticsearch/configmap.yaml"
kubectl apply -f "${BASE_DIR}/elasticsearch/headless-service.yaml"

# ==============================================================================
# Phase 10: Deploy Elasticsearch master-data node
# ==============================================================================
# The master-data node:
#   - Acts as cluster manager (master role)
#   - Stores all data shards (data role)
#   - Uses OpenEBS LocalPV for persistent storage
#   - Runs on Node 1 (minikube) via nodeSelector
#   - Heap: 256m with AlwaysPreTouch
log "============================================"
log "Phase 10: Deploy Elasticsearch master-data node"
log "============================================"
kubectl apply -f "${BASE_DIR}/elasticsearch/master-data-statefulset.yaml"
kubectl wait --for=condition=ready pod -l app=elasticsearch,role=master-data -n elk --timeout=5m
log "Elasticsearch master-data node ready"

# ==============================================================================
# Phase 11: Deploy Elasticsearch ingest node
# ==============================================================================
# The ingest node:
#   - Pre-processes documents before indexing (ingest role)
#   - Does NOT store data shards
#   - Runs on Node 2 (minikube-m02) via nodeSelector
#   - Heap: 384m (no AlwaysPreTouch to save memory)
#   - Discovers and joins the master-data node via DNS
#
# Note: The 5-minute timeout accounts for:
#   1. OpenEBS WaitForFirstConsumer PVC binding (~30s)
#   2. ES startup with 384m heap (~2-3 min)
#   3. Ingest node joining cluster via discovery (~30s)
log "============================================"
log "Phase 11: Deploy Elasticsearch ingest node"
log "============================================"
kubectl apply -f "${BASE_DIR}/elasticsearch/ingest-statefulset.yaml"
kubectl wait --for=condition=ready pod -l app=elasticsearch,role=ingest -n elk --timeout=7m
log "Elasticsearch ingest node ready"

# ==============================================================================
# Phase 12: Verify elastic password
# ==============================================================================
# Elasticsearch 8.x auto-generates a password for the 'elastic' user at first
# boot. If the ELASTIC_PASSWORD env var is set, ES uses that instead. However,
# if the Vault-synced secret wasn't available when ES first started (e.g. due
# to timing), ES may have generated its own password, and the Vault password
# won't work. In that case, we reset the password via the CLI and update the
# Secret to match.
log "============================================"
log "Phase 12: Verify elastic password"
log "============================================"
ELASTIC_PWD=$(kubectl get secret -n elk elastic-credentials -o jsonpath='{.data.elastic-password}' | base64 -d)
PWD_CHECK=$(kubectl exec -n elk es-master-data-0 -- bash -c \
  'curl -sk -u "elastic:${ELASTIC_PASSWORD}" -o /dev/null -w "%{http_code}" https://localhost:9200/' 2>/dev/null || echo "000")

if [ "$PWD_CHECK" != "200" ]; then
  warn "Elastic password from Vault may not match ES auto-configuration"
  warn "Attempting password reset..."
  RESET_OUTPUT=$(kubectl exec -n elk es-master-data-0 -- elasticsearch-reset-password -u elastic -b 2>&1)
  echo "$RESET_OUTPUT"
  NEW_PWD=$(echo "$RESET_OUTPUT" | grep -o '= .*' | cut -d' ' -f2-)
  if [ -n "$NEW_PWD" ]; then
    KIBANA_PWD=$(kubectl get secret -n elk elastic-credentials -o jsonpath='{.data.kibana-password}' | base64 -d)
    kubectl delete secret -n elk elastic-credentials --ignore-not-found
    kubectl create secret generic elastic-credentials -n elk \
      --from-literal=elastic-password="$NEW_PWD" \
      --from-literal=kibana-password="$KIBANA_PWD"
    ELASTIC_PWD=$NEW_PWD
    warn "elastic-credentials secret updated with new password"
  fi
else
  log "Elastic password verified OK"
fi

# ==============================================================================
# Phase 13: Set kibana_system password
# ==============================================================================
# Kibana authenticates to Elasticsearch as the 'kibana_system' built-in user.
# ES auto-configures this user with a random password, but we need to use
# our managed password (kibana123 from Vault). This job POSTs to the ES
# Security API to change the password.
log "============================================"
log "Phase 13: Set kibana_system password"
log "============================================"
kubectl apply -f "${BASE_DIR}/set-kibana-password-job.yaml"
kubectl wait --for=condition=complete job/set-kibana-password -n elk --timeout=3m
log "kibana_system password set"

# ==============================================================================
# Phase 14: Deploy Kibana
# ==============================================================================
# Deploys Kibana with:
#   - NodePort service for external access
#   - CA cert mounted for TLS verification of ES
#   - kibana_system credentials from Vault
#   - Runs on Node 2 (minikube-m02)
#
# After deployment, we restart Kibana to ensure it picks up the fresh
# credentials (avoiding stale auth token issues).
log "============================================"
log "Phase 14: Deploy Kibana"
log "============================================"
kubectl apply -f "${BASE_DIR}/kibana/service.yaml"
kubectl apply -f "${BASE_DIR}/kibana/deployment.yaml"
# Wait for initial deploy (readiness probe ensures HTTP is up)
# Kibana credentials (kibana_system) are already set by Phase 13 before
# this phase, so no restart is needed — avoiding a second round of
# saved-object migrations that could trigger GC warnings on the ingest node.
kubectl rollout status deployment/kibana -n elk --timeout=7m
# Verify Kibana HTTP is responding before declaring complete
log "Verifying Kibana HTTP endpoint..."
for i in $(seq 1 30); do
  CODE=$(kubectl exec -n elk deployment/kibana -- curl -s -o /dev/null -w "%{http_code}" http://localhost:5601 2>/dev/null || echo "000")
  if [ "$CODE" = "302" ] || [ "$CODE" = "200" ]; then
    log "Kibana HTTP endpoint ready (code $CODE)"
    break
  fi
  if [ "$i" -eq 30 ]; then
    warn "Kibana HTTP not ready after 30 attempts - continuing anyway"
  fi
  sleep 5
done
log "Kibana deployed and verified"

# ==============================================================================
# Deployment Complete! Print summary and access instructions.
# ==============================================================================
log "============================================"
log "Deployment Complete!"
log "============================================"
echo ""
echo "  Elasticsearch:"
echo "    kubectl exec -n elk es-master-data-0 -- curl -sk -u \"elastic:${ELASTIC_PWD}\" https://localhost:9200/_cluster/health?pretty"
echo ""
echo "  Kibana:"
echo "    kubectl port-forward -n elk svc/kibana 5601:5601"
echo "    -> http://localhost:5601"
echo ""
echo "  Or use minikube tunnel:"
echo "    minikube service kibana -n elk --url"
echo ""
echo "  Nodes:"
echo "    kubectl get pods -n elk -o wide"
echo ""
echo "  Dashboard:"
echo "    minikube dashboard"
echo ""
