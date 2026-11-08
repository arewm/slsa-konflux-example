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

# 2b-2. Refresh the SPIRE agent bootstrap bundle.
# After cluster restarts the SPIRE server rotates its CA, but the spire-bundle
# ConfigMap that agents bootstrap from is only reconciled by the SPIRE server
# when it starts — a restarted server with a rotated CA leaves agents with a
# stale bundle and every workload fails to attest. Fetch the CURRENT bundle in
# SPIFFE JSON format (NOT the default PEM — the agent expects the JSON bundle
# format under key bundle.spiffe) and restart the agents to pick it up.
echo "==> [Demo Setup] Refreshing SPIRE agent bootstrap bundle..."
SPIFFE_BUNDLE=$(kubectl exec -n spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server bundle show -format spiffe 2>/dev/null || true)
if [ -n "${SPIFFE_BUNDLE}" ]; then
  kubectl create configmap spire-bundle -n spire \
    --from-literal=bundle.spiffe="${SPIFFE_BUNDLE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl rollout restart daemonset/spire-agent -n spire
  kubectl rollout status daemonset/spire-agent -n spire --timeout=120s
  echo "  - SPIRE agents rebootstrapped with the current server bundle."
else
  echo "  [Notice] Could not fetch SPIFFE bundle from spire-server; skipping agent refresh."
fi

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
              "signers.x509.fulcio.provider": "",
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
# Delete a pre-existing EnterpriseContractPolicy first: a stale
# kubectl-client-side-apply field manager on .spec.sources makes the helm
# upgrade fail with a field-manager conflict. Deleting lets helm recreate it
# server-side. (The ECP has no state worth preserving between demo setups.)
kubectl delete enterprisecontractpolicy demo-app-ec-policy -n managed-tenant --ignore-not-found=true >/dev/null 2>&1 || true
helm upgrade --install demo-app "${SCRIPT_DIR}/../charts/component-onboarding" \
  --set componentName=demo-app \
  --set gitRepoUrl=https://github.com/konflux-ci/testrepo \
  --set containerImage=registry-service.kind-registry/slsa-e2e-test:latest \
  --set release.pipeline.pathInRepo=managed-context/pipelines/slsa-e2e-release-dual-gated/slsa-e2e-release-dual-gated.yaml \
  --set release.pipeline.revision=kubecon-na-2026-your-cis-mistaken-identity \
  --set-json 'release.policy.excludeRules=["attestation_type.pipelinerun_attestation_found","cve.cve_results_found","slsa_source_correlated.attested_source_code_reference","base_image_registries.allowed_registries_provided","base_image_registries.base_image_permitted"]'
# NOTE: release.signing.identity intentionally uses the chart default
# (tekton-pipelines/tekton-chains-controller) — Tekton Chains v0.29 signs all
# attestations as that identity, regardless of which ServiceAccount ran the
# build. Overriding it to the build SA silently fails every VSA signature
# check in Act 4.

