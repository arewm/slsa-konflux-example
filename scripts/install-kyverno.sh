#!/bin/bash
# Install Kyverno (pinned, see scripts/kyverno/kustomization.yaml) and give
# its admission controller access to the internal kind registry.
#
# Why: Konflux v0.2.2 no longer ships Kyverno (konflux-ci 3e9471e8b), but
# charts/admission-policy needs its MutatingPolicy/ValidatingPolicy/
# ImageValidatingPolicy CRDs. Idempotent (safe to run multiple times).
set -e

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "==> [Kyverno] Installing Kyverno (scripts/kyverno)..."
# Server-side apply: the Kyverno CRDs exceed the client-side
# last-applied-configuration annotation size limit.
if ! kubectl apply --server-side --force-conflicts -k "${SCRIPTDIR}/kyverno" >/dev/null 2>&1; then
    # A trusted-ca volume/mount left behind by a manual kubectl patch (added
    # under a different field manager) makes the apply fail with a duplicate
    # volume. Normalize by removing any foreign trusted-ca volume and mount,
    # then re-apply so the kustomization owns those fields.
    echo "  - Apply failed; normalizing pre-existing trusted-ca volume and retrying..."
    python3 - <<'PYEOF' >/dev/null
import json, subprocess
dep = json.loads(subprocess.check_output([
    "kubectl", "get", "deployment", "kyverno-admission-controller",
    "-n", "kyverno", "-o", "json"]))
spec = dep["spec"]["template"]["spec"]
vols = [v for v in spec.get("volumes", []) if v.get("name") != "trusted-ca"]
spec["volumes"] = vols
for c in spec.get("containers", []):
    if "volumeMounts" in c:
        c["volumeMounts"] = [m for m in c["volumeMounts"]
                             if m.get("name") != "trusted-ca"]
patch = json.dumps([{"op": "replace", "path": "/spec/template/spec",
                     "value": spec}])
subprocess.check_call(["kubectl", "patch", "deployment",
                       "kyverno-admission-controller", "-n", "kyverno",
                       "--type=json", "-p", patch])
PYEOF
    kubectl apply --server-side --force-conflicts -k "${SCRIPTDIR}/kyverno" >/dev/null
fi

# verify-bundle-signatures pulls bundles from registry-service.kind-registry,
# which requires auth. The admission-policy chart references this secret by
# name in the kyverno namespace, so copy it from kind-registry.
echo "==> [Kyverno] Copying internal-registry-client-auth into the kyverno namespace..."
REGISTRY_AUTH_JSON=$(kubectl get secret internal-registry-client-auth -n kind-registry \
  -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null || true)
if [ -n "$REGISTRY_AUTH_JSON" ]; then
    kubectl apply -f - >/dev/null <<CREDEOF
apiVersion: v1
kind: Secret
metadata:
  name: internal-registry-client-auth
  namespace: kyverno
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${REGISTRY_AUTH_JSON}
CREDEOF
else
    echo "Warning: kind-registry/internal-registry-client-auth not found; Kyverno cannot pull from the internal registry."
fi

# The trusted-ca mount (also in the kustomization) needs trust-manager to
# have synced the ConfigMap into the kyverno namespace before the pod starts.
echo "==> [Kyverno] Waiting for kyverno-admission-controller..."
kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=300s
echo "  - Kyverno ready."
