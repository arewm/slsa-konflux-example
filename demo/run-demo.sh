#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
TYPE_SPEED=30
source "${DIR}/demo-magic.sh"

DEMO_PROMPT="${CYAN}kubecon@konflux-ci${COLOR_RESET}:${BLUE}~/demo${COLOR_RESET}$ "

# Demo lifecycle settings
# Set DEMO_CLEANUP=true to delete resources immediately after each scene;
# by default (false), resources are left intact on the cluster for UI inspection and post-demo auditing.
DEMO_CLEANUP="${DEMO_CLEANUP:-false}"

demo_cleanup() {
  if [[ "${DEMO_CLEANUP}" == "true" ]]; then
    kubectl delete "$@" >/dev/null 2>&1 || true
  fi
}

clear
echo ""
echo -e "${PURPLE}╔═════════════════════════════════════════════════════════════════════════════════╗${COLOR_RESET}"
echo -e "${PURPLE}║                                                                                 ║${COLOR_RESET}"
echo -e "${PURPLE}║      KubeCon NA 2026: \"Your CI's Mistaken Identity\"                             ║${COLOR_RESET}"
echo -e "${PURPLE}║      Live Demonstration Arc: Secretless Tasks, Gated OCI & Dual Release         ║${COLOR_RESET}"
echo -e "${PURPLE}║                                                                                 ║${COLOR_RESET}"
echo -e "${PURPLE}╚═════════════════════════════════════════════════════════════════════════════════╝${COLOR_RESET}"
echo ""
echo -e "Press ${GREEN}[ENTER]${COLOR_RESET} to advance through each step."
echo ""
wait

# ==============================================================================
# ACT 0: PRE-FLIGHT VERIFICATION
# ==============================================================================
p "# =================================================================="
p "# PRE-FLIGHT: Verifying Platform Prerequisites"
p "# =================================================================="
p "# Before starting, verify Kyverno admission policies, SPIRE identity server, and OIDC discovery:"
echo -e "   ${CYAN}Konflux UI Application View:${COLOR_RESET} https://localhost:9443/application-pipeline/workspaces/default/applications/test-app"
echo ""
pe "kubectl get clusterpolicies"
pe "kubectl get pods -n spire -l app.kubernetes.io/instance=spire"
pe "kubectl get pods,services -n kind-registry -l app=registry-oidc"
pe "kubectl get pods,services -n services -l app=cve-database-service"

wait
clear

# ==============================================================================
# ACT 1: ADMISSION CONTROL & ROLE-SCOPED ATTESTATION (THE PROMISE)
# ==============================================================================
p "# =================================================================="
p "# ACT 1: Kyverno at the Gate & Separation of Duties Attestations"
p "# =================================================================="
p "# Inspect Kyverno's task classification rules before admission:"
p "# Notice: default rule sets 'trusted-task-role: dev'; pinned catalog bundles upgrade to 'prod':"
pe "kubectl get clusterpolicy classify-taskrun -o yaml 2>/dev/null | yq '.spec.rules'"

p "# 1. Submit an untrusted / inline TaskRun (not pinned or catalog-signed):"
p "# Expected: Kyverno admits the task but restricts it to the unprivileged 'dev' role."
pe "cat << 'EOF' | kubectl create -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  generateName: demo-untrusted-run-
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: test-app
    appstudio.openshift.io/component: test-app
spec:
  taskSpec:
    steps:
    - name: echo
      image: alpine:latest
      script: echo 'Untrusted inline code execution'
EOF"

UNTRUSTED_TR=$(kubectl get taskruns -n default-tenant --sort-by=.metadata.creationTimestamp | grep demo-untrusted-run | tail -n1 | awk '{print $1}')
kubectl wait --for=condition=Ready taskrun/${UNTRUSTED_TR} -n default-tenant --timeout=30s >/dev/null 2>&1 || true

p "# Inspect the labels Kyverno stamped on the TaskRun:"
pe "kubectl get taskrun ${UNTRUSTED_TR} -n default-tenant --show-labels"

p "# Verify Tekton propagates the Kyverno-verified label to the execution Pod:"
pe "kubectl get pod -n default-tenant -l tekton.dev/taskRun=${UNTRUSTED_TR} --show-labels"

p "# What workload identity does SPIRE mint for this untrusted task?"
POD_UID=$(kubectl get pod -n default-tenant -l tekton.dev/taskRun=${UNTRUSTED_TR} -o jsonpath='{.items[0].metadata.uid}')
pe "kubectl exec -n spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show -selector \"k8s:pod-uid:${POD_UID}\""

