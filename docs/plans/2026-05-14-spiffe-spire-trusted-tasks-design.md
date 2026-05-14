# SPIFFE/SPIRE + Trusted Tekton Tasks in Konflux

Date: 2026-05-14

## Problem

Konflux currently establishes trust in task results by analyzing their
provenance after the pipeline completes. Conforma evaluates whether a task
bundle was on a trusted list, whether the bundle was signed, and whether it
was pinned by digest. This works, but it means trust is determined
retroactively -- untrusted tasks run to completion before being caught, and
the trust signal isn't available to the task itself during execution.

We want to move the trust decision earlier: determine trust at admission
time, encode it as a cryptographic workload identity (SPIFFE), and let
tasks sign attestations with that identity. Downstream verifiers can then
check the signing identity on the attestation directly, without
re-verifying the bundle provenance.

## Design Decisions

These were explored and agreed during the brainstorming session:

1. **Two new Helm charts**, independent of existing `platform-config`:
   - `charts/admission-policy/` -- trust classification of TaskRuns
   - `charts/spiffe-spire/` -- SPIRE identity infrastructure + Fulcio integration

2. **Admission classifies, never blocks.** Failed verification results in a
   `dev` label, not a rejected TaskRun. Tasks always run; the label
   determines the SPIFFE identity they receive.

3. **Full SPIFFE ID hierarchy:**
   `spiffe://konflux-ci.dev/trusted/{cluster-id}/{service-account}/{task-name}`
   for prod, `spiffe://konflux-ci.dev/dev/{cluster-id}/{sa}/{task-name}` for
   dev. Both tiers include the cluster segment — you want to know where
   something ran regardless of trust classification.

4. **Fulcio integration via SPIRE OIDC Discovery Provider.** SPIRE issues
   JWT-SVIDs; cosign exchanges them with Fulcio for code signing
   certificates. No direct signing with X.509-SVIDs (wrong EKU, expiry
   problems). Integrates with the existing `konflux-ci/integrations/sigstore/`
   deployment rather than deploying a separate Sigstore stack.

5. **Both Kyverno and native VAP explored** for admission. Kyverno provides
   full coverage (mutation + signature verification). VAP handles URL/digest
   matching but cannot do signature verification natively -- that gap is
   documented.

6. **Per-pattern signing key configuration.** Different task catalogs may be
   signed by different parties. Multiple keys supported per URL pattern.

7. **Pod bypass prevention.** Any Pod with a `trusted-task-role` label must
   have ownerReferences tracing to the Tekton controller. Bare Pods with the
   label are blocked. Additionally, ClusterSPIFFEID selectors require a
   specific ServiceAccount for defense in depth.

8. **Every task signs; the identity is what matters.** Both trusted and dev
   tasks receive SPIFFE identities and sign attestations. The admission
   policy doesn't gate signing ability — it determines the identity embedded
   in the signature. A `dev/` signature is valid, it just tells verifiers
   "this task was not pre-verified at admission." The security model is
   about *who* signed, not *whether* something is signed.

## Architecture

### End-to-End Flow

```
User submits PipelineRun
        |
        v
+----------------------------------+
|  TaskRun Created                 |
|  spec.taskRef: bundle + digest   |
+---------------+------------------+
                |
                v
+----------------------------------+
|  Admission (Kyverno/VAP)         |
|  1. URL pattern match?           |
|  2. Digest pinned?               |
|  3. Signature valid?             |
|  Result: trusted-task-role label |
|    prod --or-- dev               |
+---------------+------------------+
                |
                v
+----------------------------------+
|  Pod Created by Tekton           |
|  Labels: trusted-task-role,      |
|    tekton.dev/task, etc.         |
|  Volume: spiffe-csi-driver       |
+---------------+------------------+
                |
                v
+----------------------------------+
|  Pod Admission                   |
|  Verify ownerRef -> Tekton       |
|  (blocks bare pods with label)   |
+---------------+------------------+
                |
                v
+----------------------------------+
|  SPIRE Identity Issuance         |
|  Matches label -> ClusterSPIFFEID|
|  prod -> spiffe://konflux-ci.dev/|
|    trusted/{cluster}/{sa}/{task}  |
|  dev  -> spiffe://konflux-ci.dev/|
|    dev/{cluster}/{sa}/{task}      |
+---------------+------------------+
                |
                v
+----------------------------------+
|  Task Execution                  |
|  1. Cosign detects SPIFFE socket |
|  2. Fetches JWT-SVID from        |
|     Workload API (CSI mount)     |
|  3. Exchanges JWT with Fulcio    |
|     -> code signing cert with    |
|       SPIFFE ID as URI SAN       |
|  4. Signs attestation            |
|  5. Logs to Rekor                |
+---------------+------------------+
                |
                v
+----------------------------------+
|  Verification (Conforma)         |
|  Check attestation cert identity |
|  "trusted/" = pre-verified       |
|  {sa}/{task} = specific workload |
|  No bundle re-verification needed|
+----------------------------------+
```

