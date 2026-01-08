# TODO

Outstanding work for the SLSA Konflux example project, organized by priority.

**Terminology Note:** "Conforma" refers to the policy engine tool. "EnterpriseContractPolicy (ECP)" refers to the Kubernetes CRD (legacy name not yet updated in APIs).

---

## CRITICAL PRIORITY

### Source Track Documentation (SLSA Source Level 3 with gittuf)

**Why Critical:** Largest missing piece for SLSA E2E submission. Required to demonstrate SLSA Source Track L3.

**Tasks:**
- [ ] **gittuf Installation & Setup**
  - Document gittuf installation on local machine
  - Initialize gittuf in source repository (festoji)
  - Configure GPG/signing keys for commit verification
  - Set up gittuf root of trust and metadata repository
  - Include troubleshooting for common setup issues
  - **Location:** README.md section at line 110 (currently "TODO: instructions")

- [ ] **gittuf Policy Configuration**
  - Define reference authorization policies (branch protection)
  - Set up required signatures/approvals
  - Configure who can commit to which branches
  - Example policies demonstrating git history verification
  - Document policy file structure and syntax

- [ ] **Source Attestation Documentation**
  - How gittuf generates source provenance
  - Commands to retrieve and inspect source attestations
  - Demonstrate verified git history
  - Link gittuf attestations to build inputs
  - Explain attestation format and verification

- [ ] **Source Setup Walkthrough**
  - Fork festoji repository instructions
  - Configure gittuf with security policies
  - Make compliant commit (follows policy)
  - Attempt non-compliant commit (violates policy)
  - Show how gittuf catches unauthorized changes

**Estimated Effort:** 1.5-2 days

---

### Build Track Documentation (SLSA Build Level 3)

**Why Critical:** Core demonstration of unforgeable build attestations. Multiple README placeholders block SLSA submission.

**Tasks:**
- [ ] **Build Provenance Examples**
  - Replace placeholder at README.md:189 with working commands
  - Complete `cosign download attestation` example with actual image reference
  - Display SLSA provenance structure (JSON output)
  - Explain key fields (builder, materials, metadata, invocation)
  - Demonstrate Tekton Chains signature verification
  - **Current:** `cosign download [...] | jq [...]`

- [ ] **SBOM Documentation**
  - Replace placeholder at README.md:194-196 with real commands
  - Download SBOM from OCI registry using cosign
  - Inspect SBOM contents (syft SPDX format)
  - Link SBOM attestation to build provenance
  - Verify SBOM signatures
  - **Current:** `[...]`

- [ ] **Hermetic Build Configuration**
  - Complete section at README.md:225
  - Enable hermetic builds in Tekton pipeline
  - Document network isolation configuration
  - Demonstrate reproducible builds
  - Document dependency prefetching setup
  - Show hermetic flag in SLSA provenance
  - **Current:** "TODO: change to hermetic with more accurate SBOM"

- [ ] **Vulnerability Scanning Documentation**
  - Document clair-scan results in build provenance
  - Show clamAV malware scan attestations
  - Explain how scan results link to artifacts
  - Provide vulnerability data format examples
  - Show how to query scan results from attestations

- [ ] **Build Environment Attestations**
  - Document builder image verification
  - Verify builder identity in provenance
  - Explain builder attestation format
  - Link to Tekton Chains configuration

**Estimated Effort:** 1 day

---

### Verification Track Documentation (Conforma Policy Engine)

**Why Critical:** Demonstrates "Step 2: ENFORCE" - the policy-as-code gates that are central to the SLSA story.

**Tasks:**
- [ ] **Policy Language & Structure**
  - Complete section at README.md:219-221
  - Explain Conforma policy language and structure
  - Show how policies consume attestations
  - Document available policy predicates and functions
  - Provide policy template examples with annotations
  - Link to Conforma documentation
  - **Current:** "TODO: Talk more about what Conforma can consume..."

