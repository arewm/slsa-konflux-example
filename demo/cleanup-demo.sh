#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PURGE_ALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all|--purge|-a)
      PURGE_ALL=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--all]"
      echo "  (default)  Clean up demo execution artifacts (TaskRuns, Pods, Releases, PipelineRuns, Jobs)"
      echo "  --all      Also delete demo application CRs, CVE database service, and Zot OIDC deployment"
      exit 0
      ;;
    *)
      echo "Unknown flag: $1"
      exit 1
      ;;
  esac
done

echo "==> [Demo Cleanup] Cleaning up demo execution artifacts..."

# 1. Delete default-tenant TaskRuns created during demo runs
echo "  - Deleting demo TaskRuns in default-tenant..."
kubectl delete taskrun -n default-tenant -l appstudio.openshift.io/application=demo-app --wait=true --ignore-not-found=true 2>/dev/null || true
kubectl delete taskrun attacker-unsigned-task demo-signed-task demo-sa-token-inspection demo-rogue-push-attempt demo-builder-gated-push demo-untrusted-service-query demo-trusted-scanner-query -n default-tenant --wait=true --ignore-not-found=true 2>/dev/null || true

# 2. Delete test / attacker Pods in default-tenant
echo "  - Deleting demo test/attacker pods in default-tenant..."
kubectl delete pod rogue-ambient-push test-rogue-push test-builder-push test-untrusted-client test-scanner-client attacker-label-spoof -n default-tenant --wait=true --ignore-not-found=true 2>/dev/null || true

# 3. Delete AppStudio Releases in default-tenant
echo "  - Deleting demo Releases in default-tenant..."
kubectl delete release -n default-tenant -l appstudio.openshift.io/application=demo-app --wait=true --ignore-not-found=true 2>/dev/null || true

# 4. Delete PipelineRuns in managed-tenant
echo "  - Deleting demo release PipelineRuns in managed-tenant..."
kubectl delete pipelinerun -n managed-tenant -l appstudio.openshift.io/application=demo-app --wait=true --ignore-not-found=true 2>/dev/null || true
kubectl delete pvc -n managed-tenant -l appstudio.openshift.io/application=demo-app --wait=true --ignore-not-found=true 2>/dev/null || true
kubectl delete pvc -n managed-tenant -l tekton.dev/pipeline=slsa-e2e-release-dual-gated --wait=true --ignore-not-found=true 2>/dev/null || true

# 5. Delete Rekor query jobs in default namespace
echo "  - Deleting query-rekor-demo jobs..."
kubectl delete job query-rekor-demo -n default --wait=true --ignore-not-found=true 2>/dev/null || true

# 6. Reset the registry image tag to the pristine baseline (undoing any Act 2 ambient push hijack)
echo "  - Resetting slsa-e2e-test:latest in internal registry to baseline signed image..."
REG_USER=$(kubectl get secret regcred-internal-registry -n default-tenant -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null | jq -r '.auths[].auth' 2>/dev/null | base64 -d 2>/dev/null || true)
if [ -n "${REG_USER}" ]; then
  # Extract pinned verified digest from snapshot manifest
  SNAPSHOT_DIGEST=$(grep -oE 'sha256:[a-f0-9]{64}' "${SCRIPT_DIR}/manifests/snapshot.yaml" | head -n1 || echo "sha256:5f1c994bf2a8a69bb5497c1bc3358f37c9952bf52dc109de2fc1307f080e12db")
  kubectl delete pod demo-registry-reset -n default-tenant --wait=true --ignore-not-found=true 2>/dev/null || true
  kubectl run demo-registry-reset --namespace=default-tenant \
    --image=quay.io/skopeo/stable:v1.14.2 \
    --restart=Never \
    --overrides='{
      "spec": {
        "volumes": [
          {"name": "regcred", "secret": {"secretName": "regcred-internal-registry"}}
        ],
        "containers": [{
          "name": "demo-registry-reset",
          "image": "quay.io/skopeo/stable:v1.14.2",
          "command": ["/bin/sh", "-c", "set -e\nmkdir -p ~/.docker\ncp /tekton/creds-secrets/regcred-internal-registry/.dockerconfigjson ~/.docker/config.json\nskopeo copy --all --src-tls-verify=false --dest-tls-verify=false --authfile ~/.docker/config.json docker://registry-service.kind-registry/slsa-e2e-test@'$SNAPSHOT_DIGEST' docker://registry-service.kind-registry/slsa-e2e-test:latest\n"],
          "volumeMounts": [
            {"name": "regcred", "mountPath": "/tekton/creds-secrets/regcred-internal-registry"}
          ]
        }]
      }
    }' >/dev/null 2>&1 || true
  kubectl wait --for=condition=Complete pod/demo-registry-reset -n default-tenant --timeout=45s >/dev/null 2>&1 || true
  kubectl delete pod demo-registry-reset -n default-tenant --wait=true --ignore-not-found=true 2>/dev/null || true
fi

if [[ "${PURGE_ALL}" == "true" ]]; then
  echo "==> [Demo Cleanup] Purging all demo infrastructure manifests..."
  helm uninstall demo-app 2>/dev/null || true
  kubectl delete -f "${SCRIPT_DIR}/manifests/snapshot.yaml" --wait=true --ignore-not-found=true 2>/dev/null || true
  kubectl delete -f "${SCRIPT_DIR}/manifests/cve-database-service.yaml" --wait=true --ignore-not-found=true 2>/dev/null || true
  kubectl delete -f "${SCRIPT_DIR}/manifests/zot-oidc.yaml" --wait=true --ignore-not-found=true 2>/dev/null || true
fi

echo "==> [Demo Cleanup] Cleanup complete!"