### Why Two Admission Tiers

The admission policy operates at two levels because different information
is available at each:

**TaskRun admission** has the bundle reference (`spec.taskRef` with URL and
digest). This is the only point where bundle provenance can be evaluated --
URL matching, digest pinning, signature verification. The result is the
`trusted-task-role` label.

**Pod admission** does not have the bundle reference (Tekton resolves it
before creating the Pod). But Pods are what SPIRE watches. Without the Pod
tier, a user could create a bare Pod with `trusted-task-role: prod` and
receive a trusted SPIFFE identity without going through TaskRun admission.
The Pod tier blocks any Pod with the label unless its ownerReferences trace
to the Tekton controller.

### Tekton Label Propagation

Tekton natively propagates these labels to task Pods (confirmed in
`tektoncd/pipeline` source, `pkg/pod/pod.go:makeLabels`):

- `tekton.dev/task` -- the resolved Task name
- `tekton.dev/taskRun` -- the TaskRun name
- `tekton.dev/pipeline` -- the Pipeline name (if applicable)
- `tekton.dev/pipelineRun` -- the PipelineRun name (if applicable)
- `tekton.dev/pipelineTask` -- the pipeline task reference name

All TaskRun labels are copied through to the Pod. This means the
`trusted-task-role` label set by admission and the `tekton.dev/task` label
are both available to SPIRE's ClusterSPIFFEID template without any extra
work.

## Chart: `charts/admission-policy/`

### Purpose

Classifies TaskRuns by trust level based on bundle provenance. Does not
block any TaskRuns -- failed checks result in a `dev` label, not rejection.

### Classification Flow

Applied at TaskRun creation via admission mutation:

1. Extract bundle reference from `spec.taskRef`
2. Match URL against configured trusted repository patterns
3. Verify digest pinning (`@sha256:` required)
4. Verify bundle signature against configured signing keys for the matching
   pattern (multiple keys supported per pattern)
5. All pass -> `trusted-task-role: prod`. Any fail -> `trusted-task-role: dev`.

### Pod Bypass Prevention

Applied at Pod creation via admission validation:

- Any Pod with a `trusted-task-role` label (either `prod` or `dev`) must
  have ownerReferences tracing to the Tekton controller
- Bare Pods with the label are blocked

### Configuration

```yaml
# charts/admission-policy/values.yaml
engine: kyverno  # or "vap"

trustedBundles:
  - pattern: "quay.io/konflux-ci/tekton-catalog/*"
    signingKeys:
      - name: "konflux-release-2026"
        publicKey: |
          -----BEGIN PUBLIC KEY-----
          ...
          -----END PUBLIC KEY-----
      - name: "konflux-release-2025"
        publicKey: |
          -----BEGIN PUBLIC KEY-----
          ...
          -----END PUBLIC KEY-----
  - pattern: "quay.io/my-org/custom-tasks/*"
    signingKeys:
      - name: "my-org-key"
        publicKey: |
          -----BEGIN PUBLIC KEY-----
          ...
          -----END PUBLIC KEY-----
```

### Engine Comparison

| Capability | Kyverno | VAP (CEL) |
|---|---|---|
| URL pattern matching | Yes | Yes |
| Digest pinning check | Yes | Yes |
| Bundle signature verification | Yes (`verifyImages`) | No (needs companion webhook) |
| Label mutation | Yes | Yes (MutatingAdmissionPolicy, k8s 1.32+) |
| ownerRef validation | Yes | Yes |

