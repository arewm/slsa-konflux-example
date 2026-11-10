#!/usr/bin/env bash
# Vault legacy token-exchange setup (Pattern 2 extension).
#
# Shared by setup-demo.sh (primes the infra so Act 3 Part D only runs the
# live exchange) and vault-exchange-demo.sh (standalone flow). The caller
# must have sourced demo/kubeconfig.sh and have helm on PATH.
#
# What "primed" means:
#   - the vault-legacy Helm release is deployed with SPIRE-backed JWT auth
#     (role 'scanner' bound to the scanner task's SPIFFE ID)
#   - the trivy-sbom-scan vault variant bundle is pushed to the in-cluster
#     registry and signed with the demo catalog key (so admission
#     classifies it 'prod' and SPIRE mints a trusted/... identity)
#   - the digest-pinned bundle ref is recorded in
#     demo/manifests/vault-bundle-ref for run-demo.sh Act 3 Part D

VAULT_LIB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
VAULT_REPO_DIR="${VAULT_REPO_DIR:-$( cd "${VAULT_LIB_DIR}/.." >/dev/null 2>&1 && pwd )}"

VAULT_NS="services"
VAULT_RELEASE="vault-legacy"
VAULT_URL="http://vault-legacy-exchange.${VAULT_NS}.svc.cluster.local:8200"
VAULT_ROLE="scanner"
VAULT_JWT_AUDIENCE="vault"
VAULT_BUNDLE_HOST_PORT=30010
VAULT_BUNDLE_REF_HOST="registry-service.kind-registry"
VAULT_BUNDLE_REPO="tekton-catalog/trivy-sbom-scan"
VAULT_BUNDLE_TAG="0.1-vault-demo"
VAULT_BUNDLE_REF="${VAULT_BUNDLE_REF_HOST}/${VAULT_BUNDLE_REPO}:${VAULT_BUNDLE_TAG}"
VAULT_BUNDLE_REF_FILE="${VAULT_LIB_DIR}/manifests/vault-bundle-ref"

vault_deploy() {
  helm upgrade --install "${VAULT_RELEASE}" "${VAULT_REPO_DIR}/charts/vault-legacy-exchange" \
    -n "${VAULT_NS}" --create-namespace >/dev/null
  kubectl rollout status deployment/vault-legacy-exchange -n "${VAULT_NS}" --timeout=120s >/dev/null
  # The config job is a helm hook that self-deletes on success
  # (hook-succeeded), so on re-runs it may already be gone — which means it
  # already succeeded.
  if kubectl get job/vault-legacy-config -n "${VAULT_NS}" >/dev/null 2>&1; then
    kubectl wait --for=condition=complete job/vault-legacy-config -n "${VAULT_NS}" --timeout=180s
  fi
}

vault_publish_bundle() {
  # tkn + cosign are required for the push/sign; fetch into demo/.tools
  # with permission when missing (see tools.sh).
  # shellcheck disable=SC1091
  source "${VAULT_LIB_DIR}/tools.sh"
  ensure_demo_tools tkn cosign || return 1

  # Port-forward the in-cluster registry (picks a free local port).
  local port="${VAULT_BUNDLE_HOST_PORT}"
  while lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; do
    port=$((port + 1))
  done
  local host="localhost:${port}"
  kubectl port-forward -n kind-registry svc/registry-service "${port}:443" >/dev/null 2>&1 &
  local pf_pid=$!
  trap 'kill "${pf_pid}" 2>/dev/null || true' RETURN
  local i
  for i in $(seq 1 15); do
    curl -sk -m 2 "https://${host}/v2/" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -sk -m 2 "https://${host}/v2/" >/dev/null 2>&1 || { echo "Could not port-forward to registry-service." >&2; return 1; }

  # Registry credentials from the cluster (nothing hardcoded).
  local registry_auth_json registry_user registry_pass
  registry_auth_json=$(kubectl get secret internal-registry-client-auth -n kind-registry \
    -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
  registry_user=$(echo "${registry_auth_json}" | python3 -c "import sys,json,base64; d=json.load(sys.stdin)['auths']['${VAULT_BUNDLE_REF_HOST}']['auth']; print(base64.b64decode(d).decode().split(':',1)[0])")
  registry_pass=$(echo "${registry_auth_json}" | python3 -c "import sys,json,base64; d=json.load(sys.stdin)['auths']['${VAULT_BUNDLE_REF_HOST}']['auth']; print(base64.b64decode(d).decode().split(':',1)[1])")
  [ -n "${registry_user}" ] || { echo "Could not extract registry credentials." >&2; return 1; }

  # Push (idempotent: same tag is overwritten).
  local push_out bundle_digest
  push_out=$(tkn bundle push \
    --remote-skip-tls \
    --remote-username "${registry_user}" \
    --remote-password "${registry_pass}" \
    "${host}/${VAULT_BUNDLE_REPO}:${VAULT_BUNDLE_TAG}" \
    -f "${VAULT_LIB_DIR}/manifests/trivy-sbom-scan-vault.yaml" 2>&1) || { echo "${push_out}" >&2; return 1; }
  bundle_digest=$(echo "${push_out}" | grep -o 'sha256:[a-f0-9]*' | head -1)
  [ -n "${bundle_digest}" ] || { echo "Could not resolve pushed bundle digest." >&2; return 1; }

  # Sign with the demo catalog key (the same key verify-bundle-signatures
  # verifies; admission therefore classifies this bundle 'prod'). cosign
  # reads registry creds from DOCKER_CONFIG — point it at a throwaway dir
  # so the user's ~/.docker/config.json is never touched.
  local cosign_key_file docker_config_dir
  cosign_key_file=$(mktemp /tmp/vault-demo-cosign.XXXXXX)
  kubectl get secret demo-signing-key -n kind-registry -o jsonpath='{.data.cosign\.key}' | base64 -d > "${cosign_key_file}"
  chmod 600 "${cosign_key_file}"
  docker_config_dir=$(mktemp -d /tmp/vault-demo-docker.XXXXXX)
  python3 - "${registry_user}" "${registry_pass}" "${host}" "${docker_config_dir}/config.json" <<'PYEOF'
import base64, json, sys
user, pw, host, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
json.dump({"auths": {host: {"auth": base64.b64encode(f"{user}:{pw}".encode()).decode()}}},
          open(out, "w"))
PYEOF
  DOCKER_CONFIG="${docker_config_dir}" COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign sign \
    --key "${cosign_key_file}" \
    --allow-insecure-registry \
    "${host}/${VAULT_BUNDLE_REPO}@${bundle_digest}" >/dev/null || {
      rm -rf "${docker_config_dir}" "${cosign_key_file}"; return 1; }
  rm -rf "${docker_config_dir}" "${cosign_key_file}"

  # Record the digest-pinned ref for run-demo.sh Act 3 Part D.
  cat > "${VAULT_BUNDLE_REF_FILE}" <<EOF
# Generated by demo/vault-setup-lib.sh (vault_publish_bundle). Do not edit.
VAULT_TASK_BUNDLE="${VAULT_BUNDLE_REF}@${bundle_digest}"
EOF
}

vault_setup_infra() {
  vault_deploy || return 1
  vault_publish_bundle || return 1
}
