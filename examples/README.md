# Example Applications

This directory contains sample applications that demonstrate the complete SLSA-Konflux workflow. These examples show how to configure applications for SLSA compliance and integrate with the trust boundary model.

## 🎯 Purpose

- **Complete Workflow Demonstration**: End-to-end examples from source to deployment
- **Configuration Templates**: Reusable patterns for SLSA compliance
- **Testing Scenarios**: Validate trust boundary separation and security controls
- **Learning Resources**: Practical examples for understanding SLSA implementation

## 📁 Directory Structure

```
examples/
├── go-app/                  # Go web service example
│   ├── main.go              # Application source code
│   ├── go.mod               # Go module definition
│   ├── Dockerfile           # Container build definition
│   ├── .tekton/             # Tekton pipeline configurations
│   │   ├── pipeline.yaml    # Complete build pipeline
│   │   ├── triggers.yaml    # Event triggers
│   │   └── releases/        # Release configurations
│   └── README.md            # Go app specific documentation
└── python-app/              # Python Flask application example
    ├── app.py               # Flask application code
    ├── requirements.txt     # Python dependencies
    ├── Dockerfile           # Container build definition
    ├── .tekton/             # Tekton pipeline configurations
    │   ├── pipeline.yaml    # Complete build pipeline
    │   ├── triggers.yaml    # Event triggers
    │   └── releases/        # Release configurations
    └── README.md            # Python app specific documentation
```

## 🔄 Example Workflow

Each example application demonstrates:

1. **Source Verification**: SLSA source-level verification with git-clone-slsa
2. **Build Process**: Secure container builds with provenance generation
3. **Policy Evaluation**: Security policy validation with conforma-vsa
4. **Trust Handoff**: Secure transfer to managed context
5. **VSA Generation**: Final verification summary creation and signing
6. **Publication**: Signed artifact publication with attestations

## 🛠️ Applications

### Go Web Service
**Technology Stack**: Go 1.21, HTTP server, minimal dependencies
**Security Features**:
- Static analysis with gosec
- Vulnerability scanning with govulncheck
- Minimal base image (distroless)
- Non-root container execution

**SLSA Compliance Highlights**:
- Source code signature verification
- Reproducible builds
- Complete dependency tracking
- Cryptographic attestation chain

### Python Flask Application
**Technology Stack**: Python 3.11, Flask, gunicorn
**Security Features**:
- Dependency vulnerability scanning with safety
- SAST scanning with bandit
- Container security hardening
- Security headers and middleware

**SLSA Compliance Highlights**:
- Python package provenance verification
- Virtual environment isolation
- Pinned dependency versions
- Comprehensive security scanning

## 🔒 Trust Context Configuration

### Tenant Context Configuration
Both examples include tenant context configurations:

```yaml
# .tekton/pipeline.yaml
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: example-build-pipeline
  namespace: tenant-namespace
spec:
  workspaces:
    - name: source
    - name: trust-artifacts
  
  tasks:
    # Source verification with SLSA
    - name: source-verify
      taskRef:
        name: git-clone-slsa
      workspaces:
        - name: source
          workspace: source
        - name: trust-artifacts
          workspace: trust-artifacts
    
    # Build application
    - name: build
      taskRef:
        name: buildah
      runAfter: ["source-verify"]
      workspaces:
        - name: source
          workspace: source
    
    # Policy evaluation with VSA payload
    - name: policy-evaluate
      taskRef:
        name: conforma-vsa
      runAfter: ["build"]
      workspaces:
        - name: source
          workspace: source
        - name: trust-artifacts
          workspace: trust-artifacts
```

### Managed Context Configuration
Release configurations for managed context:

```yaml
# .tekton/releases/releaseplan.yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: ReleasePlan
metadata:
  name: example-release-plan
  namespace: managed-namespace
spec:
  application: example-app
  pipeline:
    name: managed-release-pipeline
    bundle: quay.io/konflux-ci/release-pipeline:latest
  
  data:
    vsa:
      enabled: true
      signingKey: "managed-vsa-key"
    
    publication:
      registry: "registry.example.com"
      namespace: "production"
```

