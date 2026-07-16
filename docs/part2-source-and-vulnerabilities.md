# Part 2: Source Track, Vulnerability Management, and Hermetic Builds

This is Part 2 of the slsa-konflux-example walkthrough. If you haven't completed Part 1, start there. Part 1 covers the fundamentals of trust boundaries, build pipelines, and releases using Festoji as an example.

This part introduces source track verification, vulnerability management, and hermetic builds using source-test-repo as an example component.

## Why a Second Component?

Festoji was intentionally simple. It uses a scratch-based container (no real base image) and is not enrolled with source-tool, so it achieves only SLSA Source Track Level 1 (version controlled source). While this is sufficient for demonstrating the basics, real-world applications face additional challenges:

- Base images from registries like registry.access.redhat.com often contain system packages with known CVEs
- Source provenance beyond version control requires integration with source attestation tools
- Multi-repository builds need verification for every source material
- Network access during builds can introduce unreproducible dependencies

source-test-repo (https://github.com/spork-madness/source-test-repo) is configured to exercise these scenarios. It uses `registry.access.redhat.com/ubi8/ubi:latest` as a base image, is enrolled with source-tool via GitHub Actions, and can be configured for hermetic builds.

**Important**: source-test-repo is used as an EXAMPLE of what a source-tool-enrolled repository looks like. The repository contains setup-specific configuration (source-tool enrollment, Tekton pipeline definitions). If you want to exercise source track features for your own application:

1. Start with your own repository
2. Enroll it with source-tool following the source-tool documentation (https://github.com/slsa-framework/source-tool)
3. Onboard it to Konflux using the component-onboarding chart

The onboarding commands shown in this guide use source-test-repo for illustration, but you can substitute your own repository URL. If you want to use source-test-repo directly for hands-on testing, you need to be a collaborator on the spork-madness organization (or fork it, understanding that you'll need to update the workflow configurations for your environment).

This exercises Source Track Level 3, CVE scanning on real packages, and base image verification.

## Per-Application Conforma Policies

Different applications have different assurance requirements. A customer-facing production service needs stronger guarantees than an internal development tool. Konflux supports this through per-application Conforma policies.

The component-onboarding Helm chart creates an EnterpriseContractPolicy resource in the managed namespace for each application you onboard. This policy is referenced by the ReleasePlanAdmission and used during the release pipeline's verify-conforma task.

Here's how source-test-repo is onboarded with SLSA Source Level 3:

```bash
helm upgrade --install source-test-repo ./charts/component-onboarding \
  --set componentName=source-test-repo \
  --set gitRepoUrl=https://github.com/spork-madness/source-test-repo \
  --set release.policy.slsaSourceMinLevel="3"
```

Compare this to Festoji, which uses the default Level 1:

```bash
helm upgrade --install festoji ./charts/component-onboarding \
  --set componentName=festoji \
  --set gitRepoUrl=https://github.com/YOUR_ORG/festoji
  # slsaSourceMinLevel defaults to "1"
```

The chart template `charts/component-onboarding/templates/enterprisecontractpolicy.yaml` renders these values into the ECP resource:

```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: EnterpriseContractPolicy
metadata:
  name: source-test-repo-ec-policy
  namespace: managed-tenant
spec:
  description: SLSA policy for source-test-repo
  publicKey: 'k8s://tekton-pipelines/public-key'
  sources:
    - name: Release Policies
      policy:
        - oci::quay.io/conforma/release-policy:konflux@sha256:...
        - github.com/arewm/slsa-konflux-example//managed-context/policies/ec-policy-data/policy/custom/slsa_source_verification?ref=main
      data:
        - github.com/arewm/slsa-konflux-example//managed-context/policies/ec-policy-data/data
        - oci::quay.io/slsa-konflux-example/slsa-e2e-data-acceptable-bundles:latest@sha256:...
      ruleData:
        slsa_source_min_level: "3"
      config:
        include:
          - '@minimal'
          - '@slsa3'
          - '@slsa_source'
```

The `ruleData` section sets application-specific values that override the defaults. Conforma's rule data precedence is:

1. ECP `ruleData` (highest precedence)
2. Custom data source (the `data` section referencing the repository)
3. Default data source (from the policy bundle)
4. Hardcoded defaults in the Rego policy

This means the `slsa_source_min_level: "3"` set in the ECP takes precedence over the default `"2"` in `managed-context/policies/ec-policy-data/data/rule_data.yml`.

**Note on trust boundaries**: The EnterpriseContractPolicy is created in the managed namespace (managed-tenant), even though it's application-specific. This technically crosses the tenant/managed trust boundary. In a production deployment, ECPs would be managed by platform administrators separately from application onboarding. For this example, we accept this tradeoff to demonstrate per-application policy configuration.

## SLSA Source Track Level 3

SLSA Source Track provides assurance about where source code came from and how it was managed. The three levels are:

- **Level 1**: Version controlled. The source exists in a version control system.
- **Level 2**: Verified history. The version control system prevents tampering with history.
- **Level 3**: Retention and tamper resistance. Branch protection rules are enforced, and history is immutable.

Achieving Level 3 requires integration between your source repository and source attestation tools.

**Important**: Setting `slsaSourceMinLevel="3"` in the onboarding chart is a policy *requirement*, not a guarantee. The policy says "reject builds that don't achieve Level 3" — but the build itself must actually achieve that level. This requires enrolling the repository with [source-tool](https://github.com/slsa-framework/source-tool) and configuring branch protection rules on the main branch. Without both, push builds will achieve at most Level 1 and fail the policy check at release time.

### Source-Tool Enrollment

source-test-repo is enrolled with source-tool via a GitHub Actions workflow. The workflow file `.github/workflows/compute_slsa_source.yaml` runs on every push to protected branches:

```yaml
name: Compute SLSA Source Provenance
on:
  push:
    branches:
      - main

jobs:
  compute-source-provenance:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Compute source provenance
        # NOTE: Replace with actual source-tool action reference
        # See: https://github.com/slsa-framework/source-tool
        # and https://github.com/slsa-framework/source-actions
        uses: slsa-framework/source-tool@<version>
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
```

This workflow computes source provenance and uploads it to the source-tool attestation service. The provenance includes information about the repository, branch protection settings, and commit metadata.

### Build-Time Verification

During a Konflux build, the `verify-source` task receives the repository URL and revision from the `git-clone` task and invokes source-tool to verify the source provenance:

```yaml
- name: verify-source
  taskRef:
    resolver: bundles
    params:
      - name: name
        value: verify-source
      - name: bundle
        value: quay.io/konflux-ci/tekton-catalog/task-verify-source:0.1@sha256:...
      - name: kind
        value: task
  params:
    - name: url
      value: $(tasks.clone-repository.results.url)
    - name: revision
      value: $(tasks.clone-repository.results.commit)
```

The task queries the source-tool attestation service for provenance matching the URL and revision. If found, it evaluates the SLSA source level based on the repository's configuration:

- Protected branches, required reviews, and other GitHub settings
- Commit signing requirements
- Branch deletion restrictions

The task sets a result `SLSA_SOURCE_LEVEL_ACHIEVED` with a value like `SLSA_SOURCE_LEVEL_3`.

<details>
<summary>verify-source task results from source-test-repo build</summary>

```
SLSA_SOURCE_LEVEL_ACHIEVED: SLSA_SOURCE_LEVEL_3
TEST_OUTPUT: {
  "result": "PASSED",
  "timestamp": "2026-05-05T15:12:25Z",
  "namespace": "slsa-source-verification",
  "successes": 2,
  "failures": 0,
  "warnings": 0,
  "tests": [
    {"name": "vsa-fetch", "result": "PASSED"},
    {"name": "slsa-level-determination", "result": "PASSED"}
  ]
}
```

</details>

### Policy Enforcement

At release time, the `verify-conforma` task in the managed namespace checks the source verification results against the policy. The custom policy `managed-context/policies/ec-policy-data/policy/custom/slsa_source_verification/slsa_source_verification.rego` in the `@slsa_source` collection enforces four rules:

**Rule 1: required_level_achieved**

The achieved level must be greater than or equal to the configured minimum level from `slsa_source_min_level` in rule data.

```rego
deny contains result if {
    min_level := _slsa_source_min_level
    
    some att in lib.pipelinerun_attestations
    some task in tekton.tasks(att)
    some task_name in tekton.task_names(task)
    task_name == "verify-source"
    
    achieved_level_raw := tekton.task_result(task, "SLSA_SOURCE_LEVEL_ACHIEVED")
    achieved_level := _parse_level(achieved_level_raw)
    
    to_number(achieved_level) < to_number(min_level)
    
    result := lib.result_helper_with_term(
        rego.metadata.chain(),
        [achieved_level, min_level],
        "verify-source",
    )
}
```

**Rule 2: result_provided**

The verify-source task must provide the `SLSA_SOURCE_LEVEL_ACHIEVED` result. This ensures the task actually ran and completed successfully.

**Rule 3: parameters_match_git_clone**

The URL and revision parameters passed to verify-source must match the results from git-clone. This prevents a malicious pipeline from verifying a different repository than the one that was actually cloned:

```rego
deny contains result if {
    some att in lib.pipelinerun_attestations
    some verify_source_task in _verify_source_tasks(att)
    
    verify_url := tekton.task_param(verify_source_task, "url")
    verify_revision := tekton.task_param(verify_source_task, "revision")
    
    matching_git_clones := [task |
        some task in tekton.git_clone_tasks(att)
        git_url := tekton.task_result(task, "url")
        git_commit := tekton.task_result(task, "commit")
        _normalize_git_url(git_url) == _normalize_git_url(verify_url)
        git_commit == verify_revision
    ]
    
    count(matching_git_clones) == 0
    
    # Error generation code...
}
```

**Rule 4: verified_all_materials**

Every git repository in the attestation's materials section must have a corresponding verify-source task. This is critical for multi-repository builds where auxiliary repositories (vendored dependencies, shared libraries) could bypass verification:

```rego
deny contains result if {
    some att in lib.pipelinerun_attestations
    some material in _git_materials(att)
    
    verify_tasks := [task |
        some task in _verify_source_tasks(att)
        url := tekton.task_param(task, "url")
        revision := tekton.task_param(task, "revision")
        _materials_match(material, url, revision)
    ]
    
    count(verify_tasks) == 0
    
    result := lib.result_helper_with_term(
        rego.metadata.chain(),
        [material.uri, material.digest.sha1],
        sprintf("%s@%s", [material.uri, material.digest.sha1]),
    )
}
```

### VSA Output

After successful verification, the `attach-vsa` task generates a Verification Summary Attestation (VSA) that includes the source verification results. For source-test-repo, this shows `SLSA_SOURCE_LEVEL_3`:

<details>
<summary>Source-test-repo VSA (SLSA_BUILD_LEVEL_3, SLSA_SOURCE_LEVEL_3)</summary>

```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://slsa.dev/verification_summary/v1",
  "subject": [
    {
      "name": "registry-service.kind-registry/released-source-test-repo",
      "digest": { "sha256": "b48e59ec0dc3281a33f0305a7b7fe0eb86f4c14f5597970c4a607cf811898e34" }
    }
  ],
  "predicate": {
    "dependencyLevels": null,
    "policy": {
      "digest": {},
      "uri": "oci::quay.io/conforma/release-policy:konflux@sha256:1b296a925b4021f4b4959ea289596925a8735540e554f3ba7754a651731a216f"
    },
    "resourceUri": "registry-service.kind-registry/konflux-source-test-repo@sha256:b48e59ec0dc3281a33f0305a7b7fe0eb86f4c14f5597970c4a607cf811898e34",
    "slsaVersion": "1.0",
    "timeVerified": "2026-05-05T16:43:56.520817389Z",
    "verificationResult": "PASSED",
    "verifiedLevels": [
      "SLSA_BUILD_LEVEL_3",
      "SLSA_SOURCE_LEVEL_3"
    ],
    "verifier": {
      "id": "https://conforma.dev/cli",
      "version": { "ec": "v0.9.25" }
    }
  }
}
```

</details>

Compare this to Festoji, which shows `SLSA_SOURCE_LEVEL_1` because it is not enrolled with source-tool and relies only on version control.

**Note**: Images released multiple times will have multiple VSAs attached (one per release). The most recent VSA reflects the latest policy evaluation.

**Note on PR builds**: Pull request builds always achieve Level 1, regardless of enrollment, because PR branches are not protected. Only builds from protected branches (typically main) can achieve Levels 2 or 3.

## CVE Management

Real-world container images contain dependencies with known vulnerabilities. The question is not whether CVEs exist, but how to manage them systematically.

Konflux integrates vulnerability scanning into the release process through Conforma's `@minimal` collection, which includes the `cve.cve_blockers` rule. This rule blocks releases when critical or high severity CVEs with known fixes are present.

### Scanning and Detection

During the build pipeline, buildah generates an SBOM (Software Bill of Materials) during the build, and the `trivy-sbom-scan` task scans it for vulnerabilities using Trivy:

```bash
# Simplified version of what trivy-sbom-scan does
trivy image --format cyclonedx \
  --output sbom.json \
  registry-service.kind-registry/source-test-repo@sha256:...

trivy sbom sbom.json \
  --format sarif \
  --output vulnerabilities.sarif
```

The SBOM and vulnerability report are stored as attestations. At release time, verify-conforma reads these attestations and evaluates them against the CVE policy.

### The Leeway Mechanism

Not all CVEs can be patched immediately. Upstream dependencies may not have released fixes, or patches may require significant testing before deployment. The `cve_leeway` mechanism in `managed-context/policies/ec-policy-data/data/rule_data.yml` provides grace periods based on CVE severity:

```yaml
rule_data:
  # Thresholds are one day shorter than the time periods for grade C in:
  # https://access.redhat.com/articles/2803031
  cve_leeway:
    critical: 6
    high: 29
```

These values are measured in days from the CVE's issued date (not the discovered date). During the leeway window, the CVE appears as a warning instead of a violation. After the window expires, it becomes a blocking failure.

For example, if CVE-2026-1234 with critical severity is issued on May 1st:
- May 1-7: Warning (within 6-day critical leeway)
- May 8+: Violation (blocks release)

The leeway window gives teams time to evaluate patches, test fixes, and coordinate deployments without rushing or bypassing security controls.

To find actual blocking CVEs from a failed release, inspect the verify-conforma task output:

```bash
# Find blocking CVEs from a failed release
kubectl logs -n managed-tenant -l tekton.dev/pipelineTask=verify-conforma --tail=100 | grep -i "cve"
```

### Per-CVE Exceptions

Sometimes a CVE requires an exception. Perhaps the affected code path is not reachable in your deployment, or the vendor has confirmed a false positive. Konflux supports granular CVE exceptions through the ECP's `config.exclude` list.

The syntax uses a term-specific identifier: `cve.cve_blockers:CVE-ID`. Conforma's rule scoring system gives this a score of 100 (exact match), which overrides the `@minimal` collection's inclusion of `cve.cve_blockers` (score 10).

Add the exception using `helm upgrade` with the `release.policy.excludeRules` value:

```bash
helm upgrade source-test-repo ./charts/component-onboarding \
  --reuse-values \
  --set release.policy.excludeRules[0]="cve.cve_blockers:CVE-2026-4878"
```

For multiple CVE exceptions:

```bash
helm upgrade source-test-repo ./charts/component-onboarding \
  --reuse-values \
  --set release.policy.excludeRules[0]="cve.cve_blockers:CVE-2026-4878" \
  --set release.policy.excludeRules[1]="cve.cve_blockers:CVE-2026-5432"
```

Alternatively, use a values file:

```yaml
# source-test-repo-cve-exceptions.yaml
release:
  policy:
    excludeRules:
      - "cve.cve_blockers:CVE-2026-4878"
      - "cve.cve_blockers:CVE-2026-5432"
```

```bash
helm upgrade source-test-repo ./charts/component-onboarding \
  --reuse-values \
  -f source-test-repo-cve-exceptions.yaml
```

The resulting ECP includes the exclusion:

```yaml
spec:
  sources:
    - name: Release Policies
      config:
        include:
          - '@minimal'
          - '@slsa3'
          - '@slsa_source'
        exclude:
          - 'cve.cve_blockers:CVE-2026-4878'
```

This completely disables the CVE blocker for CVE-2026-4878. Releases will proceed regardless of the CVE's presence.

### Volatile Configuration for Time-Bounded Exceptions

Permanent exceptions are often the wrong tool. CVE fixes may be delayed but not indefinitely unavailable. Volatile configuration provides time-bounded, auditable exceptions that expire automatically.

The ECP supports a `volatileConfig` section that mirrors the regular `config` structure but adds `effectiveUntil` and `reference` fields.

Add a time-bounded exception using `helm upgrade` with the `release.policy.volatileExcludes` value:

```bash
helm upgrade source-test-repo ./charts/component-onboarding \
  --reuse-values \
  --set 'release.policy.volatileExcludes[0].value=cve.cve_blockers:CVE-2026-4878' \
  --set 'release.policy.volatileExcludes[0].effectiveUntil=2026-06-01T00:00:00Z' \
  --set 'release.policy.volatileExcludes[0].reference=https://issues.example.com/VULN-1234'
```

For multiple volatile exceptions, use a values file:

```yaml
# source-test-repo-volatile-cves.yaml
release:
  policy:
    volatileExcludes:
      - value: "cve.cve_blockers:CVE-2026-4878"
        effectiveUntil: "2026-06-01T00:00:00Z"
        reference: "https://issues.example.com/VULN-1234"
      - value: "cve.cve_blockers:CVE-2026-5432"
        effectiveUntil: "2026-07-15T00:00:00Z"
        reference: "https://issues.example.com/VULN-5678"
```

```bash
helm upgrade source-test-repo ./charts/component-onboarding \
  --reuse-values \
  -f source-test-repo-volatile-cves.yaml
```

The resulting ECP includes the volatile exclusion:

```yaml
spec:
  sources:
    - name: Release Policies
      config:
        include:
          - '@minimal'
          - '@slsa3'
          - '@slsa_source'
      volatileConfig:
        exclude:
          - value: "cve.cve_blockers:CVE-2026-4878"
            effectiveUntil: "2026-06-01T00:00:00Z"
            reference: "https://issues.example.com/VULN-1234"
```

This exception allows releases with CVE-2026-4878 until June 1st, 2026. The `reference` field is metadata on the CRD that provides context for auditing (it is not passed to the EC report output).

The `volatile_config` Rego package in Conforma generates warnings as the expiration approaches:
- 7 days before expiration: Warning
- 3 days before expiration: Warning with increased severity
- After expiration: Violation (blocks release)

If `effectiveUntil` is omitted, Conforma issues a "no expiration set" warning to prevent accidental permanent exceptions.

Volatile config is the recommended approach for temporary CVE exceptions. It forces periodic review, provides audit trails through the reference field, and prevents exceptions from becoming permanent through inattention.

### Unpatched CVEs

Some CVEs have no known fix. The affected package has not released a patch, or the vendor has acknowledged the issue but not committed to a timeline. The `cve.cve_blockers` rule treats these as warnings by default.

This behavior is configurable via the `restrict_unpatched_cve_security_levels` rule data. If you want to block releases on unpatched CVEs above a certain severity:

```yaml
rule_data:
  restrict_unpatched_cve_security_levels:
    - critical
    - high
```

Now unpatched critical and high severity CVEs become violations instead of warnings. The component-onboarding chart supports this via the `restrictUnpatchedCveLevels` value:

```bash
helm upgrade --install source-test-repo ./charts/component-onboarding \
  --reuse-values \
  --set 'release.policy.restrictUnpatchedCveLevels[0]=critical' \
  --set 'release.policy.restrictUnpatchedCveLevels[1]=high'
```

Use this carefully. Blocking on unpatched CVEs can halt all releases if an upstream dependency has a disclosed but unpatched vulnerability.

## Hermetic Builds

Network access during builds introduces non-determinism. A build that succeeds today might fail tomorrow if an upstream repository goes offline, a package is deleted, or a compromised registry serves malicious content. Hermetic builds eliminate this risk by removing network access after dependency prefetch.

Konflux supports hermetic builds through the `hermetic` pipeline parameter. When set to `true`, the build container loses network access after the `prefetch-dependencies` task completes.

**Note**: The hermetic build configuration applies to any component. The examples below use Festoji from Part 1, which has Go dependencies requiring `prefetch-input=gomod`. Components without external dependencies (like source-test-repo) can be made hermetic by setting only `hermetic=true` with an empty `prefetch-input` — network access is still disabled during the build, but no dependencies need prefetching.

### How It Works

A standard build pipeline with hermetic support looks like this:

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: source-test-repo-build
spec:
  params:
    - name: hermetic
      value: "true"
  pipelineRef:
    resolver: git
    params:
      - name: url
        value: https://github.com/konflux-ci/build-definitions
      - name: revision
        value: main
      - name: pathInRepo
        value: pipelines/docker-build-oci-ta/docker-build-oci-ta.yaml
```

The pipeline executes these steps:

1. **git-clone**: Clone the source repository
2. **prefetch-dependencies**: Analyze the build configuration (Dockerfile, package.json, go.mod, etc.) and download all dependencies to a trusted artifact
3. **build** (buildah-oci-ta): Execute the build using only the cloned source and prefetched dependencies. Network access is disabled via NetworkPolicy.
4. **Remaining tasks**: SBOM generation, scanning, attestation creation

The `prefetch-dependencies` task supports multiple language ecosystems:
- Go: Downloads modules from `go.mod`
- Node.js: Downloads packages from `package.json` or `package-lock.json`
- Python: Downloads wheels and source distributions from `requirements.txt`
- RPM: Downloads packages from Dockerfile `yum install` directives

Dependencies are stored as OCI images in the trusted artifact registry. The build task mounts this artifact and configures the build toolchain to use it as the sole dependency source:

```bash
# For Go builds
export GOPROXY=file:///trusted-artifacts/go-modules
export GOMODCACHE=/trusted-artifacts/go-modules

# For Node.js builds
npm config set cache /trusted-artifacts/npm-cache
npm ci --offline
```

### Benefits

**Reproducibility**: The build output depends only on the source code and the prefetched dependencies. Running the same build twice produces identical results (modulo timestamps).

**Accurate SBOMs**: Because all dependencies must be declared in lock files or manifests for prefetch to work, the SBOM reflects the actual dependencies. There are no hidden runtime downloads.

**Supply chain attack resistance**: A compromised package registry cannot inject malicious code during the build. The build uses only the prefetched, scanned dependencies.

**Build isolation**: Network outages, registry rate limits, and deleted packages do not affect build success. The build is independent of external network state.

### Configuration

Enable hermetic builds by changing the pipeline parameter defaults in your component's `.tekton/` PipelineRun definitions. The `hermetic` parameter enables network isolation, and `prefetch-input` tells the prefetch-dependencies task which package manager to use (e.g., `gomod` for Go, `pip` for Python).

These changes are made in your component's source repository. You can use either your festoji fork or source-test-repo fork — the `.tekton/` pipeline definitions have the same structure. If you don't already have a local clone, create one:

```bash
# Use whichever component you want to enable hermetic builds for
git clone https://github.com/${FORK_ORG}/<component>.git
cd <component>
```

Use `yq` to update the defaults in all `.tekton/` files:

```bash
for f in .tekton/*.yaml; do
  yq -i '(.spec.pipelineSpec.params[] | select(.name == "hermetic")).default = "true"' "$f"
  yq -i '(.spec.pipelineSpec.params[] | select(.name == "prefetch-input")).default = "gomod"' "$f"
done
```

`yq` reformats the YAML, so the diff will show whitespace and line-wrapping changes beyond the two parameter values. Verify that only the intended defaults changed:

```bash
diff <(git show HEAD:.tekton/festoji-push.yaml | yq -o json) \
     <(yq -o json .tekton/festoji-push.yaml)
```

Commit and push the change. PAC picks up the new defaults on the next build.

On macOS, install `yq` with `brew install yq`.

### Policy Enforcement

The `@minimal` collection includes the `hermetic_build_task.build_task_hermetic` rule, which checks that tasks listed in `required_hermetic_tasks` rule data ran with hermetic mode enabled:

```yaml
rule_data:
  required_hermetic_tasks:
    - buildah
    - buildah-oci-ta
    - buildah-remote
    - buildah-remote-oci-ta
    - run-script-oci-ta
```

If the build used `buildah-oci-ta` but did not set `hermetic=true`, the release is blocked with a violation.

### Verifying the Hermetic Build

After the build and release complete, inspect the provenance to confirm hermetic mode was active. The build attestation records the pipeline parameters:

```bash
cosign download attestation --allow-insecure-registry \
  localhost:5001/konflux-festoji@sha256:6173535e... \
  | jq -r '.payload | @base64d | fromjson
    | select(.predicateType == "https://slsa.dev/provenance/v0.2")
    | .predicate.invocation.parameters
    | {hermetic, "prefetch-input"}'
```

```json
{
  "hermetic": "true",
  "prefetch-input": "gomod"
}
```

The released image's VSA reflects the higher build level:

```bash
cosign download attestation --allow-insecure-registry \
  localhost:5001/released-festoji@sha256:6173535e... \
  | jq -r '.payload | @base64d | fromjson
    | select(.predicateType == "https://slsa.dev/verification_summary/v1")
    | .predicate | {verificationResult, verifiedLevels}'
```

```json
{
  "verificationResult": "PASSED",
  "verifiedLevels": [
    "SLSA_BUILD_LEVEL_3",
    "SLSA_SOURCE_LEVEL_1"
  ]
}
```

`SLSA_BUILD_LEVEL_3` is determined by trusted task verification, not hermetic mode. Conforma checks that every task in the build provenance came from the approved, digest-pinned allowlist — that is what justifies the L3 claim. Hermetic builds improve supply chain quality (reproducibility, accurate SBOMs, network isolation) but do not change the SLSA build level.

## Putting It All Together

Let's walk through onboarding source-test-repo with all features enabled:

**1. Enroll with source-tool** (done in the source repository, outside Konflux):

```yaml
# .github/workflows/compute_slsa_source.yaml
name: Compute SLSA Source Provenance
on:
  push:
    branches:
      - main

jobs:
  compute-source-provenance:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # NOTE: Replace with actual source-tool action reference
      # See: https://github.com/slsa-framework/source-tool
      # and https://github.com/slsa-framework/source-actions
      - uses: slsa-framework/source-tool@<version>
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
```

**2. Onboard to Konflux with Source Level 3**:

```bash
helm upgrade --install source-test-repo ./charts/component-onboarding \
  --set componentName=source-test-repo \
  --set gitRepoUrl=https://github.com/spork-madness/source-test-repo \
  --set release.policy.slsaSourceMinLevel="3"
```

**3. Enable hermetic builds** (in your component's source repository):

```bash
for f in .tekton/*.yaml; do
  yq -i '(.spec.pipelineSpec.params[] | select(.name == "hermetic")).default = "true"' "$f"
  yq -i '(.spec.pipelineSpec.params[] | select(.name == "prefetch-input")).default = "gomod"' "$f"
done
git add .tekton/ && git commit -m "build: Enable hermetic builds" && git push
```

**4. Monitor the build**:

```bash
kubectl get pipelineruns -n default-tenant -w
```

**5. Check for CVEs and source verification**:

After the build completes, inspect the attestations:

```bash
# Get the latest PipelineRun
PIPELINERUN=$(kubectl get pipelineruns -n default-tenant \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')

# Check verify-source result (this is a task result, not a pipeline result)
kubectl get taskrun -n default-tenant \
  -l tekton.dev/pipelineRun=$PIPELINERUN \
  -l tekton.dev/pipelineTask=verify-source \
  -o jsonpath='{.items[0].status.results[?(@.name=="SLSA_SOURCE_LEVEL_ACHIEVED")].value}'

# Check for CVE warnings
kubectl logs -n default-tenant \
  -l tekton.dev/pipelineRun=$PIPELINERUN \
  -l tekton.dev/pipelineTask=trivy-sbom-scan
```

**6. Trigger a release**:

```bash
# Discover the latest snapshot for source-test-repo
SNAPSHOT=$(kubectl get snapshots -n default-tenant \
  -l appstudio.openshift.io/application=source-test-repo \
  --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)

kubectl apply -f - <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: source-test-repo-release
  namespace: default-tenant
spec:
  releasePlan: source-test-repo-release-plan
  snapshot: ${SNAPSHOT}
EOF
```

**7. Verify the VSA**:

After the release completes, the VSA is attached to the released image:

```bash
cosign download attestation \
  --allow-insecure-registry \
  localhost:5001/released-source-test-repo@sha256:b48e59ec0dc3281a33f0305a7b7fe0eb86f4c14f5597970c4a607cf811898e34 \
  | jq '.payload | @base64d | fromjson | select(.predicateType == "https://slsa.dev/verification_summary/v1")'
```

The VSA includes source level verification (`SLSA_SOURCE_LEVEL_3`), CVE scan results, and hermetic build confirmation (`SLSA_BUILD_LEVEL_3`).

**Note**: The image digest will differ for your build. Use `kubectl get release <release-name> -n default-tenant -o jsonpath='{.status.artifacts[0].target}'` to find the released image reference.

## What's Next

This walkthrough covered source track verification, vulnerability management, and hermetic builds. Future enhancements include:

**Dependency Levels in VSA**: Extend the VSA to include SLSA levels for dependencies, particularly base image provenance verification. This closes the gap where a Level 3 build uses a Level 1 base image.

**VEX Integration**: Support Vulnerability Exploitability eXchange (VEX) documents to mark CVEs as "not affected" or "under investigation" with structured metadata instead of manual exceptions.

**Transparency Log Integration**: Publish VSAs to Sigstore's transparency log (Rekor) for public verifiability and tamper detection.

For the fundamentals of trust boundaries, task verification, and artifact immutability, see [Part 1: Build and Release](part1-build-and-release.md). For the architectural rationale behind trusted artifacts and signing key isolation, see [Trusting Artifacts](trusting-artifacts.md).
