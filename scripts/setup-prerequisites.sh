#!/bin/bash
set -e

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
REPODIR="${SCRIPTDIR}/.."

echo "==> Setting up SLSA Konflux Example Prerequisites"

# Create managed tenant namespace
echo "Creating managed-tenant namespace..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: managed-tenant
  labels:
    konflux-ci.dev/type: tenant
EOF

# Configure the Konflux operator to use the custom SLSA pipeline
BUNDLE_REF_FILE="${REPODIR}/managed-context/slsa-e2e-pipeline/bundle-ref"
if [ ! -f "$BUNDLE_REF_FILE" ]; then
    echo "Error: Bundle reference file not found: $BUNDLE_REF_FILE" >&2
    echo "Run hack/build-pipeline.sh first to push and pin the pipeline bundle." >&2
    exit 1
fi

PIPELINE_BUNDLE=$(head -1 "$BUNDLE_REF_FILE" | tr -d '[:space:]')
if [ -z "$PIPELINE_BUNDLE" ]; then
    echo "Error: Bundle reference file is empty: $BUNDLE_REF_FILE" >&2
    exit 1
fi
echo "Configuring custom SLSA pipeline: ${PIPELINE_BUNDLE}"
kubectl patch konflux konflux --type=merge -p "{
  \"spec\": {
    \"buildService\": {
      \"spec\": {
        \"pipelineConfig\": {
          \"defaultPipelineName\": \"slsa-e2e-oci-ta\",
          \"pipelines\": [{
            \"name\": \"slsa-e2e-oci-ta\",
            \"bundle\": \"${PIPELINE_BUNDLE}\"
          }]
        }
      }
    }
  }
}"

# Configure Tekton Chains to write provenance as Sigstore bundles via OCI 1.1 Referrers
# and enable keyless signing via Fulcio and Rekor
echo "Configuring Tekton Chains for keyless signing and OCI 1.1 Referrers (sigstore-bundle format)..."
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
              "storage.oci.encoding-format": "sigstore-bundle"
            }
          }
        }
      }
    }
  }
}' 2>/dev/null || echo "Warning: Could not patch TektonConfig for Chains sigstore-bundle format."

# Configure konflux-info/cluster-config for Conforma keyless parameter discovery
echo "Configuring konflux-info/cluster-config for keyless Conforma policy verification..."
kubectl patch configmap cluster-config -n konflux-info --type=merge -p '{
  "data": {
    "enableKeylessSigning": "true",
    "defaultOIDCIssuer": "https://kubernetes.default.svc",
    "tektonChainsIdentity": "https://kubernetes.io/namespaces/tekton-pipelines/serviceaccounts/tekton-chains-controller",
    "rekorHost": "http://rekor-server.rekor-system.svc.cluster.local",
    "tufMirror": "http://tuf-server.tuf-system.svc.cluster.local"
  }
}' 2>/dev/null || echo "Warning: Could not patch konflux-info/cluster-config ConfigMap."

# Configure internal registry access for build and integration pipelines.
# The common-secret label makes build-service auto-link the credential to
# every build-pipeline-{component} SA it creates.
echo "Configuring internal registry credentials for pipelines..."
kubectl label secret regcred-internal-registry -n default-tenant \
  build.appstudio.openshift.io/common-secret=true --overwrite 2>/dev/null || \
  echo "Warning: regcred-internal-registry secret not found. Internal registry credentials may not be configured."

# Link to default SA in default-tenant for direct/test PipelineRuns
kubectl patch sa default -n default-tenant \
  -p '{"secrets":[{"name":"regcred-internal-registry"}]}' 2>/dev/null || true

# The integration-runner SA is created by the operator, not build-service,
# so the common-secret label doesn't cover it. Link the credential directly.
kubectl patch sa konflux-integration-runner -n default-tenant \
  -p '{"secrets":[{"name":"regcred-internal-registry"}]}' 2>/dev/null || \
  echo "Warning: konflux-integration-runner SA not found."

# Copy the registry credential to managed-tenant for the release pipeline.
# The release pipeline's collect-data task pushes trusted artifacts to the
# internal registry and needs authentication.
echo "Configuring internal registry credentials for release pipeline..."
REGCRED_JSON=$(kubectl get secret regcred-internal-registry -n default-tenant \
  -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null || true)
if [ -n "$REGCRED_JSON" ]; then
    kubectl apply -f - <<CREDEOF
apiVersion: v1
kind: Secret
metadata:
  name: regcred-internal-registry
  namespace: managed-tenant
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${REGCRED_JSON}
CREDEOF
    kubectl patch sa release-service-account -n managed-tenant \
      -p '{"secrets":[{"name":"regcred-internal-registry"}]}' 2>/dev/null || \
      echo "Warning: release-service-account SA not found in managed-tenant."
else
    echo "Warning: Could not copy registry credentials to managed-tenant."
fi

echo ""
echo "==> Prerequisites setup complete!"
echo ""
echo "The following namespaces are now configured:"
echo "  - default-tenant (created by Konflux operator)"
echo "  - managed-tenant (created by this script)"
echo ""
echo "Custom SLSA pipeline configured on the Konflux CR."
echo ""
echo "Demo users (configured by Konflux operator):"
echo "  - user1@konflux.dev / password"
echo "  - user2@konflux.dev / password"
echo ""
echo "Next steps:"
echo "  1. Install platform config: helm upgrade --install platform ./charts/platform-config"
echo "     Then link the release SA: kubectl patch sa release-service-account -n managed-tenant -p '{\"secrets\":[{\"name\":\"regcred-internal-registry\"}]}'"
echo "  2. Onboard a component: helm upgrade --install festoji ./charts/component-onboarding --set componentName=festoji --set gitRepoUrl=https://github.com/FORK_ORG/festoji"
echo "  3. Access the UI at https://localhost:9443 and login with demo credentials"
echo "  4. Create a pull request to trigger a build"
echo ""
