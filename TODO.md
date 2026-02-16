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

---

### Build Track Documentation (SLSA Build Level 3)

**Why Critical:** Core demonstration of unforgeable build attestations. README placeholder blocks SLSA submission.

**Tasks:**
- [ ] **Hermetic Build Configuration**
  - Enable hermetic builds in Tekton pipeline
  - Document network isolation configuration
  - Demonstrate reproducible builds
  - Document dependency prefetching setup
  - Show hermetic flag in SLSA provenance

- [ ] **Vulnerability Scanning Documentation**
  - Document how to download Trivy and Clair vulnerability reports
  - Show how to interpret scan results
  - Explain vulnerability data format
  - Show how scan results link to artifacts
  - Demonstrate querying scan results from attestations

- [ ] **Build Environment Attestations**
  - Document builder image verification
  - Verify builder identity in provenance
  - Explain builder attestation format
  - Link to Tekton Chains configuration

---

### Verification Track Documentation (Conforma Policy Engine)

**Why Critical:** Demonstrates "Step 2: ENFORCE" - the policy-as-code gates that are central to the SLSA story.

**Tasks:**
- [ ] **Policy Language & Structure**
  - Explain Conforma policy language and structure
  - Show how policies consume attestations
  - Document available policy predicates and functions
  - Provide policy template examples with annotations
  - Link to Conforma documentation

- [x] **Example Policy: Source Verification**
  - Verify gittuf attestation exists
  - Check source from approved repository
  - Verify required signatures on commits
  - Block unsigned commits
  - Show policy failure messages
  - **Location:** managed-context/policies/ec-policy-data/policy/custom/slsa_source_verification/

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

- [ ] **Policy Exceptions**
  - Create policy exceptions in Conforma
  - Example: accepting known vulnerability with justification
  - Exception approval workflow
  - Exception attestation format
  - Exception audit trail and expiration

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

---

### Documentation Completeness

**Why Critical:** Table of contents and removing placeholders are required for SLSA submission.

**Tasks:**
- [ ] **Complete Table of Contents**
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

- [ ] **Complete Additional References**
  - Add relevant documentation links
  - Link to controller documentation (build-service, integration-service, release-service)
  - Add gittuf resources and guides
  - Link to Conforma documentation and policy examples
  - Add SLSA specification references (Source, Build, VSA specs)
  - Remove or populate empty sections (Documentation, Recordings, Controllers)

---

## HIGH PRIORITY

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

#### Scenario 3: verify-source Policy Enforcement Demonstration

**Purpose:** Demonstrate that Conforma policy enforcement actually catches missing required tasks.

**Current State:**
- Policy declares verify-source as required (managed-context/policies/ec-policy-data/data/required_tasks.yml)
- Build pipelines do not currently run verify-source task
- Need to show what happens during policy evaluation

**Tasks:**
- [ ] Trigger a build without verify-source task
- [ ] Show policy evaluation failure in release pipeline
- [ ] Document the specific error message from Conforma
- [ ] Capture logs showing the policy violation
- [ ] Document in README or examples/policy-enforcement-demonstration/

**Success Criteria:**
- Clear demonstration that policy catches missing verify-source
- Error message is actionable and clear
- Documentation shows the enforcement mechanism in action

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
