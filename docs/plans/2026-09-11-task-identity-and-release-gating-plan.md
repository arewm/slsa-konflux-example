# Execution Plan: Task-Scoped Identity & Managed Release Gating with Kyverno and SPIFFE/SPIRE

**Date:** 2026-09-11  
**Target Event:** KubeCon Presentation  
**Target Branch:** `worktree-spiffe-spire-exploration`  
**Related Design:** `docs/plans/2026-05-14-spiffe-spire-trusted-tasks-design.md`, `docs/plans/2026-05-30-trusted-task-admission-status.md`

---

## 1. Executive Summary & Core Premise

> *"You wouldn't ask a plumber to sign off on your electrical work. Yet most CI/CD pipelines run under a single identity: one credential for signing SBOMs and reporting vulnerabilities alike. Workload identities encode location, not authorization."*

This plan outlines the implementation and demonstration of **task-scoped cryptographic workload identities** in Tekton pipelines using **Kyverno** (admission classification and OCI bundle signature verification) and **SPIFFE/SPIRE** (workload attestation and identity issuance).

Furthermore, this document records an architectural analysis and design for the **Managed Context (Release Pipeline)** trust boundary, contrasting naive task-level identity with **PipelineRun-scoped identity** and **Cryptographic Policy Clearance Tokens**.

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

#### Three Evolving Release Trust Models

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. Current / Baseline: Static Keypair                                      │
│    - Signing key stored in Secret (managed-tenant/release-signing-key)      │
│    - Simple, offline, but ambient authority across the release SA           │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 2. PipelineRun-Scoped Dual-Gated Identity (SPIRE + Kyverno Conjunction)     │
│    - Identity represents the authorized release workflow:                   │
│      spiffe://konflux-ci.dev/release/{app}/{pipeline}                       │
│    - Issued ONLY to pods matching BOTH:                                     │
│      • trusted-pipeline-role: release-authority (verified by Kyverno)        │
│      • tekton.dev/pipelineTask: attach-summary-attestations                 │
│    - Early pipeline tasks have zero signing access                          │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 3. Cryptographic Policy Clearance Token (Capability-Based Gating)           │
│    - verify-conforma evaluates 104 rules                                    │
│    - If 104/104 pass with 0 violations:                                    │
│      Mints ephemeral JWT: clearance-token.jwt                               │
│        • sub: pipelinerun/{UID}                                             │
│        • digest: sha256:{image-digest}                                      │
│        • status: SUCCESS                                                    │
│    - attach-summary-attestations presents Token + SPIFFE identity to Fulcio│
│    - Replay-immune across pipeline runs; physical impossibility to sign    │
│      without a passing Conforma verdict                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Implementation Roadmap for the KubeCon Demo

### Phase 1: Local Patched Kyverno Controller Deployment
Because official Kyverno `v1.19.1` cut release 8 hours prior to the merge of PR #16269 (`filter` field on `imageExtractors`), we deploy the patched build from `~/workspace/src/github.com/arewm/kyverno` (`fix/imageextractor-filter`).

1. **Build Controller Image:**
   ```bash
   cd /Users/arewm/workspace/src/github.com/arewm/kyverno
   KO_DOCKER_REPO=kind.local make docker-build-admission-controller
   ```
2. **Load into Kind Cluster:**
   ```bash
   kind load docker-image kind.local/kyverno:latest --name konflux
   ```
3. **Deploy Kyverno via Helm:**
   - Install Kyverno CRDs with `filter` field in `ImageExtractorConfig`.
   - Deploy Kyverno controller pointing to `kind.local/kyverno:latest`.

---

### Phase 2: Deploy Admission Policies (`charts/admission-policy`)
Deploy the three Kyverno ClusterPolicies:
1. `classify-taskrun`: Labels TaskRuns with `trusted-task-role: dev` or `prod` based on digest-pinning and trusted bundle patterns.
2. `prevent-pod-label-spoofing`: Enforces that pods cannot self-assign `trusted-task-role`.
3. `verify-bundle-signatures`: Uses `filter: "bundle"` and `type: SigstoreBundle` to enforce cryptographic Cosign signatures on OCI referrer bundles.

