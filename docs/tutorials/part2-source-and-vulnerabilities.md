# Part 2: Source Track, Vulnerability Management, and Hermetic Builds

This guide covers advanced supply chain controls in Konflux: SLSA Source Track Level 3 verification, CVE management, and hermetic builds using `source-test-repo` as an example component.

Complete [Part 1: Build and Release](part1-build-and-release.md) before starting this guide.

---

## Why a Second Component?

Part 1 used Festoji to demonstrate baseline build isolation and SLSA Build Level 3. Festoji builds from a scratch container and tracks source solely through Git commit history, achieving SLSA Source Level 1.

Real-world production services require stronger guarantees:
- Base images (such as Red Hat UBI) contain system packages that require automated CVE scanning and leeway management.
- Source integrity beyond simple Git commits requires cryptographic provenance from source attestation tools.
- Complex builds require hermetic network isolation to prevent non-deterministic dependency tampering.

We use [`source-test-repo`](https://github.com/spork-madness/source-test-repo) to demonstrate these controls. It builds on `registry.access.redhat.com/ubi8/ubi:latest`, enrolls with `source-tool` via GitHub Actions, and configures hermetic dependency prefetching.

---

## Per-Application Conforma Policies

Different applications require different assurance levels. An internal development utility can tolerate lower source requirements than a customer-facing production service. Konflux supports per-application policies via `EnterpriseContractPolicy` (ECP) resources.

The `component-onboarding` chart creates an ECP in `managed-tenant` for each onboarded application. The release pipeline's `verify-conforma` task evaluates this policy before promotion.

Onboard `source-test-repo` requiring SLSA Source Level 3:

```bash
helm upgrade --install source-test-repo ./charts/component-onboarding \
  --set componentName=source-test-repo \
  --set gitRepoUrl=https://github.com/spork-madness/source-test-repo \
  --set release.policy.slsaSourceMinLevel="3"
```

In contrast, Festoji in Part 1 defaulted to Source Level 1:

```bash
helm upgrade --install festoji ./charts/component-onboarding \
  --set componentName=festoji \
  --set gitRepoUrl=https://github.com/YOUR_ORG/festoji
```

The chart templates these values into `managed-tenant/source-test-repo-ec-policy`:

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

Conforma evaluates rule data with the following precedence:
1. ECP `spec.ruleData` (highest precedence, overrides defaults)
2. Custom repository data sources (`data/rule_data.yml`)
3. Policy bundle default data
4. Hardcoded Rego rule defaults

Setting `slsa_source_min_level: "3"` in the ECP overrides the repository default of `"2"`.

---

## SLSA Source Track Level 3

SLSA Source Track measures source code management and integrity:
- **Level 1**: Version controlled (source exists in a VCS).
- **Level 2**: Verified history (VCS prevents rewriting commit history).
- **Level 3**: Retention and tamper resistance (enforced branch protection, mandatory reviews, immutable history).

Setting `slsaSourceMinLevel="3"` in the policy is an enforcement requirement, not an automatic grant. The repository must generate cryptographic source provenance proving branch protection rules were satisfied.

### Source-Tool Enrollment

`source-test-repo` enrolls with [source-tool](https://github.com/slsa-framework/source-tool) via a GitHub Actions workflow (`.github/workflows/compute_slsa_source.yaml`) running on pushes to `main`:

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
      - uses: slsa-framework/source-tool@v0.1.0
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
```

This workflow verifies branch protection settings, commit signatures, and review requirements, uploading a signed source attestation to the attestation authority.

### Build-Time Verification

During the Konflux build, the `verify-source` task queries the attestation authority using the repository URL and Git commit:

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

The task verifies the attestation and sets the task result `SLSA_SOURCE_LEVEL_ACHIEVED` (e.g. `SLSA_SOURCE_LEVEL_3`).

### Policy Enforcement Rules

Conforma evaluates custom Rego rules defined in `managed-context/policies/ec-policy-data/policy/custom/slsa_source_verification/slsa_source_verification.rego`:

1. **`min_level_achieved`**: Ensures `SLSA_SOURCE_LEVEL_ACHIEVED` meets or exceeds `slsa_source_min_level`.
2. **`result_provided`**: Ensures `verify-source` executed and produced an output.
3. **`parameters_match_git_clone`**: Confirms that the URL and commit SHA verified by `verify-source` match the values cloned by `git-clone`, preventing repository spoofing.
4. **`verified_all_materials`**: Ensures all Git materials in the build provenance were verified.

### VSA Output

Upon successful policy verification, `attach-summary-attestations` records the achieved level in the Verification Summary Attestation:

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
    "policy": {
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

Pull request builds achieve only Level 1 because pull request branches are mutable and unprotected. Level 2 and 3 require merges to protected branches.

---

## CVE Management

Konflux integrates vulnerability scanning into release gating using Conforma's `@minimal` policy collection. The `cve.cve_blockers` rule halts releases when critical or high-severity vulnerabilities with available fixes are detected.

### Scanning and Detection

The `trivy-sbom-scan` task scans the build SBOM against vulnerability databases and publishes an OCI attestation containing the results:

```bash
# Extract CVE findings from the attestation
cosign download attestation --allow-insecure-registry \
  ${IMAGE_URL_EXTERNAL}@${IMAGE_DIGEST} \
  | jq -r '.payload | @base64d | fromjson
    | select(.predicateType == "https://aquasecurity.github.io/trivy/report/v1")
    | .predicate.Results[].Vulnerabilities[]?
    | {VulnerabilityID, PkgName, InstalledVersion, FixedVersion, Severity}'
```

### The Leeway Mechanism

Halting releases immediately upon vulnerability disclosure can block emergency production releases. Conforma provides a **leeway mechanism** that grants a grace period for new CVEs based on their disclosure date:

```yaml
# Rule data configuring leeway days by severity
rule_data:
  cve_leeway_days:
    CRITICAL: 7
    HIGH: 14
    MEDIUM: 30
    LOW: 90
```

- A CVE disclosed 3 days ago with 7 days of leeway triggers a warning but allows the release to proceed.
- A CVE disclosed 10 days ago exceeds leeway, blocks the release, and generates a policy violation.

### Per-CVE Exceptions

When an upstream fix is unavailable or a vulnerability is not exploitable in your deployment, grant an explicit exception in `EnterpriseContractPolicy`:

```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: EnterpriseContractPolicy
metadata:
  name: source-test-repo-ec-policy
  namespace: managed-tenant
spec:
  sources:
    - name: Release Policies
      config:
        exclude:
          - "cve.cve_blockers:CVE-2026-1234"
          - "cve.cve_blockers:CVE-2026-5678"
```

The `exclude` array suppresses violations for specific CVE IDs, allowing the release pipeline to proceed.

### Volatile Configuration for Time-Bounded Exceptions

Permanent exceptions create security debt. Use `volatileConfig` to set time-bounded exceptions that expire automatically:

```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: EnterpriseContractPolicy
metadata:
  name: source-test-repo-ec-policy
  namespace: managed-tenant
spec:
  sources:
    - name: Release Policies
      volatileConfig:
        exclude:
          - value: "cve.cve_blockers:CVE-2026-1234"
            effectiveUntil: "2026-11-01T00:00:00Z"
            reference: "https://issues.redhat.com/browse/SEC-1234"
```

Once `effectiveUntil` passes, Conforma stops suppressing the violation and blocks subsequent releases until the package is updated.

---

## Hermetic Builds

Builds with unconstrained network access risk non-determinism and supply chain tampering: an upstream package registry outage breaks builds, and a compromised repository can inject malicious dependencies. Hermetic builds eliminate these risks by isolating build containers from the network after dependencies are pre-fetched.

Konflux supports hermetic builds via the `hermetic` pipeline parameter. When enabled, build containers execute with network access disabled via Kubernetes NetworkPolicy.

### How It Works

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: source-test-repo-build
spec:
  params:
    - name: hermetic
      value: "true"
    - name: prefetch-input
      value: "gomod"
```

Execution steps:
1. **`clone-repository`**: Clones the source repository.
2. **`prefetch-dependencies`**: Analyzes dependency manifests (`go.mod`, `package-lock.json`, `requirements.txt`) and downloads dependencies into an immutable Trusted Artifact.
3. **`build-container` (`buildah-oci-ta`)**: Builds the container image using only cloned source and pre-fetched dependencies. Outbound network access is disabled.
4. **Attestation & Scan**: Trivy and Chains generate SBOMs, scan reports, and provenance.

Toolchains are configured to use the local artifact cache exclusively:

```bash
# Go builds
export GOPROXY=file:///trusted-artifacts/go-modules
export GOMODCACHE=/trusted-artifacts/go-modules

# Node.js builds
npm config set cache /trusted-artifacts/npm-cache
npm ci --offline
```

### Configuration

Enable hermetic mode in `.tekton/` pipeline definitions using `yq`:

```bash
for f in .tekton/*.yaml; do
  yq -i '(.spec.pipelineSpec.params[] | select(.name == "hermetic")).default = "true"' "$f"
  yq -i '(.spec.pipelineSpec.params[] | select(.name == "prefetch-input")).default = "gomod"' "$f"
done
git add .tekton/ && git commit -m "build: Enable hermetic builds" && git push
```

### Policy Enforcement

The `@minimal` collection includes `hermetic_build_task.build_task_hermetic`. If a build task listed in `required_hermetic_tasks` executes with `hermetic=false`, Conforma halts the release with a policy violation:

```yaml
rule_data:
  required_hermetic_tasks:
    - buildah
    - buildah-oci-ta
    - buildah-remote
    - buildah-remote-oci-ta
```

### Verifying Hermetic Execution

Confirm hermetic execution in the build provenance:

```bash
cosign download attestation --allow-insecure-registry \
  localhost:5001/konflux-festoji@sha256:... \
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

---

## Putting It All Together: End-to-End Walkthrough

Deploy `source-test-repo` with Source Level 3, CVE scanning, and hermetic builds:

### 1. Onboard Component
```bash
helm upgrade --install source-test-repo ./charts/component-onboarding \
  --set componentName=source-test-repo \
  --set gitRepoUrl=https://github.com/spork-madness/source-test-repo \
  --set release.policy.slsaSourceMinLevel="3"
```

### 2. Enable Hermetic Builds in Component Repo
```bash
for f in .tekton/*.yaml; do
  yq -i '(.spec.pipelineSpec.params[] | select(.name == "hermetic")).default = "true"' "$f"
  yq -i '(.spec.pipelineSpec.params[] | select(.name == "prefetch-input")).default = "gomod"' "$f"
done
git commit -am "build: Enable hermetic mode" && git push origin main
```

### 3. Monitor Build Execution
```bash
kubectl get pipelineruns -n default-tenant -w
```

### 4. Inspect Source Verification and CVE Reports
```bash
PIPELINERUN=$(kubectl get pipelineruns -n default-tenant \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')

# Check verify-source result
kubectl get taskrun -n default-tenant \
  -l tekton.dev/pipelineRun=$PIPELINERUN \
  -l tekton.dev/pipelineTask=verify-source \
  -o jsonpath='{.items[0].status.results[?(@.name=="SLSA_SOURCE_LEVEL_ACHIEVED")].value}'

# Check Trivy scan logs
kubectl logs -n default-tenant \
  -l tekton.dev/pipelineRun=$PIPELINERUN \
  -l tekton.dev/pipelineTask=trivy-sbom-scan
```

### 5. Trigger Release
```bash
SNAPSHOT=$(kubectl get snapshots -n default-tenant \
  -l appstudio.openshift.io/application=source-test-repo \
  --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)

cat <<EOF | kubectl apply -f -
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

### 6. Verify the Released VSA
```bash
cosign download attestation \
  --allow-insecure-registry \
  localhost:5001/released-source-test-repo@sha256:... \
  | jq '.payload | @base64d | fromjson | select(.predicateType == "https://slsa.dev/verification_summary/v1")'
```

The VSA confirms `SLSA_BUILD_LEVEL_3` and `SLSA_SOURCE_LEVEL_3`.

---

## Related Documentation

- **[Part 1: Build and Release](part1-build-and-release.md)**: Onboarding basics, build isolation, and SLSA Build L3 fundamentals.
- **[Trusting Artifacts](../reference/trusting-artifacts.md)**: Threat model for task trust, OCI Trusted Artifacts, and signing key separation.
- **[CI Workload Identity Patterns](../reference/workload-identity-patterns.md)**: The 5 classes of workload identity use cases.
- **[Dual-Gated Release Guide](../reference/dual-gated-release.md)**: Model 2 release gating in `managed-tenant`.
