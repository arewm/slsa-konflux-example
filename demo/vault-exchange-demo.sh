#!/usr/bin/env bash
# Vault legacy-service token exchange demo (Pattern 2 extension).
#
# Demonstrates a trusted task exchanging its SPIRE-issued JWT-SVID for a
# static legacy credential via Vault, where Vault's JWT auth is backed by
# SPIRE's OIDC discovery endpoint and credential release is bound to a
# specific SPIFFE ID (sub claim).
#
# See docs/reference/legacy-token-exchange.md for the full pattern write-up.
#
# Prerequisites (in addition to the base demo setup):
#   - SPIRE + Konflux running (charts/spiffe-spire, platform-config)
#   - Local CLI tools: helm, tkn, cosign, python3 (for building the demo
#     task bundle)
#
# Usage:
#   demo/vault-exchange-demo.sh            # run the full demo
#   demo/vault-exchange-demo.sh --clean    # remove demo resources
set -eo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Discover the Konflux demo cluster kubeconfig (no-op if already targeted).
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/kubeconfig.sh"
REPO_DIR="$( cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd )"

TENANT_NS="default-tenant"
VAULT_NS="services"
VAULT_RELEASE="vault-legacy"
VAULT_URL="http://vault-legacy-exchange.${VAULT_NS}.svc.cluster.local:8200"
VAULT_ROLE="scanner"
JWT_AUDIENCE="vault"

# Demo catalog bundle (task name kept as trivy-sbom-scan so the SPIFFE ID
# matches the Vault role's bound_subject). The bundle is pushed through a
# kubectl port-forward to the in-cluster registry (see below).
LOCAL_REGISTRY_PORT=30009
BUNDLE_TASK_YAML="${SCRIPT_DIR}/manifests/trivy-sbom-scan-vault.yaml"
BUNDLE_HOST="localhost:${LOCAL_REGISTRY_PORT}"   # via kubectl port-forward to registry-service
BUNDLE_REF_HOST="registry-service.kind-registry"  # in-cluster registry name
BUNDLE_REPO="tekton-catalog/trivy-sbom-scan"
BUNDLE_TAG="0.1-vault-demo"
BUNDLE_REF="${BUNDLE_REF_HOST}/${BUNDLE_REPO}:${BUNDLE_TAG}"

# ---------------------------------------------------------------- helpers
say()  { echo "==> $*"; }
note() { echo "    $*"; }
fail() { echo "Error: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' is required on PATH ($2)"; }

demo_cleanup() {
  kubectl delete "$1" "$2" -n "$3" --wait=true >/dev/null 2>&1 || true
}

# Decode a JWT claim without external tools
jwt_claim() {
  python3 -c "
import sys, json, base64
p = sys.argv[1].split('.')[1]
p += '=' * (-len(p) % 4)
print(json.loads(base64.urlsafe_b64decode(p))[sys.argv[2]])
" "$1" "$2"
}

# ---------------------------------------------------------------- --clean
if [ "${1:-}" = "--clean" ]; then
  say "Removing Vault legacy-exchange demo resources..."
  helm uninstall "${VAULT_RELEASE}" -n "${VAULT_NS}" 2>/dev/null || true
  for tr in demo-vault-scanner-exchange demo-vault-dev-attempt; do
    demo_cleanup taskrun "${tr}" "${TENANT_NS}"
  done
  for pod in test-vault-login test-vault-read test-vault-dev-login; do
    demo_cleanup pod "${pod}" "${TENANT_NS}"
  done
  say "Done (task bundle in the registry is left in place)."
  exit 0
fi

# ---------------------------------------------------------------- preflight
say "Verifying cluster connection and prerequisites..."
for tool in helm tkn cosign python3; do
  need "${tool}" "required to build and sign the demo task bundle"
done
kubectl get namespace "${TENANT_NS}" >/dev/null 2>&1 || fail "Namespace ${TENANT_NS} not found."
kubectl get namespace spire >/dev/null 2>&1 || fail "SPIRE (namespace 'spire') not found."

# Port-forward the in-cluster registry to localhost for the bundle push
# (the KinD NodePort is not published on the host in all setups)
say "Port-forwarding registry-service to localhost:${LOCAL_REGISTRY_PORT}..."
kubectl port-forward -n kind-registry svc/registry-service "${LOCAL_REGISTRY_PORT}:443" >/dev/null 2>&1 &
PORTFWD_PID=$!
trap 'kill "${PORTFWD_PID}" 2>/dev/null || true; rm -f "${COSIGN_KEY_FILE:-}" 2>/dev/null || true; exit 0' EXIT
for i in $(seq 1 15); do
  if curl -sk -m 2 "https://localhost:${LOCAL_REGISTRY_PORT}/v2/" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -sk -m 2 "https://localhost:${LOCAL_REGISTRY_PORT}/v2/" >/dev/null 2>&1 || fail "Could not port-forward to registry-service."

