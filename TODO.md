# TODO

This document tracks outstanding implementation tasks for the SLSA Konflux example project.

## Release Pipeline Modifications

### 1. Create Modified Release Pipeline for Trusted Artifacts
**Status**: Review needed
**Priority**: Critical

The upstream `push-to-external-registry` release pipeline has a hardcoded reference to `quay.io/konflux-ci/release-service-trusted-artifacts` for its trusted-artifacts push and pull operations. This needs to be modified to use a configurable location.

- **Issue**: Hardcoded trusted-artifacts location prevents using custom registries: https://github.com/konflux-ci/release-service-catalog/issues/1514
- **Location**: Create in `managed-context/pipelines/push-to-external-registry-custom/`
- **Base Source**: Fork from upstream release-service-catalog push-to-external-registry pipeline
- **Required Changes**:
  - Replace hardcoded `quay.io/konflux-ci/release-service-trusted-artifacts` references
  - Make trusted-artifacts registry location configurable via parameters
  - Ensure both push and pull operations use the same configurable location

**Implementation Details**:
```yaml
# Example parameter to add
params:
  - name: trustedArtifactsRegistry
    description: Registry location for trusted artifacts storage
    default: quay.io/konflux-ci/release-service-trusted-artifacts
    type: string
```

**Dependencies**:
- Understanding of current push-to-external-registry pipeline
- Access to release-service-catalog repository for reference
- Trusted artifacts registry setup and configuration

**Validation**:
- Pipeline should successfully push/pull trusted artifacts from custom registry
- Configuration should be overridable via ReleasePlanAdmission
- Backward compatibility with default registry location

---

## Pipeline Bundle Development

### 2. Create Custom Tekton Pipeline Bundle
**Status**: Review needed
**Priority**: High

Build a pipeline tekton bundle based on the upstream [docker-build-oci-ta pipeline](https://github.com/konflux-ci/build-definitions/tree/main/pipelines/docker-build-oci-ta) with the following modifications:

- **Base Content**: Start with the same task configuration as docker-build-oci-ta
- **Task Removal**: Remove unnecessary tasks that don't apply to our SLSA demonstration
- **Task Addition**: Include the new `verify-source` task for source verification
- **Location**: Create in `tenant-context/pipelines/docker-build-slsa-oci-ta/`

**Dependencies**:
- verify-source task implementation (see tenant-context/tasks/)
- Understanding of which upstream tasks are essential vs. optional

**Validation**:
- Pipeline should build successfully with sample applications
- verify-source task should execute and produce trust artifacts
- Bundle should be compatible with Konflux deployment

---

## Helm Chart for Configuration Management

### 3. Create Helm Chart for Build Services ConfigMap Patching
**Status**: Not Started
**Priority**: High

Develop a Helm chart that manages the build-services configuration:

- **ConfigMap Patching**: Update the build-services configmap with custom bundle references
- **Bundle Reference Replacement**: Replace references to:
  - `docker-build` → our custom SLSA-aware bundle
  - `docker-build-oci-ta` → our custom SLSA-aware bundle
- **Location**: Create in `resources/helm-charts/slsa-build-config/`

**Implementation Details**:
```yaml
# Expected ConfigMap structure to patch
apiVersion: v1
kind: ConfigMap
metadata:
  name: build-services
  namespace: build-service
data:
  pipelines: |
    # Replace these references with our custom bundle
    docker-build: <our-bundle-reference>
    docker-build-oci-ta: <our-bundle-reference>
```

**Dependencies**:
- Custom pipeline bundle from Task #2 must be built and published
- Understanding of current build-services configmap structure
- Helm chart testing infrastructure

**Validation**:
- ConfigMap should be successfully patched after helm install/upgrade
- New pipeline runs should use our custom bundle
- Rollback capability should restore original configuration

---

## Enterprise Contract Policy Updates

### 4. Update ECP to Require verify-source Task
**Status**: Review needed
**Priority**: Medium

Modify the Enterprise Contract Policy (ECP) to enforce the presence of the verify-source task:

- **Policy Location**: Update policies in `managed-context/policies/`
- **Requirement**: Add verify-source task to required tasks list
- **Enforcement**: Ensure builds fail policy evaluation without verify-source execution
- **Documentation**: Document the policy requirement and rationale

**Implementation Approach**:
```yaml
# Example policy rule (rego)
package slsa_build_requirements

deny[msg] {
  # Check that verify-source task was executed
  not has_verify_source_task(input.attestations)
  msg := "verify-source task is required but was not executed"
}
```

**Dependencies**:
- verify-source task must be implemented and producing attestations
- Understanding of current ECP rule structure
- Policy evaluation testing framework

**Validation**:
- Builds without verify-source should fail policy evaluation
- Builds with verify-source should pass (assuming no other violations)
- Policy violation messages should be clear and actionable

---

## Demonstration Scenarios

### 5. Demonstrate CVE Scan Failure
**Status**: Not Started
**Priority**: Medium

Create a demonstration showing security scanning in action:

- **Scenario**: Modify application content to introduce a known CVE
- **Location**: Create in `examples/cve-demonstration/`
- **Expected Outcome**: Build should complete but fail policy evaluation due to CVE detection
- **Documentation**: Document the introduced CVE and expected failure mode

**Implementation Steps**:
1. Identify a known vulnerable dependency or base image
2. Create a sample application that uses this vulnerable component
3. Configure pipeline to run security scanning
4. Verify that CVE is detected and reported
5. Document the failure in policy evaluation logs

**Success Criteria**:
- CVE is successfully detected during build process
- Policy evaluation fails with clear CVE-related message
- Demonstration is repeatable and well-documented

---

### 6. Demonstrate volatileConfig Exception
**Status**: Not Started
**Priority**: Medium

Create a demonstration of the volatileConfig exception mechanism:

- **Scenario**: Show how to grant exceptions for specific policy violations
- **Location**: Create in `examples/volatile-config-exception/`
- **Use Case**: Document legitimate scenarios where exceptions are needed
- **Implementation**: Show how to configure and apply volatileConfig

**Implementation Steps**:
1. Identify a suitable policy violation scenario (e.g., acceptable CVE with mitigation)
2. Create volatileConfig configuration to grant exception
3. Demonstrate that build fails without exception
4. Demonstrate that build passes with exception in place
5. Document security considerations and approval process

**Expected Configuration**:
```yaml
# Example volatileConfig exception
apiVersion: appstudio.redhat.com/v1alpha1
kind: VolatileConfig
metadata:
  name: cve-exception-example
spec:
  exceptions:
    - type: cve
      value: CVE-2024-XXXXX
      justification: "Vulnerability does not affect our usage pattern"
      expiresAt: "2025-12-31"
```

**Success Criteria**:
- Exception mechanism is clearly demonstrated
- Documentation includes security review process
- Example shows both granted exception and exception expiration

---

## Implementation Notes

### Sequencing
These tasks have dependencies and should be implemented in order:
1. Task #1 (Release Pipeline) - Critical foundation for trusted artifacts
2. Task #2 (Build Pipeline Bundle) - Foundation for build configuration
3. Task #3 (Helm Chart) - Enables automated deployment
4. Task #4 (ECP Updates) - Enforces security requirements
5. Tasks #5 & #6 (Demonstrations) - Validate complete workflow

### Testing Strategy
Each task should include:
- Unit testing where applicable
- Integration testing with sample applications
- Documentation of test procedures
- Rollback/recovery procedures

### Documentation Updates
As tasks are completed, update:
- README.md with new capabilities
- CLAUDE.md with implementation details
- Individual task/pipeline documentation
- User-facing guides for demonstrations
