# Guide: Dual-Gated Managed Release Authority (Model 2)

This document describes the architecture, implementation, and verification steps for **Trust Model 2 (PipelineRun-Scoped Dual-Gating)** in the Konflux release pipeline (`managed-tenant`).

---

## 1. Problem Statement: The Ambient Release Authority Trap

In standard CI/CD and release pipelines, signing keys or workload identities are commonly bound to a Kubernetes ServiceAccount (e.g. `release-service-account`). 

This creates an **ambient authority problem**:
- Any task running in `managed-tenant` under `release-service-account` (such as `verify-access-to-resources`, `collect-data`, `reduce-snapshot`, or `apply-mapping`) possesses the authority to sign release artifacts.
- Proving **which container script ran** (`.../release-service-account/attach-summary-attestations`) does **not** prove that the policy gate (`verify-conforma`) actually passed.
- If an early task is compromised, or if a task order is rearranged, an artifact could be signed and released without satisfying enterprise contract policies.

---

## 2. Architecture of Model 2: Dual-Gated Conjunction

Model 2 closes the ambient authority gap through a cryptographic and admission conjunction between **Kyverno** (control plane admission) and **SPIFFE/SPIRE** (workload attestation):

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. Release Initiation                                                       │
│    Release CR triggers PipelineRun: slsa-e2e-release-dual-gated            │
│    Running in namespace: managed-tenant                                     │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 2. Admission Gate (Kyverno Policy: classify-release-authority)              │
│    Inspects every TaskRun created by the release PipelineRun.               │
│    Preconditions:                                                           │
│      • Namespace == managed-tenant                                          │
│      • metadata.labels["tekton.dev/pipeline"] == slsa-e2e-release-dual-gated│
│    Mutates TaskRun metadata:                                                │
│      trusted-pipeline-role: release-authority                               │
│    (prevent-pod-label-spoofing guarantees tenant pods cannot self-assign)   │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 3. Pod Execution & Workload Attestation Filter (SPIRE Server)               │
│    ClusterSPIFFEID: konflux-release-authority                               │
│    Matches ONLY the conjunction:                                            │
│      • trusted-pipeline-role: release-authority                             │
│      • tekton.dev/pipelineTask: attach-summary-attestations                 │
│                                                                             │
│    - Early Tasks (apply-mapping, verify-conforma, push-snapshot):           │
│      tekton.dev/pipelineTask != attach-summary-attestations                 │
│      ==> NO SVID ISSUED (PermissionDenied on Workload API socket)           │
│                                                                             │
│    - Signing Step (attach-summary-attestations):                            │
│      Matches BOTH selector labels!                                          │
│      ==> Mints Release SVID:                                                │
│          spiffe://konflux-ci.dev/release/{application}/{pipeline}           │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 4. Keyless Signing & Transparency Log Entry                                 │
│    attach-summary-attestations presents JWT-SVID to Fulcio.                 │
│    Fulcio validates token against SPIRE OIDC discovery endpoint & root CA.  │
│    Fulcio issues ephemeral X.509 code-signing certificate:                  │
│      URI SAN: spiffe://konflux-ci.dev/release/{app}/{pipeline}              │
│    Cosign signs VSAs & SVR, records entry in Rekor transparency log,        │
│    and attaches OCI referrer bundles to the released image in the registry. │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Implementation Details

### A. Kyverno ClusterPolicy: `classify-release-authority`
Located at `charts/admission-policy/templates/classify-release-authority.yaml`.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: classify-release-authority
spec:
  failurePolicy: Ignore
  rules:
  - name: label-release-authority-taskrun
    match:
      any:
      - resources:
          kinds: ["TaskRun"]
          namespaces: ["managed-tenant"]
    preconditions:
      all:
      - key: "{{ request.object.metadata.labels.\"tekton.dev/pipeline\" || '' }}"
        operator: Equals
        value: "slsa-e2e-release-dual-gated"
    mutate:
      patchStrategicMerge:
        metadata:
          labels:
            trusted-pipeline-role: "release-authority"
```

### B. SPIRE ClusterSPIFFEID: `konflux-release-authority`
Located at `charts/spiffe-spire/templates/cluster-spiffe-id-release-authority.yaml`.

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: konflux-release-authority
spec:
  className: spire-spire
  namespaceSelector:
    matchLabels:
      trusted-tasks-enabled: "true"
  podSelector:
    matchLabels:
      trusted-pipeline-role: release-authority
      tekton.dev/pipelineTask: attach-summary-attestations
  spiffeIDTemplate: >-
    spiffe://{{ .Values.trustDomain }}/release/{{`{{ index .PodMeta.Labels "appstudio.openshift.io/application" }}/{{ index .PodMeta.Labels "tekton.dev/pipeline" }}`}}
```

### C. Runtime Dual-Mode Signing in `attach-summary-attestations`
Located at `managed-context/tasks/attach-summary-attestations/0.1/attach-summary-attestations.yaml`.

