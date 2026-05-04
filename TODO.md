# TODO

Outstanding work for the SLSA Konflux example project, organized by priority.

**Terminology Note:** "Conforma" refers to the policy engine tool. "EnterpriseContractPolicy (ECP)" refers to the Kubernetes CRD (legacy name not yet updated in APIs).

---

## Completed

- [x] Pin task bundles to digests (all managed-context task/pipeline references use `@sha256:` pins)
- [x] Pin release pipeline git references (commit SHA pinning in pipeline definitions)
- [x] Fix namespace mismatch (tenant/managed namespace references consistent)
- [x] Fix integration test branch reference
- [x] Pin container image references (base images in tasks use digest pins)
- [x] Add CI workflow (`.github/workflows/e2e-test.yaml`)
- [x] Add Renovate config (`renovate.json`)
- [x] Add consumer verification documentation
- [x] Add source track documentation
- [x] Add SLSA source verification policy (`slsa_source_verification/`)
- [x] Add policy enforcement demonstration (pass/fail scenarios)
- [x] Push task bundles to `quay.io/slsa-konflux-example` with version-timestamp tags
- [x] Push pipeline bundle to `quay.io/slsa-konflux-example` with digest pinning
- [x] Push acceptable-bundles data bundle
- [x] Deploy on Kind and validate end-to-end (Konflux operator + Helm charts)
- [x] Validate build pipeline (Tekton Chains signing, trivy scan, SAST)
- [x] Validate integration test (EC policy evaluation: 104 rules pass)
- [x] Validate release pipeline (verify-conforma, attach-vsa, push-snapshot — all succeed)
- [x] Pin build-definitions revision in integration test scenarios
- [x] Fix `rule_data` API usage in `slsa_source_verification.rego`
- [x] Move Rego test file out of EC policy compilation path
- [x] Surface trivy scan failures (remove error suppression)
- [x] Remove push-dockerfile task (not needed, auth issues on Kind)
- [x] Add `@minimal` collection for SBOM/CVE verification alongside `@slsa3`
- [x] Remove custom `sbom_required.rego` (redundant with upstream `sbom.found` in `@minimal`)
- [x] Migrate image references from `quay.io/arewm` to `quay.io/slsa-konflux-example`
- [x] Set `slsaSourceMinLevel: "1"` override in EC policy ruleData

---

## HIGH PRIORITY

### Open PR and Run CI

- [ ] Open PR from `deploy-validation` branch
- [ ] Verify the `validate` job passes (YAML lint, Helm rendering, digest checks)
- [ ] Trigger `e2e` workflow via `workflow_dispatch`
- [ ] Fix any CI failures

### Enable Renovate

- [ ] Enable the Renovate GitHub App on `arewm/slsa-konflux-example`
- [ ] Review and merge the onboarding PR
- [ ] Verify digest-pinned `quay.io` references are detected

### Operator Compatibility

- [ ] Document which Konflux versions have been tested (currently tested: operator from main)
- [ ] Investigate proper mechanism for custom pipeline configuration (currently using scale-down workaround for `build-pipeline-config`)
- [ ] Consider pinning Konflux operator to a specific commit SHA in CI

### Fix README Table of Contents

- [ ] Align ToC entries with actual section headers (`#slsa-source-track`, `#consumer-verification`, `#optional-slsa-tracks`)

---

## MEDIUM PRIORITY

### Source Track (SLSA Source Level 2+)

- [ ] **source-tool integration** — Use [source-tool](https://github.com/slsa-framework/source-tool) for source provenance verification (as demonstrated in the 1-2-step presentation)
- [ ] **Raise `slsaSourceMinLevel` to 2** once verify-source task supports verified history

### Build Track Documentation

- [ ] Document hermetic build configuration and network isolation
- [ ] Document vulnerability report retrieval (trivy and clair)
- [ ] Document builder image verification and builder identity in provenance

### Verification Track

- [ ] **Policy: Build Requirements** — verify SLSA Build L3 provenance, hermetic flag, builder identity
- [ ] **Policy: Security Scans** — vulnerability scan completion, severity thresholds
- [ ] **Policy: Dependency Verification** — dependency attestations, approved sources
- [ ] **Policy Exceptions** — volatileConfig examples, approval workflow, audit trail

### Demonstration Scenarios

- [ ] **CVE Scan Failure** — Use an image with known vulnerabilities to demonstrate trivy + EC blocking
- [ ] **Policy Exception (volatileConfig)** — Demonstrate build fails without exception, passes with
- [ ] **verify-source Enforcement** — Trigger build without verify-source, show policy failure

---

## LOW PRIORITY / FUTURE

### Additional SLSA Tracks

- [ ] BuildEnv attestation tasks (builder images, OS, toolchain)
- [ ] Dependency attestation tasks (resolved dependencies with provenance)
- [ ] VEX generation task
- [ ] Rekor transparency log integration (needs OIDC provider)
- [ ] gittuf integration for SLSA Source L3 (tamper resistance, retention)

### Documentation

- [ ] Create `docs/building-tasks-pipelines.md` (bundle versioning, pinning, hack/ scripts)
- [ ] Add expected outputs for all README commands
- [ ] Add troubleshooting sections for common errors
- [ ] Document version compatibility matrix

### Blog Post

- [ ] Draft SLSA E2E blog post for Konflux (modeled after Ampel post)
- [ ] Review with SLSA community
