# Managed Context Components

This directory contains components that operate within the **managed (platform-controlled) namespace**. These components perform policy evaluation, VSA generation, image promotion, and vulnerability scanning with enhanced security guarantees.

## Trust Context

**Security Level**: Platform-controlled environment with elevated privileges
**Purpose**: Policy validation, VSA generation, image promotion, vulnerability scanning
**Input**: Snapshots with image references from tenant context
**Output**: Policy-validated releases with signed VSAs and vulnerability reports

## Directory Structure

```
managed-context/
├── tasks/
│   ├── verify-conforma/0.1/         # Policy evaluation with VSA generation
│   ├── attach-vsa/0.1/              # VSA signing and attachment to images
│   ├── trivy-sbom-scan/0.1/         # Vulnerability scanning with Trivy
│   ├── apply-mapping/               # Snapshot component mapping
│   └── extract-oci-storage/         # Extract OCI storage from RPA
├── pipelines/
│   └── slsa-e2e-release/            # Complete release pipeline
├── slsa-e2e-pipeline/               # Build pipeline definition
└── policies/
    └── ec-policy-data/              # Enterprise Contract policy data
        ├── data/                    # Policy rule data (required_tasks.yml, etc.)
        └── policy/custom/           # Custom policy rules (slsa_source_verification)
```

## Components

### Tasks

#### verify-conforma
**Path**: `tasks/verify-conforma/0.1/verify-conforma-vsa.yaml`

Policy evaluation task using Enterprise Contract with integrated VSA generation. Based on the upstream Conforma CLI verify-conforma-konflux-ta task with extensions for VSA creation.