demo_cleanup taskrun "${UNTRUSTED_TR}" -n default-tenant

wait
clear

p "# 2. What happens when an attacker attempts to spoof our trusted catalog by submitting an unsigned bundle?"
p "# Notice: Arbitrary tasks are safely admitted as 'dev', but claiming the trusted catalog pattern"
p "# (registry-service.kind-registry/tekton-catalog/*) without a valid platform Cosign signature"
p "# is an admission-blocking violation enforced by verify-bundle-signatures:"
p "#"
p "# Inspect the bundle signature enforcement policy:"
pe "kubectl get clusterpolicy verify-bundle-signatures -o yaml 2>/dev/null | yq '.spec.rules[] | {\"rule\": .name, \"match\": .match, \"verifyImages\": .verifyImages}'"

kubectl delete taskrun attacker-unsigned-task -n default-tenant >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl create -f - || true
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: attacker-unsigned-task
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: test-app
    appstudio.openshift.io/component: test-app
spec:
  taskRef:
    resolver: bundles
    params:
    - name: bundle
      value: registry-service.kind-registry/tekton-catalog/demo-unsigned-task@sha256:ce74927e3dabe057fd1a5647b29e394e34bd371f886ef8af7da1d34639209d5b
    - name: name
      value: demo-catalog-task
    - name: kind
      value: task
EOF"

p "# Admission denied! Sigstore verification failed: no matching signatures found."
wait

p "# 3. Now submit a cryptographically signed, pinned catalog task bundle (signed with Cosign):"
p "# Expected: Kyverno verifies the Sigstore bundle signature and promotes the role to 'prod'."
kubectl delete taskrun demo-signed-task -n default-tenant >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl create -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-signed-task
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: test-app
    appstudio.openshift.io/component: test-app
spec:
  taskRef:
    resolver: bundles
    params:
    - name: bundle
      value: registry-service.kind-registry/tekton-catalog/demo-catalog-task@sha256:ce74927e3dabe057fd1a5647b29e394e34bd371f886ef8af7da1d34639209d5b
    - name: name
      value: demo-catalog-task
    - name: kind
      value: task
EOF"

kubectl wait --for=condition=Ready taskrun/demo-signed-task -n default-tenant --timeout=30s >/dev/null 2>&1 || true

p "# Inspect the TaskRun labels stamped by Kyverno:"
pe "kubectl get taskrun demo-signed-task -n default-tenant --show-labels"

p "# Inspect the production SVID minted by SPIRE for this specific Pod:"
SIGNED_POD_UID=$(kubectl get pod -n default-tenant -l tekton.dev/taskRun=demo-signed-task -o jsonpath='{.items[0].metadata.uid}')
pe "kubectl exec -n spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show -selector \"k8s:pod-uid:${SIGNED_POD_UID}\""

demo_cleanup taskrun demo-signed-task -n default-tenant
wait
clear

p "# 4. Separation of Duties Policy Enforcement (Conforma Rego):"
p "# When tasks sign role-scoped attestations:"
p "#   • Scanner (trivy-sbom-scan) signs CVE reports"
p "#   • Builder (buildah-oci-ta) signs SBOMs & Provenance"
pe "cat ${DIR}/manifests/separation_of_duties.rego"

p "# Test Conforma policy against an adversarial attack (Builder attempts to forge clean CVE scan):"
pe "opa test ${DIR}/manifests/separation_of_duties.rego ${DIR}/manifests/separation_of_duties_test.rego -v"

wait
clear

# ==============================================================================
# ACT 2: AMBIENT PUSH HIJACK VS TASK-SCOPED OCI PUSH GATING
# ==============================================================================
p "# =================================================================="
p "# ACT 2: Ambient Push Hijack vs. Task-Scoped OCI Push Gating"
p "# =================================================================="
p "# In Kubernetes, the 'default' keyless workload identity is projected ServiceAccount tokens:"
p "#   iss: https://kubernetes.default.svc"
p "#   sub: system:serviceaccount:<namespace>:<serviceaccount>"
p "#"
p "# Let's inspect what identity a task receives under this standard pattern:"
kubectl delete taskrun demo-sa-token-inspection -n default-tenant >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-sa-token-inspection
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: test-app
    appstudio.openshift.io/component: test-app
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
kubectl delete pod rogue-ambient-push -n default-tenant >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: rogue-ambient-push
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: test-app
    appstudio.openshift.io/component: test-app
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

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/rogue-ambient-push -n default-tenant --timeout=30s >/dev/null 2>&1 || sleep 3
pe "kubectl logs rogue-ambient-push -n default-tenant | grep -A 5 \"VERIFICATION\""
demo_cleanup pod rogue-ambient-push -n default-tenant

