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
- [x] Multi-component support (component-onboarding chart supports per-app EC policies)
- [x] Source Track L3 demo (source-test-repo with source-tool enrollment)
- [x] CVE management demo (leeway mechanism, per-CVE exceptions, volatile config)
- [x] Per-application Enterprise Contract policies (different source levels per component)
- [x] Restructure docs into Part 1 (Build L3, Festoji) and Part 2 (Source L3, CVE, hermetic)
- [x] Move TRUSTING_ARTIFACTS.md to docs/ with Build L3 connection
- [x] Blog post Part 2 content (source track, CVE management, hermetic builds)
- [x] Document hermetic build configuration with prefetch-dependencies
- [x] Validate hermetic build end-to-end on Kind cluster (SLSA_BUILD_LEVEL_3 confirmed)
- [x] Add `excludeRules` support to component-onboarding chart template
- [x] Add `volatileConfig` support to component-onboarding chart template
- [x] Add hermetic build annotation support to Component template (`buildPipeline` field)
- [x] Investigate proper mechanism for custom pipeline configuration (issue #6673, PR #6678 adds operator-level `pipelineConfig`)

---

## HIGH PRIORITY

### Open PR and Run CI

- [ ] Open PR from current branch
- [ ] Verify the `validate` job passes (YAML lint, Helm rendering, digest checks)
- [ ] Trigger `e2e` workflow via `workflow_dispatch`
- [ ] Fix any CI failures

### Enable Renovate

- [ ] Enable the Renovate GitHub App on `arewm/slsa-konflux-example`
- [ ] Review and merge the onboarding PR
- [ ] Verify digest-pinned `quay.io` references are detected

### Operator Compatibility

- [ ] Document which Konflux versions have been tested (currently tested: v0.2.1-rc.1)
- [ ] Test PR #6678 for operator-level pipeline customization (replaces `buildPipeline` annotation workaround)

---

## MEDIUM PRIORITY

### Build Track Documentation

- [ ] Document vulnerability report retrieval (trivy and clair)
- [ ] Document builder image verification and builder identity in provenance

---

## LOW PRIORITY / FUTURE

These are described in the blog post's "Future Directions" section as possibilities, not planned implementation work for this repository.

- [ ] BuildEnv attestation tasks (builder images, OS, toolchain)
- [ ] Dependency levels in VSA (base image provenance verification — release signature works, provenance needs investigation)
- [ ] VEX integration (requires upstream changes to preserve excluded CVE results in EC report)
- [ ] Rekor transparency log integration (needs OIDC provider)

### Documentation

- [ ] Create `docs/building-tasks-pipelines.md` (bundle versioning, pinning, hack/ scripts)
- [ ] Add expected outputs for all doc commands
- [ ] Document version compatibility matrix

### Blog Post

- [ ] Review blog draft with SLSA community
- [ ] Finalize and submit