VAP provides a no-dependency option for everything except signature
verification. When signature verification is required, Kyverno is the
simpler choice. VAP with a companion signature-verification webhook is
viable but adds a component to maintain.

## Chart: `charts/spiffe-spire/`

### Purpose

Deploys SPIRE identity infrastructure and integrates with the existing
Sigstore deployment (from `konflux-ci/integrations/sigstore/`).

### Components

Deployed using the upstream `spiffe/helm-charts-hardened` as a subchart
dependency:

- **SPIRE Server** (StatefulSet) -- stores registration entries, manages
  the trust domain CA. Configured with trust domain `konflux-ci.dev`.

- **SPIRE Agent** (DaemonSet) -- authenticates workloads via `k8s_psat`
  node attestor. Exposes the Workload API socket to pods via the
  `spiffe-csi-driver` CSI plugin.

- **SPIRE Controller Manager** -- watches ClusterSPIFFEID CRDs and
  automatically creates/deletes SPIRE registration entries.

- **SPIRE OIDC Discovery Provider** -- serves
  `/.well-known/openid-configuration` and JWKS endpoints. Fulcio validates
  JWT-SVIDs against this endpoint. Must be reachable from the Fulcio
  deployment within the cluster.

### ClusterSPIFFEID Resources

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: konflux-trusted-prod
spec:
  spiffeIDTemplate: >-
    spiffe://konflux-ci.dev/trusted/
    {{- .ClusterName }}/
    {{- .PodSpec.ServiceAccountName }}/
    {{- index .PodMeta.Labels "tekton.dev/task" }}
  podSelector:
    matchLabels:
      trusted-task-role: "prod"
  namespaceSelector:
    matchLabels:
      trusted-tasks-enabled: "true"
---
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: konflux-dev
spec:
  spiffeIDTemplate: >-
    spiffe://konflux-ci.dev/dev/
    {{- .ClusterName }}/
    {{- .PodSpec.ServiceAccountName }}/
    {{- index .PodMeta.Labels "tekton.dev/task" }}
  podSelector:
    matchLabels:
      trusted-task-role: "dev"
```

The prod ClusterSPIFFEID additionally restricts by namespace
(`trusted-tasks-enabled: "true"` label) for defense in depth.

### Fulcio Integration

A post-install hook or integration script adds the SPIRE OIDC Discovery
Provider as a trusted issuer to the existing Fulcio deployment. This
requires:

- Fulcio's `config.json` to include the SPIRE OIDC issuer URL
- The OIDC Discovery Provider to be reachable from Fulcio at its configured
  URL
- The `jwt_issuer` in SPIRE Server config to match the issuer URL Fulcio
  expects

### Configuration

```yaml
# charts/spiffe-spire/values.yaml
trustDomain: "konflux-ci.dev"
clusterName: "kind-konflux"

# OIDC Discovery Provider for Fulcio integration
oidcDiscoveryProvider:
  enabled: true

# Fulcio integration
fulcio:
  # Namespace where Fulcio is deployed (from integrations/sigstore/)
  namespace: "sigstore-system"
  # Add SPIRE OIDC provider as a trusted issuer
  configureIssuer: true

# Namespace selector for prod identity issuance
trustedNamespaceLabel: "trusted-tasks-enabled"
```

## Task Bundle Changes

This does not replace Tekton Chains for SLSA provenance. Chains continues
to produce the pipeline-level provenance attestation for the PipelineRun.

SPIFFE identities are used for **task-level attestations** -- artifacts a
task produces and wants to cryptographically bind to its identity:

- **SBOM**: a build task produces an SBOM, pushes it via the OCI referrers
  API, then signs it. The signature proves "this SBOM was produced by the
  `buildah` task running as a trusted workload in cluster X."
- **Vulnerability scan results**: a scan task signs a VEX/CSAF or custom
  predicate with its identity.
- **Test results**: an integration test task signs its result predicate.
- **Source attestation**: `git-clone` could sign an attestation binding the
  source commit to the checkout it provided.

Tasks that produce these signed attestations need a CSI volume mount for
the SPIFFE Workload API socket. Cosign handles the rest automatically --
it detects the SPIFFE socket, fetches a JWT-SVID, exchanges it with Fulcio
for a signing cert, and signs the attestation.

```yaml
# Added to task bundle spec
volumes:
  - name: spiffe-workload-api
    csi:
      driver: csi.spiffe.io
      readOnly: true

