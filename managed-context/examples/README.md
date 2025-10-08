# Managed Context Examples

This directory contains example Custom Resources (CRs) for testing and demonstrating managed context functionality.

## 📋 Available Examples

### Test PipelineRuns

#### `test-vsa-sign-pipelinerun.yaml`
**Purpose**: Tests the vsa-sign task in isolation

**Features**:
- ✅ Mock trust artifact setup
- ✅ VSA signing with managed keys
- ✅ Attestation generation and validation
- ✅ Transparency log integration testing

#### `test-managed-pipeline-pipelinerun.yaml`
**Purpose**: Tests the complete managed pipeline

**Features**:
- ✅ Full task orchestration (conforma-vsa → image-promotion → vsa-sign)
- ✅ Conditional execution based on policy results
- ✅ Workspace sharing between tasks
- ✅ End-to-end workflow validation

### Test Data

#### `test-vsa-payload-configmap.yaml`
**Purpose**: Mock VSA payloads for testing

**Features**:
- ✅ PASSED scenario payload
- ✅ FAILED scenario payload
- ✅ Complete SLSA VSA v1.0 format
- ✅ Policy metadata and attestation references

## 🧪 Testing Scenarios

### Individual VSA Signing Test
```bash
# Create mock data
kubectl apply -f managed-context/examples/test-vsa-payload-configmap.yaml

# Run VSA signing test
kubectl create -f managed-context/examples/test-vsa-sign-pipelinerun.yaml

# Monitor execution
kubectl get pipelineruns -n managed-namespace -w

# Check signing results
kubectl logs -l test.slsa.dev/type=vsa-sign -n managed-namespace
```

### Complete Managed Pipeline Test
```bash
# Run full pipeline test
kubectl create -f managed-context/examples/test-managed-pipeline-pipelinerun.yaml

# Monitor all tasks
kubectl get pipelineruns,taskruns -n managed-namespace -w

# Check pipeline results
kubectl describe pipelinerun -l test.slsa.dev/type=managed-pipeline -n managed-namespace
```

### Failure Scenario Testing
```bash
# Test with failure payload
kubectl patch configmap test-vsa-payload -n managed-namespace --patch '
{
  "data": {
    "vsa-payload.json": "$(kubectl get configmap test-vsa-payload -n managed-namespace -o jsonpath='{.data.vsa-payload-failure\.json}')"
  }
}'

# Run test with failed policy
kubectl create -f managed-context/examples/test-vsa-sign-pipelinerun.yaml
```

## 📊 Expected Results

### Successful VSA Signing
```
📦 Creating mock trust artifacts for VSA signing test...
✅ Mock trust artifacts created
🔍 Validating trust artifacts...
✅ Trust artifact validation passed
🔄 Generating complete VSA from trust artifacts...
✅ VSA generation completed
🔐 Signing VSA with managed keys...
✅ VSA signing completed
📤 Publishing attestation...
✅ Attestation publication completed
```

### Managed Pipeline Success
```
📊 Pipeline Execution Summary:
  Source Image: registry.example.com/test-app:v1.0.0
  Target Image: registry.example.com/test-app:v1.0.0-promoted
  Policy Evaluation: PASSED
  Image Promotion: SUCCESS
  VSA Signing: SIGNED
  VSA Digest: sha256:abc123...
  Attestation URL: registry.example.com/attestations/vsa@sha256:abc123...
```

## 🔐 Security Validation

### Trust Boundary Tests
```bash
# Verify managed context has proper access
kubectl auth can-i get secrets vsa-signing-config --namespace=managed-namespace --as=system:serviceaccount:managed-namespace:managed-pipeline-sa

# Should return "yes"

# Verify tenant cannot access managed secrets
kubectl auth can-i get secrets vsa-signing-config --namespace=managed-namespace --as=system:serviceaccount:tenant-namespace:tenant-pipeline-sa

# Should return "no"
```

