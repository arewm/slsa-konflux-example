# OCI Registry Configuration for SLSA-Konflux

This document describes how to configure OCI registries for the SLSA-Konflux demonstration, including container image storage, attestation publishing, and build artifact management.

## Overview

The SLSA-Konflux workflow requires several registry endpoints:

1. **Build Registry**: Stores container images built in tenant context
2. **Production Registry**: Stores promoted images after policy validation  
3. **Attestation Registry**: Stores signed VSAs and attestations
4. **Policy Registry**: Stores Enterprise Contract policy bundles

## Registry Requirements

### Minimum Registry Features Required:
- **OCI v1.1 Support**: For attestation storage via `cosign`
- **Multi-arch Images**: Support for linux/amd64 and linux/arm64
- **Layer Deduplication**: Efficient storage for similar images
- **API Authentication**: Token or credential-based access control

### Recommended Registry Features:
- **Vulnerability Scanning**: Built-in container security scanning
- **Retention Policies**: Automatic cleanup of old images/attestations
- **Audit Logging**: Complete access and modification logs
- **Backup/Replication**: High availability and disaster recovery

## Registry Configuration Examples

### Option 1: Single Registry (Simple Setup)

Use one registry for all artifacts with different namespaces:

```yaml
# Configuration
IMAGE_REGISTRY: "quay.io/your-org/slsa-demo"

# Registry layout:
quay.io/your-org/slsa-demo/
├── builds/           # Build artifacts from tenant context
├── production/       # Promoted images after policy validation
├── attestations/     # Signed VSAs and attestations
└── policies/         # Enterprise Contract policy bundles
```

### Option 2: Multi-Registry (Production Setup)

Use separate registries for different artifact types:

```yaml
# Configuration
BUILD_REGISTRY: "registry.tenant.example.com/builds"
PRODUCTION_REGISTRY: "registry.production.example.com/apps"
ATTESTATION_REGISTRY: "registry.security.example.com/attestations"
POLICY_REGISTRY: "registry.compliance.example.com/policies"
```

## Authentication Configuration

### 1. Registry Pull Secrets

Create pull secrets for accessing private registries:

```bash
# Create registry credentials
kubectl create secret docker-registry registry-credentials \
  --docker-server=quay.io \
  --docker-username=your-username \
  --docker-password=your-token \
  --docker-email=your-email@example.com \
  --namespace=tenant-namespace

# Copy to managed namespace
kubectl get secret registry-credentials -n tenant-namespace -o yaml | \
  sed 's/namespace: tenant-namespace/namespace: managed-namespace/' | \
  kubectl apply -f -
```

### 2. Service Account Configuration

Link pull secrets to service accounts:

```yaml
# Tenant namespace service account
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tenant-build-sa
  namespace: tenant-namespace
imagePullSecrets:
  - name: registry-credentials
secrets:
  - name: registry-credentials

---
# Managed namespace service account  
apiVersion: v1
kind: ServiceAccount
metadata:
  name: managed-release-sa
  namespace: managed-namespace
imagePullSecrets:
  - name: registry-credentials
secrets:
  - name: registry-credentials
```

### 3. Push Authentication for Tasks

Configure push credentials for Tekton tasks:

```yaml
# Registry push secret
apiVersion: v1
kind: Secret
metadata:
  name: registry-push-credentials
  namespace: tenant-namespace
  annotations:
    tekton.dev/docker-0: quay.io
type: kubernetes.io/basic-auth
stringData:
  username: your-username
  password: your-token

---
# For managed namespace
apiVersion: v1  
kind: Secret
metadata:
  name: registry-push-credentials
  namespace: managed-namespace
  annotations:
    tekton.dev/docker-0: quay.io
type: kubernetes.io/basic-auth
stringData:
  username: your-username
  password: your-token
```

## Tekton Chains Registry Configuration

Configure Tekton Chains for automatic attestation publishing:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: chains-config
  namespace: tekton-chains
data:
  # Storage configuration
  artifacts.oci.storage: "oci"
  artifacts.oci.repository: "quay.io/your-org/slsa-demo/attestations"
  
  # Signing configuration
  signers.x509.fulcio.enabled: "false"
  signers.kms.kmsref: "k8s://tenant-namespace/cosign-key"
  
  # Transparency log
  transparency.enabled: "true"
  transparency.url: "https://rekor.sigstore.dev"
