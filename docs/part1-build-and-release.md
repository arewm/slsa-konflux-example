# Part 1: Build and Release

This walkthrough demonstrates end-to-end SLSA compliance using Konflux and the Festoji example component. It covers onboarding, building, policy validation, and releasing artifacts with full trust boundary separation.

For cluster setup and prerequisites, see the [main README](../README.md#pre-requisites). This guide assumes you have deployed Konflux and completed the prerequisites script.

## Onboard Your Component

Before running this walkthrough, complete the cluster setup and prerequisites as described in the [main README](../README.md#pre-requisites). This includes deploying Konflux, installing the platform configuration chart, and setting up the managed-tenant namespace.

### Onboard Festoji

Before onboarding, fork the festoji repository to your GitHub account. Navigate to https://github.com/lcarva/festoji and click Fork. Select your user or organization and create the fork. Note your fork URL for the installation step: `https://github.com/ORGANIZATION/festoji`.

Install the GitHub App you created during Konflux deployment on your forked repository. Navigate to https://github.com/settings/apps and find the GitHub App from the webhook configuration step. Click the app name, then Install App. Select your user or organization, choose "Only select repositories", and select your festoji fork. Click Install.

The GitHub App webhook sends pull request and push events to your Konflux cluster's Pipelines as Code controller, which triggers pipeline runs automatically.

Now install the component-onboarding chart for festoji:

```bash
export FORK_ORG="ORGANIZATION"
helm upgrade --install festoji ./charts/component-onboarding \
  --set componentName=festoji \
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

Third, Conforma's `trusted_tasks` package validates that every task in the build pipeline comes from an approved Tekton bundle. The Conforma policy includes a list of acceptable bundles, and at release time, Conforma verifies that each task in the build provenance matches an entry in that list. This prevents an attacker from injecting a malicious task that claims to have produced a legitimate artifact.

These three mechanisms combine to satisfy the isolation, non-falsifiable, and hermetic build requirements of SLSA Build Level 3. The signing keys are in a namespace the build cannot access, the build runs in an isolated ephemeral environment, and the policy verification step ensures that only trusted tasks were used to produce the artifact. For a detailed threat model, see [Trusting Artifacts](trusting-artifacts.md).

## Build Pipeline

After you merge the build-service PR, you can trigger builds by opening pull requests or pushing to the main branch. The `.tekton/` directory contains two pipeline definitions: one for pull request events and one for push events.

When you open a pull request, Pipelines as Code receives a webhook notification from GitHub and creates a PipelineRun in the tenant namespace. The build pipeline runs the following tasks in order:

1. **init**: Initialize workspace and set up build parameters
2. **clone-repository**: Clone the source repository at the specific commit SHA
3. **prefetch-dependencies**: Download dependencies for hermetic builds
4. **build-container**: Build the container image using buildah
5. **verify-source**: Validate the source repository against its SLSA source policy
6. **build-image-index**: Create multi-platform image manifest
7. **trivy-sbom-scan**: Scan the SBOM for vulnerabilities using Trivy (enabled by default)
8. **clair-scan**: Scan the image for vulnerabilities using Clair (disabled by default, set `enable-clair-scan` to `"true"` to enable)
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

The local registry uses a self-signed certificate and requires authentication. For the commands below, we skip TLS verification using tool-specific flags. To authenticate CLI tools with the internal registry:

```bash
# Extract registry credentials and login
REGCRED=$(kubectl get secret regcred-internal-registry -n default-tenant \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
REG_USER=$(echo "$REGCRED" | jq -r '.auths["registry-service.kind-registry"].auth' | base64 -d | cut -d: -f1)
REG_PASS=$(echo "$REGCRED" | jq -r '.auths["registry-service.kind-registry"].auth' | base64 -d | cut -d: -f2)

cosign login localhost:5001 -u "$REG_USER" -p "$REG_PASS"
```

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

<details>
<summary>Example oras discover output showing OCI referrers</summary>

```
127.0.0.1:5001/konflux-festoji@sha256:db12fe166b18e3d881ebbef06569d0bce385541dac3a177379bf5c7b58f9c3bc
└── application/sarif+json
    └── sha256:b585d36a4b4f13f33d4785fe5ee704c0f93df825cfc12115eaac753c3ff7c3f5
        └── [annotations]
            └── org.opencontainers.image.created: "2026-05-04T17:18:59Z"
```

This shows SARIF security scan results attached using the OCI Referrers API. Vulnerability reports from Trivy and Clair are also attached to platform-specific manifests using this API.

</details>

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
cosign tree ${IMAGE_URL_EXTERNAL}@${IMAGE_DIGEST} \
  --allow-insecure-registry

# Download and view the SLSA provenance attestation
cosign download attestation ${IMAGE_URL_EXTERNAL}@${IMAGE_DIGEST} \
  --allow-insecure-registry \
  | jq -r '.payload' | base64 -d | jq .

# View key provenance fields
cosign download attestation ${IMAGE_URL_EXTERNAL}@${IMAGE_DIGEST} \
  --allow-insecure-registry \
  | jq -r '.payload' | base64 -d \
  | jq '.predicateType, .predicate.buildType, .predicate.builder.id'
```

<details>
<summary>Example cosign tree output showing build artifacts</summary>

```
📦 Supply Chain Security Related artifacts for an image: localhost:5001/konflux-festoji:on-pr-a2492764734683d70e8c6aee37361d2da0e939e2
└── 📦 SBOMs for an image tag: localhost:5001/konflux-festoji:sha256-db12fe166b18e3d881ebbef06569d0bce385541dac3a177379bf5c7b58f9c3bc.sbom
   └── 🍒 sha256:585ef32fe083901059e02567ca027d3d18c04ba0639fd23f99cbf7887a049c63
└── 💾 Attestations for an image tag: localhost:5001/konflux-festoji:sha256-db12fe166b18e3d881ebbef06569d0bce385541dac3a177379bf5c7b58f9c3bc.att
   └── 🍒 sha256:e4e9c7da7486a9b89db1002ca1b3006ca80d91329c820d209f1365f75f3c5301
└── 🔐 Signatures for an image tag: localhost:5001/konflux-festoji:sha256-db12fe166b18e3d881ebbef06569d0bce385541dac3a177379bf5c7b58f9c3bc.sig
   └── 🍒 sha256:bb1b505be6b7390d2f227b9b0628ed27c030d9be264967fbd9c11576de50b2d7
└── 🔗 application/sarif+json artifacts via OCI referrer: localhost:5001/konflux-festoji@sha256:b585d36a4b4f13f33d4785fe5ee704c0f93df825cfc12115eaac753c3ff7c3f5
   └── 🍒 sha256:da808faebf6f41071851c9a8e62a73aa0a0c4b2f733cb9ad9a1ea447d0f9e08b
```

This shows the complete supply chain artifact tree for the build image, including SBOM, SLSA provenance attestation, cryptographic signature, and SARIF security scan results.

</details>

<details>
<summary>Example SLSA provenance attestation structure</summary>

```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://slsa.dev/provenance/v0.2",
  "subject": [
    {
      "name": "registry-service.kind-registry/konflux-festoji",
      "digest": { "sha256": "1d36eeae5e3a630a6521920b296fb8b8496891d833b0322b155471c3f654b39e" }
    },
    {
      "name": "registry-service.kind-registry/konflux-festoji",
      "digest": { "sha256": "db12fe166b18e3d881ebbef06569d0bce385541dac3a177379bf5c7b58f9c3bc" }
    }
  ],
  "predicate": {
    "builder": { "id": "https://tekton.dev/chains/v2" },
    "buildType": "tekton.dev/v1/PipelineRun",
    "metadata": {
      "buildFinishedOn": "2026-05-04T17:19:07Z",
      "buildStartedOn": "2026-05-04T17:17:34Z",
      "completeness": { "environment": false, "materials": false, "parameters": false },
      "reproducible": false
    }
  }
}
```

Key fields in the provenance:
- **predicateType**: SLSA provenance v0.2 specification
- **subject**: Multi-platform artifacts (image index and platform-specific manifest)
- **builder.id**: Tekton Chains v2 generated this provenance
- **buildType**: Tekton PipelineRun produced the artifacts
- **metadata**: Build timing and completeness information

</details>

The provenance attestation includes the predicate type (`https://slsa.dev/provenance/v0.2`), build type (`tekton.dev/v1/PipelineRun`), builder ID (the Tekton Chains instance that generated the provenance), build configuration (all tasks executed, their parameters, and results), and materials (source code commit, base images, and other inputs).

### Viewing the SBOM

The buildah task automatically generates an SBOM during the container build process. You can download and inspect it:

```bash
# Download the SBOM (generated by buildah during build)
# Note: cosign automatically resolves the index digest to the platform-specific manifest
cosign download sbom ${IMAGE_URL_EXTERNAL}@${IMAGE_DIGEST} \
  --allow-insecure-registry > sbom.json

# View SBOM metadata
jq '.SPDXID, .spdxVersion, .creationInfo' sbom.json

# View packages included in the image
jq '.packages[] | {name: .name, version: .versionInfo}' sbom.json
```

<details>
<summary>Example SBOM structure (SPDX 2.3)</summary>

```json
{
  "spdxVersion": "SPDX-2.3",
  "name": "registry-service.kind-registry/konflux-festoji@sha256:db12fe...",
  "dataLicense": "CC0-1.0",
  "packages": [
    { "name": "konflux-festoji", "SPDXID": "SPDXRef-image-index", "versionInfo": "on-pr-a249..." },
    { "name": "konflux-festoji_arm64", "SPDXID": "SPDXRef-image-konflux-festoji-6a84...", "versionInfo": "on-pr-a249..." }
  ],
  "total_packages": 2
}
```

</details>

The SBOM is in SPDX 2.3 format and includes all packages and dependencies in the container image, SHA256 checksums for verification, license information, and package relationships.

## Integration Tests

Building an image is only the first step. Konflux also validates builds against policy before release. Merge your onboarding PR to trigger the on-push pipeline. Let the build run, and then examine how Konflux validates it.

The `.tekton` directory contains two different PipelineRuns: one for PR events and another for push events. By default, these are almost identical, so the build you see now will largely be the same as the build you saw previously. This means that any build-time checks (including clair-scan and sast-shell-check) will still run on every build.

After a successful build, Tekton Chains generates and signs SLSA provenance attestations. The build context determines which integration tests run.

The helm chart creates two IntegrationTestScenario resources:

**policy-pr** (pull_request context): Validates PR builds at source level 1. PR source branches are not protected, so they cannot achieve higher source levels. This validates whether the resulting push will succeed.

**policy-push** (push context): Validates push builds with the same policy configuration used during release. By default, requires source level 1 (version control only).

Check integration test results:

```bash
# View integration test scenarios
kubectl get integrationtestscenario -n default-tenant

# Find snapshots for your builds
kubectl get snapshots -n default-tenant --sort-by=.metadata.creationTimestamp

# Get the snapshot name for detailed inspection
SNAPSHOT_NAME=$(kubectl get snapshots -n default-tenant \
  --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d'/' -f2)

# Check test results on a snapshot
kubectl get snapshot ${SNAPSHOT_NAME} -n default-tenant \
  -o jsonpath='{.metadata.annotations.test\.appstudio\.openshift\.io/status}' | jq .

# View PipelineRuns for specific test scenarios
kubectl get pipelineruns -n default-tenant -l test.appstudio.openshift.io/scenario=policy-pr
kubectl get pipelineruns -n default-tenant -l test.appstudio.openshift.io/scenario=policy-push
```

<details>
<summary>Example snapshot integration test results</summary>

```json
{
  "conditions": [
    {
      "lastTransitionTime": "2026-05-04T19:14:21Z",
      "message": "Snapshot integration status condition is finished since all testing pipelines completed",
      "reason": "Finished",
      "status": "True",
      "type": "AppStudioIntegrationStatus"
    },
    {
      "lastTransitionTime": "2026-05-04T19:14:21Z",
      "message": "All Integration Pipeline tests passed",
      "reason": "Passed",
      "status": "True",
      "type": "AppStudioTestSucceeded"
    },
    {
      "lastTransitionTime": "2026-05-04T19:14:22Z",
      "message": "The Snapshot was auto-released",
      "reason": "AutoReleased",
      "status": "True",
      "type": "AutoReleased"
    }
  ]
}
```

When all integration tests pass, the snapshot transitions to `AppStudioTestSucceeded`, and the `AutoReleased` condition indicates the system created a Release resource to trigger the release pipeline.

</details>

Source verification at level 2+ only applies to push builds and releases. source-tool only generates provenance for pushes to protected branches, not PRs.

## Release Pipeline

When you merge to the main branch, a push event triggers a new PipelineRun. The build completes and Chains signs the image. The system creates a Snapshot representing the built artifacts, then runs the policy integration test to validate it. If the test passes, a Release resource is created, triggering the release pipeline in the managed namespace (`managed-tenant`).

Release pipelines run in managed namespaces to isolate privileged credentials from tenant developers. The Release that was auto-created references a ReleasePlan in the tenant namespace which is mapped to a ReleasePlanAdmission in the managed namespace. When the Release is created, a new Tekton pipeline runs as specified in that ReleasePlanAdmission.

View your release configuration:

```bash
# View the ReleasePlan in the tenant namespace
kubectl get releaseplan festoji-release-plan -n default-tenant -o yaml

# View the ReleasePlanAdmission in the managed namespace
kubectl get releaseplanadmission festoji-release-plan-admission -n managed-tenant -o yaml

# View releases
kubectl get releases -n default-tenant

# Get the release name for detailed inspection
RELEASE_NAME=$(kubectl get releases -n default-tenant \
  --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d'/' -f2)

# Check release pipeline runs
kubectl get pipelineruns -n managed-tenant -l release.appstudio.openshift.io/name=${RELEASE_NAME}
```

<details>
<summary>Example release status</summary>

```
$ kubectl get releases -n default-tenant
NAME                                        STATUS      COMPLETED
festoji-dep-level-test-6kncj                Succeeded   2026-05-05T14:20:08Z
festoji-retest-cqjj8-tnfjc                  Succeeded   2026-05-04T19:16:50Z
source-test-repo-cve-exception-test-wnh84   Succeeded   2026-05-05T16:44:22Z
source-test-repo-cve-leeway-test-tjdj6      Succeeded   2026-05-05T15:45:16Z
source-test-repo-release-cjdp5              Succeeded   2026-05-05T15:25:34Z
```

The `Succeeded` status indicates the release pipeline completed successfully, including policy verification, image publishing, and VSA attachment.

</details>

The release pipeline executes several tasks in the managed namespace. The key flow is policy verification gates image publication:

1. **verify-conforma**: Validates all policies against the build provenance using Conforma
2. **push-snapshot**: Publishes the image to the release registry (only runs after successful policy verification)
3. **attach-vsa**: Attaches signed Verification Summary Attestations (VSAs) to the published image

The `verify-conforma` task validates that all SLSA Build L3 requirements are met, all build tasks came from trusted bundles, attestations are properly signed, and no policy violations exist. If verification fails, the pipeline stops and the artifact is never published. Only after successful verification does `push-snapshot` publish the built image to the destination registry specified in the mapping. Then `attach-vsa` signs and attaches VSAs containing the verification results to the published images.

<details>
<summary>Example VSA for festoji (SLSA_BUILD_LEVEL_3, SLSA_SOURCE_LEVEL_1)</summary>

```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://slsa.dev/verification_summary/v1",
  "subject": [
    {
      "name": "registry-service.kind-registry/released-festoji",
      "digest": { "sha256": "db12fe166b18e3d881ebbef06569d0bce385541dac3a177379bf5c7b58f9c3bc" }
    }
  ],
  "predicate": {
    "dependencyLevels": null,
    "policy": {
      "digest": {},
      "uri": "oci::quay.io/conforma/release-policy:konflux@sha256:1b296a925b4021f4b4959ea289596925a8735540e554f3ba7754a651731a216f"
    },
    "resourceUri": "registry-service.kind-registry/konflux-festoji@sha256:db12fe166b18e3d881ebbef06569d0bce385541dac3a177379bf5c7b58f9c3bc",
    "slsaVersion": "1.0",
    "timeVerified": "2026-05-05T14:19:42.51639462Z",
    "verificationResult": "PASSED",
    "verifiedLevels": [
      "SLSA_BUILD_LEVEL_3",
      "SLSA_SOURCE_LEVEL_1"
    ],
    "verifier": {
      "id": "https://conforma.dev/cli",
      "version": { "ec": "v0.9.25" }
    }
  }
}
```

For Festoji, the VSA includes `SLSA_BUILD_LEVEL_3` because Konflux achieves Build L3 by default, and `SLSA_SOURCE_LEVEL_1` because Festoji is not enrolled with source-tool and relies only on version control.

</details>

Get the released image URL from the Release status:

```bash
# Extract the released image URL and digest
RELEASE_IMAGE_URL=$(kubectl get release ${RELEASE_NAME} -n default-tenant \
  -o jsonpath='{.status.artifacts.images[0].urls[0]}')
RELEASE_IMAGE_DIGEST=$(kubectl get release ${RELEASE_NAME} -n default-tenant \
  -o jsonpath='{.status.artifacts.images[0].shasum}')

# Convert internal registry service name to external localhost address
RELEASE_IMAGE_URL_EXTERNAL=$(echo ${RELEASE_IMAGE_URL} | sed 's/registry-service.kind-registry/localhost:5001/')

echo "Released Image: ${RELEASE_IMAGE_URL_EXTERNAL}@${RELEASE_IMAGE_DIGEST}"
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
cosign tree ${RELEASE_IMAGE_URL_EXTERNAL}@${RELEASE_IMAGE_DIGEST} \
  --allow-insecure-registry

# Download attestations from released image
cosign download attestation ${RELEASE_IMAGE_URL_EXTERNAL}@${RELEASE_IMAGE_DIGEST} \
  --allow-insecure-registry \
  | jq -r '.payload' | base64 -d | jq .
```

<details>
<summary>Comparing build and released image artifacts</summary>

**Build image** (before release):
```
📦 Supply Chain Security Related artifacts for an image: localhost:5001/konflux-festoji:on-pr-a2492764734683d70e8c6aee37361d2da0e939e2
└── 📦 SBOMs for an image tag: localhost:5001/konflux-festoji:sha256-db12fe166b18e3d881ebbef06569d0bce385541dac3a177379bf5c7b58f9c3bc.sbom
   └── 🍒 sha256:585ef32fe083901059e02567ca027d3d18c04ba0639fd23f99cbf7887a049c63
└── 💾 Attestations for an image tag: localhost:5001/konflux-festoji:sha256-db12fe166b18e3d881ebbef06569d0bce385541dac3a177379bf5c7b58f9c3bc.att
   └── 🍒 sha256:e4e9c7da7486a9b89db1002ca1b3006ca80d91329c820d209f1365f75f3c5301
└── 🔐 Signatures for an image tag: localhost:5001/konflux-festoji:sha256-db12fe166b18e3d881ebbef06569d0bce385541dac3a177379bf5c7b58f9c3bc.sig
   └── 🍒 sha256:bb1b505be6b7390d2f227b9b0628ed27c030d9be264967fbd9c11576de50b2d7
└── 🔗 application/sarif+json artifacts via OCI referrer: localhost:5001/konflux-festoji@sha256:b585d36a4b4f13f33d4785fe5ee704c0f93df825cfc12115eaac753c3ff7c3f5
   └── 🍒 sha256:da808faebf6f41071851c9a8e62a73aa0a0c4b2f733cb9ad9a1ea447d0f9e08b
```

**Released image** (after release pipeline):
```
📦 Supply Chain Security Related artifacts for an image: localhost:5001/released-festoji:a2492764734683d70e8c6aee37361d2da0e939e2
└── 💾 Attestations for an image tag: localhost:5001/released-festoji:sha256-db12fe166b18e3d881ebbef06569d0bce385541dac3a177379bf5c7b58f9c3bc.att
   ├── 🍒 sha256:e4e9c7da7486a9b89db1002ca1b3006ca80d91329c820d209f1365f75f3c5301
   ├── 🍒 sha256:d0012b6ddc586b6202d7a844a4548f41e3d9a63bf441cc42016c5d1ef79e7aa0
   ├── 🍒 sha256:83a29c3a4d3a3a6e44e388fdc0f749b6d42f1f2b418da41bc72a2474d10ed708
   ├── 🍒 sha256:de5d8419a799dccc67ec385b2606153d8a02043f76f8358c68d0ac5ccc88834c
   └── 🍒 sha256:4590097676a3464c3ccf67a2dbdcdf975e6cf812eb79f44547393358eee4d4b7
└── 🔐 Signatures for an image tag: localhost:5001/released-festoji:sha256-db12fe166b18e3d881ebbef06569d0bce385541dac3a177379bf5c7b58f9c3bc.sig
   └── 🍒 sha256:bb1b505be6b7390d2f227b9b0628ed27c030d9be264967fbd9c11576de50b2d7
└── 📦 SBOMs for an image tag: localhost:5001/released-festoji:sha256-db12fe166b18e3d881ebbef06569d0bce385541dac3a177379bf5c7b58f9c3bc.sbom
   └── 🍒 sha256:585ef32fe083901059e02567ca027d3d18c04ba0639fd23f99cbf7887a049c63
```

The released image has **multiple attestations** (5 vs 1) because the release pipeline adds Verification Summary Attestations (VSAs) generated by the `attach-vsa` task. The SBOM and signatures are preserved from the build. If an image is released multiple times, each release adds an additional VSA attestation.

</details>

The released image includes the same SBOM and signatures as the build image, ensuring provenance is preserved through the release process. Additionally, the release pipeline adds Verification Summary Attestations (VSAs) that certify the image passed policy validation.

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
  releasePlan: festoji-release-plan
  snapshot: ${SNAPSHOT_NAME}
EOF
```

## Consumer Verification

Released artifacts include signed Verification Summary Attestations (VSAs) that consumers can use to verify the artifact meets SLSA requirements before use. The VSA is signed with the release platform's key — separate from the build platform's Tekton Chains identity — so consumers need only trust this one stable key rather than knowing how build provenance was signed. See [Trusting Artifacts](trusting-artifacts.md#consumer-trust-the-vsa-as-trust-anchor) for the full rationale.

First, extract the release signing public key from the cluster:

```bash
kubectl get secret release-signing-key -n managed-tenant \
  -o jsonpath='{.data.cosign\.pub}' | base64 -d > cosign-release.pub
```

List all attestations attached to a released image:

```bash
cosign tree ${RELEASE_IMAGE_URL_EXTERNAL}@${RELEASE_IMAGE_DIGEST} \
  --allow-insecure-registry
```

Verify the SLSA VSA with the release signing public key:

```bash
cosign verify-attestation \
  --key cosign-release.pub \
  --type https://slsa.dev/verification_summary/v1 \
  --insecure-ignore-tlog \
  --allow-insecure-registry \
  ${RELEASE_IMAGE_URL_EXTERNAL}@${RELEASE_IMAGE_DIGEST}
```

Download and inspect the VSA predicate:

```bash
cosign download attestation ${RELEASE_IMAGE_URL_EXTERNAL}@${RELEASE_IMAGE_DIGEST} \
  --predicate-type https://slsa.dev/verification_summary/v1 \
  --allow-insecure-registry \
  | jq '.payload | @base64d | fromjson | .predicate'
```

Note: If an image has been released multiple times, `cosign download attestation` will return multiple VSA attestations (one per release). Use `--predicate-type` to filter for VSAs, and use `jq` to select a specific VSA if needed. The most recent VSA reflects the latest policy evaluation.

For fail-safe verification:

```bash
cosign verify-attestation \
  --key cosign-release.pub \
  --type https://slsa.dev/verification_summary/v1 \
  --insecure-ignore-tlog \
  --allow-insecure-registry \
  ${RELEASE_IMAGE_URL_EXTERNAL}@${RELEASE_IMAGE_DIGEST} || { echo "VSA verification failed!"; exit 1; }
```

VSAs are stored as OCI attestations co-located with the artifact image. Consumers retrieve them using `cosign`. Attestations are cryptographically signed with the release signing key.

The release pipeline prevents publication of artifacts that fail policy verification. The `verify-conforma` task evaluates all policies against the build provenance first. If verification fails, the pipeline stops and `push-snapshot` never runs. Only after successful verification are artifacts published to the destination registry. Then `attach-vsa` signs and attaches VSAs to the published images. This ordering is enforced by pipeline task dependencies (`runAfter` constraints).

For a standalone example of the verification flow, see [mild-to-wild-samples](https://github.com/arewm/mild-to-wild-samples).

## Understanding the Policy

Signing alone is insufficient. Tekton Chains signs whatever tasks claim to produce, including artifacts from compromised tasks (see [Trusting Artifacts](trusting-artifacts.md)). Conforma serves as a policy engine to verify the complete build chain before releasing images.

The helm chart creates an EnterpriseContractPolicy resource that defines what must be validated:

```bash
# View the policy configuration
kubectl get enterprisecontractpolicy festoji-ec-policy -n managed-tenant -o yaml
```

The policy contains three key components.

**Policy Rules** (`spec.sources.policy`):

- **Base policy**: `oci::quay.io/conforma/release-policy:konflux`
- Includes the `@slsa3` policy collection which validates SLSA Build Level 3 requirements, trusted task verification (all tasks from approved bundles), signature validation, and build isolation and provenance completeness

**Policy Data** (`spec.sources.data`):

- **Local rule data**: `github.com/arewm/slsa-konflux-example//managed-context/policies/ec-policy-data/data`
  - Defines allowed registries, required labels, disallowed packages
  - CVE remediation timeframes (critical: 6 days, high: 29 days)
  - Release schedule restrictions (no releases on Fridays/weekends/holidays)
  - See `managed-context/policies/ec-policy-data/data/rule_data.yml` for full configuration
- **Acceptable bundles**: `oci::quay.io/slsa-konflux-example/slsa-e2e-data-acceptable-bundles:latest`
  - List of trusted Tekton task bundles allowed in builds
  - Updated automatically when new task versions are published

**Signing Key** (`spec.publicKey`):

- **Default (keyless)**: omitted — Conforma verifies Tekton Chains signatures
  against the Rekor transparency log using the Fulcio root CA distributed by TUF.
  This is the default when Sigstore is deployed.
- **Keypair fallback**: set `release.signing.publicKey` in the component-onboarding
  chart values (e.g. `k8s://tekton-pipelines/public-key`) for clusters without Sigstore.

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

A normal release with a passing policy produces a full green pipeline. After a successful install and build, trigger a release as described above. The `verify-conforma` task will pass, `push-snapshot` will publish the image, and `attach-vsa` will sign and attach the Verification Summary Attestations.

**Scenario 2: Policy Fail**

You can tighten the policy on-cluster to force a failure without modifying git. The `ruleData` field in the EnterpriseContractPolicy spec overrides any values fetched from git-based data sources.

For example, the current policy requires source level 1 and festoji achieves level 1 (version control only, since festoji is not enrolled with source-tool). To demonstrate a failure, require level 2:

```bash
# Override the minimum required source level on-cluster
kubectl patch enterprisecontractpolicy festoji-ec-policy -n managed-tenant \
  --type=json -p '[
    {"op": "add", "path": "/spec/sources/0/ruleData",
     "value": {"slsa_source_min_level": "2"}}
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
  releasePlan: festoji-release-plan
  snapshot: ${SNAPSHOT}
EOF
```

The `verify-conforma` task will fail with a message indicating the source level achieved versus the level required:

```
FAILURE: slsa_source_verification.required_level_achieved
  verify-source task achieved SLSA_SOURCE_LEVEL_1,
  but minimum required level is 2
```

The `push-snapshot` task is skipped because it depends on `verify-conforma` succeeding. The artifact is never published.

After capturing the results, revert the policy:

```bash
kubectl patch enterprisecontractpolicy festoji-ec-policy -n managed-tenant \
  --type=json -p '[{"op": "remove", "path": "/spec/sources/0/ruleData"}]'
```

## Next Steps

This walkthrough covered the basic build and release flow with SLSA compliance. You built a container image, validated it against policy, and released it with signed VSAs.

For advanced topics including source track details, vulnerability management, and customizing policies, see [Part 2: Source and Vulnerabilities](part2-source-and-vulnerabilities.md).

To adapt Konflux for your own projects, install the platform configuration once per cluster and then use the component-onboarding chart for each component you want to build. Customize the Conforma policy data in `managed-context/policies/ec-policy-data/data/rule_data.yml` to match your security requirements.

For complete platform documentation, see [Konflux Documentation](https://konflux-ci.dev/docs/). For the SLSA specification, see [slsa.dev](https://slsa.dev/spec/). For policy validation details, see [Conforma](https://conforma.dev).