# Registry credentials for pushing the demo task bundle (extracted from the
# cluster's registry client secret — nothing hardcoded)
say "Extracting in-cluster registry credentials..."
REGISTRY_AUTH_JSON=$(kubectl get secret internal-registry-client-auth -n kind-registry \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
REGISTRY_USER=$(echo "${REGISTRY_AUTH_JSON}" | python3 -c "import sys,json,base64; d=json.load(sys.stdin)['auths']['${BUNDLE_REF_HOST}']['auth']; print(base64.b64decode(d).decode().split(':',1)[0])")
REGISTRY_PASS=$(echo "${REGISTRY_AUTH_JSON}" | python3 -c "import sys,json,base64; d=json.load(sys.stdin)['auths']['${BUNDLE_REF_HOST}']['auth']; print(base64.b64decode(d).decode().split(':',1)[1])")
[ -n "${REGISTRY_USER}" ] || fail "Could not extract registry credentials."

# ---------------------------------------------------------------- 1. deploy Vault
say "Deploying Vault (dev mode) with SPIRE-backed JWT auth..."
helm upgrade --install "${VAULT_RELEASE}" "${REPO_DIR}/charts/vault-legacy-exchange" \
  -n "${VAULT_NS}" --create-namespace >/dev/null

kubectl rollout status deployment/vault-legacy-exchange -n "${VAULT_NS}" --timeout=120s >/dev/null
# The config job is a helm hook that self-deletes on success (hook-succeeded),
# so on re-runs it may already be gone — that means it already succeeded.
if kubectl get job/vault-legacy-config -n "${VAULT_NS}" >/dev/null 2>&1; then
  kubectl wait --for=condition=complete job/vault-legacy-config -n "${VAULT_NS}" --timeout=180s
fi
note "Vault is up: JWT auth -> SPIRE OIDC discovery, role '${VAULT_ROLE}' bound to"
note "  spiffe://konflux-ci.dev/trusted/kind-konflux/default/trivy-sbom-scan"

# ---------------------------------------------------------------- 2. build task bundle
# The positive case must run a digest-pinned, signed catalog task (that is
# what admission classifies as 'prod', minting a trusted/... SPIFFE ID).
# The catalog trivy-sbom-scan hardcodes its JWT audience, so we push this
# demo variant of the same task with a parameterized audience, and sign it
# with the platform demo catalog key.
say "Publishing demo task bundle ${BUNDLE_REF} (idempotent)..."
BUNDLE_PUSH_OUT=$(tkn bundle push \
  --remote-skip-tls \
  --remote-username "${REGISTRY_USER}" \
  --remote-password "${REGISTRY_PASS}" \
  "${BUNDLE_HOST}/${BUNDLE_REPO}:${BUNDLE_TAG}" \
  -f "${BUNDLE_TASK_YAML}" 2>&1) || { echo "${BUNDLE_PUSH_OUT}"; fail "tkn bundle push failed"; }
BUNDLE_DIGEST=$(echo "${BUNDLE_PUSH_OUT}" | grep -o 'sha256:[a-f0-9]*' | head -1)
[ -n "${BUNDLE_DIGEST}" ] || { echo "${BUNDLE_PUSH_OUT}"; fail "Could not resolve pushed bundle digest."; }
note "Bundle pushed: ${BUNDLE_REF}@${BUNDLE_DIGEST}"

say "Signing the bundle with the demo catalog key..."
COSIGN_KEY_FILE=$(mktemp /tmp/vault-demo-cosign.XXXXXX)
kubectl get secret demo-signing-key -n kind-registry -o jsonpath='{.data.cosign\.key}' | base64 -d > "${COSIGN_KEY_FILE}"
chmod 600 "${COSIGN_KEY_FILE}"

# Key-based signing (the same pattern the platform uses for the catalog key,
# secret demo-signing-key in kind-registry — see verify-bundle-signatures'
# 'demo-catalog-key' attestor). cosign v3 skips the Rekor transparency log
# for key-based signatures by default (no --tlog-upload flag needed), which
# matches the demo registry: no Rekor, and the admission policy verifies the
# key-based signature with insecureIgnoreTlog.

# cosign reads registry credentials from the docker config; point it at a
# throwaway one so the user's ~/.docker/config.json is never touched.
COSIGN_DOCKER_CONFIG_DIR=$(mktemp -d /tmp/vault-demo-docker.XXXXXX)
python3 - "$REGISTRY_USER" "$REGISTRY_PASS" "$BUNDLE_HOST" "${COSIGN_DOCKER_CONFIG_DIR}/config.json" << 'PYEOF'
import base64, json, sys
user, pw, host, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
json.dump({"auths": {host: {"auth": base64.b64encode(f"{user}:{pw}".encode()).decode()}}},
          open(out, "w"))
PYEOF

DOCKER_CONFIG="${COSIGN_DOCKER_CONFIG_DIR}" COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign sign \
  --key "${COSIGN_KEY_FILE}" \
  --allow-insecure-registry \
  "${BUNDLE_HOST}/${BUNDLE_REPO}@${BUNDLE_DIGEST}" >/dev/null
note "Bundle signed (key-based cosign signature with the demo catalog key)."
rm -rf "${COSIGN_DOCKER_CONFIG_DIR}"

# ---------------------------------------------------------------- 3. positive case
say "POSITIVE CASE: trusted scanner task exchanges its JWT-SVID for the legacy credential"
kubectl delete taskrun demo-vault-scanner-exchange -n "${TENANT_NS}" --wait=true >/dev/null 2>&1 || true
cat << EOF | kubectl apply -f - >/dev/null
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-vault-scanner-exchange
  namespace: ${TENANT_NS}
  labels:
    appstudio.openshift.io/application: demo-app
    appstudio.openshift.io/component: demo-app
    app.kubernetes.io/part-of: kubecon-demo
spec:
  params:
  - name: jwt-audience
    value: "${JWT_AUDIENCE}"
  taskRef:
    resolver: bundles
    params:
    - name: bundle
      value: ${BUNDLE_REF}@${BUNDLE_DIGEST}
    - name: name
      value: trivy-sbom-scan
    - name: kind
      value: task
EOF

kubectl wait --for=condition=Succeeded taskrun/demo-vault-scanner-exchange -n "${TENANT_NS}" --timeout=300s

SCANNER_JWT=$(kubectl logs demo-vault-scanner-exchange-pod -n "${TENANT_NS}" -c step-fetch-jwt \
  | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['svids'][0]['svid'])")
note "Scanner JWT-SVID subject: $(jwt_claim "${SCANNER_JWT}" sub)"
note "Scanner JWT-SVID audience: $(jwt_claim "${SCANNER_JWT}" aud)"

# (a) log in to Vault: JWT-SVID -> short-lived Vault token
kubectl delete pod test-vault-login -n "${TENANT_NS}" --wait=true >/dev/null 2>&1 || true
kubectl run test-vault-login -n "${TENANT_NS}" --restart=Never --image=curlimages/curl:latest -- \
  curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"role\": \"${VAULT_ROLE}\", \"jwt\": \"${SCANNER_JWT}\"}" \
  "${VAULT_URL}/v1/auth/jwt/login" >/dev/null
kubectl wait --for=condition=Ready pod/test-vault-login -n "${TENANT_NS}" --timeout=60s >/dev/null 2>&1 || true
for i in $(seq 1 20); do
  kubectl logs test-vault-login -n "${TENANT_NS}" > /tmp/vault-login.json 2>/dev/null || true
  if grep -q . /tmp/vault-login.json 2>/dev/null; then break; fi
  sleep 2
done
VAULT_TOKEN=$(python3 -c "import json; d=json.load(open('/tmp/vault-login.json')); print(d['auth']['client_token'])" 2>/dev/null || true)
if [ -z "${VAULT_TOKEN}" ]; then
  echo "Login response:"; cat /tmp/vault-login.json; echo
  fail "Vault login failed for the trusted scanner identity."
fi
note "Vault login OK: minted a token with policy 'cve-feed-reader' (ttl 5m)."

# (b) read the legacy static credential
kubectl delete pod test-vault-read -n "${TENANT_NS}" --wait=true >/dev/null 2>&1 || true
kubectl run test-vault-read -n "${TENANT_NS}" --restart=Never --image=curlimages/curl:latest -- \
  curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_URL}/v1/secret/data/legacy-api" >/dev/null
