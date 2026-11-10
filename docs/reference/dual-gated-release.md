# Guide: Dual-Gated Managed Release Authority (Model 2)

This guide covers the architecture, implementation, and verification steps for **Trust Model 2 (PipelineRun-Scoped Dual-Gating)** in the Konflux release pipeline (`managed-tenant`).

---

## 1. Problem Statement: The Ambient Release Authority Trap

In standard CI/CD and release pipelines, signing keys or workload identities are commonly bound to a Kubernetes ServiceAccount (e.g. `release-service-account`).

That binding creates an **ambient authority problem**:
- Any task running in `managed-tenant` under `release-service-account` — `verify-access-to-resources`, `collect-data`, `reduce-snapshot`, `apply-mapping` — can sign release artifacts.
- Proving **which container script ran** (`.../release-service-account/attach-summary-attestations`) does **not** prove that the policy gate (`verify-conforma`) actually passed.
- If an early task is compromised, or if task order is rearranged, an artifact can be signed and released without satisfying enterprise contract policies.

---

## 2. Architecture of Model 2: Dual-Gated Conjunction

Model 2 closes the ambient authority gap with a cryptographic and admission conjunction between **Kyverno** (control plane admission) and **SPIFFE/SPIRE** (workload attestation):

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

### A. Kyverno MutatingPolicy: `classify-release-authority`
Located at `charts/admission-policy/templates/classify-release-authority.yaml`.

```yaml
apiVersion: policies.kyverno.io/v1beta1
kind: MutatingPolicy
metadata:
  name: classify-release-authority
spec:
  failurePolicy: Ignore
  matchConstraints:
    resourceRules:
      - apiGroups: ["tekton.dev"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["taskruns"]
  variables:
    - name: pipelineLabel
      expression: >-
        has(request.object.metadata.labels) && 'tekton.dev/pipeline' in request.object.metadata.labels
        ? request.object.metadata.labels['tekton.dev/pipeline'] : ''
    - name: managedType
      expression: >-
        has(request.object.metadata.labels) && 'pipelines.appstudio.openshift.io/type' in request.object.metadata.labels
        ? request.object.metadata.labels['pipelines.appstudio.openshift.io/type'] : ''
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: >-
          Object{
            metadata: Object.metadata{
              labels: request.namespace == 'managed-tenant' &&
                      variables.pipelineLabel == 'slsa-e2e-release-dual-gated' &&
                      variables.managedType == 'managed'
                ? {'trusted-pipeline-role': 'release-authority'} : {}
            }
          }
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
Tekton Chains `v0.29.0+` can publish provenance attestations and signatures directly as **OCI 1.1 Referrers** in Sigstore bundle format instead of pushing legacy `.sig` / `.att` image tags.

This is enabled declaratively on `TektonConfig` (configured via `scripts/setup-prerequisites.sh`):
```yaml
spec:
  chain:
    options:
      configMaps:
        chains-config:
          data:
            artifacts.oci.signer: "none"
            storage.oci.encoding-format: "sigstore-bundle"
```

When enabled, Chains produces OCI artifacts with `artifactType: application/vnd.dev.sigstore.bundle.v0.3+json` attached to the built image subject. This matches the OCI 1.1 Referrers architecture used by Conforma, Cosign, and our release pipeline.

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
        value: kubecon-na-2026-your-cis-mistaken-identity
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
      value: kubecon-na-2026-your-cis-mistaken-identity
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
UUID=$(curl -fsS -X POST -H 'Content-Type: application/json' \
  -d '{"hash":"<image-digest>"}' \
  http://rekor-server.rekor-system.svc.cluster.local/api/v1/index/retrieve | grep -oE '[a-f0-9]{64,}' | head -n1)
curl -fsS "http://rekor-server.rekor-system.svc.cluster.local/api/v1/log/entries/${UUID}" | python3 -c "
import sys, json, base64, subprocess, tempfile
raw = sys.stdin.read()
data = json.loads(raw[raw.index('{'):])
entry = list(data.values())[0]
body = json.loads(base64.b64decode(entry['body']).decode())
cert_b64 = body['spec']['signatures'][0]['verifier']
with tempfile.NamedTemporaryFile('w', suffix='.pem') as tf:
    tf.write(base64.b64decode(cert_b64).decode())
    tf.flush()
    print(subprocess.run(['openssl', 'x509', '-in', tf.name, '-noout', '-ext', 'subjectAltName'],
                         capture_output=True, text=True).stdout)
"
```
*Verified Subject Alternative Name (SAN):*
```text
X509v3 Subject Alternative Name: critical
    URI:spiffe://konflux-ci.dev/release/test-app/slsa-e2e-release-dual-gated
```

---

## 5. Label Guard Hardening

*Added as part of the release boundary hardening work — three fail-closed
Kyverno ClusterPolicies in `charts/admission-policy/`, gated by the
`hardening` values toggle (default `true`).*

### The rogue-pipeline threat

Model 2's dual gate trusts labels: `classify-release-authority` promotes a
TaskRun to `trusted-pipeline-role=release-authority` based on its labels, and
the ClusterSPIFFEID grants the release signing identity to whatever carries
that label. Before hardening, nothing stopped an attacker with namespace
write access from hand-crafting a PipelineRun in `managed-tenant` with the
managed markers (`pipelines.appstudio.openshift.io/type=managed`,
`appstudio.openshift.io/service=release`) — location and labels were
authorization. The Tekton controller would then happily spawn its TaskRuns,
propagating the forged markers, and the "managed" release pipeline — with
its signing authority — would run attacker-controlled code.

### The three guards