```

## Registry-Specific Setup Instructions

### Quay.io Configuration

1. **Create Organization**: Create or use existing Quay.io organization
2. **Create Repositories**: 
   ```bash
   # Create repositories (via web UI or API)
   slsa-demo-builds         # Public or private
   slsa-demo-production     # Private recommended  
   slsa-demo-attestations   # Public for transparency
   slsa-demo-policies       # Public for policy distribution
   ```

3. **Robot Account**: Create robot account with push/pull permissions
   ```bash
   # Use robot account credentials for authentication
   QUAY_USERNAME="your-org+robot-name"
   QUAY_TOKEN="robot-token"
   ```

### Harbor Configuration

1. **Create Project**: Create Harbor project for the demo
2. **Configure Policies**:
   ```yaml
   # Project configuration
   project: slsa-demo
   public: false
   vulnerability_scanning: true
   cosign_signature_verification: true
   ```

3. **User Management**: Create service account for automation
   ```bash
   # Harbor service account
   HARBOR_USERNAME="robot$slsa-demo+tekton"
   HARBOR_TOKEN="generated-token"
   ```

### Amazon ECR Configuration

1. **Create Repositories**:
   ```bash
   # Create ECR repositories
   aws ecr create-repository --repository-name slsa-demo/builds --region us-east-1
   aws ecr create-repository --repository-name slsa-demo/production --region us-east-1
   aws ecr create-repository --repository-name slsa-demo/attestations --region us-east-1
   ```

2. **IAM Configuration**:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "ecr:BatchCheckLayerAvailability",
           "ecr:GetDownloadUrlForLayer",
           "ecr:BatchGetImage",
           "ecr:PutImage",
           "ecr:InitiateLayerUpload",
           "ecr:UploadLayerPart",
           "ecr:CompleteLayerUpload"
         ],
         "Resource": "arn:aws:ecr:*:*:repository/slsa-demo/*"
       }
     ]
   }
   ```

## Pipeline Registry Configuration

Update pipeline parameters to use your registry configuration:

```yaml
# scripts/setup-end-to-end-demo.sh
IMAGE_REGISTRY="${IMAGE_REGISTRY:-quay.io/your-org/slsa-demo}"

# managed-context/pipelines/slsa-managed-release-pipeline.yaml
params:
  - name: target-registry
    value: "quay.io/your-org/slsa-demo/production"
  - name: attestation-registry  
    value: "quay.io/your-org/slsa-demo/attestations"
  - name: policy-bundle-ref
    value: "oci://quay.io/your-org/slsa-demo/policies/enterprise-contract:latest"
```

## Verification and Testing

### 1. Test Registry Access

```bash
# Test pull access
podman pull quay.io/your-org/slsa-demo/test:latest

# Test push access  
echo "test" | podman build -t quay.io/your-org/slsa-demo/test:latest -f - .
podman push quay.io/your-org/slsa-demo/test:latest
```

### 2. Test Cosign Attestation Storage

```bash
# Generate test attestation
echo '{"test": "attestation"}' | cosign attest \
  --key cosign.key \
  --type application/vnd.test.attestation \
  quay.io/your-org/slsa-demo/test:latest

# Verify attestation storage
cosign verify-attestation \
  --key cosign.pub \
  --type application/vnd.test.attestation \
  quay.io/your-org/slsa-demo/test:latest
```

### 3. Test Policy Bundle Access

```bash
# Test policy bundle resolution
crane digest quay.io/your-org/slsa-demo/policies/enterprise-contract:latest

# Test policy bundle download
oras pull quay.io/your-org/slsa-demo/policies/enterprise-contract:latest
```

## Troubleshooting

### Common Issues

1. **Authentication Failures**:
   ```bash
   # Check secret configuration
   kubectl get secret registry-credentials -o yaml
   
   # Test manual authentication
   podman login quay.io
   ```

2. **Permission Errors**:
   ```bash
   # Verify service account configuration
   kubectl describe sa tenant-build-sa -n tenant-namespace
   
   # Check RBAC permissions
   kubectl auth can-i create secrets --as=system:serviceaccount:tenant-namespace:tenant-build-sa
   ```

3. **Attestation Storage Issues**:
   ```bash
   # Check Tekton Chains configuration
   kubectl get configmap chains-config -n tekton-chains -o yaml
   
   # Verify cosign configuration
   cosign version
   cosign tree quay.io/your-org/slsa-demo/test:latest
   ```

## Security Considerations

### Registry Security Best Practices:

1. **Private Registries**: Use private registries for build artifacts and production images
2. **Credential Rotation**: Regularly rotate registry access tokens and passwords
3. **Network Policies**: Restrict registry access to authorized namespaces only
4. **Vulnerability Scanning**: Enable automatic vulnerability scanning for all images
5. **Audit Logging**: Enable comprehensive audit logging for all registry operations

### Attestation Security:

1. **Public Attestations**: Store attestations in public registries for transparency
2. **Signature Verification**: Always verify attestation signatures before trusting
3. **Transparency Logs**: Use public transparency logs (Rekor) for signature transparency
4. **Key Management**: Protect signing keys with appropriate access controls

## Production Considerations

### High Availability:
- Configure registry replication across multiple regions
- Implement backup and disaster recovery procedures
- Use load balancers for registry API endpoints

### Performance:
- Configure registry caching for frequently accessed images
- Use geographically distributed registries for better performance
- Implement proper retention policies to manage storage costs

### Compliance:
- Ensure registry configuration meets organizational compliance requirements
- Implement proper data retention and deletion policies
- Configure audit logging to meet regulatory requirements

---

This configuration enables the complete SLSA-Konflux workflow with proper registry separation, authentication, and security controls while maintaining flexibility for different deployment scenarios.