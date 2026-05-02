# TODO

Outstanding work for the SLSA Konflux example project, organized by priority.

**Terminology Note:** "Conforma" refers to the policy engine tool. "EnterpriseContractPolicy (ECP)" refers to the Kubernetes CRD (legacy name not yet updated in APIs).

---

## Recently Completed

- [x] Pin task bundles to digests (all managed-context task/pipeline references use `@sha256:` pins)
- [x] Pin release pipeline git references (commit SHA pinning in pipeline definitions)
- [x] Fix namespace mismatch (tenant/managed namespace references consistent)
- [x] Fix integration test branch reference
- [x] Pin container image references (base images in tasks use digest pins)
- [x] Add CI workflow (`.github/workflows/e2e-test.yaml` — YAML validation, Helm rendering, digest checks, full e2e)
- [x] Add Renovate config (`renovate.json` — regex manager for `quay.io` digest pins, monthly schedule)
- [x] Add consumer verification documentation (README section, ToC entry)
- [x] Add source track documentation (README section, integration test explanation)
- [x] Add SLSA source verification policy (`managed-context/policies/ec-policy-data/policy/custom/slsa_source_verification/`)
- [x] Add policy enforcement demonstration (README Scenario 1/2: pass and fail demos)

---

## CRITICAL PRIORITY

### Push Bundles and Validate End-to-End

**Why Critical:** The repository references `quay.io/slsa-konflux-example/*` images that may not exist yet. Without these, neither the CI workflow nor a manual deployment will work.

**Tasks:**
- [ ] **Push task bundles to quay.io/slsa-konflux-example**
  - Build and push `task-trivy-sbom-scan:0.1` bundle
  - Build and push any other custom task bundles
  - Record the `@sha256:` digests and update references in managed-context YAML
- [ ] **Push pipeline bundle to quay.io/slsa-konflux-example**
  - Build and push `pipeline-slsa-e2e-oci-ta` bundle
  - Update `.github/workflows/e2e-test.yaml` (line 161) with the real digest
  - Update `admin/values.yaml` and any other pipeline-bundle-list references
- [ ] **Deploy on Kind and validate end-to-end**
  - Run `./scripts/deploy-local.sh` with Konflux v0.4
  - Run `./scripts/setup-prerequisites.sh`
  - Install platform + component Helm charts
  - Trigger a build, verify Chains signing, trigger a release
  - Confirm VSA generation completes successfully
- [ ] **Enable Renovate on the GitHub repository**
  - Enable the Renovate GitHub App on the `arewm/slsa-konflux-example` repo
  - Verify the initial onboarding PR is generated correctly
  - Merge the onboarding PR

### Verify Operator Compatibility

**Why Critical:** The Konflux operator evolves rapidly; scripts and CRDs may break across versions.

**Tasks:**
- [ ] **Test with Konflux v0.4**
  - Verify `scripts/setup-prerequisites.sh` works (especially `patch-pipeline-config.sh`)
  - Confirm all CRD API versions are still valid (Application, Component, IntegrationTestScenario, ReleasePlanAdmission, EnterpriseContractPolicy)
  - Check if `OPERATOR_INSTALL_METHOD=release` still works in CI
- [ ] **Pin Konflux operator version**
  - The e2e workflow pins `KONFLUX_VERSION: "v0.4"` — verify this tag remains stable
  - Consider pinning to a specific commit SHA instead of a tag for reproducibility
- [ ] **Document version compatibility matrix**
  - Record which Konflux versions have been tested
  - Note any breaking changes or required workarounds

---

## HIGH PRIORITY

### Migrate Custom Artifacts to Official Namespace

**Why High:** Current references to `quay.io/arewm/*` are personal and not sustainable for a community example.

**Current Personal References:**
- `quay.io/arewm/task-trivy-sbom-scan:0.1` (managed-context/slsa-e2e-pipeline/slsa-e2e-pipeline.yaml:340)
- `quay.io/arewm/pipeline-slsa-e2e-oci-ta:*` (admin/values.yaml, pipeline-bundle-list)

**Tasks:**
- [ ] Decide on target namespace for custom artifacts
  - Option A: Contribute trivy-sbom-scan to konflux-ci/build-definitions
  - Option B: Create dedicated namespace for SLSA example artifacts (current: `quay.io/slsa-konflux-example`)
  - Option C: Publish to separate organization
- [ ] Create CI/CD automation for building bundles
- [ ] Update all references and test with new references

