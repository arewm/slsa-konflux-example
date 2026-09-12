#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "${DIR}/demo-magic.sh"

# Demo-magic settings
TYPE_SPEED=30
DEMO_PROMPT="${CYAN}kubecon@konflux-ci${COLOR_RESET}:${BLUE}~/demo${COLOR_RESET}$ "

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
p "# 1. Submit an untrusted / inline TaskRun (not pinned or catalog-signed):"
p "# Expected: Kyverno admits the task but restricts it to the unprivileged 'dev' role."
pe "cat << 'EOF' | kubectl create -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  generateName: demo-untrusted-run-
  namespace: default-tenant
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
pe "kubectl exec -n spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show | grep -B 1 -A 5 \"$(kubectl get pod -n default-tenant -l tekton.dev/taskRun=${UNTRUSTED_TR} -o jsonpath='{.items[0].metadata.uid}')\""

wait
clear

p "# 2. What happens when an attacker attempts to spoof a catalog bundle by submitting an unsigned image?"
p "# Expected: Kyverno inspects the bundle referrer in the registry and REJECTS admission."
pe "cat << 'EOF' | kubectl create -f - || true
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: attacker-unsigned-task
  namespace: default-tenant
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
pe "cat << 'EOF' | kubectl create -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-signed-task
  namespace: default-tenant
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

p "# Inspect the production SVID minted by SPIRE:"
pe "kubectl exec -n spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show | grep -A 6 \"trusted/kind-konflux\""

kubectl delete taskrun demo-signed-task -n default-tenant >/dev/null 2>&1 || true
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
p "# In standard CI/CD, every task mounts the ServiceAccount's ambient registry secret."
p "#"
p "# THE ATTACK:"
p "# A rogue task running in the same namespace under the same ServiceAccount abuses regcred"
p "# to overwrite production image tag 'slsa-e2e-test:latest' with a malicious backdoor!"
pe "cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: rogue-ambient-push
  namespace: default-tenant
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

kubectl wait --for=condition=Ready pod/rogue-ambient-push -n default-tenant --timeout=30s >/dev/null 2>&1 || true
pe "kubectl logs rogue-ambient-push -n default-tenant | grep -A 5 \"VERIFICATION\""
kubectl delete pod rogue-ambient-push -n default-tenant >/dev/null 2>&1

p "# The tag was silently overwritten because traditional credentials provide ambient authority!"
wait

p "# THE DEFENSE: Task-Scoped OCI Push Gating with Zot OIDC Bearer Auth"
p "# Zot validates push handshakes against SPIRE OIDC discovery keys (/keys)."
p "# Access control policy strictly restricts writes to the vetted builder role:"
pe "kubectl get configmap zot-oidc-config -n kind-registry -o jsonpath='{.data.config\\.json}' | jq '.http.accessControl.repositories'"

p "# 1. Attack Attempt on Gated Registry:"
p "# A rogue dev task attempts to push to slsa-e2e-test using its SPIFFE JWT-SVID:"
pe "cat << 'EOF' | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-rogue-push-attempt
  namespace: default-tenant
  labels:
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
kubectl delete taskrun demo-rogue-push-attempt -n default-tenant >/dev/null 2>&1

p "# HTTP/2 403 Forbidden! The rogue task cannot overwrite the image tag."
wait

p "# 2. Legitimate Push on Gated Registry:"
p "# The vetted Builder task bundle (buildah-oci-ta) executes with its trusted production identity:"
pe "cat << 'EOF' | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-builder-gated-push
  namespace: default-tenant
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
kubectl delete taskrun demo-builder-gated-push -n default-tenant >/dev/null 2>&1

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
pe "cat << 'EOF' | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-untrusted-service-query
  namespace: default-tenant
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
pe "kubectl run test-untrusted-client --namespace=default-tenant --image=curlimages/curl --restart=Never --command -- curl -s -i -H \"Authorization: Bearer ${UNTRUSTED_SVID}\" http://cve-database-service.services.svc.cluster.local:8080/api/v1/vulnerabilities"
kubectl wait --for=condition=Ready pod/test-untrusted-client -n default-tenant --timeout=30s >/dev/null 2>&1 || true
sleep 2
pe "kubectl logs test-untrusted-client -n default-tenant"
pe "kubectl logs deployment/cve-database-service -n services --tail=4"
kubectl delete pod test-untrusted-client -n default-tenant >/dev/null 2>&1
kubectl delete taskrun demo-untrusted-service-query -n default-tenant >/dev/null 2>&1