- [ ] **Example Policy: Source Verification**
  - Verify gittuf attestation exists
  - Check source from approved repository
  - Verify required signatures on commits
  - Block unsigned commits
  - Show policy failure messages
  - **Location:** Create in managed-context/policies/

- [ ] **Example Policy: Build Requirements**
  - Verify SLSA Build L3 provenance is present
  - Check hermetic build flag is set
  - Verify builder identity matches approved builders
  - Ensure reproducible build configuration
  - Show enforcement in release pipeline logs

- [ ] **Example Policy: Security Scans**
  - Require vulnerability scan completion
  - Block critical vulnerabilities (define severity thresholds)
  - Require SBOM presence and validate completeness
  - Validate scan attestation signatures
  - Document exception workflow integration

- [ ] **Example Policy: Dependency Verification**
  - Verify all dependencies have attestations
  - Check dependency sources are approved
  - Validate dependency VSAs
  - Block unknown or untrusted dependencies
  - Show transitive dependency verification

- [ ] **Policy Enforcement Examples**
  - Show policy blocking non-compliant build (with logs)
  - Document release pipeline failure scenario
  - Show policy success allowing compliant build
  - VSA generation after policy pass
  - Explain policy evaluation logs and debugging
  - Replace placeholder at README.md:213 (`kubectl get [...]`)

- [ ] **Policy Exceptions**
  - Complete section at README.md:229
  - Create policy exceptions in Conforma
  - Example: accepting known vulnerability with justification
  - Exception approval workflow
  - Exception attestation format
  - Exception audit trail and expiration
  - **Current:** "TODO: introduce vulnerability, have policy exception"

**Estimated Effort:** 1.5-2 days

---

### Publication & Consumption Track Documentation

**Why Critical:** Required to demonstrate complete SLSA end-to-end flow for artifact consumers.

**Tasks:**
- [ ] **VSA Generation Documentation**
  - How Conforma generates Verification Summary Attestations
  - VSA structure and required fields
  - Verification results included in VSA
  - Link to release pipeline VSA generation step
  - VSA signature verification process
  - VSA subject and policy metadata

- [ ] **VSA Publication Documentation**
  - Where VSAs are stored (OCI registry, Rekor transparency log)
  - Commands to retrieve VSAs for published artifacts
  - VSA availability and discoverability for consumers
  - VSA metadata structure

- [ ] **End-to-End Consumer Walkthrough**
  - Download artifacts from registry (consumer perspective)
  - Discover and download all attestations
  - Verify VSA before using artifact
  - slsa-verifier usage examples
  - Show how to prevent use of unverified artifacts

- [ ] **Attestation Bundle Retrieval**
  - Commands to download complete attestation set for an artifact
  - Attestation bundle structure
  - Signature chain verification
  - Transparency log integration (Rekor)
  - Verify complete attestation coverage

**Estimated Effort:** 0.5 day

---

### Documentation Completeness

**Why Critical:** Table of contents and removing placeholders are required for SLSA submission.

**Tasks:**
- [ ] **Complete Table of Contents** (README.md:16)
  - Map sections to SLSA tracks (Source, Build, Verification, Publication, Consumption)
  - Create clear navigation structure
  - Link to all subsections
  - Ensure ToC reflects complete documentation

- [ ] **Add Expected Outputs**
  - Include example output for all commands throughout README
  - Show both success and failure scenarios
  - Add troubleshooting sections for common errors
  - Document error messages and resolutions
  - Include timing information where relevant

- [ ] **Complete Additional References** (README.md:236-238)
  - Add relevant documentation links
  - Link to controller documentation (build-service, integration-service, release-service)
  - Add gittuf resources and guides
  - Link to Conforma documentation and policy examples
  - Add SLSA specification references (Source, Build, VSA specs)
  - Remove or populate empty sections (Documentation, Recordings, Controllers)

**Estimated Effort:** 0.5 day

---

## HIGH PRIORITY