```bash
helm upgrade --install admission-policy \
  .claude/worktrees/spiffe-spire-exploration/charts/admission-policy
```

---

### Phase 3: Deploy SPIFFE/SPIRE Infrastructure (`charts/spiffe-spire`)
1. **Deploy SPIRE Server & Agent DaemonSet:**
   - CSI Driver mounted at `/spiffe-workload-api/spire-agent.sock`.
   - SPIRE OIDC Discovery Provider configured for Fulcio federation.
2. **Apply `ClusterSPIFFEID` CRs:**
   - `konflux-trusted-prod`: Mints `spiffe://konflux-ci.dev/trusted/...` for pods with `trusted-task-role: prod`.
   - `konflux-dev`: Mints `spiffe://konflux-ci.dev/dev/...` for pods with `trusted-task-role: dev`.
3. **Run Fulcio Integration Job:**
   - Registers SPIRE OIDC discovery endpoint with the in-cluster Fulcio configuration.

```bash
helm upgrade --install spiffe-spire \
  .claude/worktrees/spiffe-spire-exploration/charts/spiffe-spire
```

---

### Phase 4: Non-Breaking Dual-Mode Task Configuration
To allow `main` and `worktree-spiffe-spire-exploration` to co-exist without breaking CI or non-SPIRE clusters:
1. **Declare Workspaces as `optional: true`:**
   In `trivy-sbom-scan` and `attach-summary-attestations`:
   ```yaml
   workspaces:
     - name: spiffe-workload-api
       optional: true
       mountPath: /spiffe-workload-api
   ```
2. **Runtime Detection in Task Scripts:**
   ```bash
   if [ -S /spiffe-workload-api/spire-agent.sock ]; then
     echo "Using SPIFFE Workload Identity..."
     export SPIFFE_ENDPOINT_SOCKET="unix:///spiffe-workload-api/spire-agent.sock"
     cosign attest --predicate "$PRED" --type "$TYPE" --yes "$IMAGE"
   else
     echo "Falling back to static keypair..."
     cosign attest --predicate "$PRED" --type "$TYPE" --key "$KEY" --use-signing-config=false --tlog-upload=false "$IMAGE"
   fi
   ```

---

## 4. The Live Demo Script

1. **Scene 1 — The Untrusted Task (Role: Dev):**
   - Submit a PipelineRun with an unpinned or untrusted task bundle.
   - Show Kyverno admission log: TaskRun is classified as `trusted-task-role: dev`.
   - Inspect Pod SVID: `spiffe://konflux-ci.dev/dev/...`.
   - Attempt to verify via production policy: Conforma rejects the untrusted signature.

2. **Scene 2 — The Trusted Separation of Roles (Role: Prod):**
   - Submit the official SLSA build pipeline with signed task bundles.
   - Kyverno verifies Cosign signature on the task bundle; stamps `trusted-task-role: prod`.
   - **Trivy Pod** receives `.../task/trivy-sbom-scan` ➔ Signs CVE report.
   - **Buildah Pod** receives `.../task/buildah-oci-ta` ➔ Signs SBOM and provenance.

3. **Scene 3 — The Conforma Policy Evaluation:**
   - Execute Conforma policy validation.
   - Show rule verification: Conforma checks that the CVE report came from `.../trivy-sbom-scan` and the SBOM came from `.../buildah-oci-ta`.
   - Show positive assertion: "Right role for the right job."

4. **Scene 4 — The Future: Managed Release Gating (Discussion / Cap-stone):**
   - Show how the release pipeline uses PipelineRun-scoped identity or Cryptographic Clearance Tokens to sign the final VSA only after all gates clear.
