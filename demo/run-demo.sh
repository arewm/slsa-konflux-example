#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Discover the Konflux demo cluster kubeconfig (no-op if already targeted).
# shellcheck disable=SC1091
source "${DIR}/kubeconfig.sh"
TYPE_SPEED=30
source "${DIR}/demo-magic.sh"

DEMO_PROMPT="${CYAN}kubecon@konflux-ci${COLOR_RESET}:${BLUE}~/demo${COLOR_RESET}$ "

# Act 2 catalog bundle refs. The digests are content-addressed but NOT stable
# across tkn versions, so they are recorded per cluster by
# demo/push-demo-catalog-bundles.sh (called from setup-demo.sh) instead of
# being hardcoded here.
CATALOG_BUNDLE_REF_FILE="${DIR}/manifests/catalog-bundle-ref"
if [ -f "${CATALOG_BUNDLE_REF_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${CATALOG_BUNDLE_REF_FILE}"
fi

# Parse command-line arguments
SELECTED_ACT="all"
DEMO_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --act|-a)
      SELECTED_ACT="$2"
      shift 2
      ;;
    --act=*)
      SELECTED_ACT="${1#*=}"
      shift 1
      ;;
    *)
      DEMO_ARGS+=("$1")
      shift 1
      ;;
  esac
done

should_run_act() {
  local target="$1"
  if [[ "$SELECTED_ACT" == "all" || "$SELECTED_ACT" == "0" ]]; then
    return 0
  fi
  [[ "$SELECTED_ACT" == "$target" ]]
}

# Clear between acts ONLY when running the full arc (--act all/0). Per-act
# terminals (the slide iframes) keep their scrollback so the session can be
# walked through during post-presentation Q&A.
clear_between_acts() {
  if [[ "$SELECTED_ACT" == "all" || "$SELECTED_ACT" == "0" ]]; then
    clear
  fi
}

finish_act() {
  local act="$1"
  if [[ "$SELECTED_ACT" != "all" && "$SELECTED_ACT" != "0" ]]; then
    printf "\033]0;ACT_${act}_COMPLETE\007"
    exit 0
  fi
}

# Demo lifecycle settings
# Set DEMO_CLEANUP=true to delete resources immediately after each scene;
# by default (false), resources are left intact on the cluster for UI inspection and post-demo auditing.
DEMO_CLEANUP="${DEMO_CLEANUP:-false}"

# Retry a kubectl create on transient admission-webhook timeouts (Kyverno
# signature verification can exceed the webhook timeout on a cold cache).
kubectl_create_retry() {
  local attempt payload out err errfile
  payload=$(cat)  # buffer stdin: retries cannot re-read a pipe
  errfile=$(mktemp)
  for attempt in 1 2 3; do
    # stdout (e.g. -o jsonpath='{.metadata.name}' for generateName
    # resources) is captured and re-emitted on success; stderr goes to a
    # temp file so it can be inspected for the denial fast-path below.
    if out=$(printf '%s' "${payload}" | kubectl create -f - "$@" 2>"${errfile}"); then
      printf '%s\n' "${out}"
      rm -f "${errfile}"
      return 0
    fi
    err=$(cat "${errfile}")
    # Retrying only makes sense for transient webhook failures (cold-cache
    # Kyverno signature verification exceeding the webhook timeout). An
    # admission DENIAL is the expected demo outcome in many scenes —
    # surface it immediately instead of burning 60s on pointless retries.
    if printf '%s' "${err}" | grep -q "denied the request"; then
      printf '%s\n' "${err}" >&2
      rm -f "${errfile}"
      return 1
    fi
    printf '%s\n' "${err}" >&2
    echo "    [retry ${attempt}/3] admission webhook slow; waiting 20s..."
    sleep 20
  done
  rm -f "${errfile}"
  return 1
}

demo_cleanup() {
  if [[ "${DEMO_CLEANUP}" == "true" ]]; then
    kubectl delete "$@" --wait=true >/dev/null 2>&1 || true
  fi
}

clear
echo ""
echo -e "${PURPLE}╔═════════════════════════════════════════════════════════════════════════════════╗${COLOR_RESET}"
echo -e "${PURPLE}║                                                                                 ║${COLOR_RESET}"
echo -e "${PURPLE}║      KubeCon NA 2026: \"Your CI's Mistaken Identity\"                             ║${COLOR_RESET}"
if [[ "$SELECTED_ACT" != "all" && "$SELECTED_ACT" != "0" ]]; then
  case "$SELECTED_ACT" in
    1) ACT_TITLE="Act 1: The Breakdown (Ambient Authority & Secret Hijack)" ;;
    2) ACT_TITLE="Act 2: Task Admission & Cryptographic Identity (Kyverno & SPIRE)" ;;
    3) ACT_TITLE="Act 3: Same-Namespace API Gating (OCI Push Gating & Secretless Services)" ;;
    4) ACT_TITLE="Act 4: Managed Release Boundary (Dual-Gated Authority)" ;;
    *) ACT_TITLE="Act ${SELECTED_ACT}" ;;
  esac
  printf "${PURPLE}║      %-75s║${COLOR_RESET}\n" "$ACT_TITLE"
else
  echo -e "${PURPLE}║      Live Demonstration Arc: Secretless Tasks, Gated OCI & Dual Release         ║${COLOR_RESET}"
fi
echo -e "${PURPLE}║                                                                                 ║${COLOR_RESET}"
echo -e "${PURPLE}╚═════════════════════════════════════════════════════════════════════════════════╝${COLOR_RESET}"
echo ""
echo -e "Press ${GREEN}[ENTER]${COLOR_RESET} to advance through each step."
echo ""
wait

# Ensure demo environment is primed
if ! kubectl get application demo-app -n default-tenant >/dev/null 2>&1 || ! kubectl get deployment cve-database-service -n services >/dev/null 2>&1; then
  echo "   [Notice] Demo prerequisites missing. Running setup-demo.sh..."
  "${DIR}/setup-demo.sh" >/dev/null 2>&1
fi

if should_run_act 0; then
# ==============================================================================
# ACT 0: PRE-FLIGHT VERIFICATION & IDEMPOTENT BASELINE
# ==============================================================================
p "# =================================================================="
p "# PRE-FLIGHT: Verifying Platform Prerequisites"
p "# =================================================================="
p "# Before starting, verify Kyverno admission policies, SPIRE identity server, and OIDC discovery:"

# Fast reset of any leftover run resources to ensure repeatable runs
"${DIR}/cleanup-demo.sh" >/dev/null 2>&1

echo -e "   ${CYAN}Konflux UI Application View:${COLOR_RESET} https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app"
echo ""
pe "kubectl get clusterpolicies,imagevalidatingpolicies 2>/dev/null || kubectl get clusterpolicies"
pe "kubectl get pods -n spire -l app.kubernetes.io/instance=spire"
pe "kubectl get pods,services -n kind-registry -l app=registry-oidc"
pe "kubectl get pods,services -n services -l app=cve-database-service"

wait
clear
fi

