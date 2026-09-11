# Execution Plan: Task-Scoped Identity & Managed Release Gating with Kyverno and SPIFFE/SPIRE

**Date:** 2026-09-11  
**Target Event:** KubeCon Presentation  
**Target Branch:** `worktree-spiffe-spire-exploration`  
**Related Design:** `docs/plans/2026-05-14-spiffe-spire-trusted-tasks-design.md`, `docs/plans/2026-05-30-trusted-task-admission-status.md`  
**Implementation Guide:** `docs/dual-gated-release-guide.md`

---

## 1. Executive Summary & Core Premise

> *"You wouldn't ask a plumber to sign off on your electrical work. Yet most CI/CD pipelines run under a single identity: one credential for signing SBOMs and reporting vulnerabilities alike. Workload identities encode location, not authorization."*

This plan outlines the implementation and demonstration of **task-scoped cryptographic workload identities** in Tekton pipelines using **Kyverno** (admission classification and OCI bundle signature verification) and **SPIFFE/SPIRE** (workload attestation and identity issuance).

Furthermore, this document records the architectural analysis and implementation for the **Managed Context (Release Pipeline)** trust boundary, contrasting naive task-level identity with **PipelineRun-scoped dual-gating** (Model 2, implemented and verified) and **Cryptographic Policy Clearance Tokens** (Model 3, capability-based gating).

---

## 2. The Two Architectural Spheres

### Part A: The Tenant Context (Build Pipelines) — *KubeCon Presentation Core*
In untrusted tenant namespaces (`default-tenant`), pipelines execute arbitrary build scripts, package downloads, and container builds.
* **Goal:** Enforce separation of duties so tasks only receive identities authorized for their specific role.
* **Enforcement:**
  1. **Admission Gate (Kyverno):** Intercepts `TaskRun` creation. Verifies that the task definition is pinned by digest to an approved OCI bundle repository and verified by Cosign signature.
  2. **Role Classification:** Trusted tasks receive `trusted-task-role: prod`; untrusted/inline/tampered tasks receive `trusted-task-role: dev`.
  3. **Attestation (SPIRE):** SPIRE evaluates the Kyverno-verified pod labels and mints role-specific SVIDs:
     - Scanner Task (`trivy-sbom-scan`) ➔ `spiffe://konflux-ci.dev/trusted/{cluster}/{sa}/trivy-sbom-scan`
     - Builder Task (`buildah-oci-ta`) ➔ `spiffe://konflux-ci.dev/trusted/{cluster}/{sa}/buildah-oci-ta`
  4. **Attestation Signing:** Tasks exchange their SVID via Fulcio to sign in-toto statements (`https://aquasecurity.github.io/trivy/report/v1` vs SLSA provenance / SBOM).
  5. **Policy Verification (Conforma):** Conforma ensures that the SBOM was signed by a builder identity and CVE reports were signed by a scanner identity. If a builder attempts to sign off on a vulnerability scan, Conforma rejects it.

---

### Part B: The Managed Context (Release Pipelines) — *Release Gate Trust Model*

#### The Architectural Problem with Task-Scoped Identity in `managed-tenant`
In the platform's release namespace (`managed-tenant`), a task-scoped identity like:
```text
spiffe://konflux-ci.dev/trusted/{cluster}/release-service-account/attach-summary-attestations
```
proves only **which container script ran**, not **whether the release policy was satisfied**.

Consumers verifying a Verification Summary Attestation (VSA) or Software Verification Report (SVR) need guarantees that:
1. `verify-conforma` ran and passed with 0 violations.
2. The evaluation used the authorized `EnterpriseContractPolicy` (and pinned revision).
3. Early tasks (e.g. `collect-data` or `apply-mapping`) could not leverage ambient authority to sign a VSA prematurely.

#### Crucial Invariant: Why `verify-conforma` Must Be a Trusted Task
In both Model 2 and Model 3, **`verify-conforma` itself must be a trusted, signed catalog task admitted by Kyverno (`trusted-task-role: prod`)**.
- If a tenant or compromised managed pipeline could substitute an arbitrary or unpinned `verify-conforma` task (e.g. replacing the image with a container that simply runs `echo '{"result":"SUCCESS"}'`), any downstream gating mechanism is rendered useless.
- Therefore, the pipeline admission gate must enforce that `verify-conforma` is pulled from a digest-pinned, Cosign-signed catalog bundle before any release workflow is permitted to proceed.

---

## 3. Comparison of Release Trust Models

