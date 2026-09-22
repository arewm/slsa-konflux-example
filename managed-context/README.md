# Managed Context Components

This directory contains components that operate within the **managed (platform-controlled) namespace** (`managed-tenant`). These components perform policy evaluation, image promotion, vulnerability scanning, and release attestation generation with enhanced cryptographic guarantees.

## Trust Context

**Security Level**: Platform-controlled environment with elevated privileges  
**Purpose**: Enterprise policy validation, keyless release attestation signing, image promotion, and vulnerability scanning  
**Input**: Snapshots with image references and task-level attestations from tenant context (`default-tenant`)  
**Output**: Policy-validated releases with signed VSAs, SVRs, and Rekor transparency log entries  

## Directory Structure

```
managed-context/
├── tasks/
│   ├── verify-conforma/0.1/               # Policy evaluation using Enterprise Contract
│   ├── attach-summary-attestations/0.1/   # Dual-mode keyless / keypair VSA & SVR signer
│   ├── attach-vsa/0.1/                    # Legacy static-key VSA attachment task
│   ├── trivy-sbom-scan/0.1/               # Vulnerability scanning with Trivy
│   ├── apply-mapping/                     # Snapshot component mapping
│   └── extract-oci-storage/               # Extract OCI storage from RPA
├── pipelines/
│   ├── slsa-e2e-release-dual-gated/       # Dual-gated release pipeline (Model 2)
│   └── slsa-e2e-release/                  # Baseline release pipeline
├── slsa-e2e-pipeline/                     # Build pipeline definition
└── policies/
    └── ec-policy-data/                    # Enterprise Contract policy data
        ├── data/                          # Policy rule data (required_tasks.yml, etc.)
        └── policy/custom/                 # Custom policy rules (slsa_source_verification)
```

## Components

### Tasks

#### `attach-summary-attestations`
**Path**: `tasks/attach-summary-attestations/0.1/attach-summary-attestations.yaml`

The active release signing task supporting both **keyless SPIFFE Workload Identity** and fallback static keypairs.

**Key Features**:
- Auto-detects the SPIFFE Workload API CSI socket at `/spiffe-workload-api/spire-agent.sock`
- When SPIFFE is present, fetches a JWT-SVID, exchanges it via Fulcio for an ephemeral X.509 certificate with a task/release SPIFFE SAN, and signs attestations into the Rekor transparency log
- Attaches signed Verification Summary Attestations (VSAs) and Simple Verification Results (SVRs) to destination images using OCI 1.1 Referrers
- Falls back to static cosign keypairs (`VSA_SIGNING_KEY`) if running in environments without SPIFFE

#### `verify-conforma`
**Path**: `tasks/verify-conforma/0.1/verify-conforma-vsa.yaml`

Policy evaluation task using Enterprise Contract. Evaluates 100+ rules covering SLSA Build Level 3, source verification, hermetic builds, required tasks, and CVE leeway before allowing downstream promotion.

#### `trivy-sbom-scan`
**Path**: `tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml`

Vulnerability scanning using Trivy, analyzing container components against vulnerability databases. Scans multiple architectures and attaches reports to images as OCI artifacts.

#### `apply-mapping`
**Path**: `tasks/apply-mapping/apply-mapping.yaml`

Merges component mappings with Snapshot data, supporting variable expansion in tags and repository transformations.

#### `extract-oci-storage`
**Path**: `tasks/extract-oci-storage/extract-oci-storage.yaml`

Extracts the OCI storage location from ReleasePlanAdmission `spec.data` for use by pipeline tasks.

---

### Pipelines

#### `slsa-e2e-release-dual-gated` (Model 2 Release Gating)
**Path**: `pipelines/slsa-e2e-release-dual-gated/slsa-e2e-release-dual-gated.yaml`

The hardened release pipeline demonstrating **PipelineRun-Scoped Dual-Gating**.

**Workflow**:
1. **`verify-access-to-resources`**: Validate access to Release, ReleasePlan, RPA, and Snapshot
2. **`collect-data`**: Gather release metadata into trusted artifacts
3. **`collect-task-params`**: Extract task parameters from RPA data
4. **`check-data-keys`**: Validate required data keys in RPA
5. **`reduce-snapshot`**: Filter snapshot to component
6. **`apply-mapping`**: Merge component mappings with snapshot
7. **`verify-conforma`**: Policy evaluation (gates publication)
8. **`push-snapshot`**: Promote images to destination registry
9. **`attach-summary-attestations`**: Sign and attach VSA and SVR attestations via SPIFFE release identity
10. **`update-cr-status`**: Update Release custom resource status

**Trust Boundary Guarantees**:
- Kyverno admission policy (`classify-release-authority`) labels TaskRuns in this pipeline with `trusted-pipeline-role: release-authority`.
- SPIRE's `konflux-release-authority` ClusterSPIFFEID matches **both** `trusted-pipeline-role: release-authority` and `tekton.dev/pipelineTask: attach-summary-attestations`.
- Early tasks (`collect-data`, `apply-mapping`, `verify-conforma`) receive **no release signing identity**, eliminating the ambient release authority trap.

> For architectural details, see **[Dual-Gated Release Guide](../docs/dual-gated-release-guide.md)** and **[CI Workload Identity Patterns](../docs/task-workload-identity-patterns.md)**.

---

## Security Boundaries & Keyless Signing

**Input Trust**: Snapshots with image references, signed provenance, and task attestations from `default-tenant`  
**Processing**: Secured managed environment in `managed-tenant`  
**Output Trust**: Policy-validated releases with signed VSAs registered in Rekor  

**Keyless Architecture**:
- Static release private keys stored in Kubernetes secrets are eliminated on clusters with SPIRE and Sigstore.
- Signing authority is tied to the ephemeral lifecycle of the `attach-summary-attestations` pod through the SPIFFE CSI Workload API.
- Signatures are verifiable via Rekor and public Fulcio roots without sharing static private keys across administrators.

---

## Testing & Verification

Monitor managed release pipeline runs:

```bash
# Monitor release pipeline runs in managed-tenant
kubectl get pipelineruns -n managed-tenant -w

# Check verify-conforma results
kubectl logs -n managed-tenant -l tekton.dev/task=verify-conforma --tail=100

# Check keyless VSA attachment results
kubectl logs -n managed-tenant -l tekton.dev/pipelineTask=attach-summary-attestations --tail=100
```