p "# The tag was silently overwritten because traditional SA credentials provide ambient authority!"
wait

p "# THE DEFENSE: Task-Scoped OCI Push Gating with Zot OIDC Bearer Auth"
p "# Zot validates push handshakes against SPIRE OIDC discovery keys (/keys)."
p "# Access control policy strictly restricts writes to the vetted builder role:"
pe "kubectl get configmap zot-oidc-config -n kind-registry -o jsonpath='{.data.config\\.json}' | jq '.http.accessControl.repositories'"

p "# 1. Attack Attempt on Gated Registry:"
p "# A rogue dev task attempts to push to slsa-e2e-test using its SPIFFE JWT-SVID:"
kubectl delete taskrun demo-rogue-push-attempt -n default-tenant >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-rogue-push-attempt
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: test-app
    appstudio.openshift.io/component: test-app
    tekton.dev/task: rogue-attacker-task
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
      command: [\"sleep\", \"5\"]
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
pe "curl -s -k -i -X POST -H \"Authorization: Bearer ${ROGUE_JWT}\" https://registry-oidc.kind-registry:5000/v2/slsa-e2e-test/blobs/uploads/ | head -n 1"
pe "kubectl logs deployment/registry-oidc -n kind-registry --tail=5 | grep -i \"statusCode\":403 || true"
demo_cleanup taskrun demo-rogue-push-attempt -n default-tenant

p "# HTTP/2 403 Forbidden! The rogue task cannot overwrite the image tag."
wait

p "# 2. Legitimate Push on Gated Registry:"
p "# The vetted Builder task bundle (buildah-oci-ta) executes with its trusted production identity:"
kubectl delete taskrun demo-builder-gated-push -n default-tenant >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-builder-gated-push
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: test-app
    appstudio.openshift.io/component: test-app
spec:
  taskRef:
    resolver: bundles
    params:
    - name: bundle
      value: registry-service.kind-registry/tekton-catalog/buildah-oci-ta@sha256:aa9e8d2adcd43db81815560cf268a56e9e951b0417c4826081ac4cd51a542c6c
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
pe "curl -s -k -i -X POST -H \"Authorization: Bearer ${BUILDER_JWT}\" https://registry-oidc.kind-registry:5000/v2/slsa-e2e-test/blobs/uploads/ | head -n 1"
pe "kubectl logs deployment/registry-oidc -n kind-registry --tail=5 | grep -i \"statusCode\":202 || true"
demo_cleanup taskrun demo-builder-gated-push -n default-tenant

p "# HTTP/2 202 Accepted! Push upload session created strictly via Workload Identity."
wait
clear

# ==============================================================================
# ACT 3: PORTABLE SECRETLESS SERVICE ACCESS (TOKEN EXCHANGE)
# ==============================================================================
p "# =================================================================="
p "# ACT 3: Portable Secretless Service Access (Cross-Namespace Token Exchange)"
p "# =================================================================="
p "# Workload identity isn't just for signing—it eliminates static API tokens across pipelines."
p "# An internal CVE database service is running in namespace 'services'."
p "# It mounts ZERO Kubernetes secrets and validates callers via SPIRE OIDC discovery keys (/keys)."
pe "kubectl get pods,services -n services"

p "# 1. Untrusted Task Attempt:"
p "# A dev task requests a token and attempts to access the CVE feed:"
kubectl delete taskrun demo-untrusted-service-query -n default-tenant >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-untrusted-service-query
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: test-app
    appstudio.openshift.io/component: test-app
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
      command: [\"sleep\", \"5\"]
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
kubectl delete pod test-untrusted-client -n default-tenant >/dev/null 2>&1 || true
pe "kubectl run test-untrusted-client --namespace=default-tenant --image=curlimages/curl --restart=Never --command -- curl -s -i -H \"Authorization: Bearer ${UNTRUSTED_SVID}\" http://cve-database-service.services.svc.cluster.local:8080/api/v1/vulnerabilities"
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/test-untrusted-client -n default-tenant --timeout=30s >/dev/null 2>&1 || sleep 2
pe "kubectl logs test-untrusted-client -n default-tenant"
pe "kubectl logs deployment/cve-database-service -n services --tail=4"
demo_cleanup pod test-untrusted-client -n default-tenant
demo_cleanup taskrun demo-untrusted-service-query -n default-tenant

p "# HTTP/1.0 403 Forbidden! The untrusted task lacks scanner authorization."
wait

p "# 2. Vetted Scanner Task (trivy-sbom-scan):"
p "# The catalog scanner task presents its audience-scoped SVID to the service:"
kubectl delete taskrun demo-trusted-scanner-query -n default-tenant >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-trusted-scanner-query
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: test-app
    appstudio.openshift.io/component: test-app
spec:
  taskRef:
    resolver: bundles
    params:
    - name: bundle
      value: registry-service.kind-registry/tekton-catalog/trivy-sbom-scan@sha256:54b0dfdbb45355264f130c9ad6a9be91f2104ab56c8aa895f4bb8894248874db
    - name: name
      value: trivy-sbom-scan
    - name: kind
      value: task
EOF"

kubectl wait --for=condition=Succeeded taskrun/demo-trusted-scanner-query -n default-tenant --timeout=60s

SCANNER_SVID=$(kubectl logs demo-trusted-scanner-query-pod -n default-tenant -c step-fetch-jwt | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['svids'][0]['svid'])")
kubectl delete pod test-scanner-client -n default-tenant >/dev/null 2>&1 || true
pe "kubectl run test-scanner-client --namespace=default-tenant --image=curlimages/curl --restart=Never --command -- curl -s -i -H \"Authorization: Bearer ${SCANNER_SVID}\" http://cve-database-service.services.svc.cluster.local:8080/api/v1/vulnerabilities"
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/test-scanner-client -n default-tenant --timeout=30s >/dev/null 2>&1 || sleep 2
pe "kubectl logs test-scanner-client -n default-tenant"
pe "kubectl logs deployment/cve-database-service -n services --tail=5"
demo_cleanup pod test-scanner-client -n default-tenant
demo_cleanup taskrun demo-trusted-scanner-query -n default-tenant

p "# HTTP/1.0 200 OK! Zero pre-shared secrets, zero credentials mounted in default-tenant."
wait
clear

# ==============================================================================
# ACT 4: DUAL-GATED MANAGED RELEASE AUTHORITY
# ==============================================================================
p "# =================================================================="
p "# ACT 4: Managed Release Boundary (Dual-Gated Authority)"
p "# =================================================================="
p "# In managed-tenant, ambient ServiceAccount authority is prohibited."
p "# Release signing requires Model 2 Dual-Gating:"
p "#   1. PipelineRun-scoped classification from Kyverno (label: trusted-pipeline-role=release-authority)"
p "#   2. Precise SPIRE pod selector matching ONLY the attachment task (task=attach-summary-attestations)"
pe "kubectl get clusterpolicy classify-release-authority -o yaml 2>/dev/null | yq '.spec.rules'"
pe "kubectl get clusterspiffeid konflux-release-authority -o yaml 2>/dev/null | yq '.spec'"

p "# 1. Create an AppStudio Release Custom Resource in default-tenant:"
echo -e "   ${CYAN}Release View in Konflux UI:${COLOR_RESET} https://localhost:9443/application-pipeline/workspaces/default/applications/test-app/releases"
echo ""
RELEASE_NAME=$(cat << 'EOF' | kubectl create -f - -o jsonpath='{.metadata.name}'
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  generateName: demo-release-
  namespace: default-tenant
  labels:
    appstudio.openshift.io/application: test-app
spec:
  releasePlan: test-app-release-plan
  snapshot: demo-snapshot-release
EOF
)
pe "kubectl get release ${RELEASE_NAME} -n default-tenant"

p "# 2. Execute the Dual-Gated Managed Release Authority PipelineRun:"
p "# The release pipeline executes in managed-tenant with access to the SPIFFE Release Authority."
echo -e "   ${CYAN}PipelineRuns in Konflux UI:${COLOR_RESET} https://localhost:9443/application-pipeline/workspaces/default/applications/test-app/activity/pipelineruns"
echo ""

RELEASE_PR=$(cat << 'EOF' | kubectl create -f - -o jsonpath='{.metadata.name}'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: demo-dual-gated-release-
  namespace: managed-tenant
  labels:
    appstudio.openshift.io/application: test-app
    appstudio.openshift.io/service: release
    pipelines.appstudio.openshift.io/type: managed
    tekton.dev/pipeline: slsa-e2e-release-dual-gated
spec:
  taskRunTemplate:
    serviceAccountName: release-service-account
  pipelineSpec:
    tasks:
    - name: early-verification-step
      taskSpec:
        steps:
        - name: check-workload-api
          image: curlimages/curl:latest
          command: ["/bin/sh", "-c"]
          args:
          - |
            echo "Early pipeline task running before authorization step..."
    - name: attach-summary-attestations
      runAfter:
      - early-verification-step
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
          command: ["sleep", "5"]
        - name: sign-release-attestation
          image: quay.io/konflux-ci/task-runner:2.1.0@sha256:c34c933c269e2401bb042fe69e2999cf288331b6586d4f4eca9c845270d9b1f9
          env:
          - name: SPIFFE_ENDPOINT_SOCKET
            value: /spiffe-workload-api/spire-agent.sock
          - name: SIGSTORE_FULCIO_URL
            value: http://fulcio-server.fulcio-system.svc.cluster.local
          - name: SIGSTORE_REKOR_URL
            value: http://rekor-server.rekor-system.svc.cluster.local
          - name: SIGSTORE_TUF_URL
            value: http://tuf-server.tuf-system.svc.cluster.local
          - name: SSL_CERT_DIR
            value: /etc/pki/tls/certs
          command:
          - /bin/bash
          - -c
          args:
          - |
            set -euo pipefail
            echo "Initializing TUF root from local cluster..."
            cosign initialize --mirror "${SIGSTORE_TUF_URL}" --root "${SIGSTORE_TUF_URL}/root.json" || true
            echo '{"status": "PASSED", "policy": "dual-gated-release", "application": "test-app"}' > /tmp/vsa.json
            echo "Invoking keyless Cosign attest with SPIFFE Release Authority Workload Identity..."
            cosign attest \
              --predicate /tmp/vsa.json \
              --type https://slsa.dev/verification_summary/v1 \
              --use-signing-config=false \
              --fulcio-url="${SIGSTORE_FULCIO_URL}" \
              --rekor-url="${SIGSTORE_REKOR_URL}" \
              --yes \
              registry-service.kind-registry/slsa-e2e-test:latest
            echo "Keyless release attestation successfully signed and recorded into Rekor!"
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
EOF
)
echo -e "   ${GREEN}Scheduled PipelineRun:${COLOR_RESET} ${RELEASE_PR}"
echo -e "   ${CYAN}Track in Browser:${COLOR_RESET} https://localhost:9443/application-pipeline/workspaces/default/applications/test-app/activity/pipelineruns"
echo ""

p "# Wait for the dual-gated release authority pipeline to complete:"
pe "kubectl wait --for=condition=Succeeded pipelinerun/${RELEASE_PR} -n managed-tenant --timeout=90s"

p "# Inspect the keyless signing execution in the release pod:"
pe "kubectl logs ${RELEASE_PR}-attach-summary-attestations-pod -n managed-tenant -c step-sign-release-attestation"

p "# 3. Inspect the released container image OCI 1.1 referrers in the registry:"
REG_USER=$(kubectl get secret regcred-internal-registry -n default-tenant -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths[].auth' | base64 -d)
RELEASE_DIGEST=$(curl -s -k -u "${REG_USER}" -I -H "Accept: application/vnd.oci.image.index.v1+json" https://localhost:5001/v2/slsa-e2e-test/manifests/latest | grep -i docker-content-digest | awk '{print $2}' | tr -d '\r\n')
pe "curl -s -k -u \"${REG_USER}\" https://localhost:5001/v2/slsa-e2e-test/referrers/${RELEASE_DIGEST} | jq .manifests[].artifactType"

p "# 4. Query the Rekor transparency log dynamically using the released image attestation:"
kubectl delete job query-rekor-demo -n default >/dev/null 2>&1 || true
pe "cat << 'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: query-rekor-demo
  namespace: default
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
          set -e
          TREE_SIZE=\$(curl -s \"http://rekor-server.rekor-system.svc.cluster.local/api/v1/log\" | sed -n 's/.*\"treeSize\":\([0-9]*\).*/\\1/p')
          LATEST_INDEX=\$((TREE_SIZE - 1))
          echo \"Rekor current treeSize: \${TREE_SIZE}, querying latest logIndex: \${LATEST_INDEX}...\"
          curl -s \"http://rekor-server.rekor-system.svc.cluster.local/api/v1/log/entries?logIndex=\${LATEST_INDEX}\"
      restartPolicy: Never
EOF"

kubectl wait --for=condition=Complete job/query-rekor-demo -n default --timeout=30s >/dev/null 2>&1 || true

pe "kubectl logs job/query-rekor-demo | python3 -c \"
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

echo ""
echo -e "${GREEN}═════════════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
echo -e "${GREEN}  Demo Complete! Location ≠ Authorization. Trust is Restored across the Arc.     ${COLOR_RESET}"
echo -e "${GREEN}═════════════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
echo ""
