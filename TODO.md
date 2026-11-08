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
- [x] Kyverno admission policy chart (`charts/admission-policy/`) with bundle signature checking
- [x] SPIFFE/SPIRE workload identity chart (`charts/spiffe-spire/`) with Fulcio OIDC integration
- [x] PipelineRun-scoped release dual-gating (Model 2) with `attach-summary-attestations` and keyless Rekor signing
- [x] Multi-arch upstream Zot registry with OIDC Bearer push gating
- [x] Secretless mock CVE database service with SPIRE JWKS verification
- [x] Separation of duties Rego policy enforcement (`demo/manifests/separation_of_duties.rego`)
- [x] Interactive 4-act live demonstration script (`demo/run-demo.sh`) and slide server (`demo/serve-slides.sh`)
- [x] Workload identity documentation and taxonomy (`docs/reference/workload-identity-patterns.md`)

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

- [x] Document which Konflux versions have been tested (currently tested: v0.2.2)
- [ ] Test PR #6678 for operator-level pipeline customization (replaces `buildPipeline` annotation workaround)

---

## MEDIUM PRIORITY

### Build Track Documentation

- [ ] Document vulnerability report retrieval (trivy and clair)
- [ ] Document builder image verification and builder identity in provenance

---

## LOW PRIORITY / FUTURE

These are described in the blog post's "Future Directions" section as possibilities, not planned implementation work for this repository.

### Workload Identity Extensions (from KubeCon NA 2026 talk)

- [x] Vault-style token exchange for legacy services (Pattern 2 extension): deploy Vault with JWT auth backed by SPIRE's OIDC discovery endpoint, bind release of a static credential to specific SPIFFE IDs (sub claim), and demo a task exchanging its JWT-SVID for the credential — covers services without OIDC support (e.g. Pulp content repositories behind static API tokens). Implemented: charts/vault-legacy-exchange + demo/vault-exchange-demo.sh — see docs/reference/legacy-token-exchange.md

### Release Boundary Hardening (post-KubeCon design discussions)

- [x] Protect pipeline/task classification labels with fail-closed admission rules (partition labels by legitimate setter):
  - `tekton.dev/*` labels (pipeline, pipelineTask, pipelineRun): creator-guard via `guard-task-labels` — may only be newly set/changed by the tekton-pipelines controller SA (change-detection so annotation/status patches by other controllers are unaffected)
  - Managed markers (`pipelines.appstudio.openshift.io/type: managed`, `appstudio.openshift.io/service: release`): creator-guard via `guard-managed-labels` — only the release-service controller SA may transition them to their protected values on PipelineRuns; spec-path laundering is structurally closed (Tekton v1 podTemplates have no labels field) except `taskRunSpecs[*].metadata.labels`, which is denied regardless of creator
  - `trusted-task-role` / `trusted-pipeline-role`: validated by recomputing classification conditions in `validate-role-labels` (fail-closed) — prod requires a digest-pinned trusted-pattern bundle; release-authority requires managed namespace + Tekton-propagated managed marker + `tekton.dev/pipelineRun` label equal to the PipelineRun ownerReference (unforgeable via guard-task-labels); `classify-taskrun`'s set-dev mutate no longer overwrites hand-set labels so the validator sees them (mutate-normalizes / validate-enforces split documented in the policy)
- [ ] Run-scoped release identities: extend ClusterSPIFFEID templates with the pod's `tekton.dev/pipelineRun` label so the SVID path embeds the PipelineRun UID. Two new least-privilege identities: a policy-writer SVID for `verify-conforma` (may write, not read) and the signer SVID for `attach-summary-attestations` (may read, not write). Zot is unaffected — its allow-list continues to match the non-run-scoped builder/release IDs
- [ ] Policy-gated release signing (path-scoped capabilities, stronger against rogue-pipeline and stolen-token replay than any bearer-token form):
  - Move the release signing key out of the namespace Secret (ambient, RBAC-readable) into Vault
  - On policy PASS, `verify-conforma` writes a short-lived signing capability to `secret/release/<own-plr-uid>/<image-digest>` (authenticated by its run-scoped policy-writer SVID)
  - The signer reads it via its run-scoped SVID — Vault templated policies scope each identity to its own run's path, so cross-run replay and cleared-for-X-sign-Y substitution both fail structurally
  - Prerequisite: close the keyless side door — release authority must sign only via the Vault-held key (keypair mode, already supported by the signing task); Fulcio will otherwise mint a cert for any valid SPIRE-issued JWT regardless of run scoping
  - Optional evidence layer: attach the signed clearance as an in-toto attestation next to the VSA for downstream audit
- [x] `run-demo.sh` fixes so the demo passes its own policies: Act 4 now drives the real Release CR → release-service → managed PipelineRun flow (the manual dual-gated PR is kept behind `CREATE_MANUAL_PR=1`, created `--as` the release-service SA so it passes the guard); the rogue managed-PipelineRun denial is shown live as the Act 4 opener; Rekor/referrers steps query the snapshot's digest against the released image repo; `classify-taskrun`'s `failurePolicy: Ignore` hardening dependency is documented in the policy (mutate-normalizes / validate-enforces split)


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