## 🧪 Testing and Validation

### Local Testing
```bash
# Test Go application build
cd examples/go-app
kubectl apply -f .tekton/
kubectl create pipelinerun example-go-build --from=pipeline/example-build-pipeline

# Test Python application build  
cd examples/python-app
kubectl apply -f .tekton/
kubectl create pipelinerun example-python-build --from=pipeline/example-build-pipeline
```

### Integration Testing
```bash
# Test complete workflow with trust handoff
./scripts/test-example-workflow.sh go-app
./scripts/test-example-workflow.sh python-app

# Validate SLSA compliance
./scripts/validate-slsa-compliance.sh examples/go-app
./scripts/validate-slsa-compliance.sh examples/python-app
```

### Security Validation
```bash
# Verify trust boundaries
./scripts/test-trust-boundaries.sh

# Validate VSA generation
./scripts/test-vsa-generation.sh go-app
./scripts/test-vsa-generation.sh python-app

# Check attestation publishing
./scripts/verify-attestations.sh registry.example.com/go-app:latest
./scripts/verify-attestations.sh registry.example.com/python-app:latest
```

## 📊 Compliance Matrix

### SLSA Requirements Coverage

| Requirement | Go App | Python App | Implementation |
|-------------|--------|------------|----------------|
| Source verification | ✅ | ✅ | git-clone-slsa task |
| Build provenance | ✅ | ✅ | Tekton Chains |
| Isolated builds | ✅ | ✅ | Kubernetes namespaces |
| Dependency tracking | ✅ | ✅ | go.mod / requirements.txt |
| Vulnerability scanning | ✅ | ✅ | Integrated scanners |
| Policy enforcement | ✅ | ✅ | Conforma evaluation |
| VSA generation | ✅ | ✅ | vsa-sign task |
| Attestation signing | ✅ | ✅ | Managed key signing |

### Security Controls

| Control | Implementation | Validation |
|---------|----------------|------------|
| Code signing | GPG commit signatures | git-clone-slsa verification |
| Build isolation | Namespace separation | RBAC enforcement |
| Trust boundaries | Context separation | Trust artifact validation |
| Key management | HSM/KMS integration | Signing operation audit |
| Transparency | Rekor logging | Transparency log verification |

## 🔧 Customization Guide

### Adding New Examples
1. Create application directory under `examples/`
2. Implement source code with security best practices
3. Configure `.tekton/` directory with pipelines
4. Add language-specific security scanning
5. Configure release plans for managed context
6. Document SLSA compliance features

### Adapting for Your Use Case
```bash
# Copy example as template
cp -r examples/go-app examples/my-app

# Customize application code
# Modify .tekton/pipeline.yaml for specific requirements
# Update security scanning tools
# Configure release targets
```

### Security Scanner Integration
```yaml
# Add custom security scanning step
- name: custom-security-scan
  taskRef:
    name: my-security-scanner
  runAfter: ["build"]
  params:
    - name: image
      value: "$(tasks.build.results.IMAGE_URL)"
  workspaces:
    - name: source
      workspace: source
```

## 📖 Application-Specific Documentation

- **[Go Application](go-app/README.md)** - Go-specific implementation details
- **[Python Application](python-app/README.md)** - Python-specific configuration
- **[Adding Examples](../docs/adding-examples.md)** - Guide for contributing new examples
- **[Security Scanning](../docs/security-scanning.md)** - Security tool integration guide

## 🚀 Quick Start

1. **Choose an Example**: Start with the application closest to your stack
2. **Deploy Prerequisites**: Ensure Konflux is installed and configured
3. **Run the Pipeline**: Execute the build pipeline in tenant context
4. **Trigger Release**: Initiate release pipeline in managed context
5. **Verify Results**: Check signed attestations and VSA publication

Each example includes detailed setup instructions and troubleshooting guides to get you started quickly with SLSA-compliant workflows.