### Signing Key Validation
```bash
# Check signing secret exists
kubectl get secret vsa-signing-config -n managed-namespace

# Verify key format
kubectl get secret vsa-signing-config -n managed-namespace -o jsonpath='{.data}' | jq 'keys'

# Should show: ["cosign.key", "cosign.pub"]
```

## 🔧 Customization

### Custom Signing Configuration
```yaml
# Modify vsa-sign parameters
params:
  - name: signingKey
    value: "custom-signing-key"  # Use different key
  - name: verifier-id
    value: "https://your-managed.example.com"  # Custom verifier
  - name: registryUrl
    value: "your-registry.com"  # Custom registry
```

### Custom VSA Payload
```yaml
# In test-vsa-payload-configmap.yaml
data:
  custom-payload.json: |
    {
      "predicate": {
        "verifier": {
          "id": "https://your-verifier.example.com",
          "version": "v2.0.0"
        },
        # ... your custom VSA payload
      }
    }
```

### Pipeline Customization
```yaml
# Modify managed pipeline parameters
params:
  - name: policy-bundle-ref
    value: "oci://your-registry.com/custom-policies:v1.0"
  - name: verifier-id
    value: "https://your-managed.konflux.example.com"
```

## 🚨 Troubleshooting

### Common Issues

**Signing Key Not Found**:
```bash
# Check secret existence
kubectl get secret vsa-signing-key -n managed-namespace
kubectl describe secret vsa-signing-key -n managed-namespace

# Recreate if missing (demo keys only)
COSIGN_PASSWORD="" cosign generate-key-pair
kubectl create secret generic vsa-signing-key \
  --from-file=vsa-primary-key.key=cosign.key \
  --from-file=vsa-primary-key.pub=cosign.pub \
  --namespace=managed-namespace
```

**Pipeline Task Failures**:
```bash
# Check task status
kubectl get tasks -n managed-namespace
kubectl describe task conforma-vsa -n managed-namespace
kubectl describe task vsa-sign -n managed-namespace

# Check pipeline definition
kubectl describe pipeline slsa-managed-pipeline -n managed-namespace
```

**Workspace Issues**:
```bash
# Check PVC status
kubectl get pvc -n managed-namespace
kubectl describe pvc managed-workspace-pvc -n managed-namespace

# Check workspace mounts
kubectl logs -l tekton.dev/task=vsa-sign -n managed-namespace -c step-validate-trust-artifacts
```

### Debug Mode
```yaml
# Add debug task to pipeline
- name: debug-managed-context
  taskSpec:
    workspaces:
      - name: shared-workspace
    steps:
      - name: debug
        image: registry.redhat.io/ubi9/ubi:latest
        script: |
          echo "=== Managed Context Debug ==="
          echo "Namespace: $(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
          echo "Service Account: $(cat /var/run/secrets/kubernetes.io/serviceaccount/token | head -c 10)..."
          echo "Workspace Contents:"
          find $(workspaces.shared-workspace.path) -type f | head -20
          echo "Signing Keys:"
          ls -la /etc/signing-config/ || echo "No signing config mounted"
```

## 📈 Performance Monitoring

### Task Execution Times
```bash
# Monitor task durations
kubectl get taskruns -n managed-namespace -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[0].status,DURATION:.status.completionTime

# Expected times:
# conforma-vsa: 2-3 minutes
# vsa-sign: 30-60 seconds
# complete pipeline: 5-8 minutes
```

### Resource Usage
```bash
# Monitor resource consumption
kubectl top pods -n managed-namespace

# Check resource requests/limits
kubectl describe pipelinerun -l test.slsa.dev/type=managed-pipeline -n managed-namespace | grep -A 5 -B 5 resources
```

## 📖 Related Documentation

- **[Trust Model](../../docs/trust-model.md)**: Managed context architecture
- **[Task Development](../tasks/README.md)**: Managed context task details
- **[Security Guide](../../docs/security.md)**: Security controls and validation
- **[Testing Guide](../../scripts/README.md)**: Complete testing procedures