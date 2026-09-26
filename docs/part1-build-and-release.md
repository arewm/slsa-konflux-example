# Part 1: Build and Release

This walkthrough demonstrates end-to-end SLSA compliance with Konflux and the Festoji example component. It covers onboarding, building, policy validation, and releasing artifacts across separate trust boundaries.

For cluster setup and prerequisites, see the [main README](../README.md#pre-requisites). This guide assumes that Konflux is deployed and the prerequisites script has completed.

## Onboard Your Component

### Onboard Festoji

Fork the Festoji repository to your GitHub account:

1. Go to https://github.com/lcarva/festoji and click **Fork**.
2. Select your user or organization.
3. Create the fork and note its URL, such as `https://github.com/ORGANIZATION/festoji`.

Install the GitHub App created during Konflux deployment on the fork:

1. Go to https://github.com/settings/apps.
2. Select the GitHub App configured during the webhook setup.
3. Click **Install App**.
4. Select your user or organization.
5. Choose **Only select repositories**, then select the Festoji fork.
6. Click **Install**.

The GitHub App sends pull-request and push events to the Pipelines as Code controller, which triggers PipelineRuns automatically.

Install the component-onboarding chart:

```bash
export FORK_ORG="ORGANIZATION"
helm upgrade --install festoji ./charts/component-onboarding \
  --set componentName=festoji \
  --set gitRepoUrl=https://github.com/${FORK_ORG}/festoji
```

The chart creates the Application, Component, IntegrationTestScenario resources (`policy-pr` and `policy-push`), ReleasePlan, and ReleasePlanAdmission.

Verify the component:

```bash
kubectl get component festoji -n default-tenant
kubectl get integrationtestscenario -n default-tenant
kubectl get repository -n default-tenant
```

Build-service creates a pull request in the fork with the Tekton pipeline definitions. Find the pull request titled similar to **Konflux update ORGANIZATION/festoji**. It adds the `.tekton/` directory required for builds. Merge the pull request before continuing.

## SLSA Build Level 3

SLSA Build Level 3 requires isolated builds, inaccessible signing keys, and a build platform that uses only trusted, verified tasks. Konflux provides these properties through three controls:

- **Ephemeral pod isolation:** Tekton creates a new pod for every PipelineRun. After completion, the pod is destroyed, preventing one build from accessing another build's filesystem, environment, or processes.
- **Namespace separation:** Builds run in the tenant namespace (`default-tenant`), while signing keys exist only in the managed namespace (`managed-tenant`). Kubernetes RBAC prevents tenant workloads from reading managed-namespace secrets.
- **Trusted tasks:** Conforma's `trusted_tasks` package verifies that pipeline tasks come from approved Tekton bundles. At release time, Conforma checks each task in the provenance against the approved bundle list.

Together, these controls provide the isolation, non-falsifiable provenance, and hermetic-build properties required by SLSA Build Level 3. For the detailed threat model, see [Trusting Artifacts](trusting-artifacts.md).

## Build Pipeline

After merging the build-service pull request, trigger builds by opening a pull request or pushing to the main branch. The `.tekton/` directory contains separate pipeline definitions for pull-request and push events.

When GitHub sends a webhook, Pipelines as Code creates a PipelineRun in the tenant namespace. The build pipeline runs these tasks:

1. **init**: Initialize the workspace and build parameters.
2. **clone-repository**: Clone the source repository at the requested commit SHA.
3. **prefetch-dependencies**: Download dependencies for a hermetic build.
4. **build-container**: Build the container image with Buildah.
5. **verify-source**: Validate the source repository against its SLSA source policy.
6. **build-image-index**: Create the multi-platform image manifest.
7. **trivy-sbom-scan**: Scan the SBOM for vulnerabilities with Trivy. Enabled by default.
8. **clair-scan**: Scan the image with Clair. Disabled by default; set `enable-clair-scan` to `"true"` to enable it.
9. **sast-shell-check**: Run static analysis on shell scripts.
10. **apply-tags**: Apply Git-based tags to the image.

After the build completes, Tekton Chains generates SLSA provenance attestations. Chains watches completed TaskRuns and PipelineRuns, identifies their output artifacts, and signs attestations that describe the build. The provenance records the executed tasks, parameters, source commit, base images, and other inputs.

Monitor a build:

```bash
# Watch pipeline runs
tkn pipelinerun list -n default-tenant

# Follow logs of the latest build
tkn pipelinerun logs -n default-tenant -f
```

## Inspect Build Artifacts

After the PipelineRun completes, inspect the image and its attached SBOM, signatures, attestations, and vulnerability reports.

### Getting the Image Reference

Get the output image reference from the latest build PipelineRun:

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

`IMAGE_DIGEST` identifies the multi-platform image index. To inspect platform-specific artifacts, obtain the manifest digest for the target platform:

```bash
# Extract the manifest digest for the first platform in the index
MANIFEST_DIGEST=$(skopeo inspect --tls-verify=false --raw \
  docker://${IMAGE_URL_EXTERNAL} | jq -r '.manifests[0].digest')

echo "Image Manifest Digest: ${MANIFEST_DIGEST}"
```

Konflux attaches artifacts at different levels. SARIF scan results attach to the image index. Trivy and Clair reports, SBOMs, provenance, and signatures attach to the platform-specific image manifest.

The local registry uses a self-signed certificate and requires authentication. The following commands skip TLS verification with tool-specific options and authenticate CLI tools with the internal registry:

```bash
# Extract registry credentials and login
REGCRED=$(kubectl get secret regcred-internal-registry -n default-tenant \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
REG_USER=$(echo "$REGCRED" | jq -r '.auths["registry-service.kind-registry"].auth' | base64 -d | cut -d: -f1)
REG_PASS=$(echo "$REGCRED" | jq -r '.auths["registry-service.kind-registry"].auth' | base64 -d | cut -d: -f2)

cosign login localhost:5001 -u "$REG_USER" -p "$REG_PASS"
```

### Inspecting with Different Tools

The registry exposes attached artifacts through the OCI Distribution 1.1 Referrers API. Tekton Chains stores provenance and signatures as OCI 1.1 referrers in `sigstore-bundle` format. Use `oras` or the registry API to inspect the referrer graph directly. `cosign` and `crane` also support discovery and retrieval.

<details>
<summary><b>Using skopeo and podman</b></summary>

[skopeo](https://github.com/containers/skopeo) inspects and copies container images. [podman](https://podman.io/) pulls and runs them.

Inspect the image index:

```bash
# View the raw image index (multi-platform manifest)
skopeo inspect --tls-verify=false --raw docker://${IMAGE_URL_EXTERNAL}

# View parsed image details (requires platform override for non-linux hosts)
skopeo inspect --tls-verify=false \
  --override-arch arm64 --override-os linux \
  docker://${IMAGE_URL_EXTERNAL}
```

List image tags:

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

Inspect attached artifacts through the OCI Referrers API:

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

[crane](https://github.com/google/go-containerregistry/blob/main/cmd/crane/doc/crane.md) interacts with remote images and registries. It can inspect manifests, list repository tags, retrieve digests, and pull images.

Inspect the image:

```bash
# View the image index manifest
crane manifest ${IMAGE_URL_EXTERNAL} --insecure

# View image config
crane config ${IMAGE_URL_EXTERNAL} --insecure
```

List image tags:

```bash
# Extract repository from IMAGE_URL
REPO=$(echo ${IMAGE_URL_EXTERNAL} | cut -d: -f1)
crane ls ${REPO} --insecure
```

Get the image digest:

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

[oras](https://oras.land/) is the OCI Registry As Storage tool. It supports the OCI Referrers API for discovering attached SBOMs, attestations, signatures, and scan results.

With the local registry, use `127.0.0.1:5001` instead of `localhost:5001`. `oras` defaults to HTTP for `localhost` but uses HTTPS for IP addresses.

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

List image tags:

```bash
oras repo tags ${REPO} --insecure
```

Discover attached artifacts through the OCI Referrers API:

```bash
# Discover artifacts attached to the image index
oras discover ${REPO}@${IMAGE_DIGEST} --insecure

# Discover artifacts attached to the platform-specific manifest
oras discover ${REPO}@${MANIFEST_DIGEST} --insecure
```

Pull artifacts:

```bash
# Pull all artifacts attached to the manifest
oras pull ${REPO}@${MANIFEST_DIGEST} --insecure

# Pull only artifacts of a specific type
oras pull ${REPO}@${MANIFEST_DIGEST} --insecure \
  --artifact-type application/vnd.cyclonedx+json
```

</details>

### Understanding Attached Artifacts

Konflux attaches artifacts to both the image index and each platform-specific image manifest.

Artifacts attached to the image index (`IMAGE_DIGEST`):
- **SARIF reports**: Security scan results in SARIF format.

Artifacts attached to each platform-specific image manifest (`MANIFEST_DIGEST`):
- **SBOM**: Software Bill of Materials (SPDX format).
- **Provenance & Signatures**: SLSA provenance and signatures stored as OCI 1.1 referrers in `sigstore-bundle` format.
- **Trivy reports**: Vulnerability scan results.
- **Clair reports**: Optional vulnerability scan results.

### Viewing SLSA Provenance

Use `cosign` to inspect and retrieve the attestation associated with the image digest:

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

### Viewing the SBOM

The Buildah task generates an SBOM during the container build. Download and inspect it with `cosign`:

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

## Integration Tests

Konflux validates builds against policy before release. Merge your onboarding pull request to trigger the on-push pipeline.

The `.tekton/` directory defines two pipelines: one for pull requests and one for push events. Both run standard build-time checks (`sast-shell-check`, `trivy-sbom-scan`). After the build completes, Tekton Chains generates and signs the SLSA provenance attestation.

The onboarding Helm chart configures two `IntegrationTestScenario` resources:

- **`policy-pr`**: Validates pull-request builds at SLSA Source Level 1. Because PR branches are unprotected, they cannot achieve higher source levels. This test predicts whether the push build will succeed.
- **`policy-push`**: Validates push builds against the release policy configuration. By default, it requires SLSA Source Level 1 (version control tracking).

Inspect integration test results:

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

When all integration tests succeed, the snapshot condition transitions to `AppStudioTestSucceeded`. The `AutoReleased` condition confirms that the system created a `Release` resource to trigger the release pipeline.

## Release Pipeline

Merging to the main branch triggers an on-push build. Once Chains signs the image provenance and integration tests pass, the system creates a `Release` resource. This triggers the release pipeline in the platform-managed namespace (`managed-tenant`).

Inspect the release configuration:

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

The release pipeline executes in `managed-tenant` and enforces policy before image promotion:

1. **`verify-conforma`**: Evaluates Enterprise Contract policies against the build provenance and attached attestations.
2. **`push-snapshot`**: Promotes images to the destination registry only after `verify-conforma` passes.
3. **`attach-summary-attestations`**: Signs and attaches Verification Summary Attestations (VSAs) and Software Verification Reports (SVRs) to the published images.

The `verify-conforma` task validates that all SLSA Build Level 3 requirements are satisfied: tasks came from approved bundles, attestations are signed, and no policy violations exist. If verification fails, the pipeline halts immediately; the image is never promoted. Once verification passes, `push-snapshot` copies the image to the destination registry, and `attach-summary-attestations` attaches the signed verification receipts.

Retrieve the released image reference from the `Release` custom resource:

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

Verify that the release condition is True:

```bash
kubectl get release ${RELEASE_NAME} -n default-tenant \
  -o jsonpath='{.status.conditions[?(@.type=="Released")].status}'
# Should output: True
```

Inspect the released image and its attached attestations:

```bash
# Check released image artifacts
cosign tree ${RELEASE_IMAGE_URL_EXTERNAL}@${RELEASE_IMAGE_DIGEST} \
  --allow-insecure-registry

# Download attestations from released image
cosign download attestation ${RELEASE_IMAGE_URL_EXTERNAL}@${RELEASE_IMAGE_DIGEST} \
  --allow-insecure-registry \
  | jq -r '.payload' | base64 -d | jq .
```

### Manual Release Triggering

If automatic release is disabled, create a `Release` resource manually:

```bash
# Create a Release resource
cat <<EOF | kubectl create -f -
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  generateName: festoji-manual-release-
  namespace: default-tenant
spec:
  releasePlan: festoji-release-plan
  snapshot: ${SNAPSHOT_NAME}
EOF
```

## Consumer Verification

Consumers verify artifacts using the release platform's public key or keyless Fulcio identity, checking the signed VSA rather than inspecting the full build pipeline.

Verify the released image using the VSA:

```bash
# Verify the VSA attestation using the release public key
cosign verify-attestation \
  --key k8s://managed-tenant/release-signing-key \
  --type https://slsa.dev/verification_summary/v1 \
  --allow-insecure-registry \
  ${RELEASE_IMAGE_URL_EXTERNAL}@${RELEASE_IMAGE_DIGEST} | jq .
```

Verify specific SLSA level claims in the VSA:

```bash
# Check that the image achieved SLSA Build Level 3
cosign verify-attestation \
  --key k8s://managed-tenant/release-signing-key \
  --type https://slsa.dev/verification_summary/v1 \
  --allow-insecure-registry \
  ${RELEASE_IMAGE_URL_EXTERNAL}@${RELEASE_IMAGE_DIGEST} \
  | jq -r '.payload' | base64 -d \
  | jq -e '.predicate.verifiedLevels | index("SLSA_BUILD_LEVEL_3") != null' \
  && echo "SLSA Build Level 3 verified"

# Check verification result
cosign verify-attestation \
  --key k8s://managed-tenant/release-signing-key \
  --type https://slsa.dev/verification_summary/v1 \
  --allow-insecure-registry \
  ${RELEASE_IMAGE_URL_EXTERNAL}@${RELEASE_IMAGE_DIGEST} \
  | jq -r '.payload' | base64 -d \
  | jq -e '.predicate.verificationResult == "PASSED"' \
  && echo "Policy verification passed"
```

Consumers can also use the Conforma CLI to re-evaluate the image against their own policies:

```bash
# Consumer policy validation with conforma CLI
ec validate image \
  --image ${RELEASE_IMAGE_URL_EXTERNAL}@${RELEASE_IMAGE_DIGEST} \
  --public-key k8s://managed-tenant/release-signing-key \
  --policy "github.com/conforma/config//slsa3" \
  --output json | jq .
```

This establishes consumer trust through cryptographic verification:
1. Verify the signature on the VSA using the release public key or identity.
2. Verify that `verificationResult` is `PASSED`.
3. Verify that `verifiedLevels` includes `SLSA_BUILD_LEVEL_3`.

## Understanding the Policy

The component-onboarding chart creates an `EnterpriseContractPolicy` resource defining the rules enforced during release:

```bash
# View the policy configuration
kubectl get enterprisecontractpolicy festoji-ec-policy -n managed-tenant -o yaml
```

The policy configuration includes:

- **`sources`**: OCI bundles containing Conforma policy rules (e.g. `@slsa3`, `@slsa_source`).
- **`publicKey` or `identity`**: Keys or OIDC identities used to verify provenance and attestations.
- **`ruleData`**: Configuration data governing policy rules, such as `slsa_source_min_level: "1"`.

Inspect detailed verification results from the release pipeline:

```bash
# View verify-conforma task results
kubectl get pipelinerun -n managed-tenant \
  -l release.appstudio.openshift.io/name=${RELEASE_NAME} \
  -o jsonpath='{.items[0].status.taskRuns[?(@.pipelineTaskName=="verify-conforma")].status.taskResults}' | jq .

# Check task logs for detailed policy evaluation
kubectl logs -n managed-tenant \
  -l release.appstudio.openshift.io/name=${RELEASE_NAME} \
  -c step-validate --tail=100
```

### Demonstrating Policy Enforcement

To demonstrate policy enforcement, tighten the policy on-cluster to require a higher source level than Festoji provides. This forces `verify-conforma` to fail and prevents release promotion.

```bash
# Override the minimum required source level on-cluster
kubectl patch enterprisecontractpolicy festoji-ec-policy -n managed-tenant \
  --type=merge -p '{
    "spec": {
      "sources": [{
        "name": "Release Policies",
        "policy": [
          "oci::quay.io/conforma/release-policy:konflux@sha256:1b296a925b4021f4b4959ea289596925a8735540e554f3ba7754a651731a216f"
        ],
        "ruleData": {
          "slsa_source_min_level": "3"
        }
      }]
    }
  }'
```

Trigger a new build by opening a pull request or creating a snapshot. The integration tests and release pipeline will evaluate against the patched policy:

- `verify-conforma` detects that Festoji only achieves Source Level 1 while the policy requires Level 3.
- The task reports a policy violation and exits with a failure status.
- The release pipeline halts: `push-snapshot` and `attach-summary-attestations` do not execute.
- The container image is not promoted to the release repository.

Restore the policy to allow releases:

```bash
kubectl patch enterprisecontractpolicy festoji-ec-policy -n managed-tenant \
  --type=merge -p '{
    "spec": {
      "sources": [{
        "name": "Release Policies",
        "policy": [
          "oci::quay.io/conforma/release-policy:konflux@sha256:1b296a925b4021f4b4959ea289596925a8735540e554f3ba7754a651731a216f"
        ],
        "ruleData": {
          "slsa_source_min_level": "1"
        }
      }]
    }
  }'
```

## Next Steps

In this walkthrough, you:
- Onboarded a component and configured automated Tekton build pipelines.
- Examined how Konflux achieves SLSA Build Level 3 through pod isolation, namespace separation, and trusted task bundles.
- Inspected build artifacts including SBOMs, SLSA provenance, and vulnerability reports.
- Followed an image through policy validation, registry promotion, and VSA signing.
- Verified release integrity as an external consumer.

Continue to **[Part 2: Source Track, Vulnerability Management, and Hermetic Builds](part2-source-and-vulnerabilities.md)** to explore SLSA Source Level 3 via `source-tool`, per-application Conforma policies, CVE leeway mechanisms, and hermetic builds.
