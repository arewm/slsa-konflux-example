# SLSA Policy Analysis for Enterprise Contract Integration

This document analyzes the Enterprise Contract policy bundle for SLSA compliance gaps and identifies additional policies needed for complete SLSA Level 3 demonstration.

## Current Policy Bundle Status

### Enterprise Contract Standard Policies
Currently referencing: `oci://quay.io/konflux/ec-policy-data:latest` (placeholder)
Should reference: `oci://quay.io/enterprise-contract/ec-policy-data:latest` (real)

## SLSA Requirements Analysis

### SLSA Build Level 3 Requirements

| SLSA Requirement | Enterprise Contract Policy | Status | Gap Analysis |
|------------------|---------------------------|---------|--------------|
| **Source Verification** | `source_repository_url_provided` | ✅ Covered | Standard EC policy validates source URLs |
| **Build Isolation** | `hermetic_builds_required` | ✅ Covered | EC validates hermetic build environments |
| **Provenance Generation** | `slsa_provenance_required` | ✅ Covered | EC validates SLSA provenance presence |
| **Provenance Content** | `slsa_provenance_available` | ✅ Covered | EC validates provenance content |
| **Build Platform** | `build_platform_requirements` | ✅ Covered | EC validates build platform isolation |
| **Dependencies** | `allowed_registry_prefixes` | ✅ Covered | EC validates dependency sources |

### SLSA Source Track Requirements

| SLSA Requirement | Enterprise Contract Policy | Status | Gap Analysis |
|------------------|---------------------------|---------|--------------|
| **Version Control** | `source_repository_url_provided` | ✅ Covered | Standard EC policy |
| **Branch Protection** | - | ❌ **GAP** | **Need SLSA-specific branch protection policy** |
| **Two-Person Review** | - | ❌ **GAP** | **Need pull request review validation** |
| **Authenticated History** | - | ❌ **GAP** | **Need commit signature validation** |

### VSA-Specific Requirements

| SLSA Requirement | Enterprise Contract Policy | Status | Gap Analysis |
|------------------|---------------------------|---------|--------------|
| **VSA Format** | - | ❌ **GAP** | **Need VSA format validation policy** |
| **Verifier Identity** | - | ❌ **GAP** | **Need verifier identity validation** |
| **Input Attestations** | `attestations_required` | ✅ Covered | EC validates input attestations |
| **Policy Evaluation** | Core EC functionality | ✅ Covered | EC provides policy evaluation |

## Identified Policy Gaps

### 1. SLSA Source Track Policies (High Priority)

**Missing Policies Needed:**
```rego
# slsa_source_branch_protection_policy
package slsa.source.branch_protection

deny[msg] {
    # Validate branch protection settings
    input.source.branch_protection.required == false
    msg := "SLSA Source Level 2+ requires branch protection"
}

deny[msg] {
    # Validate deletion protection
    input.source.branch_protection.allow_deletions == true
    msg := "SLSA Source Level 2+ prohibits branch deletion"
}
```

**Implementation Priority:** HIGH - Required for SLSA Source Level 2+

### 2. VSA Format Validation (Medium Priority)

**Missing Policies Needed:**
```rego
# vsa_format_validation_policy  
package slsa.vsa.format

deny[msg] {
    # Validate VSA predicate type
    input.predicateType != "https://slsa.dev/verification_summary/v1"
    msg := "VSA must use correct SLSA predicate type"
}

deny[msg] {
    # Validate verifier identity
    not input.predicate.verifier.id
    msg := "VSA must include verifier identity"
}
```

**Implementation Priority:** MEDIUM - Important for VSA compliance

### 3. Commit Signature Validation (Medium Priority)

**Missing Policies Needed:**
```rego
# slsa_source_commit_signature_policy
package slsa.source.signatures

deny[msg] {
    # Validate commit signatures for SLSA Source Level 3
    input.source.commit.signature.verified != true
    input.slsa.source.level >= 3
    msg := "SLSA Source Level 3 requires verified commit signatures"
}
```

**Implementation Priority:** MEDIUM - Required for SLSA Source Level 3

## Recommended Implementation Strategy

### Phase 1: Update to Real Enterprise Contract Policies (Immediate)

1. **Update all policy bundle references**:
   ```bash
   # Find and replace across all files
   find . -type f \( -name "*.yaml" -o -name "*.yml" \) -exec \
     sed -i 's|oci://quay.io/konflux/ec-policy-data|oci://quay.io/enterprise-contract/ec-policy-data|g' {} \;
   ```

2. **Test with real Enterprise Contract policies**:
   ```bash
   # Verify policy bundle exists and is accessible
   crane manifest quay.io/enterprise-contract/ec-policy-data:latest
   ```

### Phase 2: Create SLSA-Specific Policy Bundle (If Gaps Remain)

If the standard Enterprise Contract policies don't cover all SLSA requirements:

