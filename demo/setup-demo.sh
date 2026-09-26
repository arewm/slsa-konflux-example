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

# 2b. Synchronize SPIRE root CA bundle with Fulcio server OIDC configuration
echo "==> [Demo Setup] Checking SPIRE root CA synchronization with Fulcio..."
python3 - << 'EOF'
import subprocess, json

try:
    spire_bundle = subprocess.check_output(
        "kubectl exec -n spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server bundle show 2>/dev/null",
        shell=True
    ).decode()

    raw_cm = subprocess.check_output(
        "kubectl get configmap fulcio-server-config -n fulcio-system -o json 2>/dev/null",
        shell=True
    ).decode()
    cm = json.loads(raw_cm)
    cfg = json.loads(cm["data"]["config.json"])

    spire_key = "https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local"
    current_cacert = cfg.get("OIDCIssuers", {}).get(spire_key, {}).get("CACert", "")

    if spire_bundle.strip() and spire_bundle.strip() != current_cacert.strip():
        print("  - Updating Fulcio with latest SPIRE root CA bundle...")
        if spire_key not in cfg.get("OIDCIssuers", {}):
            cfg.setdefault("OIDCIssuers", {})[spire_key] = {
                "IssuerURL": spire_key,
                "ClientID": "sigstore",
                "Type": "spiffe",
                "SPIFFETrustDomain": "konflux-ci.dev"
            }
        cfg["OIDCIssuers"][spire_key]["CACert"] = spire_bundle
        cm["data"]["config.json"] = json.dumps(cfg)
        p = subprocess.Popen(["kubectl", "apply", "-f", "-"], stdin=subprocess.PIPE, text=True)
        p.communicate(json.dumps(cm))
        subprocess.check_call("kubectl rollout restart deployment/fulcio-server -n fulcio-system", shell=True)
        subprocess.check_call("kubectl rollout status deployment/fulcio-server -n fulcio-system --timeout=60s", shell=True)
    else:
        print("  - Fulcio SPIRE CA bundle is up to date.")

    # Synchronize SPIRE bundle with kind-registry for Zot OIDC token verification
    subprocess.check_call(
        f"kubectl create configmap spire-bundle -n kind-registry --from-literal=ca.crt='{spire_bundle}' --dry-run=client -o yaml | kubectl apply -f -",
        shell=True
    )
    print("  - Synchronized SPIRE CA bundle to kind-registry/spire-bundle.")
except Exception as e:
    print(f"  [Notice] Could not verify SPIRE bundle sync: {e}")
EOF

# 2c. Ensure Tekton Chains is configured for Fulcio keyless signing
echo "==> [Demo Setup] Verifying Tekton Chains keyless signing configuration..."
kubectl patch tektonconfig config --type=merge -p '{
  "spec": {
    "chain": {
      "options": {
        "configMaps": {
          "chains-config": {
            "data": {
              "signers.x509.fulcio.enabled": "true",
              "signers.x509.fulcio.address": "http://fulcio-server.fulcio-system.svc.cluster.local",
              "signers.x509.fulcio.issuer": "https://kubernetes.default.svc",
              "signers.x509.fulcio.provider": "k8s",
              "signers.x509.fulcio.token.path": "/var/run/sigstore/cosign/oidc-token",
              "signers.x509.tuf.mirror.url": "http://tuf-server.tuf-system.svc.cluster.local",
              "signers.x509.rekor.address": "http://rekor-server.rekor-system.svc.cluster.local",
              "artifacts.oci.signer": "none",
              "storage.oci.encoding-format": "sigstore-bundle"
            }
          }
        }
      }
    }
  }
}' >/dev/null 2>&1 || true

# 2d. Ensure konflux-info/cluster-config enables keyless parameter discovery
kubectl patch configmap cluster-config -n konflux-info --type=merge -p '{
  "data": {
    "enableKeylessSigning": "true",
    "defaultOIDCIssuer": "https://kubernetes.default.svc",
    "tektonChainsIdentity": "https://kubernetes.io/namespaces/tekton-pipelines/serviceaccounts/tekton-chains-controller",
    "rekorHost": "http://rekor-server.rekor-system.svc.cluster.local",
    "tufMirror": "http://tuf-server.tuf-system.svc.cluster.local"
  }
}' >/dev/null 2>&1 || true

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
  --set release.pipeline.pathInRepo=managed-context/pipelines/slsa-e2e-release-dual-gated/slsa-e2e-release-dual-gated.yaml \
  --set release.signing.identity.subject="https://kubernetes.io/namespaces/default-tenant/serviceaccounts/build-pipeline-demo-app" \
  --set-json 'release.policy.excludeRules=["attestation_type.pipelinerun_attestation_found","cve.cve_results_found","slsa_source_correlated.attested_source_code_reference","base_image_registries.allowed_registries_provided","base_image_registries.base_image_permitted"]'

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