```bash
if [[ -S /spiffe-workload-api/spire-agent.sock ]]; then
  echo "Using SPIFFE Workload Identity for keyless signing..."
  export SPIFFE_ENDPOINT_SOCKET="/spiffe-workload-api/spire-agent.sock"
  cosign attest \
    --predicate "$VSA_FILE" \
    --type "$PRED_TYPE" \
    --use-signing-config=false \
    --fulcio-url="${SIGSTORE_FULCIO_URL:-http://fulcio-server.fulcio-system.svc.cluster.local}" \
    --rekor-url="${SIGSTORE_REKOR_URL:-http://rekor-server.rekor-system.svc.cluster.local}" \
    --yes \
    "$DEST_IMAGE"
else
  echo "Using static signing key..."
  cosign attest \
    --predicate "$VSA_FILE" \
    --type "$PRED_TYPE" \
    --key "$(params.VSA_SIGNING_KEY)" \
    --tlog-upload=false \
    "$DEST_IMAGE"
fi
```

### D. Fulcio OIDC Configuration
Fulcio is configured in `fulcio-server-config` to accept tokens from SPIRE's OIDC discovery provider, with SPIRE's root CA certificate provided in `CACert`:

```json
{
  "OIDCIssuers": {
    "https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local": {
      "IssuerURL": "https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local",
      "ClientID": "sigstore",
      "Type": "spiffe",
      "SPIFFETrustDomain": "konflux-ci.dev",
      "CACert": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----"
    }
  }
}
```

### E. Tekton Chains OCI 1.1 Referrers (`sigstore-bundle`)
Tekton Chains `v0.29.0+` supports publishing provenance attestations and signatures directly as **OCI 1.1 Referrers** in Sigstore bundle format rather than pushing legacy `.sig` / `.att` image tags.

This is enabled declaratively on `TektonConfig` (configured via `scripts/setup-prerequisites.sh`):
```yaml
spec:
  chain:
    options:
      configMaps:
        chains-config:
          data:
            storage.oci.encoding-format: "sigstore-bundle"
```

When enabled, Chains produces OCI artifacts with `artifactType: application/vnd.dev.sigstore.bundle.v0.3+json` attached to the built image subject, matching the OCI 1.1 Referrers architecture used by Conforma, Cosign, and our release pipeline.

---

## 4. Verification & Inspection Commands

### 1. Trigger a Release PipelineRun
```bash
cat << 'EOF' | kubectl create -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: dual-gated-release-
  namespace: managed-tenant
  labels:
    appstudio.openshift.io/application: test-app
    tekton.dev/pipeline: slsa-e2e-release-dual-gated
spec:
  taskRunTemplate:
    serviceAccountName: release-service-account
  pipelineRef:
    resolver: git
    params:
      - name: url
        value: https://github.com/arewm/slsa-konflux-example
      - name: revision
        value: worktree-spiffe-spire-exploration
      - name: pathInRepo
        value: managed-context/pipelines/slsa-e2e-release-dual-gated/slsa-e2e-release-dual-gated.yaml
  params:
    - name: release
      value: default-tenant/test-release-final
    - name: releasePlan
      value: default-tenant/test-app-release-plan
    - name: releasePlanAdmission
      value: managed-tenant/test-app-release-plan-admission
    - name: releaseServiceConfig
      value: release-service/release-service-config
    - name: snapshot
      value: default-tenant/test-snapshot-final
    - name: enterpriseContractPolicy
      value: '{"description":"SLSA policy","publicKey":"k8s://tekton-pipelines/public-key","sources":[{"name":"Policies","policy":["oci::quay.io/conforma/release-policy:konflux@sha256:1b296a925b4021f4b4959ea289596925a8735540e554f3ba7754a651731a216f"],"config":{"include":["@minimal"]}}]}'
    - name: taskGitUrl
      value: https://github.com/arewm/slsa-konflux-example
    - name: taskGitRevision
      value: worktree-spiffe-spire-exploration
    - name: ociStorage
      value: registry-service.kind-registry/trusted-artifacts
EOF
```

### 2. Verify Early Tasks Receive No Release Authority SVID
While `verify-conforma` or `apply-mapping` are executing, inspect SPIRE Server:
```bash
kubectl exec -n spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show | grep -A 5 "release/test-app"
```
*Result:* Returns empty. Early tasks match `trusted-pipeline-role: release-authority`, but do NOT match `pipelineTask: attach-summary-attestations`.

### 3. Verify Only `attach-summary-attestations` Receives the Release SVID
When `attach-summary-attestations` starts:
```bash
# Check pod labels
kubectl get pods -n managed-tenant -l tekton.dev/pipelineTask=attach-summary-attestations --show-labels

# Check SPIRE entry registration
kubectl exec -n spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show | grep -A 5 "release/test-app"
```
*Expected Output:*
```text
SPIFFE ID               : spiffe://konflux-ci.dev/release/test-app/slsa-e2e-release-dual-gated
Parent ID               : spiffe://konflux-ci.dev/spire/agent/k8s_psat/kind-konflux/...
```

### 4. Inspect Attestation Signing in Rekor
Query Rekor log entries generated during the release:
```bash
kubectl run query-rekor --image=curlimages/curl:latest --rm -it --restart=Never -- \
  curl -s http://rekor-server.rekor-system.svc.cluster.local/api/v1/log/entries | jq .
```

Decode the signer certificate from any of the newly created DSSE log entries:
```bash
python3 -c "
import json, base64, subprocess
# Fetch and print SAN
# cert_pem extracted from Rekor entry spec.signatures[0].verifier
"
```
*Verified Subject Alternative Name (SAN):*
```text
X509v3 Subject Alternative Name: critical
    URI:spiffe://konflux-ci.dev/release/test-app/slsa-e2e-release-dual-gated
```
