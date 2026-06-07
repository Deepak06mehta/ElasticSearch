#!/bin/bash
# ==============================================================================
# deploy.sh — Orchestrates full ELK stack deployment on minikube
#
# Usage: ./deploy.sh
# Prerequisites: minikube running, kubectl configured, jq installed.
#
# Phases:
#   0 — Infrastructure (namespace, secrets, RBAC, service, configmap)
#   1 — Bootstrap (TLS cert generation + k8s Secret)
#   2 — StatefulSet (start ES, wait for readiness)
#   2b — Password verification (reset if ES auto-generated a different one)
#   3 — Set kibana_system password via API
#   4 — Deploy Kibana
#   5 — Restart Kibana (fresh credentials, no stale auth token)
# ==============================================================================

# --- Phase 0: Infrastructure -------------------------------------------------
# All foundational resources that do not depend on other phases.
kubectl apply -f namespace.yaml
kubectl apply -f secrets.yaml
kubectl apply -f rbac.yaml
kubectl apply -f headless-service.yaml
kubectl apply -f configmap.yaml

# --- Phase 1: Bootstrap Job --------------------------------------------------
# Generate CA + per-node TLS certificates using elasticsearch-certutil,
# then store them in a k8s Secret named "elastic-certs".
# The StatefulSet init containers copy per-node certs from this Secret.
kubectl apply -f bootstrap-job.yaml
kubectl wait \
  --for=condition=complete \
  job/elastic-bootstrap \
  -n elk \
  --timeout=3m

# --- Phase 2: StatefulSet ----------------------------------------------------
# Deploy 2-node Elasticsearch cluster with TLS, security, and persistent storage.
# Wait for BOTH pods to become 1/1 Ready.
kubectl apply -f statefulset.yaml

kubectl wait \
  --for=condition=ready \
  pod -l app=elasticsearch \
  -n elk \
  --timeout=5m

# --- Phase 2b: Elastic Password Verification ---------------------------------
# Verify that the elastic password from the static secret works against the
# running cluster. In most cases ES honours the ELASTIC_PASSWORD env var when
# starting with a fresh data directory. However, some ES 8.x versions run
# auto-configuration and generate a random password instead.
#
# If auth fails, use elasticsearch-reset-password (CLI tool) in batch mode to
# generate a new password, capture it, and update the k8s Secret so all
# subsequent phases use the correct credentials.
echo "Verifying elastic password..."

# Attempt authenticated request; expect HTTP 200.
PWD_CHECK=$(kubectl exec -n elk elasticsearch-0 -- bash -c 'curl -sk -u "elastic:${ELASTIC_PASSWORD}" -o /dev/null -w "%{http_code}" https://localhost:9200/')

if [ "$PWD_CHECK" != "200" ]; then
  echo "WARN: elastic password from secret does not match ES auto-configuration."
  echo "Resetting password via elasticsearch-reset-password..."

  # Run reset-password in batch mode (-b). Output looks like:
  # "Password for the [elastic] user = XyZ..."
  RESET_OUTPUT=$(kubectl exec -n elk elasticsearch-0 -- elasticsearch-reset-password -u elastic -b 2>&1)
  echo "$RESET_OUTPUT"

  # Extract the generated password from the output.
  NEW_ELASTIC_PWD=$(echo "$RESET_OUTPUT" | grep -o '= .*' | cut -d' ' -f2-)

  if [ -n "$NEW_ELASTIC_PWD" ]; then
    echo "Updating elastic-credentials secret with new password..."

    # Preserve the existing kibana-password from the current secret.
    KIBANA_PWD=$(kubectl get secret -n elk elastic-credentials -o jsonpath='{.data.kibana-password}' | base64 -d)

    # Recreate the secret with the new elastic password.
    kubectl delete secret -n elk elastic-credentials --ignore-not-found
    kubectl create secret generic elastic-credentials -n elk \
      --from-literal=elastic-password="$NEW_ELASTIC_PWD" \
      --from-literal=kibana-password="$KIBANA_PWD"

    echo "Secret updated. New elastic password: $NEW_ELASTIC_PWD"
  else
    echo "ERROR: Could not parse elasticsearch-reset-password output."
    echo "Please manually run: kubectl exec -n elk elasticsearch-0 -- elasticsearch-reset-password -u elastic -i"
    exit 1
  fi
else
  echo "Elastic password verified OK"
fi

# --- Phase 3: Set kibana_system Password -------------------------------------
# The kibana_system password must be set via the ES Security API because
# env-var-based configuration does not apply to the built-in users on first
# boot. The set-password-job waits for ES to be healthy, then POSTs the
# password change authenticated as the elastic user.
kubectl apply -f set-password-job.yaml
kubectl wait \
  --for=condition=complete \
  job/set-kibana-password \
  -n elk \
  --timeout=5m

# --- Phase 4: Deploy Kibana --------------------------------------------------
# Deploy the Kibana web UI and expose it via a NodePort service.
kubectl apply -f kibana-service.yaml
kubectl apply -f kibana.yaml

# --- Phase 5: Restart Kibana -------------------------------------------------
# Kibana may have started and cached an auth token before the kibana_system
# password was set in Phase 3. This cached token is invalid, causing
# monitoring upload failures. A rollout restart forces Kibana to re-read
# the credentials from the secret and establish a fresh session with ES.
kubectl rollout status deployment/kibana -n elk --timeout=3m
kubectl rollout restart deployment/kibana -n elk
kubectl rollout status deployment/kibana -n elk --timeout=3m

# Apply the cert rotation CronJob (placeholder — does nothing yet).
kubectl apply -f cert-rotation-cronjob.yaml
