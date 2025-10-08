# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This repository demonstrates end-to-end SLSA (Supply-chain Levels for Software Artifacts) compliance using Konflux with strict trust boundary separation. It serves as both a working implementation and comprehensive guide for SLSA adoption.

## Repository Structure

```
slsa-konflux-example/
├── tenant-context/          # Developer-controlled components
│   ├── tasks/               # Build-time verification tasks
│   ├── pipelines/           # Build pipeline definitions
│   └── policies/            # Build-time security policies
├── managed-context/         # Platform-controlled components
│   ├── tasks/               # Release-time tasks (conforma-vsa, vsa-sign)
│   ├── pipelines/           # Release pipeline definitions
│   └── policies/            # Release security policies
├── shared/                  # Cross-context artifacts
│   ├── trust-artifacts/     # Verification data exchange
│   └── schemas/             # Common data formats
├── examples/                # Sample applications
│   ├── go-app/              # Go application demo
│   └── python-app/          # Python application demo
├── scripts/                 # Installation and setup automation
├── docs/                    # Documentation
└── .internal/               # Local development resources
    ├── repositories/        # 19 cloned Konflux/SLSA repositories
    ├── REPOSITORY_ANALYSIS.md
    ├── REPOSITORY_SUMMARY.md
    └── story-arc-transcript.txt
```

## Development Context

This is an **active implementation project** with working code, trust boundaries, and local repository dependencies. The project implements a complete SLSA-compliant workflow with:

### Trust Boundary Architecture
- **Tenant Context**: Source verification, builds (no signing keys)
- **Managed Context**: Policy evaluation, VSA generation, signing
- **Shared Context**: Cryptographically secured trust artifact exchange

### Key Implementation Components
- Custom SLSA-aware git clone task
- Enhanced Conforma task with VSA payload generation  
- VSA signing and attestation publishing
- Complete trust artifact schemas and validation

## Local Repository Dependencies

The `.internal/repositories/` directory contains 19 cloned repositories providing:
- **Real implementation patterns** for task development
- **ARM/macOS compatibility solutions** 
- **Policy evaluation examples** and rule definitions
- **SLSA compliance patterns** and VSA formats
- **Signing and attestation** integration examples

### Critical Dependencies
- `build-definitions/` - Base for git-clone-slsa task
- `release-service-catalog/` - Managed pipeline templates
- `cli/` (conforma) - Policy evaluation patterns
- `chains/` - SLSA provenance generation
- `cosign/` - VSA signing implementation
- `attestation/` - In-toto attestation formats

## Key Planning and Analysis Documents

- `.internal/SLSA_STORY_ARC_PLAN.md` - Complete implementation roadmap
- `.internal/TRUST_BOUNDARY_VALIDATION.md` - Security architecture validation
- `.internal/REPOSITORY_ANALYSIS.md` - Repository dependency analysis
- `.internal/Dependant-repository-layout.md` - Konflux ecosystem mapping
- `.internal/story-arc-transcript.txt` - Original planning discussions

## Development Workflow

1. **Task Development**: Extend existing patterns from `build-definitions/` and `release-service-catalog/`
2. **Trust Boundaries**: Maintain strict separation between tenant and managed contexts
3. **SLSA Compliance**: Use patterns from `chains/`, `slsa/`, and `attestation/` repositories
4. **ARM Compatibility**: Leverage solutions from `konflux-ci/` installer patterns
5. **Policy Integration**: Build on `cli/`, `policy/`, and `rhtap-ec-policy/` examples

## Testing and Validation

- Use example applications in `examples/` for end-to-end validation
- Validate trust boundary separation with provided security tests
- ARM/macOS compatibility testing using installation automation
- SLSA compliance verification using policy evaluation frameworks

## Common Development Commands

### Setup and Installation
```bash
# Install Konflux (ARM/macOS compatible)
./scripts/install-konflux.sh

# Bootstrap managed namespace with signing keys
./scripts/bootstrap-managed-namespace.sh

# Run complete demonstration
./scripts/run-demo.sh
```

### Testing and Validation
```bash
# Test trust boundary separation
./scripts/test-trust-boundaries.sh

# Validate SLSA compliance 
./scripts/validate-slsa-compliance.sh

# Verify attestations and VSAs
./scripts/verify-attestations.sh
```

### Development Tasks
```bash
# Validate Tekton task definitions
kubectl apply --dry-run=client -f tenant-context/tasks/git-clone-slsa/0.1/
kubectl apply --dry-run=client -f managed-context/tasks/conforma-vsa/0.1/
kubectl apply --dry-run=client -f managed-context/tasks/vsa-sign/0.1/

# Test individual components
kubectl create -f examples/go-app/pipeline-run.yaml
kubectl create -f examples/python-app/pipeline-run.yaml
```

## Work Stream Implementation Strategy

This repository follows a 6-stream parallel development approach defined in `.internal/work-streams/`:

### Priority Order (Critical Path)
1. **WS5 (Trust Artifact Schema)** - Foundation for all streams (.internal/work-streams/WS5-Trust-Artifact-Schema.md)
2. **WS1 (Infrastructure & ARM Compatibility)** - Platform setup (.internal/work-streams/WS1-Infrastructure-ARM-Compatibility.md)  
3. **WS3 (Managed Context Development)** - Security architecture (.internal/work-streams/WS3-Managed-Context-Development.md)
4. **WS2 (Tenant Context Development)** - Build tasks (.internal/work-streams/WS2-Tenant-Context-Development.md)
5. **WS4 (Policy Integration)** - Compliance framework (.internal/work-streams/WS4-Policy-Integration-Compliance.md)
6. **WS6 (Documentation & Community)** - Adoption materials (.internal/work-streams/WS6-Documentation-Community-Adoption.md)

## Core Architecture Patterns

### Trust Boundary Enforcement
- **Tenant Context**: Source verification, builds, no signing keys
  - Primary task: `git-clone-slsa` - SLSA-aware source cloning with verification
  - Output: Trust artifacts and build provenance
- **Managed Context**: Policy evaluation, VSA generation, cryptographic signing
  - Primary tasks: `conforma-vsa` (policy evaluation), `vsa-sign` (VSA signing)
  - Input: Trust artifacts from tenant context
  - Output: Signed VSAs and attestations

### SLSA Integration Points
- **Source Track**: Implemented in `git-clone-slsa` task using slsa-framework/source-tool
- **Build Track**: Tekton Chains integration for SLSA provenance generation
- **VSA Generation**: Policy evaluation results converted to verification summaries
- **Attestation Publishing**: Signed VSAs published to OCI registries

### Tekton Task Development
- Extend patterns from `.internal/repositories/build-definitions/`
- Use trusted artifact storage for cross-context communication
- Follow Tekton conventions for parameters, results, and workspaces
- ARM/macOS compatibility using multi-arch base images

## Security Considerations

- **Never modify trust boundaries** - tenant and managed contexts must remain isolated
- **Cryptographic verification** required for all trust artifacts
- **Policy evaluation** must occur in managed context only
- **Signing keys** exclusively in managed namespace
- **Complete audit trail** from source to signed release