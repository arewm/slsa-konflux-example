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
APPLY_ERR=$(mktemp)
if ! kubectl apply --server-side --force-conflicts -k "${SCRIPTDIR}/kyverno" 2>"${APPLY_ERR}"; then
    # A trusted-ca volume/mount left behind by a manual kubectl patch (added
    # under a different field manager) makes the apply fail with a duplicate
    # volume. Only in that case, strip the foreign entries by index and
    # re-apply so the kustomization owns those fields. Any other apply error
    # is a real failure: surface it and stop.
    if grep -q "Duplicate value" "${APPLY_ERR}" && \
       kubectl get deployment kyverno-admission-controller -n kyverno >/dev/null 2>&1; then
        echo "  - Duplicate trusted-ca volume detected; normalizing and retrying..."
        python3 - <<'PYEOF'
import json, subprocess
dep = json.loads(subprocess.check_output([
    "kubectl", "get", "deployment", "kyverno-admission-controller",
    "-n", "kyverno", "-o", "json"]))
spec = dep["spec"]["template"]["spec"]
patch = []
for i, vol in enumerate(spec.get("volumes") or []):
    if vol.get("name") == "trusted-ca":
        patch.append({"op": "remove", "path": f"/spec/template/spec/volumes/{i}"})
for ci, c in enumerate(spec.get("containers") or []):
    for mi, m in enumerate(c.get("volumeMounts") or []):
        if m.get("name") == "trusted-ca":
            patch.append({"op": "remove",
                          "path": f"/spec/template/spec/containers/{ci}/volumeMounts/{mi}"})
if patch:
    subprocess.check_call(["kubectl", "patch", "deployment",
                           "kyverno-admission-controller", "-n", "kyverno",
                           "--type=json", "-p", json.dumps(patch)])
PYEOF
        kubectl apply --server-side --force-conflicts -k "${SCRIPTDIR}/kyverno"
    else
        echo "Error: Kyverno apply failed:" >&2
        cat "${APPLY_ERR}" >&2
        rm -f "${APPLY_ERR}"
        exit 1
    fi
fi
rm -f "${APPLY_ERR}"

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
# have synced the ConfigMap into the kyverno namespace before the pod can
# start. Fail with a clear message rather than letting the rollout timeout
# take the whole setup down.
echo "==> [Kyverno] Waiting for the trusted-ca ConfigMap in the kyverno namespace..."
TRUSTED_CA_WAITED=0
while [ ${TRUSTED_CA_WAITED} -lt 120 ]; do
    if kubectl get cm trusted-ca -n kyverno >/dev/null 2>&1; then
        echo "  - trusted-ca present."
        break
    fi
    sleep 10
    TRUSTED_CA_WAITED=$((TRUSTED_CA_WAITED + 10))
done
if [ "${TRUSTED_CA_WAITED}" -ge 120 ]; then
    echo "Warning: cm/trusted-ca not found in kyverno after 120s (trust-manager Bundle not synced there yet?)." >&2
    echo "         The admission controller may stay in ContainerCreating until it appears." >&2
fi
echo "==> [Kyverno] Waiting for kyverno-admission-controller..."
kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=300s
echo "  - Kyverno ready."