### Release Pipeline for Custom Registries

**Why High:** Blocks ability to use custom registries for trusted artifacts storage. Referenced by upstream issue.

**Issue:** Hardcoded trusted-artifacts location prevents using custom registries: https://github.com/konflux-ci/release-service-catalog/issues/1514

**Tasks:**
- [ ] Create modified release pipeline
  - **Location:** Create in `managed-context/pipelines/push-to-external-registry-custom/`
  - **Base Source:** Fork from upstream release-service-catalog push-to-external-registry pipeline
- [ ] Make trusted-artifacts registry configurable
  - Replace hardcoded `quay.io/konflux-ci/release-service-trusted-artifacts` references
  - Add parameter for trusted-artifacts registry location
  - Ensure both push and pull operations use configurable location
  - Default to upstream location for backward compatibility
- [ ] Validate implementation
  - Test push/pull of trusted artifacts from custom registry
  - Verify configuration is overridable via ReleasePlanAdmission
  - Ensure backward compatibility with default registry

**Example Implementation:**
```yaml
params:
  - name: trustedArtifactsRegistry
    description: Registry location for trusted artifacts storage
    default: quay.io/konflux-ci/release-service-trusted-artifacts
    type: string
```

**Dependencies:**
- Understanding of current push-to-external-registry pipeline
- Access to release-service-catalog repository for reference
- Trusted artifacts registry setup and configuration

---

### Migrate Custom Artifacts to Official Namespace

**Why High:** Current references to `quay.io/arewm/*` are personal and not sustainable for community example.

**Current Personal References:**
- `quay.io/arewm/task-trivy-sbom-scan:0.1` (managed-context/slsa-e2e-pipeline/slsa-e2e-pipeline.yaml:340)
- `quay.io/arewm/pipeline-slsa-e2e-oci-ta:*` (admin/values.yaml, pipeline-bundle-list)

**Tasks:**
- [ ] Decide on target namespace for custom artifacts
  - Option A: Contribute trivy-sbom-scan to konflux-ci/build-definitions
  - Option B: Create dedicated namespace for SLSA example artifacts
  - Option C: Publish to separate organization

- [ ] Create CI/CD automation for building bundles
  - Automate pipeline bundle builds
  - Automate task bundle builds
  - Version tagging strategy

- [ ] Update all references
  - Pipeline definitions
  - Helm chart values (admin/values.yaml)
  - Documentation and README
  - Build scripts (hack/build-and-push.sh)

- [ ] Test with new references
  - Deploy and verify pipeline execution
  - Ensure all custom tasks work
  - Update docs with new locations

**Success Criteria:**
- No references to `quay.io/arewm/*` in codebase
- All bundles published to official/sustainable namespace
- Documentation updated with new references
- CI/CD in place for future updates

---

## MEDIUM PRIORITY

### Update Conforma Policy to Require verify-source Task

**Why Medium:** Enforces source verification in policy, but verify-source task must be implemented first.

**Tasks:**
- [ ] Implement policy rule requiring verify-source task
  - **Policy Location:** Update policies in `managed-context/policies/`
  - Add verify-source task to required tasks list
  - Ensure builds fail policy evaluation without verify-source execution

**Example Policy Rule (Rego):**
```yaml
package slsa_build_requirements

deny[msg] {
  # Check that verify-source task was executed
  not has_verify_source_task(input.attestations)
  msg := "verify-source task is required but was not executed"
}
```

**Dependencies:**
- verify-source task must be implemented and producing attestations
- Understanding of current Conforma/ECP rule structure
- Policy evaluation testing framework

**Validation:**
- Builds without verify-source should fail policy evaluation
- Builds with verify-source should pass (assuming no other violations)
- Policy violation messages should be clear and actionable

---

### Demonstration Scenarios

**Why Medium:** Useful for presentations and understanding real-world usage, but not blocking SLSA submission.

#### Scenario 1: CVE Scan Failure Demonstration