| Dimension | Model 1: Static Keypair (Baseline) | Model 2: Dual-Gated Identity (Implemented) | Model 3: Clearance Token (Capability Gating) |
| :--- | :--- | :--- | :--- |
| **Trust Anchor** | Secret in `managed-tenant` | Kyverno admission + SPIRE pod conjunction | Ephemeral JWT signed by Policy Evaluator |
| **Identity Scope** | Ambient ServiceAccount | PipelineRun-scoped release authority | Ephemeral Capability Token tied to Policy Verdict |
| **Gating Level** | Control plane (ServiceAccount) | Control plane conjunction (Kyverno + SPIRE) | Data plane cryptographic token handoff |
| **Attestation Signer** | Long-lived static key | Short-lived Fulcio cert with Release SAN | Fulcio cert issued on clearance presentation |
| **Policy Proof** | Implicit (assumes pipeline ran) | Implicit (conjunction ensures late pipeline step) | **Explicit & Cryptographic** (verdict in token) |
| **Replay Protection** | None (key usable anytime) | Bound to PipelineRun lifecycle | Token bound to PipelineRun UID + image digest |
| **Implementation Status**| Baseline (`main`) | **Fully Implemented & Verified Live** | Detailed Architectural Specification |

---

## 4. Deep-Dive: Model 2 — PipelineRun-Scoped Dual-Gated Identity *(Implemented)*

Model 2 solves the ambient authority problem by issuing the release authority identity **only** to the exact task in the pipeline that is authorized to attach attestations, and only when running inside the legitimate release pipeline.

### Conjunction Rules:
1. **Admission Rule (`classify-release-authority` ClusterPolicy):**
   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: classify-release-authority
   spec:
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

2. **Attestation Conjunction (`ClusterSPIFFEID` `konflux-release-authority`):**
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
       spiffe://{{ .Values.trustDomain }}/release/{{ index .PodMeta.Labels "appstudio.openshift.io/application" }}/{{ index .PodMeta.Labels "tekton.dev/pipeline" }}
   ```

### Execution Guarantee:
- Early tasks (`collect-data`, `apply-mapping`, `verify-conforma`, `push-snapshot`) match `trusted-pipeline-role: release-authority`, but their `tekton.dev/pipelineTask` is NOT `attach-summary-attestations`. SPIRE issues **no identity**.
- Only `attach-summary-attestations` matches both selectors. It receives:
  `spiffe://konflux-ci.dev/release/test-app/slsa-e2e-release-dual-gated`.
- Fulcio issues an ephemeral certificate with that SAN; Cosign signs the VSA and SVR to Rekor.

---

## 5. Deep-Dive: Model 3 — Cryptographic Policy Clearance Token *(Capability-Based Gating)*

While Model 2 enforces control-plane gating (admitting the task only at the right step), Model 3 advances to **zero-trust capability-based gating**. Signing authority is physically un-mintable without a passing cryptographic proof issued by the policy engine.

