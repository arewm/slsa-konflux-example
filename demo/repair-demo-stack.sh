#!/usr/bin/env bash
# ==============================================================================
# Repair the demo stack after a host/cluster restart, without a full setup run.
#
# Why this exists: kind containers survive host reboots (podman start), but
# several demo dependencies do not survive the in-cluster restart cleanly:
#   - Rekor can come back with a rotated signing key while the TUF root still
#     publishes the pre-restart key, so every EC/cosign transparency-log
#     verification fails with "not enough verified log entries" (0 < 1).
#   - demo-trusted-root (cosign verify beats) embeds the Rekor key and must be
#     regenerated from the current secrets.
# setup-demo.sh performs these repairs (steps 2 / 2h / 2c-3) but only during a
# full ~40-minute run; serve-slides.sh skips setup when the baseline is primed,
# so a reboot left no lightweight recovery path. This script is exactly the
# idempotent repair subset — safe to run any time, also from setup-demo's
# perspective (it re-checks before changing anything).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/kubeconfig.sh"

echo "==> [Demo Repair] Post-restart repair (idempotent)..."

# 1. Rekor public key synchronization with the TUF root (setup-demo step 2).
REKOR_PK=$(kubectl run probe-rekor-pk -n default --image=curlimages/curl:latest --restart=Never --rm -i --quiet --command -- curl -s --max-time 10 http://rekor-server.rekor-system.svc/api/v1/log/publicKey 2>/dev/null || true)
if [ -n "${REKOR_PK}" ]; then
  CURRENT_TUF_PK=$(kubectl get secret rekor-public-key -n tuf-system -o jsonpath='{.data.key}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ "${REKOR_PK}" != "${CURRENT_TUF_PK}" ]; then
    echo "  - Rekor public key has changed (cluster restart). Synchronizing secret and restarting TUF server..."
    kubectl create secret generic rekor-public-key -n tuf-system --from-literal=key="${REKOR_PK}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl rollout restart deployment/sigstore-scaffold-tuf-tuf -n tuf-system
    kubectl rollout status deployment/sigstore-scaffold-tuf-tuf -n tuf-system --timeout=120s
    # TUF re-signs its repository on restart; Chains caches TUF metadata in an
    # emptyDir, so force a re-bootstrap by deleting the pod (the operator
    # reverts `kubectl rollout restart`).
    CHAINS_POD=$(kubectl get pods -n tekton-pipelines -l app=tekton-chains-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -n "${CHAINS_POD}" ] && kubectl delete pod "${CHAINS_POD}" -n tekton-pipelines
    kubectl rollout status deployment/tekton-chains-controller -n tekton-pipelines --timeout=300s >/dev/null
  else
    echo "  - Rekor public key is aligned with TUF root."
  fi
else
  echo "  [Warning] Could not fetch the Rekor public key; skipping sync."
fi

# 2. Regenerate demo-trusted-root from the current secrets (setup-demo 2c-3):
# the ConfigMap embeds the Rekor (and ctlog/Fulcio) keys used by the cosign
# verify beats in Acts 3 and 4.
echo "==> [Demo Repair] Regenerating demo-trusted-root..."
TR_DIR=$(mktemp -d)
kubectl get secret fulcio-server-secret -n fulcio-system -o jsonpath='{.data.cert}' | base64 -d > "${TR_DIR}/fulcio-root.pem"
kubectl get secret rekor-public-key -n tuf-system -o jsonpath='{.data.key}' | base64 -d > "${TR_DIR}/rekor-pub.pem"
kubectl get secret ctlog-public-key -n tuf-system -o jsonpath='{.data.public}' | base64 -d > "${TR_DIR}/ctlog-pub.pem"
python3 - "${TR_DIR}" <<'PYEOF'
import json, subprocess, base64, hashlib, sys
d = sys.argv[1]def der(pem):
    return subprocess.run(['openssl','pkey','-pubin','-in',pem,'-outform','DER'],capture_output=True).stdout
def logentry(pem, base_url):
    pk = der(pem)
    return {
        "baseUrl": base_url,
        "hashAlgorithm": "SHA2_256",
        "publicKey": {
            "rawBytes": base64.b64encode(pk).decode(),
            "keyDetails": "PKIX_ECDSA_P256_SHA_256",
            "validFor": {"start": "2024-01-01T00:00:00Z"},
        },
        "logId": {"keyId": base64.b64encode(hashlib.sha256(pk).digest()).decode()},
    }
root = subprocess.run(['openssl','x509','-in',f'{d}/fulcio-root.pem','-outform','DER'],capture_output=True).stdout
tr = {
    "mediaType": "application/vnd.dev.sigstore.trustedroot+json;version=0.1",
    "tlogs": [logentry(f'{d}/rekor-pub.pem', "http://rekor-server.rekor-system.svc.cluster.local")],
    "ctlogs": [logentry(f'{d}/ctlog-pub.pem', "http://ctlog.ctlog-system.svc.cluster.local")],
    "certificateAuthorities": [{
        "subject": {"organization": "Linux Foundation"},
        "certChain": {"certificates": [{"rawBytes": base64.b64encode(root).decode()}]},
        "validFor": {"start": "2024-01-01T00:00:00Z"},
    }],
}
json.dump(tr, open(f'{d}/trusted-root.json','w'), indent=2)
PYEOF
kubectl delete configmap demo-trusted-root -n default-tenant --ignore-not-found >/dev/null 2>&1
kubectl create configmap demo-trusted-root -n default-tenant --from-file=trusted-root.json="${TR_DIR}/trusted-root.json" >/dev/null
rm -rf "${TR_DIR}"
echo "  - demo-trusted-root regenerated."

# 3. SPIRE root CA sync with Fulcio (setup-demo step 2b) and Zot: the OIDC
# discovery provider's serving cert chains to the SPIRE root; if the bundle
# changed, Fulcio cannot process SPIFFE identity tokens (keyless signing
# fails with "There was an error processing the identity token").
echo "==> [Demo Repair] Checking SPIRE root CA synchronization with Fulcio..."
python3 - <<'EOF'
import subprocess, json
spire_bundle = subprocess.check_output(
    "kubectl exec -n spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server bundle show 2>/dev/null",
    shell=True).decode()
raw_cm = subprocess.check_output(
    "kubectl get configmap fulcio-server-config -n fulcio-system -o json 2>/dev/null", shell=True).decode()
cm = json.loads(raw_cm)
cfg = json.loads(cm["data"]["config.json"])
spire_key = "https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local"
current = cfg.get("OIDCIssuers", {}).get(spire_key, {}).get("CACert", "")
if spire_bundle.strip() and spire_bundle.strip() != current.strip():
    print("  - Updating Fulcio with latest SPIRE root CA bundle...")
    cfg.setdefault("OIDCIssuers", {})[spire_key] = {
        "IssuerURL": spire_key, "ClientID": "sigstore",
        "Type": "spiffe", "SPIFFETrustDomain": "konflux-ci.dev",
    }
    cfg["OIDCIssuers"][spire_key]["CACert"] = spire_bundle
    cm["data"]["config.json"] = json.dumps(cfg)
    p = subprocess.Popen(["kubectl", "apply", "-f", "-"], stdin=subprocess.PIPE, text=True)
    p.communicate(json.dumps(cm))
    subprocess.check_call("kubectl rollout restart deployment/fulcio-server -n fulcio-system", shell=True)
    subprocess.check_call("kubectl rollout status deployment/fulcio-server -n fulcio-system --timeout=120s", shell=True)
else:
    print("  - Fulcio SPIRE CA bundle is up to date.")
# Zot OIDC registry verifies JWTs against the SPIRE bundle too.
subprocess.check_call(
    "kubectl create configmap spire-bundle -n kind-registry --from-literal=ca.crt='" + spire_bundle +
    "' --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - 2>/dev/null", shell=True)
print("  - Zot spire-bundle synced.")
EOF

# 4. OIDC discovery provider DNS SANs: the provider's serving cert is an
# x509-SVID renewed from autoPopulateDNSNames; after restarts the derived
# SAN set can stop short of the fully-qualified
# spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local that Fulcio's
# issuer URL requires (observed post-reboot: TLS "certificate is valid for
# ... not ...svc.cluster.local"). Pin the full set explicitly — an
# idempotent patch of the helm-managed ClusterSPIFFEID (owned by the spire
# release), same pattern as the trusted-ca Bundle patch.
echo "==> [Demo Repair] Pinning OIDC provider DNS SANs..."
kubectl patch clusterspiffeid spire-spiffe-oidc-discovery-provider --type merge -p '{"spec":{"dnsNameTemplates":["oidc-discovery.{{ .TrustDomain }}","spire-spiffe-oidc-discovery-provider","spire-spiffe-oidc-discovery-provider.spire","spire-spiffe-oidc-discovery-provider.spire.svc","spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local"]}}' >/dev/null 2>&1 || echo "  [Warning] Could not patch clusterspiffeid."
echo "  - DNS SAN templates pinned (provider SVID rotates on renewal)."

# 5. CT log health (Trillian data can be lost after restarts; setup-demo step
# 2 has the full re-initialization — here we only detect and point at it).CTLOG_STH=$(kubectl run probe-ctlog-r -n default --image=curlimages/curl:latest --restart=Never --rm -i --quiet --command -- curl -s --max-time 10 http://ctlog.ctlog-system.svc/sigstorescaffolding/ct/v1/get-sth 2>/dev/null || true)
if echo "${CTLOG_STH}" | grep -q "tree_size"; then
  echo "  - CT log healthy."
else
  echo "  [Warning] CT log unhealthy (Trillian data lost after restart?)."
  echo "            Run the full setup: ./setup-demo.sh (it re-initializes the transparency logs)."
fi

echo "==> [Demo Repair] Done. If the demo image was built before this repair,"
echo "    rebuild it (setup-demo or a fresh build PipelineRun) so its Rekor"
echo "    entries are verifiable, then re-run the affected act."
