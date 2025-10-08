# VSA Signing Key Management

This document covers the complete key management strategy for VSA generation, including private key security and public key distribution for verification.

## Overview

The VSA generation process requires:
- **Private key**: Secure storage in managed namespace for signing
- **Public key**: Accessible distribution for VSA verification
- **Trust chain**: Verifiable authority for VSA signatures

## Private Key Management (Managed Namespace)

### Key Generation
```bash
# Generate cosign key pair
cosign generate-key-pair --output-key-prefix=vsa-signing

# This creates:
# - vsa-signing.key (private key)
# - vsa-signing.pub (public key)
```

### Secure Storage
```bash
# Store private key in managed namespace secret
kubectl create secret generic vsa-signing-key \
  --from-file=cosign.key=vsa-signing.key \
  --from-file=cosign.pub=vsa-signing.pub \
  --from-literal=verifier-id="https://managed.konflux.example.com" \
  -n managed-namespace

# Verify secret creation
kubectl get secret vsa-signing-key -n managed-namespace -o yaml
```

### Security Controls
- **Namespace isolation**: Only `managed-namespace` has access
- **RBAC restrictions**: Limited to VSA signing ServiceAccount
- **Read-only mounting**: Key is mounted read-only in signing step
- **Minimal exposure**: Only `sign-vsa` step can access the key

## Public Key Distribution

### Problem
Users need the **public key** to verify VSA signatures:
```bash
# Verification requires public key
cosign verify-attestation \
  --type https://slsa.dev/verification_summary/v1 \
  --key cosign.pub \  # ← Users need this
  quay.io/example/app:v1.0.0
```

### Solution 1: ConfigMap Distribution
```bash
# Create public key ConfigMap (cluster-wide access)
kubectl create configmap vsa-public-key \
  --from-file=cosign.pub=vsa-signing.pub \
  --from-literal=verifier-id="https://managed.konflux.example.com" \
  -n kube-system  # System namespace for cluster-wide access

# Label for easy discovery
kubectl label configmap vsa-public-key \
  app.kubernetes.io/name=vsa-verification \
  app.kubernetes.io/component=public-key \
  -n kube-system
```

### Solution 2: OCI Registry Distribution
```bash
# Push public key to OCI registry (recommended)
cosign public-key --key vsa-signing.key > vsa-signing.pub

# Store in well-known location
crane cp vsa-signing.pub \
  quay.io/konflux/vsa-public-keys:latest

# Users can fetch the key
crane export quay.io/konflux/vsa-public-keys:latest | \
  tar -xf - cosign.pub
```

### Solution 3: Service Discovery
```yaml
# Service for public key distribution
apiVersion: v1
kind: Service
metadata:
  name: vsa-public-key-service
  namespace: kube-system
spec:
  ports:
  - port: 8080
    targetPort: 8080
  selector:
    app: vsa-public-key-server
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vsa-public-key-server
  namespace: kube-system
spec:
  replicas: 2
  selector:
    matchLabels:
      app: vsa-public-key-server
  template:
    metadata:
      labels:
        app: vsa-public-key-server
    spec:
      containers:
      - name: server
        image: nginx:alpine
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: public-key
          mountPath: /usr/share/nginx/html
          readOnly: true
      volumes:
      - name: public-key
        configMap:
          name: vsa-public-key
```

## User Verification Workflow

### Option 1: ConfigMap Access
```bash
# Users get public key from ConfigMap
kubectl get configmap vsa-public-key \
  -n kube-system \
  -o jsonpath='{.data.cosign\.pub}' > cosign.pub

# Verify VSA
cosign verify-attestation \
  --type https://slsa.dev/verification_summary/v1 \
  --key cosign.pub \
  quay.io/example/app:v1.0.0
```

### Option 2: OCI Registry Access
```bash
# Download public key from registry
crane export quay.io/konflux/vsa-public-keys:latest | \
  tar -xf - cosign.pub

# Verify VSA
cosign verify-attestation \
  --type https://slsa.dev/verification_summary/v1 \
  --key cosign.pub \
  quay.io/example/app:v1.0.0
```

### Option 3: Service Discovery
```bash
# Get public key from service
kubectl port-forward svc/vsa-public-key-service 8080:8080 -n kube-system &
curl http://localhost:8080/cosign.pub > cosign.pub

# Verify VSA
cosign verify-attestation \
  --type https://slsa.dev/verification_summary/v1 \
  --key cosign.pub \
  quay.io/example/app:v1.0.0
```