for i in $(seq 1 20); do
  kubectl logs test-vault-read -n "${TENANT_NS}" > /tmp/vault-read.json 2>/dev/null || true
  if grep -q . /tmp/vault-read.json 2>/dev/null; then break; fi
  sleep 2
done
if ! python3 -c "import json; json.load(open('/tmp/vault-read.json'))['data']['data']['api_token']" 2>/dev/null; then
  echo "Read response:"; cat /tmp/vault-read.json; echo
  fail "Vault secret read failed for the trusted scanner identity."
fi
LEGACY_TOKEN=$(python3 -c "import json; print(json.load(open('/tmp/vault-read.json'))['data']['data']['api_token'])")
note "Secret read OK: legacy-api api_token = ${LEGACY_TOKEN}"
note "The task can now authenticate to the legacy service (e.g. Pulp content"
note "repository behind static API tokens) with zero pre-shared secrets."
demo_cleanup pod test-vault-login "${TENANT_NS}"
demo_cleanup pod test-vault-read "${TENANT_NS}"
demo_cleanup taskrun demo-vault-scanner-exchange "${TENANT_NS}"

# ---------------------------------------------------------------- 4. negative case
say "NEGATIVE CASE: dev-tier task attempts the same exchange"
kubectl delete taskrun demo-vault-dev-attempt -n "${TENANT_NS}" --wait=true >/dev/null 2>&1 || true
cat << 'EOF' | kubectl apply -f - >/dev/null
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-vault-dev-attempt
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: demo-app
    appstudio.openshift.io/component: demo-app
    tekton.dev/task: dev-experiment
    app.kubernetes.io/part-of: kubecon-demo