steps:
  - name: attest
    image: gcr.io/projectsigstore/cosign
    env:
      - name: SPIFFE_ENDPOINT_SOCKET
        value: "unix:///spiffe-workload-api/spire-agent.sock"
      - name: SIGSTORE_FULCIO_URL
        value: "http://fulcio.sigstore-system.svc"
      - name: SIGSTORE_REKOR_URL
        value: "http://rekor.sigstore-system.svc"
    volumeMounts:
      - name: spiffe-workload-api
        mountPath: /spiffe-workload-api
        readOnly: true
    script: |
      cosign attest --yes \
        --type <predicate-type> \
        --predicate <predicate-file> \
        <image-ref>
```

Cosign's SPIFFE provider (added in v1.5.0, `pkg/providers/spiffe/spiffe.go`)
automatically detects the socket via `SPIFFE_ENDPOINT_SOCKET`, fetches a
JWT-SVID with the Fulcio audience, and uses it as the OIDC identity token.
No flags or wrappers required.

## Relationship to Existing Systems

### Conforma and trusted_task_rules (ADR 0053)

The admission policy is a **pre-compute** of the trust decision that
Conforma would otherwise make post-run. Instead of Conforma re-verifying
the bundle signature after the pipeline completes, the trust decision is
encoded in the SPIFFE identity at admission time. Conforma can then check
the attestation's signing certificate identity -- if it contains
`spiffe://konflux-ci.dev/trusted/...`, trust was already established.

The admission policy's signing key configuration is separate from
Conforma's `trusted_task_rules` data format. They serve the same purpose
at different lifecycle stages and can have independent configs. The
operational invariant is that they should agree on what's trusted.

