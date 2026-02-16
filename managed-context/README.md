# Managed Context Components

This directory contains all components that operate within the **managed (platform-controlled) namespace**. These components are responsible for processing Snapshots from tenant builds, performing policy evaluation, VSA generation, artifact signing, and release publication with enhanced security guarantees.

## 🔒 Trust Context

**Security Level**: Platform-controlled environment with elevated privileges
**Purpose**: Snapshot processing, policy evaluation, VSA generation, and trusted release
**Input**: Snapshots with image references from tenant context
**Output**: Policy-validated releases with signed VSAs

## 📁 Directory Structure

```
managed-context/
├── tasks/                              # Privileged Tekton tasks
│   ├── conforma-vsa/                   # Policy evaluation and VSA payload generation
│   ├── vsa-sign/                       # VSA generation and signing
│   └── image-promotion/                # Image promotion after policy validation
├── pipelines/                          # Release pipeline definitions
│   └── slsa-managed-release-pipeline.yaml  # Complete release pipeline
├── releases/                           # Release automation
│   └── slsa-demo-releaseplanadmission.yaml # Snapshot → Release trigger
└── policies/                           # Release security policies
    └── enterprise-contract-extended/   # Enhanced policy validation
```

## 🔧 Components

### Tasks

#### conforma-vsa
**Purpose**: Trusted policy evaluation and VSA payload generation from Snapshots
**Key Features**:
- Processes Snapshot to extract image references
- Fetches build attestations from OCI registries by image digest
- Authoritative Enterprise Contract policy evaluation in managed environment
- VSA payload generation from evaluation results
- Converts Conforma results to SLSA VSA v1.0 format

#### vsa-sign
**Purpose**: VSA (Verification Summary Attestation) signing and publication
**Key Features**:
- Consumes VSA payloads from conforma-vsa task
- Signs VSAs with managed signing keys using cosign
- Publishes signed VSAs to OCI registries as attestations
- Creates immutable transparency log entries via Rekor

#### image-promotion
**Purpose**: Conditional image promotion based on policy evaluation
**Key Features**:
- Only promotes images if policy evaluation PASSED
- Copies images from build registry to production registry
- Maintains image digest integrity during promotion
- Updates image references for downstream consumers

### Pipelines

#### slsa-managed-release-pipeline
**Purpose**: Complete release pipeline triggered by ReleasePlanAdmission
**Key Features**:
- Triggered automatically when Snapshots are created in tenant context
- Processes Snapshot to extract image references and metadata
- Orchestrates conforma-vsa → image-promotion → vsa-sign task sequence
- Conditional execution: policy failures prevent promotion and signing
- Complete result tracking and error handling

### Releases

#### slsa-demo-releaseplanadmission  
**Purpose**: Configures automatic managed pipeline triggering
**Key Features**:
- Monitors for new Releases created from tenant Snapshots
- Automatically triggers slsa-managed-release-pipeline
- Provides Snapshot data to managed pipeline for processing
- Ensures proper tenant → managed context data flow

### Policies

#### slsa-source
SLSA source-level verification policies including:
- Git repository verification requirements
- Branch protection validation
- Commit signing requirements
- Source provenance attestation rules

#### enterprise-contract-extended
Enhanced policy validation including:
- Trust artifact verification requirements
- Release readiness criteria
- Compliance validation rules
- Security threshold enforcement

## 🔄 Workflow

1. **Snapshot Reception**: ReleasePlanAdmission detects new Snapshots from tenant builds
2. **Release Creation**: Konflux automatically creates Release referencing the Snapshot
3. **Pipeline Trigger**: slsa-managed-release-pipeline starts automatically
4. **Snapshot Processing**: Pipeline extracts image references and metadata from Snapshot
5. **Attestation Fetching**: Build attestations retrieved from OCI registries by image digest
6. **Policy Evaluation**: `conforma-vsa` task performs Enterprise Contract evaluation
7. **Conditional Promotion**: `image-promotion` task only runs if policy evaluation PASSED
8. **VSA Signing**: `vsa-sign` task creates and signs SLSA VSA v1.0 attestations  
9. **Publication**: Signed VSAs published to OCI registries with transparency logging

## 🛡️ Security Boundaries

**Input Trust**: Snapshots with image references, attestations fetched from OCI registries
**Processing**: Highly secured environment with signing key access
**Output Trust**: Policy-validated releases with signed VSAs

**Key Principles**:
- Exclusive access to VSA signing keys (not in tenant context)
- No direct developer access to managed namespace
- Policy evaluation occurs only in trusted managed environment
- Complete audit trail via Tekton, cosign, and Rekor transparency logs
- Snapshot data validated before processing

**Isolation Mechanisms**:
- Network policies restricting external access
- RBAC preventing tenant namespace interaction
- Managed signing keys isolated from developer access
- Comprehensive logging and monitoring via Konflux

## 🔑 Key Management

**Signing Keys**:
- **VSA Signing Key**: Verification Summary Attestation signing via cosign
- **Demo Keys**: Fallback for environments without real signing infrastructure

**Security Measures**:
- Cosign key-pair generation and management
- Transparency logging via Rekor for all signatures
- Key isolation in managed namespace only
- Audit trail for all signing operations

## 🔗 Integration

**Upstream**: Tenant context via Snapshots and OCI-stored attestations
**Downstream**: OCI registries for promoted images and signed VSAs
**Monitoring**: Konflux dashboard, Tekton pipeline metrics, transparency logs

## 📋 Configuration

Managed context configurations include:
- Signing key specifications and rotation policies
- Release criteria and approval workflows
- Compliance validation thresholds
- Publication target configurations

**Security Configuration**:
```yaml
signing:
  keys:
    release: "projects/PROJECT/locations/LOCATION/keyRings/RING/cryptoKeys/KEY"
    vsa: "projects/PROJECT/locations/LOCATION/keyRings/RING/cryptoKeys/VSA_KEY"
  
policies:
  requireAllChecks: true
  minimumApprovals: 2
  
publication:
  registries:
    - "registry.secure.example.com"
  attestationStorage: "gs://attestations-bucket"
```

## 🧪 Testing

The managed context workflow is automatically triggered when applications are onboarded via the helm chart in `resources/`. Monitor the release pipeline runs:

```bash
# Monitor release pipeline runs in managed namespace
kubectl get pipelineruns -n managed-tenant -w

# Check VSA generation and signing results
kubectl logs -n managed-tenant -l tekton.dev/task=vsa-sign --tail=100
```

## 🚨 Security Considerations

**Access Control**:
- Only platform administrators have namespace access
- Service accounts with minimal required permissions
- Network policies prevent unauthorized communication

**Audit Requirements**:
- All signing operations logged with immutable audit trail
- Regular security reviews and access audits
- Compliance reporting and monitoring

**Incident Response**:
- Automated key revocation procedures
- Emergency signing key rollover capabilities
- Incident containment and investigation workflows

## 📊 Monitoring and Alerting

**Key Metrics**:
- Signing operation success/failure rates
- Policy violation frequency
- Trust artifact validation results
- Publication success metrics

**Alerts**:
- Failed signing operations
- Policy violations in release pipeline
- Unauthorized access attempts
- Key rotation requirements

## 📖 Related Documentation

- [Trust Model](../docs/trust-model.md) - Security architecture overview
- [Key Management](../docs/key-management.md) - Signing key procedures
- [Incident Response](../docs/incident-response.md) - Security incident handling
- [Compliance](../docs/compliance.md) - Regulatory and policy compliance