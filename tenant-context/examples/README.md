# Tenant Context Examples

This directory contains example Custom Resources (CRs) for testing and demonstrating tenant context functionality.

## 📋 Available Examples

### Test PipelineRuns

#### `test-conforma-vsa-pipelinerun.yaml`
**Purpose**: Tests the conforma-vsa task in isolation

**Features**:
- ✅ Mock build artifacts generation
- ✅ Policy evaluation simulation  
- ✅ VSA payload generation testing
- ✅ Enterprise Contract integration validation

**Usage**:
```bash
# Apply and run test
kubectl apply -f tenant-context/examples/test-conforma-vsa-pipelinerun.yaml

# Monitor execution
kubectl get pipelineruns -n tenant-namespace -w

# Check results
kubectl logs -l app.kubernetes.io/part-of=slsa-konflux-test -n tenant-namespace
```

**Test Validation**:
- Verifies conforma-vsa task executes successfully
- Validates VSA payload generation with SLSA v1.0 format
- Confirms policy evaluation integration
- Tests workspace management and artifact flow

## 🧪 Testing Scenarios

### Individual Task Testing
```bash
# Test conforma-vsa task
kubectl create -f tenant-context/examples/test-conforma-vsa-pipelinerun.yaml

# Wait for completion
kubectl wait --for=condition=Succeeded pipelinerun -l test.slsa.dev/type=conforma-vsa -n tenant-namespace --timeout=300s

# Verify VSA output
kubectl logs -l test.slsa.dev/type=conforma-vsa -n tenant-namespace | grep "VSA"
```

### Trust Boundary Validation
```bash
# Test that tenant context cannot access managed secrets
kubectl auth can-i get secrets --namespace=managed-namespace --as=system:serviceaccount:tenant-namespace:tenant-pipeline-sa

# Should return "no"
```

## 📊 Expected Results

### Successful Test Output
```
✅ Mock build artifacts created
🔧 Running Conforma policy evaluation...
✅ Policy evaluation completed
🔄 Converting Conforma results to VSA format...
✅ VSA conversion completed
📊 VSA Summary:
  Path: /workspace/vsa-results/test-vsa.json
  Result: PASSED
```

### Test Artifacts Generated
- **VSA Payload**: `/workspace/vsa-results/test-vsa.json`
- **Policy Results**: Conforma evaluation output
- **Trust Artifacts**: Workspace artifacts for managed context consumption

## 🔧 Customization

### Modify Test Parameters
```yaml
# In test-conforma-vsa-pipelinerun.yaml
params:
  - name: image
    value: "your-registry.com/your-app:tag"  # Change test image
  - name: policy-bundle-ref
    value: "oci://your-registry.com/policies:tag"  # Use custom policies
  - name: verifier-id
    value: "https://your-tenant.example.com"  # Custom verifier ID
```

### Add Custom Mock Data
```yaml
# Extend setup-mock-artifacts task
- name: create-custom-mock
  script: |
    # Add your custom mock data here
    echo "Custom test data" > $(workspaces.build-artifacts.path)/custom-file
```

## 🚨 Troubleshooting

### Common Issues

**Task Not Found**:
```bash
# Verify task installation
kubectl get tasks conforma-vsa -n tenant-namespace
kubectl describe task conforma-vsa -n tenant-namespace
```

**Workspace Issues**:
```bash
# Check PVC creation
kubectl get pvc -n tenant-namespace
kubectl describe pvc -n tenant-namespace
```

**Permission Errors**:
```bash
# Verify service account
kubectl get serviceaccount tenant-pipeline-sa -n tenant-namespace
kubectl describe rolebinding tenant-pipeline-binding -n tenant-namespace
```

### Debug Mode
```yaml
# Add debug step to PipelineRun
- name: debug-workspace
  taskSpec:
    steps:
      - name: debug
        image: registry.redhat.io/ubi9/ubi:latest
        script: |
          echo "=== Workspace Contents ==="
          find /workspace -type f -exec ls -la {} \;
          echo "=== Environment ==="
          env | sort
```

## 📖 Related Documentation

- **[Trust Model](../../docs/trust-model.md)**: Trust boundary architecture
- **[Task Development](../tasks/README.md)**: Tenant context task details
- **[Testing Guide](../../scripts/README.md)**: Complete testing procedures
- **[Troubleshooting](../../docs/troubleshooting.md)**: Detailed problem resolution