### Architectural Flow:
```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. verify-conforma Evaluates EnterpriseContractPolicy                       │
│    Runs 104 rules against Snapshot, SBOMs, CVE scans, and SLSA provenance.  │
│    Status verdict: 104/104 PASSED (0 violations).                           │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 2. Ephemeral Clearance Token Minting                                        │
│    verify-conforma requests / mints an ephemeral Clearance JWT Token:       │
│    Signed by Policy Evaluator Private Key (or SPIRE OIDC delegated signer). │
│                                                                             │
│    Claims:                                                                  │
│      iss: https://policy.konflux-ci.dev/verifier                            │
│      sub: pipelinerun/dual-gated-release-9vd22                              │
│      aud: sigstore-release-ca                                               │
│      digest: sha256:b27826d99fa895c302c327c58ca1d861b962b7cc...             │
│      verdict: PASSED                                                        │
│      policy_hash: sha256:1b296a925b4021f4b4959ea289596925...                │
│      exp: <5 minutes>                                                       │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │ (Passed via Trusted Artifacts OCI)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 3. Token Presentation at Signing Gate                                       │
│    attach-summary-attestations unpacks clearance-token.jwt.                │
│    Presents to Fulcio:                                                      │
│      1. Workload Identity (JWT-SVID from SPIRE Workload API)                │
│      2. Clearance Token (policy proof)                                      │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 4. Fulcio Verification & Certificate Issuance                               │
│    Fulcio validates:                                                        │
│      • SPIFFE SVID proves the caller is attach-summary-attestations         │
│      • Clearance Token signature is valid from the Policy Evaluator         │
│      • Token claims match: pipelinerun_uid and image digest                 │
│      • Token verdict == PASSED and exp has not expired                      │
│    Fulcio embeds custom extension:                                          │
│      1.3.6.1.4.1.57264.1.X (Policy Clearance Verdict: PASSED)               │
│    Issues signing certificate. Cosign attaches VSA to container image.      │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Threat Model & Mitigations:
1. **Malicious / Compromised Pipeline Task:**
   - *Threat:* An earlier task in `managed-tenant` attempts to sign a VSA without running policy checks.
   - *Mitigation:* Fulcio rejects certificate requests lacking a valid `clearance-token.jwt` signed by the Policy Evaluator.
2. **Replay Across Pipeline Runs:**
   - *Threat:* An attacker reuses an old passing clearance token from a previous build on a newly built, vulnerable snapshot.
   - *Mitigation:* The clearance token is bound to both the unique `PipelineRunUID` and the immutable target container `image-digest`, with a tight 5-minute TTL.
3. **Forged Policy Engine:**
   - *Threat:* An attacker runs a fake `verify-conforma` task that always returns success.
   - *Mitigation:* Kyverno requires `verify-conforma` to be a signed catalog bundle (`trusted-task-role: prod`). Only tasks with the authenticated policy evaluator SPIFFE identity can obtain the token-signing key from SPIRE.

---

## 6. Implementation Roadmap & Verified Deliverables

### Phase 1: Local Patched Kyverno Controller Deployment *(Completed)*
- Built patched Kyverno admission controller from `~/workspace/src/github.com/arewm/kyverno` (`fix/imageextractor-filter`) containing PR #16268 (scalar skip) and PR #16269 (`filter` field on `imageExtractors`).
- Loaded image `kind.local/kyverno:latest` into Kind cluster `konflux`.
- Deployed Kyverno Helm chart with custom CA and internal registry credentials mounted.

### Phase 2: Deploy Admission Policies (`charts/admission-policy`) *(Completed)*
- Deployed `classify-taskrun`: labels tasks `dev` or `prod` based on digest-pinning and trusted catalog patterns.
- Deployed `prevent-pod-label-spoofing`: validates ownerReference to prevent label spoofing.
- Deployed `verify-bundle-signatures`: enforces Cosign signatures on Tekton catalog task bundles using `type: SigstoreBundle` and `filter: bundle`.
- Deployed `classify-release-authority`: stamps `trusted-pipeline-role: release-authority` on release pipeline tasks.

### Phase 3: Deploy SPIFFE/SPIRE Infrastructure (`charts/spiffe-spire`) *(Completed)*
- Deployed SPIRE Server, Agent DaemonSet, SPIFFE CSI Driver, and SPIRE OIDC Discovery Provider.
- Configured `ClusterSPIFFEID`s: `konflux-dev`, `konflux-trusted-prod`, and `konflux-release-authority`.
- Configured in-cluster Fulcio with SPIRE root CA and OIDC discovery URL.

### Phase 4: Non-Breaking Dual-Mode Task Configuration *(Completed)*
- Updated `attach-summary-attestations` to auto-detect SPIFFE CSI socket at `/spiffe-workload-api/spire-agent.sock` and execute keyless Cosign attestations via Fulcio/Rekor, falling back to static keypairs if absent.
- Configured Tekton Chains in `TektonConfig` via `scripts/setup-prerequisites.sh` to use `storage.oci.encoding-format: sigstore-bundle` (OCI 1.1 Referrers).
- Created and executed `slsa-e2e-release-dual-gated.yaml` demonstrating full Model 2 dual-gating.

---

## 7. The Live Demo Script

1. **Scene 1 — The Untrusted Task (Role: Dev):**
   - Submit a PipelineRun with an unpinned or untrusted task bundle.
   - Kyverno admission stamps `trusted-task-role: dev`.
   - Pod receives `spiffe://konflux-ci.dev/dev/...`.
   - Conforma policy rejects dev identity signature for production release.

2. **Scene 2 — The Trusted Separation of Roles (Role: Prod):**
   - Submit the official SLSA build pipeline with signed catalog task bundles.
   - Kyverno verifies Cosign bundle signature; stamps `trusted-task-role: prod`.
   - **Trivy Pod** receives `.../trivy-sbom-scan` ➔ Signs CVE report.
   - **Buildah Pod** receives `.../buildah-oci-ta` ➔ Signs SBOM and provenance.

3. **Scene 3 — The Conforma Policy Evaluation:**
   - Execute Conforma policy validation.
   - Proves separation of duties: CVE report must be signed by scanner, SBOM by builder.
   - Adversarial attempt (builder signs CVE report) is rejected by Rego policy.

4. **Scene 4 — The Managed Release Boundary (Dual-Gated Authority):**
   - Execute `slsa-e2e-release-dual-gated`.
   - Demonstrate that early tasks in `managed-tenant` have NO release identity.
   - Once `verify-conforma` clears 104/104 checks, `attach-summary-attestations` matches the dual-gate conjunction.
   - SPIRE mints `spiffe://konflux-ci.dev/release/test-app/slsa-e2e-release-dual-gated`.
   - Keyless VSA/SVR signed into Rekor transparency log.