## Policy Distribution

### Current Implementation
Policies are passed to the VSA generation task via parameters:

```yaml
params:
  - name: policy-bundle-ref
    description: OCI reference to policy bundle
    default: "oci://quay.io/conforma/slsa3-policy:latest"
```

### Policy Bundle Structure
```bash
# Policy bundle contains:
# - Rego policy files (.rego)
# - Policy configuration (policy.yaml)
# - Data files (.yml, .json)

# Example policy bundle reference:
oci://quay.io/konflux-ci/release-policy@sha256:1fc38e278963af0f...
```

### Policy Evaluation Process
1. **Task receives**: `policy-bundle-ref` parameter
2. **Conforma downloads**: Policy bundle from OCI registry
3. **Evaluation**: Policies applied to image and attestations
4. **Results**: Stored in JSON format for VSA conversion

## Security Considerations

### Private Key Security
- **Never expose**: Private key outside managed namespace
- **Rotate regularly**: Establish key rotation schedule (quarterly)
- **Audit access**: Log all signing operations
- **Backup strategy**: Secure backup of signing keys

### Public Key Trust
- **Chain of custody**: Document public key distribution
- **Integrity verification**: Hash verification for public keys
- **Version management**: Support multiple public key versions
- **Revocation**: Process for revoking compromised keys

### Trust Boundaries
```
┌─────────────────────────────────────────────────────────┐
│ managed-namespace (Private Key)                         │
│ ├── vsa-signing-key secret                              │
│ ├── conforma-vsa task (signing step only)               │
│ └── RBAC restrictions                                   │
└─────────────────────────────────────────────────────────┘
                             │
                             │ Signed VSA
                             ▼
┌─────────────────────────────────────────────────────────┐
│ Public Key Distribution (All Users)                    │
│ ├── ConfigMap (kube-system)                            │
│ ├── OCI Registry (public)                              │
│ └── Service Discovery (HTTP)                           │
└─────────────────────────────────────────────────────────┘
```

## Deployment Checklist

### Setup Phase
- [ ] Generate cosign key pair
- [ ] Create private key secret in managed namespace
- [ ] Deploy public key via chosen distribution method
- [ ] Configure RBAC for managed namespace access
- [ ] Test key access from VSA task

### Operation Phase
- [ ] Monitor signing operations
- [ ] Verify public key accessibility
- [ ] Test VSA verification workflow
- [ ] Audit key usage logs
- [ ] Plan key rotation schedule

### User Onboarding
- [ ] Document public key access methods
- [ ] Provide verification examples
- [ ] Test user verification workflow
- [ ] Create troubleshooting guides
- [ ] Monitor verification success rates

## Troubleshooting

### Common Issues

#### Private Key Access
```bash
# Debug: Check secret exists
kubectl get secret vsa-signing-key -n managed-namespace

# Debug: Verify secret content
kubectl get secret vsa-signing-key -n managed-namespace -o yaml

# Debug: Check RBAC permissions
kubectl auth can-i get secrets -n managed-namespace --as=system:serviceaccount:managed-namespace:default
```

#### Public Key Access
```bash
# Debug: Check ConfigMap
kubectl get configmap vsa-public-key -n kube-system

# Debug: Test public key retrieval
kubectl get configmap vsa-public-key -n kube-system -o jsonpath='{.data.cosign\.pub}' | cosign public-key --key -

# Debug: Verify key format
file cosign.pub
```

#### VSA Verification
```bash
# Debug: Check VSA exists
cosign verify-attestation --type https://slsa.dev/verification_summary/v1 quay.io/example/app:v1.0.0

# Debug: Manual verification
cosign verify-attestation \
  --type https://slsa.dev/verification_summary/v1 \
  --key cosign.pub \
  --output=json \
  quay.io/example/app:v1.0.0 | jq '.payload | @base64d | fromjson'
```

## Recommendations

### Production Deployment
1. **Use OCI registry** for public key distribution (most scalable)
2. **Implement key rotation** with automated processes
3. **Monitor verification** success rates and failures
4. **Document trust chain** for compliance requirements
5. **Test disaster recovery** for key compromise scenarios

### Security Hardening
1. **Use HSM/KMS** for private key storage in production
2. **Implement multi-signature** for high-security environments
3. **Regular security audits** of key management processes
4. **Automated monitoring** for unauthorized key access
5. **Compliance reporting** for key usage and verification