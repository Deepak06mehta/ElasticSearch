#!/bin/bash
set -euo pipefail

# ==============================================================================
# uninstall.sh — Removes EVERYTHING deployed by deploy.sh
#
# Order matters: remove resources that depend on operators before removing
# the operators themselves. Otherwise CRD finalizers can hang forever.
# ==============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

log "Starting uninstall..."

# Phase 1: Remove Elasticsearch resources (before removing storage)
log "Removing Elasticsearch StatefulSets..."
kubectl delete statefulset es-master-data -n elk --ignore-not-found --wait=true --timeout=2m 2>/dev/null || true
kubectl delete statefulset es-ingest -n elk --ignore-not-found --wait=true --timeout=2m 2>/dev/null || true

log "Removing Elasticsearch PVCs..."
kubectl delete pvc -l app=elasticsearch -n elk --ignore-not-found --wait=true --timeout=2m 2>/dev/null || true

log "Remaining PVCs in elk namespace (if any):"
kubectl get pvc -n elk 2>/dev/null || true

# Phase 2: Remove Kibana
log "Removing Kibana..."
kubectl delete deployment kibana -n elk --ignore-not-found --wait=true --timeout=2m 2>/dev/null || true
kubectl delete service kibana -n elk --ignore-not-found 2>/dev/null || true

# Phase 3: Remove jobs
log "Removing jobs..."
kubectl delete job set-kibana-password -n elk --ignore-not-found 2>/dev/null || true
kubectl delete job configure-vault -n elk --ignore-not-found 2>/dev/null || true

# Phase 4: Remove ExternalSecret (before removing ESO operator)
log "Removing ExternalSecret and SecretStore..."
kubectl delete externalsecret elastic-credentials -n elk --ignore-not-found 2>/dev/null || true
kubectl delete clustersecretstore vault-backend --ignore-not-found 2>/dev/null || true

# Phase 5: Remove cert-manager resources
log "Removing cert-manager resources..."
kubectl delete certificate es-node -n elk --ignore-not-found 2>/dev/null || true
kubectl delete certificate es-ca -n elk --ignore-not-found 2>/dev/null || true
kubectl delete clusterissuer es-ca-issuer --ignore-not-found 2>/dev/null || true
kubectl delete clusterissuer selfsigned-issuer --ignore-not-found 2>/dev/null || true

# Phase 6: Remove remaining elk resources
log "Removing Services and ConfigMaps in elk namespace..."
kubectl delete service es-master-data -n elk --ignore-not-found 2>/dev/null || true
kubectl delete service es-ingest -n elk --ignore-not-found 2>/dev/null || true
kubectl delete service elasticsearch -n elk --ignore-not-found 2>/dev/null || true
kubectl delete configmap elasticsearch-config -n elk --ignore-not-found 2>/dev/null || true
kubectl delete secret elastic-certs -n elk --ignore-not-found 2>/dev/null || true
kubectl delete secret elastic-credentials -n elk --ignore-not-found 2>/dev/null || true
kubectl delete serviceaccount vault-config -n elk --ignore-not-found 2>/dev/null || true
kubectl delete clusterrolebinding vault-config --ignore-not-found 2>/dev/null || true

# Phase 7: Remove Longhorn (helm uninstall)
log "Removing Longhorn..."
helm uninstall longhorn -n longhorn-system --ignore-not-found --wait --timeout=3m 2>/dev/null || true
log "Removing Longhorn CRDs and namespace..."
kubectl delete namespace longhorn-system --ignore-not-found --wait=true --timeout=2m 2>/dev/null || true

# Wait for Longhorn CRDs to be fully cleaned up
warn "Waiting 15s for Longhorn CRD cleanup..."
sleep 15

# Phase 8: Remove External Secrets Operator
log "Removing External Secrets Operator..."
helm uninstall external-secrets -n external-secrets --ignore-not-found --wait --timeout=2m 2>/dev/null || true
kubectl delete namespace external-secrets --ignore-not-found --wait=true --timeout=2m 2>/dev/null || true

# Phase 9: Remove Vault
log "Removing Vault..."
helm uninstall vault -n elk --ignore-not-found --wait --timeout=2m 2>/dev/null || true

# Phase 10: Remove cert-manager
log "Removing cert-manager..."
helm uninstall cert-manager -n cert-manager --ignore-not-found --wait --timeout=2m 2>/dev/null || true
kubectl delete namespace cert-manager --ignore-not-found --wait=true --timeout=2m 2>/dev/null || true

# Phase 11: Remove namespace
log "Removing elk namespace..."
kubectl delete namespace elk --ignore-not-found --wait=true --timeout=2m 2>/dev/null || true

# Phase 12: Remove node labels
log "Cleaning up node labels..."
kubectl label node minikube node-role.kubernetes.io/master-data- 2>/dev/null || true
kubectl label node minikube-m02 node-role.kubernetes.io/ingest- 2>/dev/null || true

log "Uninstall complete."
log "To reset minikube entirely: minikube delete --all --purge"