1. **Create custom policy bundle**:
   ```bash
   # Build custom policy bundle with SLSA-specific policies
   mkdir slsa-policies
   
   # Add SLSA source track policies
   cat > slsa-policies/slsa-source-branch-protection.rego <<EOF
   package slsa.source.branch_protection
   # Policy content here
   EOF
   
   # Add VSA format validation  
   cat > slsa-policies/vsa-format-validation.rego <<EOF
   package slsa.vsa.format
   # Policy content here
   EOF
   
   # Build and publish bundle
   opa build slsa-policies/ -o slsa-policy-bundle.tar.gz
   oras push quay.io/konflux-slsa-example/slsa-policies:v1.0 slsa-policy-bundle.tar.gz
   ```

2. **Update policy bundle references**:
   ```yaml
   policy-bundle-ref: "oci://quay.io/konflux-slsa-example/slsa-policies:v1.0"
   ```

### Phase 3: Hybrid Approach (Recommended)

Use Enterprise Contract as base + SLSA-specific additions:

```yaml
# Multiple policy bundles for comprehensive coverage
policy-bundles:
  - "oci://quay.io/enterprise-contract/ec-policy-data:latest"  # Base EC policies
  - "oci://quay.io/konflux-slsa-example/slsa-source-policies:v1.0"  # SLSA source track
  - "oci://quay.io/konflux-slsa-example/vsa-policies:v1.0"  # VSA-specific policies
```

## Policy Bundle Creation Guide

### 1. SLSA Source Track Policy Bundle

**File Structure:**
```
slsa-source-policies/
├── metadata.yaml
├── policies/
│   ├── branch-protection.rego
│   ├── commit-signatures.rego
│   └── two-person-review.rego
└── data/
    └── allowed-repositories.json
```

**Build Command:**
```bash
conftest build slsa-source-policies/ --output bundle.tar.gz
oras push quay.io/konflux-slsa-example/slsa-source-policies:v1.0 bundle.tar.gz
```

### 2. VSA Validation Policy Bundle

**File Structure:**
```
vsa-policies/
├── metadata.yaml
├── policies/
│   ├── vsa-format.rego
│   ├── verifier-identity.rego
│   └── attestation-completeness.rego
└── schemas/
    └── vsa-schema.json
```

## Immediate Action Plan

### Step 1: Verify Real Enterprise Contract Policies
```bash
# Check if real EC policy bundle exists and is accessible
crane manifest quay.io/enterprise-contract/ec-policy-data:latest

# If not accessible, check alternative locations:
crane manifest quay.io/konflux-ci/ec-policy-data:latest
crane manifest quay.io/redhat-appstudio/ec-policy-data:latest
```

### Step 2: Update Policy References  
```bash
# Create script to update all policy references
cat > update-policy-refs.sh <<EOF
#!/bin/bash
find . -type f \( -name "*.yaml" -o -name "*.yml" -o -name "*.md" \) \
  -not -path "./.git/*" \
  -exec sed -i.bak 's|quay.io/konflux/ec-policy-data|quay.io/enterprise-contract/ec-policy-data|g' {} \;

# Clean up backup files
find . -name "*.bak" -delete
EOF

chmod +x update-policy-refs.sh
./update-policy-refs.sh
```

### Step 3: Test Policy Evaluation
```bash
# Test policy evaluation with updated references
kubectl apply -f managed-context/examples/test-managed-pipeline-pipelinerun.yaml
kubectl logs -f pipelinerun/test-managed-pipeline-run
```

## Risk Assessment

### Low Risk: Standard Enterprise Contract Policies
- **Build security policies**: Well established and tested
- **Container policies**: Comprehensive coverage for container security
- **Attestation validation**: Standard attestation format validation

### Medium Risk: SLSA-Specific Gaps
- **Source track policies**: May need custom policies for branch protection
- **VSA format validation**: May need specific VSA predicate validation
- **Commit signature validation**: May need git signature verification

### High Risk: Policy Bundle Availability
- **Enterprise Contract bundle location**: Need to verify correct OCI registry location
- **Authentication requirements**: May need registry credentials for policy bundle access
- **Version compatibility**: Need to ensure policy bundle version matches EC CLI version

## Monitoring and Validation

### Policy Evaluation Metrics
- **Policy evaluation success rate**: Track percentage of successful policy evaluations
- **Policy violation types**: Monitor most common policy violations
- **VSA generation success**: Track VSA generation and signing success rates

### SLSA Compliance Metrics
- **SLSA level achieved**: Track highest SLSA level achieved per artifact
- **Source track compliance**: Monitor source verification success rates
- **Build track compliance**: Monitor build isolation and provenance generation

---

**Recommendation**: Start with updating to real Enterprise Contract policies and test the workflow. Only create custom SLSA policy bundles if specific gaps are identified during testing.