# ==============================================================================
# ACT 1: THE BREAKDOWN (AMBIENT AUTHORITY & SECRET HIJACK)
# ==============================================================================
if should_run_act 1; then
p "# =================================================================="
p "# ACT 1: The Breakdown (Ambient Authority & Secret Hijack)"
p "# =================================================================="
p "# In Kubernetes, the 'default' keyless workload identity is projected ServiceAccount tokens:"
p "#   iss: https://kubernetes.default.svc"
p "#   sub: system:serviceaccount:<namespace>:<serviceaccount>"
p "#"
p "# Let's inspect what identity a task receives under this standard pattern:"
kubectl delete taskrun demo-sa-token-inspection -n default-tenant --wait=true >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl_create_retry
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-sa-token-inspection
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: demo-app
    appstudio.openshift.io/component: demo-app
    app.kubernetes.io/part-of: kubecon-demo
spec:
  taskSpec:
    stepTemplate:
      volumeMounts:
      - mountPath: /var/run/secrets/tokens
        name: sa-token
    steps:
    - name: inspect-sa-token
      image: curlimages/curl:latest
      command:
      - /bin/sh
      - -c
      - |
        TOKEN=\$(cat /var/run/secrets/tokens/sa-token)
        echo \"\$TOKEN\"
    volumes:
    - name: sa-token
      projected:
        sources:
        - serviceAccountToken:
            audience: https://registry-oidc.kind-registry:5000
            expirationSeconds: 3600
            path: sa-token
EOF"

kubectl wait --for=condition=Succeeded taskrun/demo-sa-token-inspection -n default-tenant --timeout=30s >/dev/null 2>&1 || true
pe "kubectl logs demo-sa-token-inspection-pod -n default-tenant -c step-inspect-sa-token | python3 -c \"
import sys, json, base64
raw = sys.stdin.read().strip()
for line in raw.splitlines():
    if line.startswith('ey'):
        p = line.split('.')[1]
        p += '=' * (-len(p)%4)
        claims = json.loads(base64.urlsafe_b64decode(p).decode())
        print('Projected SA Identity (Default Keyless):')
        print('  Issuer (iss):', claims.get('iss'))
        print('  Subject (sub):', claims.get('sub'))
        print('  Namespace:    ', claims.get('kubernetes.io', {}).get('namespace'))
        print('  ServiceAccount:', claims.get('kubernetes.io', {}).get('serviceaccount', {}).get('name'))
\""
demo_cleanup taskrun demo-sa-token-inspection -n default-tenant

p "# Notice the problem: The identity is coarse-grained to the ServiceAccount (default-tenant:default)."
p "# EVERY task running in this namespace shares this exact same identity and ambient credentials!"
wait

p "# THE ATTACK:"
p "# A rogue task running in the same namespace under the same ServiceAccount abuses regcred"
p "# to overwrite production image tag 'slsa-e2e-test:latest' with a malicious backdoor!"
kubectl delete pod rogue-ambient-push -n default-tenant --wait=true >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl_create_retry
apiVersion: v1
kind: Pod
metadata:
  name: rogue-ambient-push
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: demo-app
    appstudio.openshift.io/component: demo-app
    app.kubernetes.io/part-of: kubecon-demo
spec:
  containers:
  - name: attacker
    image: quay.io/konflux-ci/task-runner:1.3.0@sha256:3f007bf58821885f8aa30d72c84fcbfcb14babc6521eaf6ac1bc4f8c078d9e58
    command:
    - /bin/bash
    - -c
    - |
      set -e
      export SSL_CERT_DIR=/tekton-custom-certs
      mkdir -p ~/.docker
      cp /tekton/creds-secrets/regcred-internal-registry/.dockerconfigjson ~/.docker/config.json
      
      echo 'MALICIOUS BACKDOOR EXECUTED' > /tmp/payload.txt
      cd /tmp
      oras push --insecure registry-service.kind-registry/slsa-e2e-test:latest \
        --artifact-type application/vnd.konflux.test \
        payload.txt:application/text
      
      oras pull --insecure registry-service.kind-registry/slsa-e2e-test:latest -o /tmp/pulled
      echo \"[VERIFICATION] Tag contents: \$(cat /tmp/pulled/payload.txt)\"
    volumeMounts:
    - mountPath: /tekton/creds-secrets/regcred-internal-registry
      name: regcred
    - mountPath: /tekton-custom-certs/ca-bundle.crt
      name: trusted-ca
      subPath: ca-bundle.crt
  volumes:
  - name: regcred
    secret:
      secretName: regcred-internal-registry
  - name: trusted-ca
    configMap:
      items:
      - key: ca-bundle.crt
        path: ca-bundle.crt
      name: trusted-ca
  restartPolicy: Never
EOF"

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/rogue-ambient-push -n default-tenant --timeout=180s >/dev/null 2>&1 || true
for i in $(seq 1 30); do kubectl logs rogue-ambient-push -n default-tenant >/dev/null 2>&1 || { sleep 5; continue; }; break; done
pe "kubectl logs rogue-ambient-push -n default-tenant | grep -A 5 \"VERIFICATION\""
demo_cleanup pod rogue-ambient-push -n default-tenant

p "# The tag was silently overwritten because traditional SA credentials provide ambient authority!"
wait

clear_between_acts
finish_act 1
fi

# ==============================================================================
# ACT 2: TASK ADMISSION & CRYPTOGRAPHIC IDENTITY (KYVERNO & SPIRE)
# ==============================================================================
if should_run_act 2; then
# Act 2 needs the demo catalog bundles (pushed+signed per cluster by
# demo/push-demo-catalog-bundles.sh via setup-demo.sh).
if [ -z "${CATALOG_TASK_BUNDLE:-}" ] || [ -z "${UNSIGNED_TASK_BUNDLE:-}" ]; then
  echo "Error: ${CATALOG_BUNDLE_REF_FILE} is missing CATALOG_TASK_BUNDLE/UNSIGNED_TASK_BUNDLE."
  echo "Run demo/push-demo-catalog-bundles.sh (or demo/setup-demo.sh) first."
  exit 1
fi
# shellcheck disable=SC1090
. "${CATALOG_BUNDLE_REF_FILE}"
p "# =================================================================="
p "# ACT 2: Task Admission & Cryptographic Identity (Kyverno & SPIRE)"
p "# =================================================================="
p "# PART 1 — THE RULES: meet the admission policies before we test them."
p "# Classification gate: prod is EARNED, not claimed. The trustedProd variable"
p "# recomputes it from the TaskRun's own bundle reference alone — digest-pinned"
p "# and from the trusted catalog registry. Namespace-agnostic by design:"
pe "kubectl get mutatingpolicy classify-taskrun -o yaml 2>/dev/null | yq '.spec.variables[] | select(.name == \"trustedProd\") | .expression'"
p ""
p "# Only then do the mutations act on it — a 'dev' floor for the unlabeled,"
p "# and the prod upgrade when trustedProd holds:"
pe "kubectl get mutatingpolicy classify-taskrun -o yaml 2>/dev/null | yq '.spec.mutations'"
p ""
p "# And the path pattern alone is not trust. The ImageValidatingPolicy scopes"
p "# itself to exactly that pattern — out-of-scope bundles never reach these"
p "# checks (and can never be prod either, since trustedProd demands the same"
p "# pattern):"
pe "kubectl get imagevalidatingpolicy verify-bundle-signatures -o yaml 2>/dev/null | yq '.spec.matchConditions[].name'"
p ""
p "# For every bundle IN scope, two fail-closed validations — immutable digest"
p "# pin, and a valid platform Cosign signature:"
pe "kubectl get imagevalidatingpolicy verify-bundle-signatures -o yaml 2>/dev/null | yq '.spec.validations'"
p ""
p "# One more guard: labels cannot be forged at the Pod level either —"
p "# trusted-task-role on a Pod requires a TaskRun owner reference:"
pe "kubectl get validatingpolicy prevent-pod-label-spoofing -o yaml 2>/dev/null | yq '.spec.validations'"
p ""
p "# And the last link: the admission rules decide the label, and SPIRE turns"
p "# the verified label into a cryptographic identity — production SVIDs are"
p "# minted only for pods carrying the Kyverno-stamped prod label:"
pe "kubectl get clusterspiffeid konflux-trusted-prod -o yaml 2>/dev/null | yq '.spec.podSelector'"

