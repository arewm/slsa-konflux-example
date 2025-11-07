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

## Helm Chart for Configuration Management

### 2. Create Helm Chart for Build Services ConfigMap Patching
**Status**: ✅ **COMPLETED**
**Priority**: High

~~Develop~~ **Implemented** a Helm chart that manages the build-services configuration:

- ✅ **ConfigMap Patching**: Updates the build-services configmap with custom bundle references
- ✅ **Bundle Reference Replacement**: Replaces references with custom `slsa-e2e-oci-ta` pipeline bundle
- ✅ **Location**: Implemented in `admin/` directory

**Implementation Complete**:
```yaml
# Implemented ConfigMap in admin/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: build-pipeline-config
  namespace: build-service
data:
  config.yaml: |
    default-pipeline-name: slsa-e2e-oci-ta
    pipelines:
    - name: slsa-e2e-oci-ta
      bundle: quay.io/arewm/pipeline-slsa-e2e-oci-ta:latest
```

**Usage** (documented in README.md:89-96):
```bash
# Delete any existing non-Helm managed ConfigMap
kubectl delete configmap build-pipeline-config -n build-service

# Install the build configuration via Helm
helm install build-config ./admin
```

**Features Delivered**:
- ✅ Comprehensive README documentation (admin/README.md)
- ✅ Flexible configuration via values.yaml
- ✅ Support for multiple pipeline overrides
- ✅ Full config override capability
- ✅ Rollback support via Helm
- ✅ Security considerations documented

---

## Enterprise Contract Policy Updates

### 2. Update ECP to Require verify-source Task
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

## Workarounds and Temporary Solutions

### 3. Remove build-image-index Workaround
**Status**: Blocked - Waiting on upstream PR
**Priority**: Medium
**Blocking**: [PR #2965](https://github.com/konflux-ci/build-definitions/pull/2965)

Currently using a patched version of build-image-index task to support CA trust in KinD environments:

- **Current Reference**: `quay.io/arewm/task-build-image-index@sha256:17ed551...`
- **Location**: `managed-context/slsa-e2e-pipeline/slsa-e2e-pipeline.yaml:284`
- **Reason**: Upstream task doesn't install mounted CA certificates

**Required Actions**:
1. Monitor PR #2965 for merge
2. Once merged, update pipeline to use upstream task reference
3. Remove comment: "Change back to this once the task supports mounting certs"
4. Test with KinD registry to ensure CA trust still works

---

### 4. Migrate Custom Tasks to Official Namespace
**Status**: Not Started
**Priority**: High

Several custom tasks and bundles are currently in the `arewm` namespace and need to be migrated:

**Task Bundles**:
- `quay.io/arewm/task-trivy-sbom-scan:0.1` (managed-context/slsa-e2e-pipeline/slsa-e2e-pipeline.yaml:340)
- Decision needed: Contribute to konflux-ci/build-definitions or maintain separately?

**Pipeline Bundles**:
- `quay.io/arewm/pipeline-slsa-e2e-oci-ta:*`
- Referenced in: admin/values.yaml, pipeline-bundle-list
- Needs migration to official namespace

**Implementation Steps**:
1. Decide on target namespace for custom artifacts
2. Create CI/CD automation for building bundles
3. Update all references in:
   - Pipeline definitions
   - Helm chart values
   - Documentation
   - Build scripts (hack/build-and-push.sh)
4. Consider contributing trivy-sbom-scan upstream to build-definitions

**Success Criteria**:
- No references to `quay.io/arewm/*` in codebase
- All bundles published to official namespace
- Documentation updated with new references

---

### 5. Add Documentation for Custom Task/Pipeline Development
**Status**: Not Started
**Priority**: Low

Users may want to build and test custom tasks/pipelines locally:

**Required Documentation**:
- Link to or create docs/building-tasks-pipelines.md
- Document hack/build-and-push.sh usage
- Explain bundle versioning and pinning strategy
- Document testing workflow (build → push → update pipeline → test)
- Include troubleshooting for common issues

**Reference from README**:
Add a section in README.md pointing to this documentation for advanced users

---

## Demonstration Scenarios

### 6. Demonstrate CVE Scan Failure
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

### 7. Demonstrate volatileConfig Exception
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
2. ~~Task #2 (Build Pipeline Bundle)~~ - ✅ COMPLETED
3. ~~Task #3 (Helm Chart)~~ - ✅ COMPLETED
4. Task #3 (Remove build-image-index Workaround) - Blocked on upstream PR
5. Task #4 (Migrate to Official Namespace) - High priority
6. Task #2 (ECP Updates) - Enforces security requirements
7. Tasks #6 & #7 (Demonstrations) - Validate complete workflow

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
