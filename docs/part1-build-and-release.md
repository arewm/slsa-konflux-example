# Part 1: Build and Release

This walkthrough demonstrates end-to-end SLSA compliance using Konflux and the Festoji example component. It covers onboarding, building, policy validation, and releasing artifacts with full trust boundary separation.

For cluster setup and prerequisites, see the [main README](../README.md#pre-requisites). This guide assumes you have deployed Konflux and completed the prerequisites script.

## Onboard Your Component

Konflux separates infrastructure configuration from component onboarding through two helm charts. The platform configuration installs once per cluster to establish the trust boundaries, signing keys, and policies. Component onboarding creates the application, integration tests, and release plan for each component you build.

Both charts operate across two namespaces:

- `default-tenant`: The unprivileged tenant namespace where builds occur (created by the Konflux operator)
- `managed-tenant`: The privileged managed namespace where releases are validated and signed (created by the prerequisites script)

### Install Platform Configuration

Install the platform configuration once per cluster:

```bash
helm install platform ./charts/platform-config
```

This creates the EnterpriseContractPolicy for SLSA3 validation, RoleBindings for admin access, ServiceAccounts for release pipeline execution, and signing keys for release attestation signing.

### Onboard Festoji

Before onboarding, fork the festoji repository to your GitHub account. Navigate to https://github.com/lcarva/festoji and click Fork. Select your user or organization and create the fork. Note your fork URL for the installation step: `https://github.com/ORGANIZATION/festoji`.

Install the GitHub App you created during Konflux deployment on your forked repository. Navigate to https://github.com/settings/apps and find the GitHub App from the webhook configuration step. Click the app name, then Install App. Select your user or organization, choose "Only select repositories", and select your festoji fork. Click Install.

The GitHub App webhook sends pull request and push events to your Konflux cluster's Pipelines as Code controller, which triggers pipeline runs automatically.

Now install the component-onboarding chart for festoji:

```bash
export FORK_ORG="ORGANIZATION"
helm install festoji ./charts/component-onboarding \
  --set applicationName=festoji \
  --set gitRepoUrl=https://github.com/${FORK_ORG}/festoji
```

This creates the Application and Component resources, IntegrationTestScenarios (policy-pr and policy-push), and ReleasePlan with ReleasePlanAdmission.

Verify the component was onboarded:

```bash
kubectl get component festoji -n default-tenant
kubectl get integrationtestscenario -n default-tenant
kubectl get repository -n default-tenant
```

Build-service creates a pull request in your forked repository with Tekton pipeline definitions. Check your GitHub repository for the PR titled something like "Konflux update ORGANIZATION/festoji". This PR contains the `.tekton/` directory with pipeline definitions required for builds. Your component will not build until you merge this PR.

## SLSA Build Level 3

SLSA Build Level 3 requires that builds be isolated from each other, that signing keys remain inaccessible to build processes, and that the build platform uses only trusted, verified tasks to produce artifacts. Konflux achieves Build L3 by default through three architectural decisions.

First, Kubernetes pod isolation ensures that each build runs in an ephemeral pod that is destroyed after completion. Tekton creates a new pod for every PipelineRun, which prevents one build from accessing another build's filesystem, environment variables, or process space. This addresses the SLSA requirement that builds be isolated from each other.

Second, namespace separation prevents builds from accessing signing keys. Builds run in the tenant namespace (default-tenant), while signing keys exist only in the managed namespace (managed-tenant). Kubernetes RBAC prevents tenant workloads from reading secrets in the managed namespace. This ensures that even if a build task is compromised, it cannot access the cryptographic material used to sign attestations during release.

Third, Conforma's `trusted_tasks` package validates that every task in the build pipeline comes from an approved Tekton bundle. The Enterprise Contract policy includes a list of acceptable bundles, and at release time, Conforma verifies that each task in the build provenance matches an entry in that list. This prevents an attacker from injecting a malicious task that claims to have produced a legitimate artifact.

These three mechanisms combine to satisfy the isolation, non-falsifiable, and hermetic build requirements of SLSA Build Level 3. The signing keys are in a namespace the build cannot access, the build runs in an isolated ephemeral environment, and the policy verification step ensures that only trusted tasks were used to produce the artifact. For a detailed threat model, see [Trusting Artifacts](trusting-artifacts.md).

## Build Pipeline

After you merge the build-service PR, you can trigger builds by opening pull requests or pushing to the main branch. The `.tekton/` directory contains two pipeline definitions: one for pull request events and one for push events.

When you open a pull request, Pipelines as Code receives a webhook notification from GitHub and creates a PipelineRun in the tenant namespace. The build pipeline runs the following tasks in order:

1. **init**: Initialize workspace and set up build parameters
2. **git-clone**: Clone the source repository at the specific commit SHA
3. **verify-source**: Validate the source repository against its SLSA source policy
4. **prefetch-dependencies**: Download dependencies for hermetic builds
5. **build-container**: Build the container image using buildah
6. **build-image-index**: Create multi-platform image manifest
7. **clair-scan**: Scan the image for vulnerabilities using Clair
8. **trivy-sbom-scan**: Scan the SBOM for vulnerabilities using Trivy
9. **sast-shell-check**: Run static analysis on shell scripts
10. **apply-tags**: Apply git-based tags to the built image

After the build completes, Tekton Chains automatically generates SLSA provenance attestations. Chains watches for completed TaskRuns and PipelineRuns, extracts the artifacts produced, and generates signed attestations describing how those artifacts were built. The provenance includes all tasks executed, their parameters, the source code commit, base images, and other inputs.

Monitor a build in progress:

```bash
# Watch pipeline runs
tkn pipelinerun list -n default-tenant

# Follow logs of the latest build
tkn pipelinerun logs -n default-tenant -f
```

## Inspect Build Artifacts

Once your pipeline run completes, you can inspect the built container image and its attached artifacts. The image includes an SBOM, signatures, attestations, and vulnerability reports.

### Getting the Image Reference

First, get the output image reference from your completed build PipelineRun:

```bash
# Find your latest build PipelineRun (filter by type=build to exclude policy checks)
PIPELINERUN=$(kubectl get pipelinerun -n default-tenant \
  -l pipelines.appstudio.openshift.io/type=build \
  --sort-by=.metadata.creationTimestamp \
  -o name | tail -1)

# Get the IMAGE_URL and IMAGE_DIGEST from the PipelineRun results
IMAGE_URL=$(kubectl get ${PIPELINERUN} -n default-tenant \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}')
IMAGE_DIGEST=$(kubectl get ${PIPELINERUN} -n default-tenant \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}')

# Convert internal registry service name to external localhost address
IMAGE_URL_EXTERNAL=$(echo ${IMAGE_URL} | sed 's/registry-service.kind-registry/localhost:5001/')

echo "Image URL: ${IMAGE_URL_EXTERNAL}"
echo "Image Index Digest: ${IMAGE_DIGEST}"
```

The `IMAGE_DIGEST` is the digest of the image index, which is the multi-platform manifest. To inspect platform-specific artifacts, you need the image manifest digest for your platform:

```bash
# Extract the manifest digest for the first platform in the index
MANIFEST_DIGEST=$(skopeo inspect --tls-verify=false --raw \
  docker://${IMAGE_URL_EXTERNAL} | jq -r '.manifests[0].digest')

echo "Image Manifest Digest: ${MANIFEST_DIGEST}"
```

Konflux attaches different artifacts at different levels. SARIF scan results attach to the image index, while Trivy and Clair vulnerability reports, SBOMs, and signatures attach to the platform-specific image manifest.

The local registry uses a self-signed certificate. For the commands below, we skip TLS verification using tool-specific flags.

### Inspecting with Different Tools

<details>
<summary><b>Using skopeo and podman</b></summary>

[skopeo](https://github.com/containers/skopeo) is a command-line tool for inspecting and copying container images. [podman](https://podman.io/) is a container engine that can pull and run images.

Inspect the image index:

```bash
# View the raw image index (multi-platform manifest)
skopeo inspect --tls-verify=false --raw docker://${IMAGE_URL_EXTERNAL}

# View parsed image details (requires platform override for non-linux hosts)
skopeo inspect --tls-verify=false \
  --override-arch arm64 --override-os linux \
  docker://${IMAGE_URL_EXTERNAL}
```

List image tags in the repository:

```bash
# Extract repository from IMAGE_URL
REPO=$(echo ${IMAGE_URL_EXTERNAL} | cut -d: -f1)
skopeo list-tags --tls-verify=false docker://${REPO}
```

Pull and run the image:

```bash
# Pull the image
podman pull --tls-verify=false ${IMAGE_URL_EXTERNAL}

# Run a container from the image
podman run --rm ${IMAGE_URL_EXTERNAL}
```

Inspect attached artifacts using curl:

```bash
# Extract repository path for curl commands (everything after registry address)
REPO_PATH=$(echo ${IMAGE_URL} | sed 's|registry-service.kind-registry.svc.cluster.local/||')

# Artifacts attached to the image index
curl -sk https://localhost:5001/v2/${REPO_PATH}/referrers/${IMAGE_DIGEST} | jq

# Artifacts attached to the platform-specific manifest
curl -sk https://localhost:5001/v2/${REPO_PATH}/referrers/${MANIFEST_DIGEST} | jq
```

</details>

<details>
<summary><b>Using crane</b></summary>

[crane](https://github.com/google/go-containerregistry/blob/main/cmd/crane/doc/crane.md) is a tool from Google for interacting with remote container images and registries.

Inspect the image:

```bash
# View the image index manifest
crane manifest ${IMAGE_URL_EXTERNAL} --insecure

# View image config
crane config ${IMAGE_URL_EXTERNAL} --insecure
```

List image tags in the repository:

```bash
# Extract repository from IMAGE_URL
REPO=$(echo ${IMAGE_URL_EXTERNAL} | cut -d: -f1)
crane ls ${REPO} --insecure
```

Get image digest:

```bash
crane digest ${IMAGE_URL_EXTERNAL} --insecure
```

Pull the image:

```bash
# Export to podman/docker
crane pull ${IMAGE_URL_EXTERNAL} - --insecure | podman load

# Or pull to a tarball
crane pull ${IMAGE_URL_EXTERNAL} image.tar --insecure
```

</details>

<details>
<summary><b>Using oras</b></summary>

[oras](https://oras.land/) is the OCI Registry As Storage tool, which supports the OCI Referrers API for discovering attached artifacts like SBOMs and attestations.

When using `oras` with the local registry, use `127.0.0.1:5001` instead of `localhost:5001`. The `oras` tool defaults to HTTP for `localhost` but uses HTTPS for IP addresses.

```bash
# Convert IMAGE_URL to use 127.0.0.1 for oras
IMAGE_URL_ORAS=$(echo ${IMAGE_URL_EXTERNAL} | sed 's/localhost/127.0.0.1/')
REPO=$(echo ${IMAGE_URL_ORAS} | cut -d: -f1)

echo "Image URL for oras: ${IMAGE_URL_ORAS}"
```

Inspect the image manifest:

```bash
# View the image index manifest
oras manifest fetch ${IMAGE_URL_ORAS} --insecure

# Pretty-print the manifest
oras manifest fetch ${IMAGE_URL_ORAS} --insecure --pretty
```

List image tags in the repository:

```bash
oras repo tags ${REPO} --insecure
```

Discover attached artifacts using the OCI Referrers API:

```bash
# Discover artifacts attached to the image index
oras discover ${REPO}@${IMAGE_DIGEST} --insecure

# Discover artifacts attached to the platform-specific manifest
# (This is where vulnerability reports are attached)
oras discover ${REPO}@${MANIFEST_DIGEST} --insecure
```

Example output showing the artifact tree:

```
127.0.0.1:5001/default-tenant/festoji@sha256:fe4b4eb7...
├── application/vnd.trivy.report+json
│   └── sha256:614b0d13...
└── application/vnd.redhat.clair-report+json
    └── sha256:a3cc9dbd...
```

Pull specific artifacts:

```bash
# Pull all artifacts attached to the manifest
oras pull ${REPO}@${MANIFEST_DIGEST} --insecure

# Pull only artifacts of a specific type
oras pull ${REPO}@${MANIFEST_DIGEST} --insecure \
  --artifact-type application/vnd.cyclonedx+json
```

</details>

### Understanding Attached Artifacts

The image built by Konflux includes various attached artifacts at different levels.

Artifacts on the image index (`IMAGE_DIGEST`):

- **SARIF Reports**: Security scan results in SARIF format

Artifacts on the image manifest (`MANIFEST_DIGEST`) for each platform:

- **SBOM**: Software Bill of Materials listing all dependencies
- **Signatures**: Cryptographic signatures from Tekton Chains
- **Attestations**: SLSA provenance showing how the image was built
- **Trivy Reports**: Vulnerability scan results from Trivy
- **Clair Reports**: Vulnerability scan results from Clair

To see all artifacts, inspect both the image index and the platform-specific manifest digests.

Konflux uses a mixed approach for storing artifacts due to varying tool support for the OCI Referrers API (OCI Distribution Spec 1.1.0+):

- **OCI Referrers API (modern)**: Vulnerability scanners (Trivy, Clair) and SARIF reports use the `/v2/<repo>/referrers/<digest>` endpoint. Tools like `oras discover` and `curl` can query this API to find these artifacts.

- **Tag-based (backwards compatible)**: Tekton Chains stores signatures, attestations, and SBOMs as special tags like `sha256-<digest>.sig`, `sha256-<digest>.att`, and `sha256-<digest>.sbom`. Tools like `cosign` and `crane ls` can discover these by listing repository tags.

To see all artifacts, use both approaches: the OCI Referrers API (`curl` or `oras discover`) and tag listing (`crane ls` or `skopeo list-tags`).

### Viewing SLSA Provenance

To view the attestations attached to your built image, use `cosign` (requires cosign v2+):

```bash
# View the attestation tree (shows provenance, signatures, and SBOM)
cosign tree localhost:5001/default-tenant/festoji@${IMAGE_DIGEST}

# Download and view the SLSA provenance attestation
cosign download attestation localhost:5001/default-tenant/festoji@${IMAGE_DIGEST} \
  | jq -r '.payload' | base64 -d | jq .

# View key provenance fields
cosign download attestation localhost:5001/default-tenant/festoji@${IMAGE_DIGEST} \
  | jq -r '.payload' | base64 -d \
  | jq '.predicateType, .predicate.buildType, .predicate.builder.id'
```

The provenance attestation includes the predicate type (`https://slsa.dev/provenance/v0.2`), build type (`tekton.dev/v1/PipelineRun`), builder ID (the Tekton Chains instance that generated the provenance), build configuration (all tasks executed, their parameters, and results), and materials (source code commit, base images, and other inputs).

### Viewing the SBOM

The buildah task automatically generates an SBOM during the container build process. You can download and inspect it:

```bash
# Download the SBOM (generated by buildah during build)
cosign download sbom localhost:5001/default-tenant/festoji@${IMAGE_DIGEST} > sbom.json

# View SBOM metadata
jq '.SPDXID, .spdxVersion, .creationInfo' sbom.json

# View packages included in the image
jq '.packages[] | {name: .name, version: .versionInfo}' sbom.json
```

The SBOM is in SPDX 2.3 format and includes all packages and dependencies in the container image, SHA256 checksums for verification, license information, and package relationships.

## Integration Tests

Building an image is only the first step. Konflux also validates builds against policy before release. Merge your onboarding PR to trigger the on-push pipeline. Let the build run, and then examine how Konflux validates it.

The `.tekton` directory contains two different PipelineRuns: one for PR events and another for push events. By default, these are almost identical, so the build you see now will largely be the same as the build you saw previously. This means that any build-time checks (including clair-scan and sast-shell-check) will still run on every build.

After a successful build, Tekton Chains generates and signs SLSA provenance attestations. The build context determines which integration tests run.

The helm chart creates two IntegrationTestScenario resources:

**policy-pr** (pull_request context): Validates PR builds at source level 1. PR source branches are not protected, so they cannot achieve higher source levels. This validates whether the resulting push will succeed.

**policy-push** (push context): Validates push builds with the same strict policy used during release. Requires source level 2+ with source-tool provenance.

Check integration test results:

```bash
# View integration test scenarios
kubectl get integrationtestscenario -n default-tenant

# Find snapshots for your builds
kubectl get snapshots -n default-tenant --sort-by=.metadata.creationTimestamp

# Check test results on a snapshot
kubectl get snapshot <SNAPSHOT_NAME> -n default-tenant \
  -o jsonpath='{.metadata.annotations.test\.appstudio\.openshift\.io/status}' | jq .

# View PipelineRuns for specific test scenarios
kubectl get pipelineruns -n default-tenant -l test.appstudio.openshift.io/scenario=policy-pr
kubectl get pipelineruns -n default-tenant -l test.appstudio.openshift.io/scenario=policy-push
```

Source verification at level 2+ only applies to push builds and releases. source-tool only generates provenance for pushes to protected branches, not PRs.

## Release Pipeline

When you merge to the main branch, a push event triggers a new PipelineRun. The build completes and Chains signs the image. The system creates a Snapshot representing the built artifacts, then runs the policy integration test to validate it. If the test passes, a Release resource is created, triggering the release pipeline in the managed namespace (`managed-tenant`).

Release pipelines run in managed namespaces to isolate privileged credentials from tenant developers. The Release that was auto-created references a ReleasePlan in the tenant namespace which is mapped to a ReleasePlanAdmission in the managed namespace. When the Release is created, a new Tekton pipeline runs as specified in that ReleasePlanAdmission.

View your release configuration:

```bash
# View the ReleasePlan in the tenant namespace
kubectl get releaseplan festoji-release -n default-tenant -o yaml

# View the ReleasePlanAdmission in the managed namespace
kubectl get releaseplanadmission festoji-release-admission -n managed-tenant -o yaml

# View releases
kubectl get releases -n default-tenant

# Check release pipeline runs
kubectl get pipelineruns -n managed-tenant -l release.appstudio.openshift.io/name=<RELEASE_NAME>
```

The release pipeline executes several tasks in the managed namespace:

1. **verify-conforma**: Re-evaluates all policies against the build provenance using Conforma
2. **apply-mapping**: Maps artifacts to destination registries based on the release plan
3. **push-snapshot**: Publishes the image to the release registry
4. **attach-vsa**: Generates and signs Verification Summary Attestations (VSAs)

The `verify-conforma` task validates that all SLSA Build L3 requirements are met, all build tasks came from trusted bundles, attestations are properly signed, and no policy violations exist. When the policy check passes, the release pipeline continues to push the image. When the policy check fails, the release pipeline halts before pushing images, the Release is marked as failed, and policy violation details are available in task logs.

After policy verification succeeds, the `push-snapshot` task publishes the built image to the destination registry specified in the mapping. The `attach-vsa` task then generates VSAs containing the verification results and signs them with the release signing key.

Example VSA predicate:

```json
{
  "verifier": { "id": "https://conforma.dev/cli" },
  "timeVerified": "2026-01-15T10:30:00Z",
  "resourceUri": "localhost:5001/default-tenant/festoji@sha256:abc123...",
  "policy": { "uri": "oci::quay.io/enterprise-contract/ec-release-policy:konflux" },
  "verificationResult": "PASSED",
  "verifiedLevels": ["SLSA_BUILD_LEVEL_3", "SLSA_SOURCE_LEVEL_1"]
}
```

For Festoji, the VSA includes `SLSA_BUILD_LEVEL_3` because Konflux achieves Build L3 by default, and `SLSA_SOURCE_LEVEL_1` because Festoji is not enrolled with source-tool and relies only on version control.

Get the released image URL from the Release status:

```bash
# Get the release name from your earlier command
RELEASE_NAME=$(kubectl get releases -n default-tenant --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d'/' -f2)

# Extract the released image URL
RELEASE_IMAGE_URL=$(kubectl get release ${RELEASE_NAME} -n default-tenant \
  -o jsonpath='{.status.processing.releasePlanAdmission.applications[0].repository}')
RELEASE_IMAGE_DIGEST=$(kubectl get release ${RELEASE_NAME} -n default-tenant \
  -o jsonpath='{.status.processing.releasePlanAdmission.applications[0].digest}')

echo "Released Image: ${RELEASE_IMAGE_URL}@${RELEASE_IMAGE_DIGEST}"
```

Verify the release completed successfully:

```bash
kubectl get release ${RELEASE_NAME} -n default-tenant \
  -o jsonpath='{.status.conditions[?(@.type=="Released")].status}'
# Should output: True
```

View released images and their attestations:

```bash
# Check released image artifacts
cosign tree ${RELEASE_IMAGE_URL}@${RELEASE_IMAGE_DIGEST}

# Download attestation from released image
cosign download attestation ${RELEASE_IMAGE_URL}@${RELEASE_IMAGE_DIGEST} \
  | jq -r '.payload' | base64 -d | jq .
```

The released image includes the same attestations as the build image, ensuring provenance is preserved through the release process.

You can manually create a Release to re-release an existing Snapshot without rebuilding. This is useful for testing the release pipeline without rebuilding, re-releasing after fixing release pipeline configuration, or releasing an older snapshot:

```bash
# Create a Release resource
kubectl create -f - <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  generateName: festoji-manual-
  namespace: default-tenant
spec:
  releasePlan: festoji-release
  snapshot: <SNAPSHOT_NAME>
EOF
```

## Consumer Verification

Released artifacts include signed Verification Summary Attestations (VSAs) that consumers can use to verify the artifact meets SLSA requirements before use.

List all attestations attached to a released image:

```bash
cosign tree <registry>/<image>:<tag>
```

Verify the SLSA VSA with the release signing public key:

```bash
cosign verify-attestation \
  --key <public-key-or-url> \
  --type https://slsa.dev/verification_summary/v1 \
  --insecure-ignore-tlog \
  <registry>/<image>:<tag>
```

Download and inspect the VSA predicate:

```bash
cosign download attestation <registry>/<image>:<tag> \
  --predicate-type https://slsa.dev/verification_summary/v1 | jq '.payload | @base64d | fromjson | .predicate'
```

For fail-safe verification:

```bash
cosign verify-attestation \
  --key <public-key> \
  --type https://slsa.dev/verification_summary/v1 \
  --insecure-ignore-tlog \
  <image> || { echo "VSA verification failed!"; exit 1; }
```

VSAs are stored as OCI attestations co-located with the artifact image. Consumers retrieve them using `cosign`. Attestations are cryptographically signed with the release signing key.

The release pipeline prevents publication of artifacts that fail policy verification. The `verify-conforma` task evaluates all policies against the build provenance first. If verification fails, the pipeline stops and `push-snapshot` never runs. Only after successful verification are artifacts published to the destination registry. Then `attach-vsa` signs and attaches VSAs to the published images. This ordering is enforced by pipeline task dependencies (`runAfter` constraints).

For a standalone example of the verification flow, see [mild-to-wild-samples](https://github.com/arewm/mild-to-wild-samples).

## Understanding the Policy

Signing alone is insufficient. Tekton Chains signs whatever tasks claim to produce, including artifacts from compromised tasks (see [Trusting Artifacts](trusting-artifacts.md)). Conforma serves as a policy engine to verify the complete build chain before releasing images.

The helm chart creates an EnterpriseContractPolicy resource that defines what must be validated:

```bash
# View the policy configuration
kubectl get enterprisecontractpolicy ec-policy -n managed-tenant -o yaml
```

The policy contains three key components.

**Policy Rules** (`spec.sources.policy`):

- **Base policy**: `oci::quay.io/enterprise-contract/ec-release-policy:konflux`
- Includes the `@slsa3` policy collection which validates SLSA Build Level 3 requirements, trusted task verification (all tasks from approved bundles), signature validation, and build isolation and provenance completeness

**Policy Data** (`spec.sources.data`):

- **Local rule data**: `github.com/arewm/slsa-konflux-example//managed-context/policies/ec-policy-data/data`
  - Defines allowed registries, required labels, disallowed packages
  - CVE remediation timeframes (critical: 6 days, high: 29 days)
  - Release schedule restrictions (no releases on Fridays/weekends/holidays)
  - See `managed-context/policies/ec-policy-data/data/rule_data.yml` for full configuration
- **Acceptable bundles**: `oci::quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest`
  - List of trusted Tekton task bundles allowed in builds
  - Updated automatically when new task versions are published

**Signing Key** (`spec.publicKey`):

- **Key location**: `k8s://tekton-pipelines/public-key`
- Used to verify Tekton Chains signatures on attestations

The policy includes 104 policy rules across three collections:

| Collection | Purpose | Example Rules |
|------------|---------|---------------|
| @minimal | Basic security hygiene | No disallowed packages, required labels present |
| @slsa3 | SLSA Build Level 3 | Trusted tasks only, isolated builds, complete provenance |
| @slsa_source | Source verification | Source level 2+, protected branches, code review |

The `verify-conforma` task in the release pipeline validates all of these requirements:

```bash
# View verify-conforma task results
kubectl get taskruns -n managed-tenant -l tekton.dev/pipelineTask=verify-conforma

# Check task logs for detailed policy evaluation
kubectl logs -n managed-tenant <VERIFY_CONFORMA_TASKRUN> --container=report
```

When the policy check passes, all SLSA Build L3 requirements are met, all build tasks came from trusted bundles, attestations are properly signed, no policy violations exist, and the release pipeline continues to push the image.

When the policy check fails, the release pipeline halts before pushing images, the Release is marked as failed, and policy violation details are available in task logs.

### Demonstrating Policy Enforcement

The policy evaluation can be demonstrated in two scenarios: a passing release (the default) and a failing release (by tightening the policy). This is useful for understanding how policy enforcement works and for educational demonstrations.

**Scenario 1: Policy Pass**

A normal release with a passing policy produces a full green pipeline. After a successful `helm install` and build, trigger a release as described above. The `verify-conforma` task will pass, `push-snapshot` will publish the image, and `attach-vsa` will sign and attach the Verification Summary Attestations.

**Scenario 2: Policy Fail**

You can tighten the policy on-cluster to force a failure without modifying git. The `ruleData` field in the EnterpriseContractPolicy spec overrides any values fetched from git-based data sources.

For example, the current policy requires source level 2. The `verify-source` task achieves level 3. To demonstrate a failure, require level 4 (which does not exist in the SLSA spec and therefore cannot be achieved):

```bash
# Override the minimum required source level on-cluster
kubectl patch enterprisecontractpolicy ec-policy -n managed-tenant \
  --type=json -p '[
    {"op": "add", "path": "/spec/sources/0/ruleData",
     "value": {"slsa_source_min_level": "4"}}
  ]'
```

Then trigger a release manually against an existing snapshot:

```bash
SNAPSHOT=$(kubectl get snapshots -n default-tenant \
  --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)

kubectl create -f - <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  generateName: festoji-policy-fail-demo-
  namespace: default-tenant
spec:
  releasePlan: festoji-release
  snapshot: ${SNAPSHOT}
EOF
```

The `verify-conforma` task will fail with a message indicating the source level achieved versus the level required:

```
FAILURE: slsa_source_verification.required_level_achieved
  verify-source task achieved SLSA_SOURCE_LEVEL_3,
  but minimum required level is 4
```

The `push-snapshot` task is skipped because it depends on `verify-conforma` succeeding. The artifact is never published.

After capturing the results, revert the policy:

```bash
kubectl patch enterprisecontractpolicy ec-policy -n managed-tenant \
  --type=json -p '[{"op": "remove", "path": "/spec/sources/0/ruleData"}]'
```

## Next Steps

This walkthrough covered the basic build and release flow with SLSA compliance. You built a container image, validated it against policy, and released it with signed VSAs.

For advanced topics including source track details, vulnerability management, and customizing policies, see [Part 2: Source and Vulnerabilities](part2-source-and-vulnerabilities.md).

To adapt Konflux for your own projects, install the platform configuration once per cluster and then use the component-onboarding chart for each component you want to build. Customize the Enterprise Contract policy in `managed-context/policies/ec-policy-data/data/rule_data.yml` to match your security requirements.

For complete platform documentation, see [Konflux Documentation](https://konflux-ci.dev/docs/). For the SLSA specification, see [slsa.dev](https://slsa.dev/spec/). For policy validation details, see [Conforma](https://conforma.dev).
