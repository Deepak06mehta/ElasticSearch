#!/bin/bash
set -euo pipefail

# ==============================================================================
# deploy.sh — Production-grade ELK + Vault + Longhorn on Minikube (2 nodes)
#
# Architecture:
#   Node 1 (minikube): control-plane, es-master-data, vault, cert-manager
#   Node 2 (minikube-m02): es-ingest, kibana, longhorn
#
# Prerequisites:
#   - minikube with --nodes=2 (see README for start command)
#   - kubectl, helm, jq installed
# ==============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

# Verify tools
command -v kubectl >/dev/null 2>&1 || err "kubectl is required"
command -v helm >/dev/null 2>&1 || err "helm is required"
command -v jq >/dev/null 2>&1 || err "jq is required"

# Check minikube is running with 2 nodes
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
log "Detected ${NODE_COUNT} node(s)"
log "Minikube status: $(minikube status --format '{{.Host}}' 2>/dev/null || echo 'unknown')"

log "============================================"
log "Phase 0: Label nodes for architecture layout"
log "============================================"
kubectl label node minikube node-role.kubernetes.io/master-data=true --overwrite 2>/dev/null || true
kubectl label node minikube-m02 node-role.kubernetes.io/ingest=true --overwrite 2>/dev/null || true
log "Nodes labeled"

log "============================================"
log "Phase 1: Create namespace"
log "============================================"
kubectl apply -f "${BASE_DIR}/namespace.yaml"

log "============================================"
log "Phase 2: Install cert-manager"
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

log "============================================"
log "Phase 3: Create ClusterIssuer and certificates"
log "============================================"
kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=2m
kubectl apply -f "${BASE_DIR}/cert-manager/cluster-issuer.yaml"
sleep 5
kubectl wait --for=condition=Ready certificate/es-ca -n elk --timeout=2m
kubectl apply -f "${BASE_DIR}/cert-manager/certificate.yaml"
kubectl wait --for=condition=Ready certificate/es-node -n elk --timeout=2m
log "TLS certificates created by cert-manager"

log "============================================"
log "Phase 4: Install Vault (dev mode)"
log "============================================"
helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
helm upgrade --install vault hashicorp/vault \
  --namespace elk \
  --values "${BASE_DIR}/vault/vault-values.yaml" \
  --wait --timeout=3m
log "Vault installed"

log "============================================"
log "Phase 5: Configure Vault (secrets + k8s auth)"
log "============================================"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n elk --timeout=3m
kubectl apply -f "${BASE_DIR}/vault/configure-vault-job.yaml"
kubectl wait --for=condition=complete job/configure-vault -n elk --timeout=2m
log "Vault configured with elasticsearch secrets and k8s auth"

log "============================================"
log "Phase 6: Install External Secrets Operator"
log "============================================"
helm repo add external-secrets https://charts.external-secrets.io --force-update
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --set resources.requests.memory=32Mi \
  --set resources.limits.memory=64Mi \
  --wait --timeout=3m
log "External Secrets Operator installed"

log "============================================"
log "Phase 7: Create SecretStore and ExternalSecret"
log "============================================"
kubectl wait --for=condition=Available deployment/external-secrets -n external-secrets --timeout=2m
kubectl apply -f "${BASE_DIR}/external-secrets/secret-store.yaml"
sleep 5
kubectl apply -f "${BASE_DIR}/external-secrets/external-secret.yaml"
sleep 10
# Verify the secret was synced
kubectl wait --for=condition=Ready secretsync -n elk --timeout=30s elastic-credentials 2>/dev/null || true
log "ExternalSecret created, waiting for secret sync..."
for i in $(seq 1 12); do
  if kubectl get secret elastic-credentials -n elk >/dev/null 2>&1; then
    log "Secret elastic-credentials synced from Vault"
    break
  fi
  sleep 5
done

log "============================================"
log "Phase 8: Install Longhorn"
log "============================================"
helm repo add longhorn https://charts.longhorn.io --force-update
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --values "${BASE_DIR}/longhorn/values.yaml" \
  --set longhornManager.resources.requests.memory=64Mi \
  --set longhornManager.resources.limits.memory=128Mi \
  --set instanceManager.resources.requests.memory=64Mi \
  --set instanceManager.resources.limits.memory=128Mi \
  --set engineImage.resources.requests.memory=64Mi \
  --set engineImage.resources.limits.memory=128Mi \
  --wait --timeout=5m
log "Longhorn installed with numberOfReplicas: 1"

log "============================================"
log "Phase 9: Deploy Elasticsearch ConfigMap & Services"
log "============================================"
kubectl apply -f "${BASE_DIR}/elasticsearch/configmap.yaml"
kubectl apply -f "${BASE_DIR}/elasticsearch/headless-service.yaml"

log "============================================"
log "Phase 10: Deploy Elasticsearch master-data node"
log "============================================"
kubectl apply -f "${BASE_DIR}/elasticsearch/master-data-statefulset.yaml"
kubectl wait --for=condition=ready pod -l app=elasticsearch,role=master-data -n elk --timeout=5m
log "Elasticsearch master-data node ready"

log "============================================"
log "Phase 11: Deploy Elasticsearch ingest node"
log "============================================"
kubectl apply -f "${BASE_DIR}/elasticsearch/ingest-statefulset.yaml"
kubectl wait --for=condition=ready pod -l app=elasticsearch,role=ingest -n elk --timeout=3m
log "Elasticsearch ingest node ready"

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
    warn "elastic-credentials secret updated with new password"
  fi
else
  log "Elastic password verified OK"
fi

log "============================================"
log "Phase 13: Set kibana_system password"
log "============================================"
kubectl apply -f "${BASE_DIR}/set-kibana-password-job.yaml"
kubectl wait --for=condition=complete job/set-kibana-password -n elk --timeout=3m
log "kibana_system password set"

log "============================================"
log "Phase 14: Deploy Kibana"
log "============================================"
kubectl apply -f "${BASE_DIR}/kibana/service.yaml"
kubectl apply -f "${BASE_DIR}/kibana/deployment.yaml"
kubectl rollout status deployment/kibana -n elk --timeout=3m
kubectl rollout restart deployment/kibana -n elk
kubectl rollout status deployment/kibana -n elk --timeout=3m
log "Kibana deployed and restarted with fresh credentials"

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
echo "  Nodes:"
echo "    kubectl get pods -n elk -o wide"
echo ""
echo "  Dashboard:"
echo "    minikube dashboard"
echo ""
