---
title: "SLSA End-to-End With Konflux"
author: "DRAFT"
is_guest_post: true
draft: true
---

<!-- DRAFT - Not yet reviewed or submitted -->

This guest post walks through a practical, end-to-end SLSA implementation using
[Konflux](https://konflux-ci.dev/) — a Kubernetes-native CI/CD system built on
Tekton — along with [Conforma](https://conforma.dev/) (formerly Enterprise
Contract) for policy evaluation and VSA generation. You'll see how Konflux
enforces trust boundaries between build and release contexts, and how each stage
of the SLSA E2E model is validated with concrete policy rules.

## Requirements

This example uses the
[slsa-konflux-example](https://github.com/arewm/slsa-konflux-example)
repository, which provides Helm charts, Tekton pipelines, and Conforma policies
for a complete SLSA deployment. To try it yourself, you need:

- A Kubernetes cluster (Kind works for local development)
- [Konflux operator](https://github.com/konflux-ci/konflux-ci) deployed
- [Helm](https://helm.sh/) for chart installation
- `cosign` and `crane` for inspecting attestations

The repository includes setup scripts and example configuration that set up
build pipelines and release policies. A full walkthrough is in the
[README](https://github.com/arewm/slsa-konflux-example#readme).

## Meet the Festoji Project

Our example component is [Festoji](https://github.com/arewm/festoji), a small
Go utility. What makes it interesting for this walkthrough isn't the application
itself — it's the supply chain infrastructure wrapped around it. Festoji is
onboarded to Konflux by creating Application, Component,
IntegrationTestScenario, and ReleasePlan resources that define its entire
lifecycle from source to signed release. (In the example repository, these
resources are templated via Helm charts for convenience, but Helm is not a
Konflux requirement — any method of creating Kubernetes resources works.)

## Trust Boundary Architecture

Before walking through the stages, it's worth understanding Konflux's trust
boundary model. The system separates concerns into two Kubernetes namespaces:

**Tenant Context** (`default-tenant`): Where builds happen. Developers have
access here. The build pipeline runs source verification, compilation, SAST
scanning, vulnerability scanning, and SBOM generation. Tekton Chains
automatically generates SLSA provenance and signs it — no signing keys are
exposed to the tenant.

**Managed Context** (`managed-tenant`): Where releases happen. Only the platform
controls this namespace. The release pipeline evaluates policy, generates VSAs,
signs attestations with a dedicated release key, and publishes artifacts. Build
artifacts flow in; signed, verified releases flow out.

This separation means a compromised build environment cannot forge release
attestations, and developers never touch signing keys.

## SLSA Build Level 3 — By Default

SLSA Build Level 3 requires isolated builds, inaccessible signing keys, and
verified build tasks. Konflux achieves all three through its architecture rather
than requiring pipeline authors to configure them.

Kubernetes pod isolation ensures each build runs in an ephemeral pod that is
destroyed after completion. Tekton creates a new pod for every PipelineRun, so
one build cannot access another's filesystem, environment variables, or process
space.

Namespace separation prevents builds from accessing signing keys. Builds run in
`default-tenant`; signing keys exist only in `managed-tenant`. Kubernetes RBAC
prevents tenant workloads from reading secrets in the managed namespace.

Conforma's `trusted_tasks` package validates that every task in the build
pipeline comes from an approved, digest-pinned Tekton bundle. The Enterprise
Contract policy includes a list of acceptable bundles, and at release time,
Conforma verifies each task in the build provenance matches that list.

Together, these properties mean an attacker who compromises a single build
cannot affect other builds, cannot sign arbitrary artifacts, and cannot inject
untrusted tasks without detection. For more on the threat model, see
[Trusting Artifacts](https://github.com/arewm/slsa-konflux-example/blob/main/docs/trusting-artifacts.md).

## It All Starts at the Source

Konflux uses a `verify-source` Tekton task that validates each source repository
used in the build. The task receives the repository URL and commit SHA from the
`git-clone` task results, ensuring the verification targets exactly what was
built — not a potentially different ref.

The results are checked by a custom Conforma policy in the `@slsa_source`
collection (`slsa_source_verification.rego`), which enforces four rules:

- **`required_level_achieved`** — The verify-source task achieved the minimum
  required SLSA source level
- **`result_provided`** — The task actually produced a
  `SLSA_SOURCE_LEVEL_ACHIEVED` result
- **`parameters_match_git_clone`** — The URL and revision passed to
  verify-source match what git-clone reported
- **`verified_all_materials`** — Every git repository in the attestation
  materials has a corresponding verify-source task

For Festoji, we achieve SLSA Source Level 1 (version controlled) because the
repository has not been enrolled with
[source-tool](https://github.com/slsa-framework/source-tool). The policy's
`slsa_source_min_level` is configurable, so raising the bar is a policy change —
not a pipeline change. In Part 2, we show how enrolling a repository with
source-tool raises the source level to L3.

## Build Provenance — Automatic With Tekton Chains

Unlike systems where you manually generate provenance, Konflux delegates this to
[Tekton Chains](https://tekton.dev/docs/chains/). Chains observes every
PipelineRun, captures the build inputs and outputs, and generates SLSA
provenance attestations automatically. The attestation is signed with a key
managed by the platform — the build pipeline itself never sees it.

The `@slsa3` policy collection validates the provenance:

- **`slsa_build_build_service.slsa_builder_id_found`** — Builder ID is present
- **`slsa_build_build_service.slsa_builder_id_accepted`** — Builder ID matches
  the expected `https://tekton.dev/chains/v2`
- **`slsa_build_scripted_build.build_script_used`** — Build task contains
  defined steps (not ad-hoc commands)
- **`slsa_build_scripted_build.subject_build_task_matches`** — Provenance
  subject matches the build task's `IMAGE_DIGEST` and `IMAGE_URL` results
- **`slsa_provenance_available.attestation_predicate_type_accepted`** — The
  attestation uses a recognized SLSA provenance predicate type

## Verification — 104 Policy Rules

This is where Konflux's approach gets distinctive. Rather than running a single
verification step, the system evaluates the artifact against **104 policy rules**
drawn from three Conforma collections:

| Collection | Purpose | Rule Count |
|---|---|---|
| `@minimal` | SBOM existence, CVE scanning, base image validation | 23 |
| `@slsa3` | SLSA Build L3 provenance and builder verification | 8 |
| `@slsa_source` | Custom source track verification | 14 |
| *(foundation)* | Attestation format, task validation, config checks | 7 |

### SBOM Validation

The `@minimal` collection includes `sbom.found`, which confirms that at least
one SBOM attestation (SPDX or CycloneDX) exists. Konflux builds automatically
generate SBOMs via Tekton Chains, and our pipeline adds a Trivy scan for
vulnerability detection. The policy validates both format correctness and
existence:

```
sbom.found                         PASS
sbom_cyclonedx.cdx_supported_version  PASS
sbom_cyclonedx.valid_cdx_1_4       PASS
sbom_cyclonedx.valid_cdx_1_5       PASS
sbom_cyclonedx.valid_cdx_1_6       PASS
sbom_spdx.valid                    PASS
```

### CVE Scanning

The CVE rules check that vulnerability scan results exist and that no
critical/high CVEs with known fixes are present:

```
cve.cve_results_found              PASS
cve.cve_blockers                   PASS
cve.cve_warnings                   PASS
cve.unpatched_cve_blockers         PASS
cve.unpatched_cve_warnings         PASS
```

By default, `@minimal` blocks on critical and high severity CVEs that have known
fixes. Unpatched CVEs generate warnings rather than failures. These thresholds
are configurable via `rule_data`.

### Base Image Validation

The policy verifies that base images come from approved registries:

```
base_image_registries.base_image_permitted    PASS
base_image_registries.base_image_info_found   PASS
```

The `allowed_registry_prefixes` in `rule_data.yml` defines which registries are
trusted. Festoji uses `registry.access.redhat.com/ubi8/go-toolset` and `scratch`,
both of which pass.

### Integration Testing as a Gate

Konflux runs the Conforma policy evaluation as an
[IntegrationTestScenario](https://konflux-ci.dev/docs/how-tos/testing/integration/)
(ITS) — a Kubernetes resource that defines what tests to run and when. Two
scenarios are configured:

- **`policy-pr`** — Runs on pull requests with relaxed source level requirements
  (`slsa_source_min_level=1`), since PR branches are not protected
- **`policy-push`** — Runs on push (merge) builds with full policy enforcement,
  matching release requirements

If the push ITS fails, no Release is created. This is the gate between "built"
and "releasable."

## Publication — The Release Pipeline

When the integration test passes, Konflux automatically creates a Release
resource. This triggers the release pipeline in the managed context, which runs
these tasks:

1. **`verify-conforma`** — Re-evaluates the full EC policy (52 rules per
   component, 104 total for multi-arch) in the managed context with the release
   signing key available
2. **`apply-mapping`** — Maps build artifacts to release destinations
3. **`push-snapshot`** — Publishes the verified image to the release registry
4. **`attach-vsa`** — Generates and signs VSAs, attaching them to the released
   image

The release pipeline runs entirely in the managed namespace. The tenant has no
ability to interfere with policy evaluation or signing.

### The VSA

The `attach-vsa` task generates a SLSA Verification Summary Attestation that
captures the verification result:

```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://slsa.dev/verification_summary/v1",
  "subject": [{
    "name": "registry-service.kind-registry/released-festoji",
    "digest": {
      "sha256": "db12fe166b18e3d881ebbef06569d0bce385541dac3a177379bf5c7b58f9c3bc"
    }
  }],
  "predicate": {
    "verificationResult": "PASSED",
    "verifiedLevels": [
      "SLSA_BUILD_LEVEL_3",
      "SLSA_SOURCE_LEVEL_1"
    ],
    "verifier": {
      "id": "https://conforma.dev/cli",
      "version": { "ec": "v0.9.25" }
    },
    "policy": {
      "uri": "oci::quay.io/conforma/release-policy:konflux@sha256:1b296a..."
    },
    "timeVerified": "2026-05-04T19:16:10.167893793Z"
  }
}
```

The VSA records that this artifact achieved **SLSA Build Level 3** and **SLSA
Source Level 1** (Level 1 because the repository isn't yet enrolled with
source-tool — enrolling it would raise this to Level 2 or 3 without any pipeline
changes). It is signed with the release signing key and attached to the released
image as an in-toto attestation.

The released image ends up with three attestation layers:

1. **Build provenance** — SLSA provenance from Tekton Chains
2. **Conforma VSA** — Detailed verification summary with full policy config
3. **SLSA VSA** — Standard SLSA verification summary

Plus `.sig` (signature) and `.sbom` (software bill of materials) artifacts.

## End User Verification

Downstream consumers can verify the released image using the VSA without
repeating all 104 policy checks. The VSA acts as a receipt: if you trust the
verifier (Conforma) and the signing key, you can check the VSA instead of
re-running the full policy evaluation.

```bash
# Inspect attestations on the released image
crane ls <registry>/released-festoji --insecure

# Download the SLSA VSA
crane manifest <registry>/released-festoji:sha256-<digest>.att --insecure \
  | jq -r '.layers[] | select(.annotations.predicateType == 
    "https://slsa.dev/verification_summary/v1") | .digest' \
  | xargs -I{} crane blob <registry>/released-festoji@{} --insecure \
  | jq '.payload' -r | base64 -d | jq '.'
```

For consumers who want deeper assurance, the full build provenance and SBOM are
also attached to the image. The Conforma VSA includes the complete policy
configuration (collections, data sources, rule data) so consumers can understand
exactly what was verified.

## Part 2: Going Further With Source Track L3 and CVE Management

Festoji was intentionally simple — a scratch-based Go binary with no real
dependencies. Real-world applications face additional challenges: base images
with known CVEs, source provenance beyond version control, and unreproducible
network-dependent builds. To demonstrate these scenarios, we use
[source-test-repo](https://github.com/spork-madness/source-test-repo) as a
second example component.

**Important:** source-test-repo is used as an example, not a template. It
contains source-tool enrollment configuration and Tekton pipeline definitions
specific to our setup. If you want to replicate this for your own application,
start with your own repository, enroll it with source-tool following that
project's documentation, then onboard to Konflux using the component-onboarding
chart.

### SLSA Source Track L3

source-test-repo is enrolled with source-tool via a GitHub Actions workflow that
computes source provenance on every push to protected branches. During a Konflux
build, the `verify-source` task queries the source-tool attestation service and
evaluates the repository's SLSA source level based on branch protection
settings, commit signing requirements, and history retention.

The `@slsa_source` collection enforces that the achieved level meets the
configured minimum (`slsa_source_min_level`), the verify-source task provided
results, the verified URL and revision match what git-clone actually cloned, and
every git repository in the attestation materials has a corresponding
verify-source task. This last rule is critical for multi-repository builds where
auxiliary repositories could bypass verification.

The VSA for source-test-repo includes `SLSA_SOURCE_LEVEL_3` instead of
Festoji's `SLSA_SOURCE_LEVEL_1`. The pipeline is the same; the difference is
enrollment and policy configuration.

### Per-Application Policies

Different applications need different assurance levels. The component-onboarding
Helm chart creates an application-specific `EnterpriseContractPolicy` in the
managed namespace. source-test-repo is onboarded with
`slsa_source_min_level: "3"` while Festoji uses the default `"1"`.

The `ruleData` field in the ECP overrides values from git-based data sources.
Conforma's rule data precedence is: ECP `ruleData` > custom data source >
default data source > hardcoded Rego defaults. This means you can tighten or
relax policy per-application without forking the policy rules.

### CVE Management

The `cve.cve_blockers` rule in `@minimal` blocks releases when critical or
high severity CVEs with known fixes are present. But not all CVEs can be patched
immediately. Konflux provides three mechanisms for managing them:

**Leeway.** The `cve_leeway` rule data defines grace periods by severity —
critical CVEs get 6 days, high CVEs get 29 days from the CVE's issued date.
During the leeway window, the CVE appears as a warning instead of a violation.

**Per-CVE exceptions.** When a specific CVE requires an exception (false
positive, unreachable code path), you can exclude it via the ECP's
`config.exclude` list using the syntax `cve.cve_blockers:CVE-ID`. Conforma's
scoring system gives this exact match a score of 100, overriding the
collection-level inclusion at score 10.

**Volatile configuration.** For time-bounded exceptions, the ECP supports
`volatileConfig.exclude` entries with `effectiveUntil` and `reference` fields.
The `volatile_config` Rego package generates warnings as expiration approaches
and violations after expiry. If `effectiveUntil` is omitted, Conforma warns
about the missing expiration to prevent accidental permanent exceptions.
Volatile config is the recommended approach for temporary CVE exceptions — it
forces periodic review and prevents exceptions from becoming permanent through
inattention.

### Hermetic Builds

Network access during builds introduces non-determinism. A build that succeeds
today might fail tomorrow if an upstream repository goes offline or a compromised
registry serves malicious content. Konflux supports hermetic builds through the
`hermetic` pipeline parameter. When set to `true`, the build container loses
network access after the `prefetch-dependencies` task completes.

All dependencies must be declared in lock files or manifests for prefetch to
work, so the resulting SBOM reflects actual dependencies with no hidden runtime
downloads. The `hermetic_build_task.build_task_hermetic` rule in `@minimal` can
enforce that builds used hermetic mode.

## What Makes This Different

A few things distinguish the Konflux approach:

**Kubernetes-native trust boundaries.** The tenant/managed namespace separation
is enforced by Kubernetes RBAC, not by convention. Signing keys physically
cannot be accessed from the build context.

**Automatic provenance.** Tekton Chains generates SLSA provenance without any
pipeline configuration. You don't write steps to create provenance — it happens
as a side effect of running the build.

**Policy as configuration.** The EC policy is a Kubernetes resource
(`EnterpriseContractPolicy`). Adding `@minimal` to the policy collections list
is a one-field change to the resource, and the 23 new rules it brings are
immediately enforced.

**Layered verification.** The same policy is evaluated twice — once as an
integration test (gating release creation) and once in the release pipeline
(gating publication). The release evaluation happens in the managed context
where the signing key is available, so the VSA can be signed as part of the same
atomic operation.

## Future Directions

Several extensions follow naturally from this architecture.

**BuildEnv attestations.** The SLSA BuildEnv track is a draft specification.
Konflux provides build environment isolation through Kubernetes pod execution,
but formal BuildEnv attestations are not currently generated. A Tekton task
could capture builder image digests and generate BuildEnv attestations, which
Tekton Chains would sign alongside the build provenance.

**Dependency levels in VSA.** The `attach-vsa` task can read base image
annotations (`org.opencontainers.image.base.name` and `.base.digest`) and
verify the base image's release signature and provenance attestation. This
would let the VSA include `dependencyLevels` giving downstream consumers
transitive assurance about the base image. We have demonstrated release
signature verification; provenance verification needs further investigation.

**VEX integration.** Conforma's `config.exclude` mechanism and volatile
configuration provide a foundation for vulnerability triage, but excluded
results are silently dropped from the EC report. To support VEX
(Vulnerability Exploitability eXchange) post-processing, excluded-but-present
results would need to be preserved with exclusion metadata. This would let
consumers understand not just what passed, but what was assessed and
intentionally accepted.

**Transparency log integration.** Publishing VSAs and provenance to Sigstore's
Rekor transparency log would add public auditability and tamper detection.
Combined with OIDC-based keyless signing, this removes the need for consumers
to manage verification keys.

Each of these extensions follows the same pattern: add a Tekton task to generate
or collect the attestation, and add a Conforma rule to verify it. The trust
boundary architecture doesn't change.

## Conclusion

This walkthrough covered the five SLSA E2E stages as implemented in Konflux,
first with Festoji (Build L3 and source verification fundamentals), then with
source-test-repo (Source L3, CVE management, and hermetic builds):

1. **Source** — `verify-source` task validates repository integrity, checked by
   `@slsa_source` policy collection. Source-tool enrollment raises the level
   from L1 to L3 without pipeline changes.
2. **Build** — Tekton Chains generates SLSA provenance automatically, checked by
   `@slsa3` policy collection. Konflux achieves Build L3 by default through pod
   isolation, namespace separation, and trusted task verification.
3. **Verification** — 104 Conforma rules validate provenance, SBOMs, CVEs, base
   images, and source correlation across `@minimal` + `@slsa3` + `@slsa_source`.
   Per-application policies allow different assurance levels per component.
4. **Publication** — Release pipeline in managed context re-verifies, generates
   signed VSAs, and publishes to release registry. CVE leeway and volatile
   configuration provide auditable exception mechanisms.
5. **Use** — Consumers verify via VSA attestation on the released image.

The [slsa-konflux-example](https://github.com/arewm/slsa-konflux-example)
repository is open source and includes everything needed to reproduce this
setup: Kubernetes resource definitions, Tekton tasks and pipelines, Conforma
policies, and setup scripts. Contributions and feedback are welcome.

## Resources

slsa-konflux-example, the SLSA E2E demo repository:<br>
[https://github.com/arewm/slsa-konflux-example](https://github.com/arewm/slsa-konflux-example)

Konflux CI, Kubernetes-native CI/CD:<br>
[https://konflux-ci.dev/](https://konflux-ci.dev/)

Conforma (Enterprise Contract), policy engine for supply chain security:<br>
[https://conforma.dev/](https://conforma.dev/)

Tekton Chains, automatic provenance generation:<br>
[https://tekton.dev/docs/chains/](https://tekton.dev/docs/chains/)

source-tool, SLSA Source Track CLI:<br>
[https://github.com/slsa-framework/source-tool](https://github.com/slsa-framework/source-tool)

SLSA E2E specification:<br>
[https://slsa.dev/blog/2025/07/slsa-e2e](https://slsa.dev/blog/2025/07/slsa-e2e)

