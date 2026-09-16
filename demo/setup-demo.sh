#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "==> [Demo Setup] Verifying cluster connection and prerequisites..."
kubectl cluster-info >/dev/null 2>&1 || {
  echo "Error: Cannot connect to Kubernetes cluster via kubectl."
  exit 1
}

# 1. Verify required namespaces exist
for ns in default-tenant managed-tenant kind-registry spire tuf-system rekor-system; do
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "Error: Required namespace '$ns' does not exist."
    echo "Ensure platform-config and base setup have been applied."
    exit 1
  fi
done

# 2. Check and synchronize Rekor public key with TUF root secret if needed
echo "==> [Demo Setup] Checking Rekor public key synchronization with TUF root..."
REKOR_PK=$(kubectl run probe-rekor-pk -n default --image=curlimages/curl:latest --restart=Never --rm -i --quiet --command -- curl -s http://rekor-server.rekor-system.svc.cluster.local/api/v1/log/publicKey 2>/dev/null || true)
if [ -n "$REKOR_PK" ]; then
  CURRENT_TUF_PK=$(kubectl get secret rekor-public-key -n tuf-system -o jsonpath='{.data.key}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ "$REKOR_PK" != "$CURRENT_TUF_PK" ]; then
    echo "  - Rekor public key has changed (cluster restart). Synchronizing secret and restarting TUF server..."
    kubectl create secret generic rekor-public-key -n tuf-system --from-literal=key="$REKOR_PK" --dry-run=client -o yaml | kubectl apply -f -
    kubectl rollout restart deployment/sigstore-scaffold-tuf-tuf -n tuf-system
    kubectl rollout status deployment/sigstore-scaffold-tuf-tuf -n tuf-system --timeout=60s
  else
    echo "  - Rekor public key is aligned with TUF root."
  fi
fi

# 3. Deploy OIDC-Gated Zot Registry
echo "==> [Demo Setup] Deploying OIDC-gated Zot registry..."
kubectl apply -f "${SCRIPT_DIR}/manifests/zot-oidc.yaml"
kubectl rollout status deployment/registry-oidc -n kind-registry --timeout=60s

# 4. Deploy CVE Database Service
echo "==> [Demo Setup] Deploying CVE Database Service..."
kubectl apply -f "${SCRIPT_DIR}/manifests/cve-database-service.yaml"
kubectl rollout status deployment/cve-database-service -n services --timeout=60s

# 5. Deploy dedicated Demo Application via component-onboarding Helm chart
echo "==> [Demo Setup] Deploying demo-app via charts/component-onboarding..."
helm upgrade --install demo-app "${SCRIPT_DIR}/../charts/component-onboarding" \
  --set componentName=demo-app \
  --set gitRepoUrl=https://github.com/konflux-ci/testrepo \
  --set containerImage=registry-service.kind-registry/slsa-e2e-test:latest \
  --set release.pipeline.pathInRepo=managed-context/pipelines/slsa-e2e-release-dual-gated/slsa-e2e-release-dual-gated.yaml

echo "==> [Demo Setup] Applying demo-app test snapshot..."
kubectl apply -f "${SCRIPT_DIR}/manifests/snapshot.yaml"

# 6. Ensure clean initial baseline state
echo "==> [Demo Setup] Establishing pristine baseline state..."
"${SCRIPT_DIR}/cleanup-demo.sh"

echo ""
echo -e "\033[0;32m═════════════════════════════════════════════════════════════════════════════════\033[0m"
echo -e "\033[0;32m  Demo Setup Complete! The environment is primed and in a clean initial state.   \033[0m"
echo -e "\033[0;32m═════════════════════════════════════════════════════════════════════════════════\033[0m"
echo ""
echo "Konflux UI Demo Links:"
echo "  - Application View: https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app"
echo "  - Releases View:    https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app/releases"
echo "  - PipelineRuns:     https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app/activity/pipelineruns"
echo ""
echo "To run the demo:"
echo "  ${SCRIPT_DIR}/run-demo.sh"
echo ""