p "# HTTP/1.0 403 Forbidden! The untrusted task lacks scanner authorization."
wait

p "# 2. Vetted Scanner Task (trivy-sbom-scan):"
p "# The catalog scanner task presents its audience-scoped SVID to the service:"
pe "cat << 'EOF' | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: demo-trusted-scanner-query
  namespace: default-tenant
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
pe "kubectl run test-scanner-client --namespace=default-tenant --image=curlimages/curl --restart=Never --command -- curl -s -i -H \"Authorization: Bearer ${SCANNER_SVID}\" http://cve-database-service.services.svc.cluster.local:8080/api/v1/vulnerabilities"
kubectl wait --for=condition=Ready pod/test-scanner-client -n default-tenant --timeout=30s >/dev/null 2>&1 || true
sleep 2
pe "kubectl logs test-scanner-client -n default-tenant"
pe "kubectl logs deployment/cve-database-service -n services --tail=5"
kubectl delete pod test-scanner-client -n default-tenant >/dev/null 2>&1
kubectl delete taskrun demo-trusted-scanner-query -n default-tenant >/dev/null 2>&1

p "# HTTP/1.0 200 OK! Zero pre-shared secrets, zero credentials mounted in default-tenant."
wait
clear

# ==============================================================================
# ACT 4: DUAL-GATED MANAGED RELEASE AUTHORITY
# ==============================================================================
p "# =================================================================="
p "# ACT 4: Managed Release Boundary (Dual-Gated Authority)"
p "# =================================================================="
p "# In managed-tenant, release signing requires BOTH:"
p "#   1. PipelineRun-scoped validation from Kyverno"
p "#   2. Precise SPIRE pod selector matching ONLY the attachment task"
pe "kubectl get clusterspiffeid konflux-release-authority -o yaml"

p "# Inspect the released container image OCI 1.1 referrers in the registry:"
pe "curl -s -k -u konflux:6V99jCUvkV-VxycFp8Ixadp51oHBnRiD https://localhost:5001/v2/released-test-app/referrers/sha256:b27826d99fa895c302c327c58ca1d861b962b7cc0587efdc7911e3d770a13d85 | jq .manifests[].artifactType"

p "# Query the Rekor transparency log entry to verify the signer certificate identity:"
pe "kubectl create job --from=cronjob/none query-rekor-demo 2>/dev/null || cat << 'EOF' | kubectl apply -f -
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
        command: [\"curl\", \"-s\", \"http://rekor-server.rekor-system.svc.cluster.local/api/v1/log/entries?logIndex=19\"]
      restartPolicy: Never
EOF"

kubectl wait --for=condition=Complete job/query-rekor-demo -n default --timeout=30s >/dev/null 2>&1 || true

pe "kubectl logs job/query-rekor-demo | python3 -c \"
import sys, json, base64, subprocess, tempfile
raw = sys.stdin.read()
data = json.loads(raw)
entry = list(data.values())[0]
body = json.loads(base64.b64decode(entry['body']).decode())
cert_pem = base64.b64decode(body['spec']['signature']['publicKey']['content']).decode()
with tempfile.NamedTemporaryFile('w') as tf:
    tf.write(cert_pem)
    tf.flush()
    san = subprocess.check_output(f'openssl x509 -in {tf.name} -noout -ext subjectAltName', shell=True).decode()
    print('Rekor logIndex 19 Certificate SAN:')
    print(san.strip())
\""
kubectl delete job query-rekor-demo >/dev/null 2>&1

echo ""
echo -e "${GREEN}═════════════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
echo -e "${GREEN}  Demo Complete! Location ≠ Authorization. Trust is Restored across the Arc.     ${COLOR_RESET}"
echo -e "${GREEN}═════════════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
echo ""