See also: [conforma/policy#1680](https://github.com/conforma/policy/pull/1680)
for per-allow-rule signature verification in Conforma, and
[ADR 0053](https://github.com/konflux-ci/architecture/blob/main/ADR/0053-trusted-task-model.md)
for the trusted task model.

### Tekton Chains

Chains continues to generate SLSA provenance attestations for PipelineRuns
as it does today. SPIFFE/SPIRE does not replace this. Instead, it adds a
complementary attestation layer: individual tasks sign the artifacts they
produce (SBOMs, scan results, test results) with their SPIFFE-derived
identity. Chains provides pipeline-level provenance; SPIFFE provides
task-level identity binding for ancillary attestations.

### tsf-cli / Red Hat Trusted Artifact Signer

The `tsf-cli` deploys Red Hat's productized Sigstore (TAS) on OpenShift
via OLM. The community `konflux-ci/integrations/sigstore/` uses the
upstream `sigstore/scaffold` Helm chart. The SPIRE integration should
work with either -- both expose Fulcio with configurable OIDC issuers.

## Security Controls

| Attack Vector | Mitigation |
|---|---|
| Malicious/unsigned bundle | Admission labels as `dev`; gets dev SPIFFE identity only |
| Tag mutability (TOCTOU) | Digest pinning required for `prod` label |
| Label spoofing (bare Pod) | Pod admission blocks Pods with `trusted-task-role` unless owned by Tekton |
| Task substitution | SPIFFE ID encodes task name + SA + cluster; verifiers check specific identity |
| SVID theft via sidecar | Lockdown rule forbids sidecars in prod TaskRuns |
| Volume tampering | If SPIFFE socket is overridden, cosign fails to connect; no signature produced |
| Stale trust | Signing key rotation via per-pattern key lists; Conforma handles expiry |

## Chains Signing with Fulcio

Tekton Chains should use Fulcio directly for signing SLSA provenance,
rather than a separate cosign keypair. Chains is a long-running controller,
not a task workload -- it doesn't need SPIRE's per-task identity
classification. It presents its own ServiceAccount token to Fulcio and
receives a cert with the Chains controller's identity.

This eliminates the `signing-secrets` keypair in the `tekton-chains`
namespace and the associated key generation/rotation burden.

The signing identity picture becomes:

- **Pipeline-level provenance** (SLSA predicate): signed by Chains via
  Fulcio directly, identity = the Chains controller SA
- **Task-level attestations** (SBOM, scan results, test results, SVRs):
  signed by individual tasks via SPIRE -> Fulcio, identity =
  `spiffe://konflux-ci.dev/{trusted|dev}/{cluster}/{sa}/{task}`

These are two different signers at two different lifecycle stages. Chains
attests "here's what the pipeline did." Tasks attest "here's what I
specifically produced."

## Build-Time Verification with SVR Attestations

### Shifting Verification Left

Currently, all policy evaluation happens at release time in the managed
pipeline. The `verify-conforma` task has a 4-hour timeout and is the
primary bottleneck in the release flow. With task-level SPIFFE identities,
policy verification can shift to the build pipeline.

A trusted `verify-conforma` task runs in the integration test scenario
(ITS), after the build pipeline completes and Chains has produced the
provenance attestation. At this point all task-level attestations (SBOM,
source, etc.) are attached to the image. The `verify-conforma` task
evaluates all policies -- digest pinning, required attestations, hermetic
build, CVE checks -- and produces a Simple Verification Result (SVR)
attestation recording the outcome.

### SVR Predicate

The SVR uses the [in-toto SVR predicate](https://github.com/in-toto/attestation/blob/main/spec/predicates/svr.md)
(`https://in-toto.io/attestation/svr/v0.1`):

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [
    {
      "name": "registry.example/image",
      "digest": {"sha256": "..."}
    }
  ],
  "predicateType": "https://in-toto.io/attestation/svr/v0.1",
  "predicate": {
    "verifier": {
      "id": "spiffe://konflux-ci.dev/trusted/kind-konflux/appstudio-pipeline/verify-conforma",
      "policy": {
        "uri": "oci://quay.io/conforma/policy:latest",
        "digest": {"sha256": "abc123..."}
      }
    },
    "timeCreated": "2026-05-15T10:00:00Z",
    "properties": [
      "CONFORMA_SLSA_BUILD_LEVEL_3",
      "CONFORMA_SLSA_SOURCE_LEVEL_3",
      "CONFORMA_HERMETIC_BUILD_TASK",
      "CONFORMA_REQUIRED_TASKS_PRESENT",
      "CONFORMA_DIGEST_PINNED",
      "CONFORMA_NO_CRITICAL_VULNERABILITIES"
    ]
  }
}
```

The `verifier.id` is the task's SPIFFE URI from its Fulcio cert. Each
passing conforma rule becomes a property entry.

The `verifier.policy` extension captures the full evaluation context, not
just the Rego source. The same policy rules with different rule_data (e.g.,
trusted task lists, CVE leeway values) produce different results, so all
inputs that affect the evaluation must be pinned:

```json
"verifier": {
  "id": "spiffe://konflux-ci.dev/trusted/kind-konflux/appstudio-pipeline/verify-conforma",
  "policy": {
    "uri": "k8s://managed-tenant/enterprise-contract-policy",
    "digest": {"sha256": "..."},
    "sources": [
      {
        "uri": "oci://quay.io/conforma/policy:latest",
        "digest": {"sha256": "aaa..."}
      }
    ],
    "data": [
      {
        "uri": "oci://quay.io/conforma/data:latest",
        "digest": {"sha256": "bbb..."}
      }
    ],
    "extraRuleData": "pipeline_intention=release"
  }
}
```

The top-level `digest` is a hash of the entire evaluation context: the ECP
CR's `.spec`, resolved policy source digests, resolved data source digests,
and extra rule data. This single value is what the release pipeline
compares to determine whether re-verification is needed. The individual
`sources` and `data` entries with their digests allow identifying which
specific input changed if the composite digest differs.

The ECP CR is pinned by hashing its `.spec` content rather than using the
Kubernetes `resourceVersion` (which changes on metadata updates, not just
spec changes). The `ec validate` command already resolves the ECP and all
its sources; it could compute and emit this composite digest as part of
SVR generation.

The SVR is signed by the `verify-conforma` task's SPIFFE-derived Fulcio
cert and attached to the image via the OCI referrers API.

### Release-Time Verification Shortcut

With a signed SVR attached to the image, the release pipeline no longer
needs to re-run the full conforma evaluation. The release-time check
becomes:

1. Does a valid SVR exist for this image, signed by a trusted
   `verify-conforma` functionary?
2. Does the policy digest in the SVR match the current active policy?

If the policy hasn't changed, accept the SVR and skip re-verification.
If the policy has changed, re-run conforma (or evaluate only the delta
if feasible).

This changes the release pipeline from re-deriving trust from scratch to
verifying a chain of signed evidence -- the in-toto layout model. Trust
comes from the cryptographic binding between the functionary identity
(SPIFFE ID in the Fulcio cert) and the attestation content.

### Conforma Performance Impact

Without this change, the release pipeline runs the full conforma
evaluation on every release -- fetching attestations from the registry,
evaluating all policy rules, checking CVE databases. This is the primary
bottleneck in the release flow (configured with a 4-hour timeout).

With build-time SVRs, the release-time cost when policy hasn't changed
drops to: one referrers API call to discover the SVR, one fetch to
retrieve it, one Fulcio cert chain verification, and one digest comparison
against the current policy. This replaces the full policy evaluation with
a handful of local crypto operations and registry calls.

Re-verification is only needed when the policy itself changes between
build and release, which is infrequent compared to the number of releases.

### VSA Signing in the Release Pipeline

The release pipeline still produces a VSA as the release-gate attestation.
With SPIFFE identities, the `verify-conforma` task in the release pipeline
signs the VSA with its own SPIFFE-derived Fulcio cert instead of the
`release-signing-key` keypair. This eliminates the key generation job, the
`release-signing-key` secret, and the RBAC roles for key access.

The conforma verification and VSA generation/signing should happen in the
same task so that a single task identity covers the entire "verify, produce
VSA, sign VSA" flow. The current `verify-conforma-vsa.yaml` task already
does this -- `ec validate` with `--vsa` generates the VSA in the same step
that runs policy evaluation. The separate `attach-vsa` task handles OCI
registry attachment and could be folded into the same task to keep a single
signing identity.

The release pipeline may still use a namespace-scoped key for signing
released images during `push-snapshot`. Image signing is a release action
distinct from attestation signing.

## Open Questions

1. **ClusterSPIFFEID template access to `.ClusterName`**: needs verification
   that the SPIRE controller manager exposes this. If not, cluster ID may
   need to be injected as a Helm value.

2. **Fulcio issuer reconfiguration**: the post-install hook to add SPIRE's
   OIDC provider as a trusted issuer may require restarting Fulcio. Need to
   test whether Fulcio hot-reloads its config.

3. **cosign `SPIFFE_ENDPOINT_SOCKET` path**: the CSI driver mount path and
   the socket filename within it need to match cosign's expectations.
   Default is `/tmp/spire-agent/public/api.sock`; the CSI driver may use a
   different layout.

4. **VAP MutatingAdmissionPolicy availability**: beta in k8s 1.32. KinD
   cluster version needs to support this for the VAP path to work.

5. **SPIFFE ID URI length limits**: the full hierarchy
   `spiffe://konflux-ci.dev/trusted/{cluster}/{sa}/{task}` may approach
   URI length limits in X.509 certificates if names are long. Need to verify.

6. **Conforma CLI keyless VSA signing**: the `ec` CLI currently accepts
   `--vsa-signing-key` for keypair-based VSA signing. It would need to
   support Fulcio/keyless signing for VSAs (using the task's SPIFFE-derived
   identity) to eliminate the keypair dependency.

7. **SVR property naming convention**: how conforma rule names map to SVR
   property strings. Whether to use a flat `CONFORMA_` prefix or encode
   the rule package hierarchy.

8. **Composite policy digest computation**: the `ec` CLI needs to compute
   and emit a digest covering the full evaluation context (ECP `.spec`,
   resolved policy source digests, resolved data source digests, extra rule
   data). This composite digest doesn't exist today -- `ec validate` would
   need to produce it as an output or include it in the SVR automatically.

9. **Chains Fulcio signing configuration**: Chains supports Fulcio as a
   signing backend but needs the cluster's Fulcio and Rekor endpoints
   configured, and Fulcio must trust the Chains controller's SA token
   issuer. Verify this works with the in-cluster Sigstore deployment.