spec:
  taskSpec:
    stepTemplate:
      volumeMounts:
      - mountPath: /spiffe-workload-api
        name: spiffe-workload-api
        readOnly: true
    steps:
    - name: wait-spire
      image: cgr.dev/chainguard/busybox@sha256:19f02276bf8dbdd62f069b922f10c65262cc34b710eea26ff928129a736be791
      command:
      - sleep
      - '5'
    - name: fetch-jwt
      image: ghcr.io/spiffe/spire-agent:1.15.3
      command:
      - /opt/spire/bin/spire-agent
      - api
      - fetch
      - jwt
      - -audience
      - vault
      - -socketPath
      - /spiffe-workload-api/spire-agent.sock
      - -output
      - json
    volumes:
    - csi:
        driver: csi.spiffe.io
        readOnly: true
      name: spiffe-workload-api
EOF

# Inline taskSpec => admission classifies 'dev' (not a pinned catalog bundle)
kubectl wait --for=condition=Succeeded taskrun/demo-vault-dev-attempt -n "${TENANT_NS}" --timeout=300s

DEV_JWT=$(kubectl logs demo-vault-dev-attempt-pod -n "${TENANT_NS}" -c step-fetch-jwt \
  | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['svids'][0]['svid'])")
note "Dev task JWT-SVID subject: $(jwt_claim "${DEV_JWT}" sub)"

kubectl delete pod test-vault-dev-login -n "${TENANT_NS}" --wait=true >/dev/null 2>&1 || true
kubectl run test-vault-dev-login -n "${TENANT_NS}" --restart=Never --image=curlimages/curl:latest -- \
  curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"role\": \"${VAULT_ROLE}\", \"jwt\": \"${DEV_JWT}\"}" \
  "${VAULT_URL}/v1/auth/jwt/login" >/dev/null
for i in $(seq 1 20); do
  kubectl logs test-vault-dev-login -n "${TENANT_NS}" > /tmp/vault-dev-login.json 2>/dev/null || true
  if grep -q . /tmp/vault-dev-login.json 2>/dev/null; then break; fi
  sleep 2
done

echo "    Vault response to the dev-tier login attempt:"
sed 's/^/      /' /tmp/vault-dev-login.json; echo

if python3 -c "import json; json.load(open('/tmp/vault-dev-login.json'))['auth']" 2>/dev/null; then
  fail "UNEXPECTED: the dev-tier identity was granted a Vault token!"
fi
note "Vault denied the login: the JWT subject does not match the role's"
note "  bound_subject (spiffe://konflux-ci.dev/trusted/...). The dev-tier task"
note "  cannot obtain the legacy credential."
demo_cleanup pod test-vault-dev-login "${TENANT_NS}"
demo_cleanup taskrun demo-vault-dev-attempt "${TENANT_NS}"

say "Demo complete. Vault remains deployed (${VAULT_NS}/${VAULT_RELEASE});"
say "re-run with --clean to remove it."

exit 0
