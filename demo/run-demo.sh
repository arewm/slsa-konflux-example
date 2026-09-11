#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "${DIR}/demo-magic.sh"

# Demo-magic settings
TYPE_SPEED=30
DEMO_PROMPT="${CYAN}kubecon@konflux-ci${COLOR_RESET}:${BLUE}~/demo${COLOR_RESET}$ "

clear
echo ""
echo -e "${PURPLE}╔═══════════════════════════════════════════════════════════════════╗${COLOR_RESET}"
echo -e "${PURPLE}║                                                                   ║${COLOR_RESET}"
echo -e "${PURPLE}║      KubeCon NA 2026: \"Your CI's Mistaken Identity\"               ║${COLOR_RESET}"
echo -e "${PURPLE}║      Live Interactive Demo Script                                 ║${COLOR_RESET}"
echo -e "${PURPLE}║                                                                   ║${COLOR_RESET}"
echo -e "${PURPLE}╚═══════════════════════════════════════════════════════════════════╝${COLOR_RESET}"
echo ""
echo -e "Press ${GREEN}[ENTER]${COLOR_RESET} to advance through each step."
echo ""
wait

# --- PART 1: THE ADMISSION GATE & SEPARATION OF DUTIES ---
p "# ------------------------------------------------------------------"
p "# SCENE 1: Kyverno at the Gate & Untrusted Task Admission"
p "# ------------------------------------------------------------------"
p "# Let's check active Kyverno policies enforcing TaskRun admission:"
pe "kubectl get clusterpolicies"

p "# We submit an untrusted / inline TaskRun (not pinned or catalog-signed):"
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

p "# Watch Kyverno classify the TaskRun with the 'dev' role:"
UNTRUSTED_TR=$(kubectl get taskruns -n default-tenant --sort-by=.metadata.creationTimestamp | grep demo-untrusted-run | tail -n1 | awk '{print $1}')
pe "kubectl get taskrun ${UNTRUSTED_TR} -n default-tenant --show-labels"

p "# Verify Tekton propagates the Kyverno-verified label to the execution Pod:"
pe "kubectl get pod -n default-tenant -l tekton.dev/taskRun=${UNTRUSTED_TR} --show-labels"

p "# Notice the label: trusted-task-role=dev"
p "# What identity does SPIRE mint for this untrusted task?"
pe "kubectl exec -n spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show | grep -B 1 -A 5 \"$(kubectl get pod -n default-tenant -l tekton.dev/taskRun=${UNTRUSTED_TR} -o jsonpath='{.items[0].metadata.uid}')\""

wait
clear

p "# ------------------------------------------------------------------"
p "# SCENE 2: Signed Catalog Tasks & Production Roles"
p "# ------------------------------------------------------------------"
p "# What happens when an attacker attempts to submit an unsigned bundle under our catalog pattern?"
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

p "# Kyverno blocks admission! Sigstore verification failed: no matching signatures found."
wait

p "# Now submit a signed, pinned catalog task bundle (signed with Cosign):"
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

p "# Kyverno verifies the Sigstore referrer signature and stamps 'prod':"
pe "kubectl get taskrun demo-signed-task -n default-tenant --show-labels"

p "# Inspect the production SVID minted by SPIRE:"
pe "kubectl exec -n spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show | grep -A 6 \"trusted/kind-konflux\""

wait
clear

p "# ------------------------------------------------------------------"
p "# SCENE 3: Separation of Duties Enforcement in Conforma"
p "# ------------------------------------------------------------------"
p "# When tasks sign role-scoped attestations:"
p "#   • Scanner (trivy-sbom-scan) signs CVE reports"
p "#   • Builder (buildah-oci-ta) signs SBOMs"
p "#"
p "# Conforma Rego policy enforces: 'Right role for the right job!'"
pe "cat << 'EOF'
package policy.separation_of_duties
import rego.v1

deny contains msg if {
    some attestation in input.attestations
    attestation.statement.predicateType == \"https://aquasecurity.github.io/trivy/report/v1\"
    some sig in attestation.signatures
    uri := sig.certificate.extensions.subjectAlternativeName
    not regex.match(\"^spiffe://konflux-ci.dev/trusted/.*/trivy-sbom-scan$\", uri)
    msg := sprintf(\"CVE scan report signed by unauthorized role: %s (expected scanner role)\", [uri])
}
EOF"

p "# Let's test Conforma policy against an adversarial attack (Builder attempts to forge clean CVE scan):"
pe "opa test /tmp/separation_of_duties.rego /tmp/separation_of_duties_test.rego -v"

wait
clear

# --- PART 2: THE MANAGED RELEASE BOUNDARY ---
p "# ------------------------------------------------------------------"
p "# SCENE 4: Managed Release Boundary (Dual-Gated Authority)"
p "# ------------------------------------------------------------------"
p "# In managed-tenant, ambient ServiceAccount authority is dangerous."
p "# We demonstrate PipelineRun-Scoped Dual-Gating (Model 2):"
pe "kubectl get clusterspiffeid konflux-release-authority -o yaml"

p "# Notice the selector conjunction: BOTH trusted-pipeline-role AND pipelineTask: attach-summary-attestations!"
p "#"
p "# Let's inspect the released container image OCI 1.1 referrers in the registry:"
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

pe "sleep 3
kubectl logs job/query-rekor-demo | python3 -c \"
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
\"
kubectl delete job query-rekor-demo"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${COLOR_RESET}"
echo -e "${GREEN}  Demo Complete! Location ≠ Authorization. Trust is Restored.     ${COLOR_RESET}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${COLOR_RESET}"
echo ""
