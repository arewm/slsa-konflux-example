# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This repository demonstrates end-to-end SLSA (Supply-chain Levels for Software Artifacts) compliance using Konflux with strict trust boundary separation. It serves as both a working implementation and comprehensive guide for SLSA adoption.

## Repository Structure

```
slsa-konflux-example/
├── admin/                   # Admin configuration
├── hack/                    # Build/push scripts
├── managed-context/         # Platform-controlled components
│   ├── tasks/               # Release-time tasks (verify-conforma, attach-vsa, etc.)
│   ├── pipelines/           # Release pipeline definitions
│   ├── slsa-e2e-pipeline/   # SLSA end-to-end pipeline
│   └── policies/            # Release security policies
├── resources/               # Helm chart for onboarding
├── scripts/                 # Setup automation
└── .internal/               # Internal development artifacts
```

## Development Context

This is an **active implementation project** with working code, trust boundaries, and local repository dependencies. The project implements a complete SLSA-compliant workflow with:

### Trust Boundary Architecture
- **Tenant Context**: Source verification, builds (no signing keys)
- **Managed Context**: Policy evaluation, VSA generation, signing

### Key Implementation Components
- Conforma policy verification (`verify-conforma` task)
- VSA attachment to release artifacts (`attach-vsa` task)
- SBOM generation and scanning (`trivy-sbom-scan` task)
- OCI storage extraction (`extract-oci-storage` task)
- Mapping application for trust artifacts (`apply-mapping` task)

## Development Workflow

1. **Task Development**: Create Tekton tasks in `managed-context/tasks/` following established patterns
2. **Trust Boundaries**: Maintain strict separation between tenant and managed contexts
3. **SLSA Compliance**: Implement SLSA provenance and VSA generation workflows
4. **ARM Compatibility**: Use multi-arch base images and test on ARM/macOS
5. **Policy Integration**: Integrate with Enterprise Contract policy evaluation

## Testing and Validation

- Dry-run validation of Tekton task definitions using `kubectl apply --dry-run=client`
- Monitor pipeline runs in target namespaces
- ARM/macOS compatibility testing using installation automation
- SLSA compliance verification using policy evaluation frameworks

## Common Development Commands

### Setup and Installation
```bash
# Deploy Konflux operator
git clone https://github.com/konflux-ci/konflux-ci.git
cd konflux-ci
./scripts/deploy-local.sh

# Setup prerequisites (creates managed-tenant namespace and custom pipeline config)
cd /path/to/slsa-konflux-example
./scripts/setup-prerequisites.sh

# Onboard your application using helm chart
helm install festoji ./resources \
  --set applicationName=festoji \
  --set gitRepoUrl=https://github.com/FORK_ORG/festoji
```

### Testing and Validation
```bash
# Monitor pipeline runs
kubectl get pipelineruns -n default-tenant -w

# Check release status
kubectl get releases -n default-tenant
```

### Development Tasks
```bash
# Validate Tekton task definitions
kubectl apply --dry-run=client -f managed-context/tasks/verify-conforma/0.1/
kubectl apply --dry-run=client -f managed-context/tasks/attach-vsa/0.1/
kubectl apply --dry-run=client -f managed-context/tasks/trivy-sbom-scan/0.1/
kubectl apply --dry-run=client -f managed-context/tasks/extract-oci-storage/
kubectl apply --dry-run=client -f managed-context/tasks/apply-mapping/
```

## Core Architecture Patterns

### Trust Boundary Enforcement
- **Tenant Context**: Source verification, builds, no signing keys
  - Standard Konflux build pipelines
  - Output: Build provenance via Tekton Chains
- **Managed Context**: Policy evaluation, VSA generation, cryptographic signing
  - Primary tasks: `verify-conforma` (policy evaluation), `attach-vsa` (VSA attachment)
  - Additional tasks: `trivy-sbom-scan`, `extract-oci-storage`, `apply-mapping`
  - Input: Artifacts and attestations from tenant context
  - Output: Signed VSAs and release artifacts

### SLSA Integration Points
- **Build Track**: Tekton Chains integration for SLSA provenance generation
- **VSA Generation**: Policy evaluation results converted to verification summaries via `attach-vsa`
- **Attestation Publishing**: Signed VSAs and attestations published to OCI registries
- **Policy Verification**: Enterprise Contract integration via `verify-conforma` task

### Tekton Task Development
- Create tasks in `managed-context/tasks/` with versioned subdirectories (e.g., `0.1/`)
- Use OCI-based artifact storage for cross-context communication
- Follow Tekton conventions for parameters, results, and workspaces
- ARM/macOS compatibility using multi-arch base images

## Security Considerations

- **Never modify trust boundaries** - tenant and managed contexts must remain isolated
- **Cryptographic verification** required for all trust artifacts
- **Policy evaluation** must occur in managed context only
- **Signing keys** exclusively in managed namespace
- **Complete audit trail** from source to signed release