**Purpose:** Show security scanning in action with policy enforcement.

**Tasks:**
- [ ] Identify known vulnerable dependency or base image
- [ ] Create sample application using vulnerable component
- [ ] Configure pipeline to run security scanning
- [ ] Verify CVE is detected and reported in attestations
- [ ] Show policy evaluation failure with clear CVE-related message
- [ ] Document the demonstration in `examples/cve-demonstration/`

**Success Criteria:**
- CVE is successfully detected during build process
- Policy evaluation fails with actionable message
- Demonstration is repeatable and well-documented

#### Scenario 2: Policy Exception (volatileConfig) Demonstration

**Purpose:** Show how to handle legitimate policy exceptions with proper justification and audit trail.

**Tasks:**
- [ ] Identify suitable policy violation scenario (e.g., acceptable CVE with mitigation)
- [ ] Create volatileConfig configuration to grant exception
- [ ] Demonstrate build fails without exception
- [ ] Demonstrate build passes with exception in place
- [ ] Document security considerations and approval process
- [ ] Show exception expiration handling
- [ ] Document in `examples/volatile-config-exception/`

**Example Configuration:**
```yaml
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

**Success Criteria:**
- Exception mechanism is clearly demonstrated
- Documentation includes security review process
- Example shows both granted exception and exception expiration

---

## LOW PRIORITY

### Documentation for Custom Task/Pipeline Development

**Why Low:** Only needed for advanced users who want to extend the example.

**Tasks:**
- [ ] Create docs/building-tasks-pipelines.md
- [ ] Document hack/build-and-push.sh usage
  - How to build custom task bundles
  - How to build custom pipeline bundles
  - Testing locally before pushing
- [ ] Explain bundle versioning and pinning strategy
  - When to use :latest vs semantic versions
  - Immutable references for production
- [ ] Document testing workflow
  - Build → push → update pipeline → test cycle
  - Local testing with tkn
  - Debugging failed tasks
- [ ] Include troubleshooting for common issues
  - Bundle push failures
  - Task resolution errors
  - Pipeline parameter mismatches
- [ ] Add reference from README Additional References section

**Location:** Link from README.md:234

---

## BLOCKED

### Remove build-image-index Workaround

**Why Blocked:** Waiting on upstream PR to merge CA trust support.

**Current State:**
- Using patched version: `quay.io/arewm/task-build-image-index@sha256:17ed551...`
- **Location:** managed-context/slsa-e2e-pipeline/slsa-e2e-pipeline.yaml:284
- **Reason:** Upstream task doesn't install mounted CA certificates needed for KinD registry

**Blocking Issue:** https://github.com/konflux-ci/build-definitions/pull/2965

**Tasks (when unblocked):**
- [ ] Monitor PR #2965 for merge
- [ ] Update pipeline to use upstream task reference
- [ ] Remove comment: "Change back to this once the task supports mounting certs"
- [ ] Test with KinD registry to ensure CA trust still works
- [ ] Remove custom task image from quay.io/arewm

---

## Implementation Sequencing

**Recommended Order:**
1. **Week 1:** CRITICAL - Source Track (gittuf) + Build Track documentation
2. **Week 2:** CRITICAL - Verification Track (Conforma policies) + VSA/Consumer docs
3. **Week 3:** HIGH - Release pipeline modifications + namespace migration
4. **Week 4:** MEDIUM - verify-source policy + demo scenarios
5. **Ongoing:** LOW - Custom task/pipeline docs
6. **When unblocked:** Remove build-image-index workaround

**For SLSA E2E Submission (Critical Path):**
Source (gittuf) → Build examples → Conforma policies → VSA → Consumer guide → Table of Contents

**Total Estimated Effort:**
- CRITICAL items: 5-6 days focused work
- HIGH items: 2-3 days
- MEDIUM items: 1-2 days
- LOW items: 0.5-1 day
- **Total:** ~9-12 days for complete implementation