wait
p ""
p "# ═══════════════════════════════════════════════════════════════════════════"
p ""

p "# PART 2 — THE TESTS: watch those rules interact under attack."
p ""
p "# TEST 1 — Can a rogue Pod simply claim prod by setting the label itself?"
kubectl delete pod attacker-label-spoof -n default-tenant --wait=true >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl_create_retry
apiVersion: v1
kind: Pod
metadata:
  name: attacker-label-spoof
  namespace: default-tenant
  labels:
    trusted-task-role: prod
spec:
  containers:
  - name: rogue
    image: alpine:3.20
    command: [\"sleep\", \"30\"]
EOF" || true
p "Admission denied: prevent-pod-label-spoofing denied the request (trusted-task-role requires a TaskRun owner reference)."
demo_cleanup pod attacker-label-spoof -n default-tenant

p "# TEST 2 — Submit an untrusted / inline TaskRun (not pinned or catalog-signed):"
p "# Expected: Kyverno admits the task but restricts it to the unprivileged 'dev' role."
UNTRUSTED_TR=$(cat << 'EOF' | kubectl_create_retry -o jsonpath='{.metadata.name}'
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  generateName: demo-untrusted-run-
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: demo-app
    appstudio.openshift.io/component: demo-app
    app.kubernetes.io/part-of: kubecon-demo
spec:
  taskSpec:
    steps:
    - name: echo
      image: alpine:latest
      script: echo 'Untrusted inline code execution'
EOF
)

pe "kubectl wait --for=condition=Succeeded taskrun/${UNTRUSTED_TR} -n default-tenant --timeout=30s"

p "# Inspect the labels Kyverno stamped on the TaskRun:"
pe "kubectl get taskrun ${UNTRUSTED_TR} -n default-tenant --show-labels"

p "# Verify Tekton propagates the Kyverno-verified label to the execution Pod:"
pe "kubectl get pod -n default-tenant -l tekton.dev/taskRun=${UNTRUSTED_TR} --show-labels"

p "# What workload identity does SPIRE mint for this untrusted task?"
POD_UID=$(kubectl get pod -n default-tenant -l tekton.dev/taskRun=${UNTRUSTED_TR} -o jsonpath='{.items[0].metadata.uid}')
pe "kubectl exec -n spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show -selector \"k8s:pod-uid:${POD_UID}\""
p "# Note the identity segment: spiffe://konflux-ci.dev/DEV/... — SPIRE minted"
p "# the unprivileged dev identity, scoped to exactly this task. No prod"
p "# authority, no ambient secrets — just a narrowly-scoped dev SVID."

demo_cleanup taskrun "${UNTRUSTED_TR}" -n default-tenant

wait

p "# TEST 3 — Spoof the trusted catalog: submit an unsigned bundle that claims"
p "# the tekton-catalog/* path. The path is the trust grant, but the signature"
p "# check is mandatory for EVERY bundle on that path — we saw the validations"
p "# in Part 1; now watch them bite. Denied outright, not merely downgraded:"

kubectl delete taskrun attacker-unsigned-task -n default-tenant --wait=true >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl create -f - || true
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: attacker-unsigned-task
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: demo-app
    appstudio.openshift.io/component: demo-app
    app.kubernetes.io/part-of: kubecon-demo
spec:
  taskRef:
    resolver: bundles
    params:
    - name: bundle
      value: ${UNSIGNED_TASK_BUNDLE}
    - name: name
      value: demo-catalog-task
    - name: kind
      value: task
EOF"

p "# Admission denied! Sigstore verification failed: no matching signatures found."
wait
p ""
p "# ═══════════════════════════════════════════════════════════════════════════"
p ""

p "# TEST 4 — Now do it right: a cryptographically signed, digest-pinned catalog bundle:"
p "# Expected: Kyverno verifies the Sigstore bundle signature and promotes the role to 'prod'."
kubectl delete taskrun demo-signed-task -n default-tenant --wait=true >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl_create_retry
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-signed-task
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: demo-app
    appstudio.openshift.io/component: demo-app
    app.kubernetes.io/part-of: kubecon-demo
spec:
  taskRef:
    resolver: bundles
    params:
    - name: bundle
      value: ${CATALOG_TASK_BUNDLE}
    - name: name
      value: demo-catalog-task
    - name: kind
      value: task
EOF"

pe "kubectl wait --for=condition=Succeeded taskrun/demo-signed-task -n default-tenant --timeout=30s"

p "# Inspect the TaskRun labels stamped by Kyverno:"
pe "kubectl get taskrun demo-signed-task -n default-tenant --show-labels"

p "# Inspect the production SVID (SPIFFE Verifiable Identity Document) minted by SPIRE for this Pod:"
SIGNED_POD_UID=$(kubectl get pod -n default-tenant -l tekton.dev/taskRun=demo-signed-task -o jsonpath='{.items[0].metadata.uid}')
pe "kubectl exec -n spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show -selector \"k8s:pod-uid:${SIGNED_POD_UID}\""
p "# And here: spiffe://konflux-ci.dev/TRUSTED/... — earned by the signed,"
p "# digest-pinned bundle. Admission decided the label; SPIRE minted the"
p "# production identity the label authorizes. Trust, end to end."

demo_cleanup taskrun demo-signed-task -n default-tenant
wait
clear_between_acts
p ""
p "# ═══════════════════════════════════════════════════════════════════════════"
p ""

finish_act 2
fi

# ==============================================================================
# ACT 3: SAME-NAMESPACE API GATING (OCI PUSH GATING & SECRETLESS SERVICES)
# ==============================================================================
if should_run_act 3; then
p "# =================================================================="
p "# ACT 3: Same-Namespace API Gating (OCI Push Gating & Secretless Services)"
p "# =================================================================="
p "# THE DEFENSE: Task-Scoped OCI Push Gating with Zot OIDC Bearer Auth"
p "# Zot validates push handshakes against SPIRE OIDC discovery keys (/keys)."
p "# Access control policy strictly restricts writes to the vetted builder role:"
pe "kubectl get configmap zot-oidc-config -n kind-registry -o jsonpath='{.data.config\\.json}' | jq '.http.accessControl.repositories'"

p "# 1. Attack Attempt on Gated Registry:"
p "# A rogue dev task attempts to push to slsa-e2e-test using its SPIFFE JWT-SVID:"
kubectl delete taskrun demo-rogue-push-attempt -n default-tenant --wait=true >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl_create_retry
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-rogue-push-attempt
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: demo-app
    appstudio.openshift.io/component: demo-app
    tekton.dev/task: rogue-attacker-task
    app.kubernetes.io/part-of: kubecon-demo
spec:
  taskSpec:
    stepTemplate:
      volumeMounts:
      - mountPath: /spiffe-workload-api
        name: spiffe-workload-api
        readOnly: true
      - mountPath: /etc/pki/tls/certs/ca-custom-bundle.crt
        name: trusted-ca
        readOnly: true
        subPath: ca-bundle.crt
    steps:
    - name: wait-spire
      image: cgr.dev/chainguard/busybox@sha256:19f02276bf8dbdd62f069b922f10c65262cc34b710eea26ff928129a736be791
      command:
      - sleep
      - '10'
    - name: fetch-jwt
      image: ghcr.io/spiffe/spire-agent:1.15.3
      command:
      - /opt/spire/bin/spire-agent
      - api
      - fetch
      - jwt
      - -audience
      - https://registry-oidc.kind-registry:5000
      - -socketPath
      - /spiffe-workload-api/spire-agent.sock
      - -output
      - json
    volumes:
    - csi:
        driver: csi.spiffe.io
        readOnly: true
      name: spiffe-workload-api
    - configMap:
        items:
        - key: ca-bundle.crt
          path: ca-bundle.crt
        name: trusted-ca
      name: trusted-ca
EOF"

kubectl wait --for=condition=Succeeded taskrun/demo-rogue-push-attempt -n default-tenant --timeout=60s

ROGUE_JWT=$(kubectl logs demo-rogue-push-attempt-pod -n default-tenant -c step-fetch-jwt | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['svids'][0]['svid'])")
p "# Inspect the identity minted for the rogue task:"
pe "python3 -c \"import sys, json, base64; p = '${ROGUE_JWT}'.split('.')[1]; p += '=' * (-len(p)%4); print('Subject:', json.loads(base64.urlsafe_b64decode(p))['sub'])\""

p "# Attempt push handshake to the gated registry with the rogue identity:"
kubectl delete pod test-rogue-push -n default-tenant --wait=true >/dev/null 2>&1 || true
pe "kubectl run test-rogue-push -n default-tenant --restart=Never --image=curlimages/curl:latest -- curl -k -s -i -X POST -H \"Authorization: Bearer ${ROGUE_JWT}\" https://registry-oidc.kind-registry:5000/v2/slsa-e2e-test/blobs/uploads/"
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/test-rogue-push -n default-tenant --timeout=30s >/dev/null 2>&1 || sleep 2
pe "kubectl logs test-rogue-push -n default-tenant | head -n 5"
pe "kubectl logs deployment/registry-oidc -n kind-registry --tail=5 | grep -i \"statusCode\":403 || true"
demo_cleanup pod test-rogue-push -n default-tenant
demo_cleanup taskrun demo-rogue-push-attempt -n default-tenant

p "# HTTP/2 403 Forbidden! The rogue task cannot obtain push authorization."
wait

p "# 2. Legitimate Push on Gated Registry:"
p "# The vetted Builder task bundle (buildah-oci-ta) executes with its trusted production identity:"
kubectl delete taskrun demo-builder-gated-push -n default-tenant --wait=true >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl_create_retry
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-builder-gated-push
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: demo-app
    appstudio.openshift.io/component: demo-app
    app.kubernetes.io/part-of: kubecon-demo
spec:
  taskRef:
    resolver: bundles
    params:
    - name: bundle
      value: ${BUILDAH_TASK_BUNDLE}
    - name: name
      value: buildah-oci-ta
    - name: kind
      value: task
EOF"

kubectl wait --for=condition=Succeeded taskrun/demo-builder-gated-push -n default-tenant --timeout=60s

BUILDER_JWT=$(kubectl logs demo-builder-gated-push-pod -n default-tenant -c step-fetch-jwt | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['svids'][0]['svid'])")
p "# Inspect the identity minted for the vetted builder:"
pe "python3 -c \"import sys, json, base64; p = '${BUILDER_JWT}'.split('.')[1]; p += '=' * (-len(p)%4); print('Subject:', json.loads(base64.urlsafe_b64decode(p))['sub'])\""

p "# Inspect the in-pod push handshake result against the gated registry:"
kubectl delete pod test-builder-push -n default-tenant --wait=true >/dev/null 2>&1 || true
pe "kubectl run test-builder-push -n default-tenant --restart=Never --image=curlimages/curl:latest -- curl -k -s -i -X POST -H \"Authorization: Bearer ${BUILDER_JWT}\" https://registry-oidc.kind-registry:5000/v2/slsa-e2e-test/blobs/uploads/"
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/test-builder-push -n default-tenant --timeout=30s >/dev/null 2>&1 || sleep 2
pe "kubectl logs test-builder-push -n default-tenant | head -n 5"
pe "kubectl logs deployment/registry-oidc -n kind-registry --tail=5 | grep -i \"statusCode\":202 || true"
demo_cleanup pod test-builder-push -n default-tenant
demo_cleanup taskrun demo-builder-gated-push -n default-tenant

p "# HTTP/2 202 Accepted! Push upload session created strictly via Workload Identity."
wait
clear

p "# ------------------------------------------------------------------"
p "# Part B: Portable Secretless Service Access (Token Exchange)"
p "# ------------------------------------------------------------------"
p "# Workload identity isn't just for signing—it eliminates static API tokens across pipelines."
p "# An internal CVE database service is running in namespace 'services'."
p "# It mounts ZERO Kubernetes secrets and validates callers via SPIRE OIDC discovery keys (/keys)."
pe "kubectl get pods,services -n services"

p "# 1. Untrusted Task Attempt:"
p "# A dev task requests a token and attempts to access the CVE feed:"
kubectl delete taskrun demo-untrusted-service-query -n default-tenant --wait=true >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl_create_retry
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-untrusted-service-query
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
      - mountPath: /etc/pki/tls/certs/ca-custom-bundle.crt
        name: trusted-ca
        readOnly: true
        subPath: ca-bundle.crt
    steps:
    - name: wait-spire
      image: cgr.dev/chainguard/busybox@sha256:19f02276bf8dbdd62f069b922f10c65262cc34b710eea26ff928129a736be791
      command:
      - sleep
      - '10'
    - name: fetch-jwt
      image: ghcr.io/spiffe/spire-agent:1.15.3
      command:
      - /opt/spire/bin/spire-agent
      - api
      - fetch
      - jwt
      - -audience
      - https://cve-database.internal
      - -socketPath
      - /spiffe-workload-api/spire-agent.sock
      - -output
      - json
    volumes:
    - csi:
        driver: csi.spiffe.io
        readOnly: true
      name: spiffe-workload-api
    - configMap:
        items:
        - key: ca-bundle.crt
          path: ca-bundle.crt
        name: trusted-ca
      name: trusted-ca
EOF"

kubectl wait --for=condition=Succeeded taskrun/demo-untrusted-service-query -n default-tenant --timeout=60s

UNTRUSTED_SVID=$(kubectl logs demo-untrusted-service-query-pod -n default-tenant -c step-fetch-jwt | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['svids'][0]['svid'])")
kubectl delete pod test-untrusted-client -n default-tenant --wait=true >/dev/null 2>&1 || true
pe "kubectl run test-untrusted-client --namespace=default-tenant --image=curlimages/curl --restart=Never --command -- curl -s -i -H \"Authorization: Bearer ${UNTRUSTED_SVID}\" http://cve-database-service.services.svc.cluster.local:8080/api/v1/vulnerabilities"
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/test-untrusted-client -n default-tenant --timeout=30s >/dev/null 2>&1 || sleep 2
pe "kubectl logs test-untrusted-client -n default-tenant"
pe "kubectl logs deployment/cve-database-service -n services --tail=4"
demo_cleanup pod test-untrusted-client -n default-tenant
demo_cleanup taskrun demo-untrusted-service-query -n default-tenant

p "# HTTP/1.0 403 Forbidden! The untrusted task lacks scanner authorization."
wait
sleep 2

p "# 2. Vetted Scanner Task (trivy-sbom-scan):"
p "# The catalog scanner task presents its audience-scoped SVID (SPIFFE Verifiable" 
p "# Identity Document) to the service:"
kubectl delete taskrun demo-trusted-scanner-query -n default-tenant --wait=true >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl_create_retry
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-trusted-scanner-query
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: demo-app
    appstudio.openshift.io/component: demo-app
    tekton.dev/task: trivy-sbom-scan
    app.kubernetes.io/part-of: kubecon-demo
spec:
  taskRef:
    resolver: bundles
    params:
    - name: bundle
      value: ${TRIVY_TASK_BUNDLE}
    - name: name
      value: trivy-sbom-scan
    - name: kind
      value: task
EOF"

kubectl wait --for=condition=Succeeded taskrun/demo-trusted-scanner-query -n default-tenant --timeout=60s

SCANNER_SVID=$(kubectl logs demo-trusted-scanner-query-pod -n default-tenant -c step-fetch-jwt | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['svids'][0]['svid'])")
kubectl delete pod test-scanner-client -n default-tenant --wait=true >/dev/null 2>&1 || true
pe "kubectl run test-scanner-client --namespace=default-tenant --image=curlimages/curl --restart=Never --command -- curl -s -i -H \"Authorization: Bearer ${SCANNER_SVID}\" http://cve-database-service.services.svc.cluster.local:8080/api/v1/vulnerabilities"
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/test-scanner-client -n default-tenant --timeout=30s >/dev/null 2>&1 || sleep 2
pe "kubectl logs test-scanner-client -n default-tenant"
pe "kubectl logs deployment/cve-database-service -n services --tail=5"
demo_cleanup pod test-scanner-client -n default-tenant
demo_cleanup taskrun demo-trusted-scanner-query -n default-tenant

p "# HTTP/1.0 200 OK! Zero pre-shared secrets, zero credentials mounted in default-tenant."
wait
clear

p "# ------------------------------------------------------------------"
p "# Part C: Separation of Duties Policy Enforcement (Conforma Rego)"
p "# ------------------------------------------------------------------"
p "# 4. Separation of Duties Policy Enforcement (Conforma Rego):"
p "# When tasks sign role-scoped attestations:"
p "#   • Scanner (trivy-sbom-scan) signs CVE reports"
p "#   • Builder (buildah-oci-ta) signs SBOMs & Provenance"
pe "cat ${DIR}/manifests/separation_of_duties.rego"

p "# Test Conforma policy against an adversarial attack (Builder attempts to forge clean CVE scan):"
pe "opa test ${DIR}/manifests/separation_of_duties.rego ${DIR}/manifests/separation_of_duties_test.rego -v"

wait
p ""
p "# ------------------------------------------------------------------"
p "# Part D: Legacy Token Exchange (Vault broker — Pattern 2 extension)"
p "# ------------------------------------------------------------------"
p "# When the service CANNOT speak OIDC (legacy static-token APIs, e.g."
p "# Pulp content repositories), a broker exchanges the task's JWT-SVID for"
p "# the static credential — released only to the bound SPIFFE ID, never"
p "# mounted ambiently in the tenant namespace."

VAULT_BUNDLE_REF_FILE="${DIR}/manifests/vault-bundle-ref"
if [ -f "${VAULT_BUNDLE_REF_FILE}" ] && kubectl get deployment vault-legacy-exchange -n services >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  source "${VAULT_BUNDLE_REF_FILE}"
  VAULT_URL="http://vault-legacy-exchange.services.svc.cluster.local:8200"

  p "# The vetted scanner task fetches an audience-scoped JWT-SVID (audience"
  p "# 'vault') and presents it to the broker:"
  kubectl delete taskrun demo-vault-scanner-exchange -n default-tenant --wait=true >/dev/null 2>&1 || true
  pe "cat << 'EOF' | kubectl_create_retry
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-vault-scanner-exchange
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: demo-app
    appstudio.openshift.io/component: demo-app
    app.kubernetes.io/part-of: kubecon-demo
spec:
  params:
  - name: jwt-audience
    value: "vault"
  taskRef:
    resolver: bundles
    params:
    - name: bundle
      value: ${VAULT_TASK_BUNDLE}
    - name: name
      value: trivy-sbom-scan
    - name: kind
      value: task
EOF"
  pe "kubectl wait --for=condition=Succeeded taskrun/demo-vault-scanner-exchange -n default-tenant --timeout=300s"
  SCANNER_JWT=$(kubectl logs demo-vault-scanner-exchange-pod -n default-tenant -c step-fetch-jwt \
    | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['svids'][0]['svid'])")
  p "# JWT-SVID subject: $(python3 -c "
import base64, json, sys
p = '${SCANNER_JWT}'.split('.')[1]; p += '=' * (-len(p) % 4)
print(json.loads(base64.urlsafe_b64decode(p))['sub'])")"

  p "# Exchange it at the broker — login mints a short-lived (5m) Vault token:"
  kubectl delete pod test-vault-login -n default-tenant --wait=true >/dev/null 2>&1 || true
  pe "kubectl run test-vault-login -n default-tenant --restart=Never --image=curlimages/curl:latest -- curl -s -X POST -H 'Content-Type: application/json' -d '{\"role\": \"scanner\", \"jwt\": \"${SCANNER_JWT}\"}' ${VAULT_URL}/v1/auth/jwt/login"
  for i in $(seq 1 20); do
    kubectl logs test-vault-login -n default-tenant > /tmp/vault-login.json 2>/dev/null || true
    if grep -q . /tmp/vault-login.json 2>/dev/null; then break; fi
    sleep 2
  done
  VAULT_TOKEN=$(python3 -c "import json; d=json.load(open('/tmp/vault-login.json')); print(d['auth']['client_token'])" 2>/dev/null || true)
  p "# Login OK: Vault minted a token with policy 'cve-feed-reader' (ttl 5m)."

  p "# Read the legacy static credential with it:"
  kubectl delete pod test-vault-read -n default-tenant --wait=true >/dev/null 2>&1 || true
  pe "kubectl run test-vault-read -n default-tenant --restart=Never --image=curlimages/curl:latest -- curl -s -H 'X-Vault-Token: ${VAULT_TOKEN}' ${VAULT_URL}/v1/secret/data/legacy-api"
  for i in $(seq 1 20); do
    kubectl logs test-vault-read -n default-tenant > /tmp/vault-read.json 2>/dev/null || true
    if grep -q . /tmp/vault-read.json 2>/dev/null; then break; fi
    sleep 2
  done
  pe "kubectl logs test-vault-read -n default-tenant"
  p "# The scanner can now authenticate to the legacy service with ZERO"
  p "# pre-shared secrets — the credential followed the verified identity."

  demo_cleanup pod test-vault-login -n default-tenant
  demo_cleanup pod test-vault-read -n default-tenant
  demo_cleanup taskrun demo-vault-scanner-exchange -n default-tenant

  wait
  p "# Now the dev-tier task attempts the same exchange:"
  kubectl delete taskrun demo-vault-dev-attempt -n default-tenant --wait=true >/dev/null 2>&1 || true
  DEV_VAULT_ATTEMPTS=0
  while [ ${DEV_VAULT_ATTEMPTS} -lt 3 ]; do
    DEV_VAULT_ATTEMPTS=$((DEV_VAULT_ATTEMPTS + 1))
    cat << 'EOF' | kubectl_create_retry >/dev/null
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
      - '10'
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
    if kubectl wait --for=condition=Succeeded taskrun/demo-vault-dev-attempt -n default-tenant --timeout=120s >/dev/null 2>&1; then
      break
    fi
    # The dev SVID entry is minted by the controller-manager shortly after
    # the pod appears; if fetch-jwt lost that race, retry with a fresh pod.
    if kubectl logs demo-vault-dev-attempt-pod -n default-tenant -c step-fetch-jwt 2>/dev/null | grep -q "no identity issued"; then
      p "# (SPIRE entry not yet minted for the fresh pod — retrying)"
      kubectl delete taskrun demo-vault-dev-attempt -n default-tenant --wait=true >/dev/null 2>&1 || true
      continue
    fi
    break
  done
  DEV_JWT=$(kubectl logs demo-vault-dev-attempt-pod -n default-tenant -c step-fetch-jwt 2>/dev/null \
    | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['svids'][0]['svid'])" 2>/dev/null || true)
  if [ -n "${DEV_JWT}" ]; then
    kubectl delete pod test-vault-dev-login -n default-tenant --wait=true >/dev/null 2>&1 || true
    pe "kubectl run test-vault-dev-login -n default-tenant --restart=Never --image=curlimages/curl:latest -- curl -s -X POST -H 'Content-Type: application/json' -d '{\"role\": \"scanner\", \"jwt\": \"${DEV_JWT}\"}' ${VAULT_URL}/v1/auth/jwt/login"
    for i in $(seq 1 20); do
      kubectl logs test-vault-dev-login -n default-tenant > /tmp/vault-dev-login.json 2>/dev/null || true
      if grep -q . /tmp/vault-dev-login.json 2>/dev/null; then break; fi
      sleep 2
    done
    pe "kubectl logs test-vault-dev-login -n default-tenant"
    p "# Vault DENIED the login: the JWT subject is the dev-tier identity,"
    p "# which does not match the role's bound_subject. The dev task cannot"
    p "# obtain the legacy credential."
    demo_cleanup pod test-vault-dev-login -n default-tenant
  else
    p "# (dev-tier task could not fetch a JWT-SVID; skipping the denial)"
  fi
  demo_cleanup taskrun demo-vault-dev-attempt -n default-tenant
else
  p "# (Vault extension not primed — run demo/setup-demo.sh and accept the"
  p "#  tkn/cosign tool fetch to enable this part.)"
fi

wait
clear_between_acts
finish_act 3
fi

# ==============================================================================
# ACT 4: DUAL-GATED MANAGED RELEASE AUTHORITY
# ==============================================================================
if should_run_act 4; then
p "# =================================================================="
p "# ACT 4: Managed Release Boundary (Dual-Gated Authority)"
p "# =================================================================="
p "# In managed-tenant, ambient ServiceAccount authority is prohibited."
p "# Release signing requires Model 2 Dual-Gating:"
p "#   1. PipelineRun-scoped classification from Kyverno (label: trusted-pipeline-role=release-authority)"
p "#   2. Precise SPIRE pod selector matching ONLY the attachment task (task=attach-summary-attestations)"
pe "kubectl get mutatingpolicy classify-release-authority -o yaml 2>/dev/null | yq '.spec.mutations'"
pe "kubectl get clusterspiffeid konflux-release-authority -o yaml 2>/dev/null | yq '.spec'"

p "# 0. Clean slate: remove leftover Rekor query jobs and failed pods from prior runs"
kubectl delete job query-rekor-demo -n default --wait=true --ignore-not-found=true >/dev/null 2>&1 || true
kubectl delete pod -n default-tenant -l app.kubernetes.io/part-of=kubecon-demo --field-selector=status.phase=Failed --wait=true --ignore-not-found=true >/dev/null 2>&1 || true
kubectl delete pod -n default --field-selector=status.phase=Failed --wait=true --ignore-not-found=true >/dev/null 2>&1 || true
p "Prior-run artifacts removed."

p "# 0b. The release boundary is now HARDENED with fail-closed label guards:"
p "#   guard-managed-labels  — only the release-service controller may set the managed markers"
p "#   guard-task-labels     — only the Tekton controller may set tekton.dev/* labels on TaskRuns"
p "#   validate-role-labels  — trust labels must survive a recompute of their classification"
pe "kubectl get validatingpolicy guard-managed-labels guard-task-labels validate-role-labels"

p "# THE ROGUE PIPELINE ATTACK:"
p "# An attacker (us, as admin) tries to hand-craft a 'managed' release PipelineRun"
p "# in managed-tenant to claim the release authority..."
kubectl delete pipelinerun rogue-managed-pr -n managed-tenant --wait=true >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl create -f - || true
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: rogue-managed-pr
  namespace: managed-tenant
  labels:
    appstudio.openshift.io/application: demo-app
    pipelines.appstudio.openshift.io/type: managed
spec:
  pipelineSpec:
    tasks:
    - name: noop
      taskSpec:
        steps:
        - name: echo
          image: alpine:3.20
          script: echo rogue
EOF"
p "# Admission DENIED! guard-managed-labels: the managed markers may only be set"
p "# by the release-service controller. Location ≠ Authorization."
wait

p "# 1. Create an AppStudio Release Custom Resource in default-tenant:"
echo -e "   ${CYAN}Release View in Konflux UI:${COLOR_RESET} https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app/releases"
echo ""
RELEASE_NAME=$(cat << 'EOF' | kubectl_create_retry -o jsonpath='{.metadata.name}'
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  generateName: demo-release-
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: demo-app
    app.kubernetes.io/part-of: kubecon-demo
spec:
  releasePlan: demo-app-release-plan
  snapshot: demo-app-snapshot
EOF
)
# generateName + jsonpath can race with admission-latency retries; fall back
# to the most recently created demo-release- object if the name was not captured.
if [ -z "${RELEASE_NAME}" ]; then
  RELEASE_NAME=$(kubectl get releases -n default-tenant --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)
fi
pe "kubectl get release ${RELEASE_NAME} -n default-tenant"

p "# 2. The release-service controller reconciles the Release and creates the managed PipelineRun:"
p "# The dual-gated release pipeline executes in managed-tenant with access to the SPIFFE Release Authority."
p "# Note the PipelineRun is created BY the release service (managed-* prefix, managed markers)"
p "# — the only identity allowed through guard-managed-labels."
echo -e "   ${CYAN}PipelineRuns in Konflux UI:${COLOR_RESET} https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app/activity/pipelineruns"
echo ""

# CREATE_MANUAL_PR=1 creates the dual-gated PipelineRun directly (as the
# release-service SA, so it passes guard-managed-labels) instead of going
# through the Release CR flow — useful for comparison demos of both paths.
CREATE_MANUAL_PR="${CREATE_MANUAL_PR:-0}"
if [[ "${CREATE_MANUAL_PR}" == "1" ]]; then
p "# [CREATE_MANUAL_PR=1] Creating the dual-gated PipelineRun directly as the release-service SA..."
RELEASE_PR=$(cat << 'EOF' | kubectl_create_retry --as=system:serviceaccount:release-service:release-service-controller-manager -f - -o jsonpath='{.metadata.name}'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: demo-dual-gated-release-
  namespace: managed-tenant
  labels:
    appstudio.openshift.io/application: demo-app
    appstudio.openshift.io/service: release
    pipelines.appstudio.openshift.io/type: managed
    tekton.dev/pipeline: slsa-e2e-release-dual-gated
    app.kubernetes.io/part-of: kubecon-demo
spec:
  taskRunTemplate:
    serviceAccountName: release-service-account
  pipelineSpec:
    workspaces:
    - name: shared-data
    tasks:
    - name: verify-conforma
      workspaces:
      - name: shared-data
        workspace: shared-data
      taskSpec:
        workspaces:
        - name: shared-data
        steps:
        - name: run-conforma
          image: quay.io/conforma/cli:latest@sha256:2f5bed7fd51f678ea960aaf5bed033412b7d207a83bb1b02b108be5ca71a058d
          env:
          - name: HOME
            value: /tmp
          - name: DOCKER_CONFIG
            value: /tmp/.docker
          - name: SSL_CERT_DIR
            value: /tekton-custom-certs
          script: |
            #!/bin/bash
            set -euo pipefail
            mkdir -p /tmp/.docker
            cp /tekton/creds-secrets/regcred-internal-registry/.dockerconfigjson /tmp/.docker/config.json
            echo "==> [verify-conforma] Initializing TUF root..."
            ec sigstore initialize --mirror http://tuf-server.tuf-system.svc.cluster.local --root http://tuf-server.tuf-system.svc.cluster.local/root.json
            echo "==> [verify-conforma] Fetching demo-app snapshot..."
            kubectl get snapshot demo-app-snapshot -n default-tenant -o jsonpath='{.spec}' > /tmp/snapshot.json
            echo "==> [verify-conforma] Fetching the exact immutable image digest from the snapshot..."
            IMAGE_DIGEST=$(jq -r '.components[] | select(.containerImage != null) | .containerImage' /tmp/snapshot.json | head -n1)
            if [[ "${IMAGE_DIGEST}" != registry-service.kind-registry/slsa-e2e-test@sha256:* ]]; then
              echo "ERROR: snapshot image is not an immutable slsa-e2e-test digest: ${IMAGE_DIGEST}"
              exit 1
            fi
            printf '%s' "${IMAGE_DIGEST}" > "$(workspaces.shared-data.path)/release-image"
            echo "==> [verify-conforma] Evaluating EnterpriseContractPolicy against snapshot with keyless verification..."
            ec validate image \
              --images /tmp/snapshot.json \
              --policy managed-tenant/demo-app-ec-policy \
              --skip-image-sig-check \
              --rekor-url http://rekor-server.rekor-system.svc.cluster.local \
              --retry-max-retry 5 \
              --retry-max-wait 5s \
              --strict=true \
              --show-successes \
              --output "json=$(workspaces.shared-data.path)/report.json" \
              --output "text=$(workspaces.shared-data.path)/report.txt" \
              --output "vsa=$(workspaces.shared-data.path)/vsa.json"
            echo "==> [verify-conforma] Policy check PASSED (0 violations); VSA is bound to ${IMAGE_DIGEST}."
    - name: attach-summary-attestations
      runAfter:
      - verify-conforma
      workspaces:
      - name: shared-data
        workspace: shared-data
      taskSpec:
        workspaces:
        - name: shared-data
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
          - '10'
        - name: sign-release-attestation
          image: quay.io/konflux-ci/task-runner:2.1.0@sha256:c34c933c269e2401bb042fe69e2999cf288331b6586d4f4eca9c845270d9b1f9
          env:
          - name: HOME
            value: /tmp
          - name: DOCKER_CONFIG
            value: /tmp/.docker
          - name: SPIFFE_ENDPOINT_SOCKET
            value: /spiffe-workload-api/spire-agent.sock
          - name: SIGSTORE_FULCIO_URL
            value: http://fulcio-server.fulcio-system.svc.cluster.local
          - name: SIGSTORE_REKOR_URL
            value: http://rekor-server.rekor-system.svc.cluster.local
          - name: SIGSTORE_TUF_URL
            value: http://tuf-server.tuf-system.svc.cluster.local
          command:
          - /bin/bash
          - -c
          args:
          - |
            set -euo pipefail
            mkdir -p /tmp/.docker
            cp /tekton/creds-secrets/regcred-internal-registry/.dockerconfigjson /tmp/.docker/config.json
            echo "==> [attach-summary-attestations] Initializing TUF root from local cluster..."
            cosign initialize --mirror "${SIGSTORE_TUF_URL}" --root "${SIGSTORE_TUF_URL}/root.json" || true
            
            VSA_FILE="$(workspaces.shared-data.path)/vsa.json"
            DEST_IMAGE="$(cat "$(workspaces.shared-data.path)/release-image")"
            if [[ ! -f "$VSA_FILE" || "$DEST_IMAGE" != registry-service.kind-registry/slsa-e2e-test@sha256:* ]]; then
              echo "ERROR: immutable VSA or release image is missing. Policy check must precede attestation."
              exit 1
            fi
            
            echo "==> [attach-summary-attestations] Invoking keyless Cosign attest with SPIFFE Release Authority..."
            cosign attest \
              --predicate "$VSA_FILE" \
              --type https://slsa.dev/verification_summary/v1 \
              --use-signing-config=false \
              --fulcio-url="${SIGSTORE_FULCIO_URL}" \
              --rekor-url="${SIGSTORE_REKOR_URL}" \
              --yes \
              "$DEST_IMAGE"
            echo "==> [attach-summary-attestations] Keyless release attestation successfully signed and recorded into Rekor!"
        volumes:
        - csi:
            driver: csi.spiffe.io
            readOnly: true
          name: spiffe-workload-api
  workspaces:
  - name: shared-data
    volumeClaimTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 100Mi
EOF
)
echo -e "   ${GREEN}Scheduled PipelineRun:${COLOR_RESET} ${RELEASE_PR}"
else
p "# Waiting for the release-service controller to create the managed PipelineRun..."
RELEASE_PR=""
# The release-service controller can take several minutes to validate the
# Release and process skipped tenant/collector pipelines before creating the
# managed PipelineRun; poll for up to 7.5 minutes.
for i in $(seq 1 90); do
  RELEASE_PR=$(kubectl get pipelineruns -n managed-tenant \
    -l release.appstudio.openshift.io/name=${RELEASE_NAME} \
    --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)
  [ -n "${RELEASE_PR}" ] && break
  sleep 5
done
if [ -z "${RELEASE_PR}" ]; then
  echo "Error: release-service did not create a managed PipelineRun for Release ${RELEASE_NAME}."
  kubectl get release ${RELEASE_NAME} -n default-tenant -o jsonpath='{.status.conditions}'; echo
  exit 1
fi
echo -e "   ${GREEN}Managed PipelineRun:${COLOR_RESET} ${RELEASE_PR} (created by the release-service controller)"
fi
echo -e "   ${CYAN}Track in Browser:${COLOR_RESET} https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app/activity/pipelineruns"
echo ""

p "# Inspect the managed PipelineRun: created by the release service, carrying the guarded markers:"
pe "kubectl get pipelinerun ${RELEASE_PR} -n managed-tenant --show-labels"

p "# Wait for the dual-gated release authority pipeline to complete"
p "# (EC verification retries make this take several minutes):"
pe "kubectl wait --for=condition=Succeeded pipelinerun/${RELEASE_PR} -n managed-tenant --timeout=600s"

p "# Inspect the keyless signing execution in the release pod:"
# The release pipeline's attach task names its steps differently from the
# manual dual-gated PR variant, so search all containers for the signing
# result instead of naming one.
kubectl wait --for=condition=Succeeded taskrun/${RELEASE_PR}-attach-summary-attestations -n managed-tenant --timeout=60s >/dev/null 2>&1 || true
ATTACH_POD=$(kubectl get pod -n managed-tenant -l "tekton.dev/pipeline=${RELEASE_PR}" -o name 2>/dev/null | head -1)
pe "kubectl logs -n managed-tenant ${ATTACH_POD:-pod/${RELEASE_PR}-attach-summary-attestations-pod} --all-containers 2>/dev/null | grep -iE 'keyless|attestation|rekor' | tail -5 || true"

p "# 3. Inspect the released container image OCI 1.1 referrers in the registry:"
p "# The release pushed to registry-service.kind-registry/released-demo-app; the VSA attestation"
p "# is recorded against the SNAPSHOT's immutable image digest."
REG_USER=$(kubectl get secret regcred-internal-registry -n default-tenant -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths[].auth' | base64 -d)
RELEASE_DIGEST=$(kubectl get snapshot demo-app-snapshot -n default-tenant -o jsonpath='{.spec.components[0].containerImage}' | grep -oE 'sha256:[a-f0-9]{64}')
p "# Released image digest (from the snapshot): ${RELEASE_DIGEST}"
pe "curl -s -k -u \"${REG_USER}\" https://localhost:5001/v2/released-demo-app/referrers/${RELEASE_DIGEST} | jq .manifests[].artifactType"

p "# 4. Query the Rekor transparency log dynamically using the released image attestation:"
kubectl delete job query-rekor-demo -n default --wait=true >/dev/null 2>&1 || true
cat << 'EOF' | sed "s|__DIGEST__|${RELEASE_DIGEST}|g" | kubectl_create_retry
apiVersion: batch/v1
kind: Job
metadata:
  name: query-rekor-demo
  namespace: default
  labels:
    app.kubernetes.io/part-of: kubecon-demo
spec:
  template:
    spec:
      containers:
      - name: query
        image: curlimages/curl:latest
        command:
        - /bin/sh
        - -c
        - |
          set -eu
          HASH="__DIGEST__"
          echo "Searching Rekor index for artifact hash ${HASH}..."
          UUID=$(curl -fsS -X POST -H 'Content-Type: application/json' -d "{\"hash\":\"${HASH}\"}" http://rekor-server.rekor-system.svc.cluster.local/api/v1/index/retrieve | grep -oE '[a-f0-9]{64,}' | head -n1)
          if [ -z "${UUID}" ]; then echo "ERROR: no Rekor entry found for ${HASH}"; exit 1; fi
          echo "Found matching Rekor entry UUID: ${UUID}"
          curl -fsS "http://rekor-server.rekor-system.svc.cluster.local/api/v1/log/entries/${UUID}"
      restartPolicy: Never
EOF
# Wait for the job properly and surface failures instead of piping garbage:
# --pod-running-timeout makes `kubectl logs job/` wait for (and select) the
# current pod rather than erroring with "Found N pods" from prior runs.
if ! kubectl wait --for=condition=Complete job/query-rekor-demo -n default --timeout=180s >/dev/null 2>&1; then
  echo "   [Error] query-rekor-demo job did not complete. Pod logs for debugging:"
  kubectl logs job/query-rekor-demo -n default --pod-running-timeout=30s --tail=20 || \
    kubectl get pods -n default -l job-name=query-rekor-demo -o wide
  kubectl delete job query-rekor-demo -n default --ignore-not-found=true >/dev/null 2>&1 || true
  exit 1
fi

pe "kubectl logs job/query-rekor-demo --pod-running-timeout=10s | python3 -c \"
import sys, json, base64, subprocess, tempfile

line = sys.stdin.readline()
while line and not line.startswith('{'):
    line = sys.stdin.readline()
raw = line + sys.stdin.read()
data = json.loads(raw)
entry = list(data.values())[0]
body = json.loads(base64.b64decode(entry['body']).decode())
kind = body.get('kind')
print(f'Entry kind: {kind}, logIndex: {entry.get(\\\"logIndex\\\")}')

cert_b64 = None
if kind == 'dsse':
    cert_b64 = body.get('spec', {}).get('signatures', [{}])[0].get('verifier')
elif kind == 'hashedrekord':
    cert_b64 = body.get('spec', {}).get('signature', {}).get('publicKey', {}).get('content')

if cert_b64:
    cert_pem = base64.b64decode(cert_b64).decode()
    with tempfile.NamedTemporaryFile('w') as tf:
        tf.write(cert_pem)
        tf.flush()
        san = subprocess.check_output(f'openssl x509 -in {tf.name} -noout -ext subjectAltName', shell=True).decode()
        print('Rekor Certificate SAN:')
        print(san.strip())
\""
demo_cleanup job query-rekor-demo -n default
demo_cleanup release ${RELEASE_NAME} -n default-tenant
demo_cleanup pipelinerun ${RELEASE_PR} -n managed-tenant
demo_cleanup pvc -n managed-tenant -l tekton.dev/pipelineRun=${RELEASE_PR}

echo ""
echo -e "${GREEN}═════════════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
echo -e "${GREEN}  Demo Complete! Location ≠ Authorization. Trust is Restored across the Arc.     ${COLOR_RESET}"
echo -e "${GREEN}═════════════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
echo ""
echo "Inspect live demo resources in Konflux UI:"
echo -e "  - ${CYAN}Application:${COLOR_RESET}  https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app"
echo -e "  - ${CYAN}Releases:${COLOR_RESET}     https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app/releases"
echo -e "  - ${CYAN}PipelineRuns:${COLOR_RESET} https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app/activity/pipelineruns"
echo ""

if [[ "${DEMO_CLEANUP}" == "true" ]]; then
  echo "==> DEMO_CLEANUP=true set; executing demo/cleanup-demo.sh..."
  "${DIR}/cleanup-demo.sh"
else
  echo -e "Resources have been retained on the cluster for UI inspection."
  echo -e "Run ${CYAN}${DIR}/cleanup-demo.sh${COLOR_RESET} anytime to reset the cluster."
  echo ""
  if [ -t 0 ]; then
    read -p "Clean up demo execution resources now? [y/N]: " -r RESP
    if [[ "$RESP" =~ ^[Yy]$ ]]; then
      "${DIR}/cleanup-demo.sh"
    fi
  fi
fi

finish_act 4
fi

if [[ "$SELECTED_ACT" == "0" || "$SELECTED_ACT" == "all" ]]; then
  printf "\033]0;ACT_0_COMPLETE\007"
fi