# 5b. (Re)build the demo snapshot.
# The checked-in demo/manifests/snapshot.yaml pins a digest+revision that goes
# stale whenever signing keys rotate (cluster restarts). REBUILD_SNAPSHOT=1
# (default) runs a fresh build PipelineRun and recreates the snapshot from its
# results; set REBUILD_SNAPSHOT=0 to apply the checked-in pinned snapshot.
REBUILD_SNAPSHOT="${REBUILD_SNAPSHOT:-1}"
if [[ "${REBUILD_SNAPSHOT}" == "1" ]]; then
  echo "==> [Demo Setup] Running fresh build PipelineRun for demo-app snapshot..."
  TESTREPO_SHA=$(git ls-remote https://github.com/konflux-ci/testrepo HEAD | cut -f1)
  if [ -z "${TESTREPO_SHA}" ]; then
    echo "Error: could not resolve konflux-ci/testrepo HEAD."
    exit 1
  fi
  echo "  - Building testrepo revision ${TESTREPO_SHA}"
  cat <<EOF | kubectl create -f - >/dev/null
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: slsa-e2e-build-
  namespace: default-tenant
  labels:
    pipelines.appstudio.openshift.io/type: build
    appstudio.openshift.io/application: demo-app
    appstudio.openshift.io/component: demo-app
spec:
  taskRunTemplate:
    serviceAccountName: build-pipeline-demo-app
  pipelineRef:
    resolver: bundles
    params:
      - name: bundle
        value: quay.io/slsa-konflux-example/pipeline-slsa-e2e-oci-ta:latest@sha256:086650cb7640955989a4c1acfa21fb94a6138e6f3f24e46ae4cceec2e61b8e42
      - name: name
        value: slsa-e2e-oci-ta
      - name: kind
        value: pipeline
  params:
    - name: git-url
      value: https://github.com/konflux-ci/testrepo
    - name: revision
      value: "${TESTREPO_SHA}"
    - name: output-image
      value: "registry-service.kind-registry/slsa-e2e-test:build-\$(context.pipelineRun.uid)"
  workspaces:
    - name: workspace
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 1Gi
  taskRunSpecs:
    - pipelineTaskName: prefetch-dependencies
      computeResources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          memory: 1Gi
    - pipelineTaskName: build-container
      computeResources:
        requests:
          cpu: 200m
          memory: 512Mi
        limits:
          memory: 2Gi
EOF
  BUILD_PR=$(kubectl get pipelineruns -n default-tenant \
    -l pipelines.appstudio.openshift.io/type=build,appstudio.openshift.io/component=demo-app \
    --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
  echo "  - Build PipelineRun: ${BUILD_PR}"
  BUILD_START=$(date +%s)
  while true; do
    BUILD_STATUS=$(kubectl get pipelinerun "${BUILD_PR}" -n default-tenant -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || true)
    if [ "${BUILD_STATUS}" = "True" ]; then break; fi
    if [ "${BUILD_STATUS}" = "False" ]; then
      echo "Error: build PipelineRun ${BUILD_PR} failed:"
      kubectl get pipelinerun "${BUILD_PR}" -n default-tenant -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].message}'; echo
      exit 1
    fi
    if [ $(( $(date +%s) - BUILD_START )) -ge 1200 ]; then
      echo "Error: timed out waiting for build PipelineRun ${BUILD_PR}"
      exit 1
    fi
    sleep 10
  done
  echo "  - Build succeeded; waiting for Tekton Chains to sign the new provenance..."
  CHAINS_START=$(date +%s)
  while true; do
    SIGNED=$(kubectl get pipelinerun "${BUILD_PR}" -n default-tenant -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}' 2>/dev/null || true)
    [ "${SIGNED}" = "true" ] && break
    if [ $(( $(date +%s) - CHAINS_START )) -ge 300 ]; then
      echo "  [Notice] Chains signing annotation not seen after 300s; continuing anyway."
      break
    fi
    sleep 10
  done
  IMAGE_DIGEST=$(kubectl get pipelinerun "${BUILD_PR}" -n default-tenant -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}')
  CHAINS_COMMIT=$(kubectl get pipelinerun "${BUILD_PR}" -n default-tenant -o jsonpath='{.status.results[?(@.name=="CHAINS-GIT_COMMIT")].value}')
  SNAPSHOT_REVISION="${CHAINS_COMMIT:-${TESTREPO_SHA}}"
  if [ -z "${IMAGE_DIGEST}" ]; then
    echo "Error: build PipelineRun ${BUILD_PR} produced no IMAGE_DIGEST result."
    exit 1
  fi
  echo "  - New image digest: ${IMAGE_DIGEST} (revision ${SNAPSHOT_REVISION})"
  # Snapshots are immutable — delete and recreate with the fresh build results.
  kubectl delete snapshot demo-app-snapshot -n default-tenant --ignore-not-found=true >/dev/null 2>&1 || true
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: appstudio.redhat.com/v1alpha1
kind: Snapshot
metadata:
  name: demo-app-snapshot
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: demo-app
    app.kubernetes.io/part-of: kubecon-demo
spec:
  application: demo-app
  components:
  - name: demo-app
    containerImage: "registry-service.kind-registry/slsa-e2e-test@${IMAGE_DIGEST}"
    source:
      git:
        revision: "${SNAPSHOT_REVISION}"
        url: https://github.com/konflux-ci/testrepo
EOF
  echo "  - Recreated snapshot demo-app-snapshot from the fresh build."
else
  echo "==> [Demo Setup] Applying checked-in demo-app test snapshot (REBUILD_SNAPSHOT=0)..."
  kubectl apply -f "${SCRIPT_DIR}/manifests/snapshot.yaml"
fi

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
