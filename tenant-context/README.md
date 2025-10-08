# Tenant Context Components

This directory contains all components that operate within the **tenant (developer-controlled) namespace**. These components are responsible for source verification, container image building, and generating Snapshots that trigger managed release pipelines.

## 🔒 Trust Context

**Security Level**: Developer-controlled environment
**Purpose**: Source verification, container builds, and Snapshot creation
**Output**: Container images with attestations, Snapshots for release automation

## 📁 Directory Structure

```
tenant-context/
├── tasks/                   # Custom Tekton tasks
│   └── git-clone-slsa/      # SLSA-aware source retrieval
├── pipelines/               # Build pipeline definitions
│   └── slsa-tenant-build-pipeline.yaml  # Complete build pipeline
├── releases/                # Release configuration
│   └── slsa-demo-releaseplan.yaml      # ReleasePlan for automation
└── policies/                # Build-time security policies
    └── slsa-source/         # SLSA source verification rules
```

## 🔧 Components

### Tasks

#### git-clone-slsa
**Purpose**: Enhanced git clone with SLSA source verification
**Key Features**:
- SLSA source provenance validation
- Git commit signature verification
- Source integrity attestation generation
- Compatible with standard Tekton Chains provenance

*Note: Policy evaluation (conforma-vsa) occurs in managed context to ensure trusted evaluation at release time.*

### Pipelines

#### slsa-tenant-build-pipeline
**Purpose**: Complete build pipeline that produces Konflux Snapshots
**Key Features**:
- Source code retrieval and verification (git-clone-slsa)
- Container image building with SLSA provenance
- SBOM generation and attestation creation
- Snapshot creation with image references
- Tekton Chains integration for automatic attestation publishing

### Releases

#### slsa-demo-releaseplan
**Purpose**: Configures automatic release triggering
**Key Features**:
- Links Application/Component to managed release pipeline
- Triggers managed pipeline when new Snapshots are created
- Provides data transfer from tenant to managed context

## 🔄 Workflow

1. **Git Commit**: Developer pushes code to repository
2. **Build Trigger**: Konflux automatically starts tenant build pipeline  
3. **Source Verification**: `git-clone-slsa` task fetches and verifies source code
4. **Image Build**: Container image built with Tekton Chains provenance
5. **Snapshot Creation**: Konflux creates Snapshot with image references
6. **Release Trigger**: ReleasePlan automatically triggers managed release pipeline

## 🛡️ Security Boundaries

**Input Trust**: Source code repositories and developer credentials
**Processing**: Build environment with Tekton Chains provenance
**Output Trust**: Container images with attestations stored in OCI registries

**Key Principles**:
- No direct access to release signing keys (managed context only)
- Container images and attestations published to OCI registries
- Snapshots contain image references (not attestations directly)
- Policy evaluation occurs in managed context at release time
- Complete audit trail via Tekton Chains and Konflux

## 🔗 Integration

**Upstream**: Source code repositories, container base images, dependency registries
**Downstream**: Managed context via Snapshots and OCI-stored attestations
**Monitoring**: Build metrics, Tekton Chains attestation publishing, Snapshot creation

## 📋 Configuration

Task and pipeline configurations can be customized for:
- Different source verification requirements
- Custom policy rule sets
- Integration with existing developer workflows
- Artifact storage and format preferences

See individual task directories for detailed configuration options.

## 🧪 Testing

```bash
# Test source verification
kubectl apply -f tasks/git-clone-slsa/test/
kubectl apply -f pipelines/test-build-pipeline.yaml

# Validate policy evaluation
kubectl apply -f tasks/conforma-vsa/test/
```

## 📖 Related Documentation

- [Trust Model](../docs/trust-model.md) - Overall security architecture
- [SLSA Compliance](../docs/slsa-compliance.md) - How components meet SLSA requirements
- [Configuration Guide](../docs/configuration.md) - Customization options