**Success Criteria:**
- No references to `quay.io/arewm/*` in codebase
- All bundles published to official/sustainable namespace
- CI/CD in place for future updates

### Fix README Table of Contents

**Why High:** The ToC references `#slsa-source-track` and `#consumer-verification` sections that do not exist as headers. Either add those sections or remove the ToC entries.

**Tasks:**
- [ ] Add `## SLSA Source Track` section or remove ToC entry (line 40)
- [ ] Add `## Consumer Verification` section or remove ToC entry (line 41)
- [ ] Add `## Optional SLSA Tracks` section or remove ToC entry (line 42)

---

## MEDIUM PRIORITY

### Source Track Documentation (SLSA Source Level 3 with gittuf)

**Why Medium:** Important for SLSA E2E completeness but gittuf integration is forward-looking.

**Tasks:**
- [ ] **gittuf Installation & Setup**
  - Document gittuf installation on local machine
  - Initialize gittuf in source repository (festoji)
  - Configure GPG/signing keys for commit verification
  - Set up gittuf root of trust and metadata repository

- [ ] **gittuf Policy Configuration**
  - Define reference authorization policies (branch protection)
  - Set up required signatures/approvals
  - Document policy file structure and syntax

- [ ] **Source Attestation Documentation**
  - How gittuf generates source provenance
  - Commands to retrieve and inspect source attestations
  - Link gittuf attestations to build inputs

- [ ] **Source Setup Walkthrough**
  - Fork festoji repository instructions
  - Configure gittuf with security policies
  - Demonstrate compliant vs. non-compliant commits

### Build Track Documentation (SLSA Build Level 3)

**Tasks:**
- [ ] **Hermetic Build Configuration**
  - Enable hermetic builds in Tekton pipeline
  - Document network isolation configuration and dependency prefetching

- [ ] **Vulnerability Scanning Documentation**
  - Document how to download Trivy and Clair vulnerability reports
  - Show how scan results link to artifacts

- [ ] **Build Environment Attestations**
  - Document builder image verification
  - Verify builder identity in provenance

### Verification Track Documentation

**Tasks:**
- [x] **Example Policy: Source Verification** (completed: `slsa_source_verification/`)
- [ ] **Example Policy: SBOM Required** (in progress: `sbom_required/`)
- [ ] **Example Policy: Build Requirements** (verify SLSA Build L3 provenance, hermetic flag, builder identity)
- [ ] **Example Policy: Security Scans** (vulnerability scan completion, severity thresholds)
- [ ] **Example Policy: Dependency Verification** (dependency attestations, approved sources)
- [ ] **Policy Enforcement Examples** (blocking/passing logs, VSA generation)
- [ ] **Policy Exceptions** (volatileConfig examples, approval workflow, audit trail)

### Demonstration Scenarios

#### Scenario 1: CVE Scan Failure Demonstration
- [ ] Identify known vulnerable dependency or base image
- [ ] Configure pipeline to run security scanning
- [ ] Document the demonstration

#### Scenario 2: Policy Exception (volatileConfig) Demonstration
- [ ] Create volatileConfig configuration to grant exception
- [ ] Demonstrate build fails without exception, passes with
- [ ] Document security considerations

#### Scenario 3: verify-source Policy Enforcement Demonstration
- [ ] Trigger a build without verify-source task
- [ ] Show policy evaluation failure in release pipeline
- [ ] Capture and document the specific error message

---

## LOW PRIORITY / FUTURE

### Additional SLSA Tracks (Incremental)

- [ ] **BuildEnv attestation tasks** — Attest to the build environment (builder images, OS, toolchain)
- [ ] **Dependency attestation tasks** — Attest to resolved dependencies with provenance
- [ ] **VEX generation task** — Generate Vulnerability Exploitability eXchange documents
- [ ] **Rekor transparency log integration** — Publish attestations to Rekor (needs OIDC provider)
- [ ] **Integrate gittuf for SLSA Source L3** — End-to-end gittuf policy enforcement

### Documentation for Custom Task/Pipeline Development

- [ ] Create docs/building-tasks-pipelines.md
- [ ] Document hack/build-and-push.sh usage
- [ ] Explain bundle versioning and pinning strategy
- [ ] Document testing workflow (build → push → update → test cycle)
- [ ] Include troubleshooting for common issues

### Documentation Completeness

- [ ] Add expected outputs for all commands throughout README
- [ ] Complete additional references (controller docs, gittuf, Conforma, SLSA spec links)
- [ ] Add troubleshooting sections for common errors