**Key Features**:
- Validates container images against Enterprise Contract policies
- Generates Verification Summary Attestations (VSAs) when enabled
- Supports trusted artifacts for secure data transfer
- Configurable policy sources (EnterpriseContractPolicy resources or git URLs)
- VSA signing with managed signing keys (k8s:// references)
- Local VSA storage or Rekor transparency log upload

**Key Parameters**:
- `POLICY_CONFIGURATION`: Policy to evaluate against (namespace/name or git URL)
- `PUBLIC_KEY`: Cosign public key for signature verification
- `VSA_SIGNING_KEY`: Private key for VSA signing (k8s://namespace/secret)
- `ENABLE_VSA`: Enable VSA generation (default: false)
- `VSA_UPLOAD`: VSA destination (local@/path or rekor@url)

**Results**:
- `TEST_OUTPUT`: Policy evaluation summary
- `VSA_GENERATED`: Whether VSA was created (true/false)
- `VSA_LOCATION`: Location of generated VSA

#### attach-vsa
**Path**: `tasks/attach-vsa/0.1/attach-vsa.yaml`

Attaches signed VSA attestations to container images in the destination registry after policy validation and image promotion.

**Key Features**:
- Reads VSA files from trusted artifacts
- Signs VSA predicates using cosign
- Attaches signed attestations to destination images
- Creates DSSE envelopes with signatures
- Conditional execution based on VSA generation status

**Key Parameters**:
- `SNAPSHOT_FILENAME`: Mapped snapshot with destination image references
- `SOURCE_DATA_ARTIFACT`: Trusted artifact containing VSA files
- `VSA_GENERATED`: Whether to attach VSAs (from verify-conforma)
- `VSA_SIGNING_KEY`: Signing key reference (k8s://namespace/secret)

#### trivy-sbom-scan
**Path**: `tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml`

Vulnerability scanning using Trivy, analyzing container components against vulnerability databases. Scans multiple architectures and attaches reports to images as OCI artifacts.

**Key Features**:
- Multi-architecture vulnerability scanning
- Generates both Trivy and Clair report formats
- Attaches vulnerability reports to images via ORAS
- Aggregates vulnerability counts by severity
- Distinguishes patched vs. unpatched vulnerabilities

**Results**:
- `SCAN_OUTPUT`: Aggregated vulnerability counts by severity
- `IMAGES_PROCESSED`: List of scanned image digests
- `REPORTS`: Mapping of image digests to report digests

#### apply-mapping
**Path**: `tasks/apply-mapping/apply-mapping.yaml`

Merges component mappings with Snapshot data, supporting variable expansion in tags and repository transformations.

**Key Features**:
- Merges ReleasePlanAdmission mapping with Snapshot components
- Tag variable expansion (timestamp, git_sha, incrementer, oci_version, etc.)
- Repository format conversion (quay.io ↔ registry.redhat.io)
- Image metadata extraction (labels, annotations, environment variables)
- Trusted artifacts for secure data transfer

**Supported Variables**:
- `{{ timestamp }}`: Build date from image metadata
- `{{ git_sha }}`: Git commit SHA
- `{{ incrementer }}`: Auto-incremented tag based on existing tags
- `{{ oci_version }}`: OCI image version annotation
- `{{ labels.name }}`: Image label values

#### extract-oci-storage
**Path**: `tasks/extract-oci-storage/extract-oci-storage.yaml`

Extracts the OCI storage location from ReleasePlanAdmission spec.data for use by pipeline tasks.

### Pipelines

#### slsa-e2e-release
**Path**: `pipelines/slsa-e2e-release/slsa-e2e-release.yaml`

Complete release pipeline for promoting Snapshots to external registries with policy validation and VSA generation.

**Workflow**:
1. **verify-access-to-resources**: Validate access to Release, ReleasePlan, RPA, Snapshot
2. **collect-data**: Gather release metadata into trusted artifacts
3. **collect-task-params**: Extract task parameters from RPA data
4. **check-data-keys**: Validate required data keys in RPA
5. **reduce-snapshot**: Filter snapshot to single component if needed
6. **apply-mapping**: Merge component mappings with snapshot
7. **verify-conforma**: Policy evaluation with VSA generation
8. **push-snapshot**: Promote images to destination registry
9. **attach-vsa**: Sign and attach VSA attestations to promoted images
10. **collect-registry-token-secret**: Get registry credentials
11. **make-repo-public**: Set repository visibility
12. **update-cr-status**: Update Release resource status

**Key Integration Points**:
- Uses `verify-conforma` from Conforma CLI repository
- Uses `attach-vsa` from this repository (demo tasks)
- Uses shared tasks from release-service-catalog
- Enables VSA generation by default
- Attaches VSAs to destination images after promotion

#### slsa-e2e-oci-ta
**Path**: `slsa-e2e-pipeline/slsa-e2e-pipeline.yaml`

Build pipeline using trusted artifacts for SLSA compliance. Based on the docker-build-oci-ta pipeline from build-definitions.

**Key Tasks**:
- **clone-repository**: Git clone with OCI artifact storage
- **verify-source**: Source verification checks
- **prefetch-dependencies**: Dependency prefetching for hermetic builds
- **build-container**: Container build with buildah
- **build-image-index**: Multi-arch image index creation
- **trivy-sbom-scan**: Vulnerability scanning
- **clair-scan**: Additional vulnerability scanning (optional)
- **sast-shell-check**: Static analysis for shell scripts

### Policies

#### ec-policy-data
**Path**: `policies/ec-policy-data/`

Enterprise Contract policy data and custom policy rules for the SLSA demonstration.

**Data Files** (`data/`):
- `required_tasks.yml`: List of required tasks for policy compliance
- `known_rpm_repositories.yml`: Allowed RPM repository sources
- `rule_data.yml`: Additional rule configuration data

**Custom Policies** (`policy/custom/slsa_source_verification/`):
- `slsa_source_verification.rego`: SLSA source verification policy rules
- `slsa_source_verification_test.rego`: Policy unit tests

## Workflow

1. **Snapshot Creation**: Tenant context creates Snapshot after successful build
2. **Release Trigger**: ReleasePlanAdmission triggers managed release pipeline
3. **Data Collection**: Pipeline collects Release, Snapshot, and mapping data
4. **Mapping Application**: Component mappings merged with Snapshot
5. **Policy Evaluation**: `verify-conforma` validates images against EC policies
6. **VSA Generation**: VSAs created for policy validation results
7. **Image Promotion**: Images pushed to destination registry (if policy passes)
8. **VSA Attachment**: Signed VSAs attached to promoted images
9. **Status Update**: Release resource updated with results

## Security Boundaries

**Input Trust**: Snapshots with image references, attestations from OCI registries
**Processing**: Secured managed environment with signing key access
**Output Trust**: Policy-validated releases with signed VSAs

**Key Principles**:
- Exclusive access to VSA signing keys in managed namespace
- Policy evaluation only in trusted managed environment
- Complete audit trail via Tekton task results
- Snapshot validation before processing

**Isolation Mechanisms**:
- RBAC prevents tenant namespace access to managed namespace
- Managed signing keys isolated via Kubernetes secrets
- Trusted artifacts for secure cross-task data transfer

## Key Management

**Signing Keys**:
- VSA signing keys stored as Kubernetes secrets (e.g., `k8s://slsa-e2e-managed-tenant/release-signing-key`)
- Accessed via cosign key references in task parameters
- Used by both `verify-conforma` (VSA generation) and `attach-vsa` (VSA signing)

**Security Measures**:
- Keys isolated in managed namespace
- RBAC prevents unauthorized access
- Audit trail via pipeline task results

## Testing

Monitor managed pipeline runs:

```bash
# Monitor release pipeline runs
kubectl get pipelineruns -n slsa-e2e-managed-tenant -w

# Check verify-conforma results
kubectl logs -n slsa-e2e-managed-tenant -l tekton.dev/task=verify-conforma --tail=100

# Check VSA attachment results
kubectl logs -n slsa-e2e-managed-tenant -l tekton.dev/task=attach-vsa --tail=100
```