| Policy | Protects | Legitimate setter | Mechanism |
|---|---|---|---|
| `guard-managed-labels` | managed markers on PipelineRuns | release-service controller SA (`system:serviceaccount:release-service:release-service-controller-manager`) | deny when a marker transitions to its protected value and the requester is not the release SA; also deny marker injection via `taskRunSpecs[].metadata.labels` regardless of creator |
| `guard-task-labels` | `tekton.dev/pipeline`, `tekton.dev/pipelineTask`, `tekton.dev/pipelineRun` on TaskRuns | Tekton pipelines controller SA | deny when one of these labels is newly set or changed and the requester is not the Tekton controller |
| `validate-role-labels` | `trusted-task-role=prod`, `trusted-pipeline-role=release-authority` | nobody — recomputed invariants | deny when the claimed trust level does not survive a recompute of its classification conditions |

All three run with `failurePolicy: Fail` and `validationFailureAction:
Enforce` (fail-closed). The mutate policies (`classify-taskrun`,
`classify-release-authority`) keep `failurePolicy: Ignore` deliberately: if
Kyverno is unavailable, TaskRuns land unclassified ("dev", the trust floor)
rather than blocking the cluster — Ignore is availability-only, not
security, because the validating guards are the enforcement. This is the
*mutate-normalizes / validate-enforces* split.

### Design details worth knowing

* **Change-detection, not presence.** The usurpation rules compare
  `request.object` against `request.oldObject` (empty on CREATE), so
  controllers that patch annotations/status of an already-managed PipelineRun
  (Tekton Chains, the release-service reconciler) are not denied — only
  *transitions* of the protected labels are. Setting
  `pipelines.appstudio.openshift.io/type=build` remains unrestricted.
* **Spec-path laundering is structurally closed.** Verified against the
  Tekton v1 PipelineRun CRD: podTemplates carry no `labels` field, so the
  only spec path that can inject labels onto spawned TaskRuns is
  `taskRunSpecs[*].metadata.labels` — denied by `guard-managed-labels`
  regardless of creator, since no legitimate flow uses it.
* **Release-authority provenance chain.** `validate-role-labels` accepts
  `trusted-pipeline-role=release-authority` only when the TaskRun (a) is in
  `managed-tenant`, (b) carries the managed marker — which Tekton propagates
  from the PipelineRun (verified empirically) — and (c) has a
  `tekton.dev/pipelineRun` label, unforgeable via `guard-task-labels`, equal
  to its PipelineRun ownerReference name. A rogue cannot satisfy (c) even
  with a hand-set marker or a forged ownerReference, because it cannot set
  `tekton.dev/pipelineRun` itself. The named owner being genuinely managed
  follows transitively: the propagated marker comes from that PipelineRun,
  whose markers only the release-service controller may set.
* **`classify-taskrun`'s `set-dev` rule no longer overwrites hand-set
  labels.** Mutations run before validations in the admission chain, so
  normalizing a hand-set `trusted-task-role=prod` back to `dev` would hide
  the claim from `validate-role-labels`. The rule now only stamps the default
  when the label is absent; unearned claims reach the validator and are
  denied.

### Try the attacks yourself

```bash
# 1. Rogue managed PipelineRun (denied by guard-managed-labels)
kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: rogue-managed-pr-
  namespace: managed-tenant
  labels:
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
EOF

# 2. Hand-set prod trust without a pinned, trusted bundle
#    (denied by validate-role-labels)
kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: rogue-prod-label
  namespace: default-tenant
  labels:
    trusted-task-role: prod
spec:
  taskSpec:
    steps:
    - name: echo
      image: alpine:3.20
      script: echo rogue
EOF

# 3. Hand-set tekton.dev/pipeline label (denied by guard-task-labels)
kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: rogue-tekton-label
  namespace: default-tenant
  labels:
    tekton.dev/pipeline: slsa-e2e-release-dual-gated
spec:
  taskSpec:
    steps:
    - name: echo
      image: alpine:3.20
      script: echo rogue
EOF
```

All three are denied at admission; the legitimate flows (build
PipelineRuns, the release-service-created `managed-*` release PipelineRun,
catalog-signed TaskRuns) pass unchanged. `demo/run-demo.sh --act 4` opens
with the rogue-pipeline attack to show the denial live, then runs the real
Release CR → release-service → managed PipelineRun flow.

---

## 6. Future Direction: Run-Scoped Signing Capability

Dual-gating closes the rogue-pipeline hole, but it still assumes the
sanctioned pipeline orders policy verification before signing. The next
design removes that assumption by binding the signing capability to the
policy result:

1. **Run-scoped identities.** The release ClusterSPIFFEID template gains
   the pod's `tekton.dev/pipelineRun` label, so the SVID path embeds the
   PipelineRun UID. Two least-privilege identities replace one: a
   policy-writer SVID for `verify-conforma` (may write, not read) and the
   existing signer SVID for `attach-summary-attestations` (may read, not
   write). A task in any other run structurally cannot reach another
   run's capability.
2. **Policy-gated release signing.** The release signing key moves out of
   its namespace Secret into Vault. On a policy pass, `verify-conforma`
   writes a short-lived signing capability to
   `secret/release/<own-plr-uid>/<image-digest>`, authenticated by its
   run-scoped SVID. The signer reads it through its own run-scoped
   identity. Cross-run replay and cleared-for-X-sign-Y substitution both
   fail by construction: the readable path is derived from the reader's
   attested run, not from anything presented.
3. **Prerequisite.** Release authority must sign only via the Vault-held
   key. The signing task already supports keypair mode alongside keyless,
   so this is a configuration choice, not new machinery: keyless signing
   stays available to build tasks while release signing goes through the
   gated key.

Neither design is implemented yet; the dual-gate and label guards
described earlier in this guide are what runs today.
