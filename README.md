# SLSA End-to-End Example (Konflux style)

This repository demonstrates how to achieve end-to-end SLSA (Supply-chain Levels for Software Artifacts) compliance using [Konflux](https://konflux-ci.dev).
It is created in response to the SLSA [request for examples](https://slsa.dev/blog/2025/07/slsa-e2e).

If you are not familiar with Konflux, it is an open source, cloud-native software factory focused on software supply chain security. We understand that there
are often competing interests between software developers and security professionals, but we try to strike a balance. By hardening our platform so that we can
achieve SLSA Build L3 out of the box, we give developers the flexibility to build what they need to while also ensuring that the necessary requirements are
met before those artifacts are pushed anywhere outside their control.

After you complete the prerequisites, this repository provides a self-contained example for how to configure a Konflux tenant, onboard a component, and release
it while ensuring that we meet all required policies. We will show you along the way how we leverage guidance from many of SLSA's tracks.

## Table of Contents

- [Pre-requisites](#pre-requisites)
  - [Configure Demo Authentication](#configure-demo-authentication)
  - [Accessing the Konflux UI](#accessing-the-konflux-ui)
  - [Accessing the Kind Cluster Registry](#accessing-the-kind-cluster-registry)
  - [Tips](#tips)
- [Workflow Overview](#workflow-overview)
- [Administrator Setup](#administrator-setup)
  - [Configure Build Pipeline Bundles](#configure-build-pipeline-bundles)
- [Setup Your Repository](#setup-your-repository)
  - [Fork the Demo Repository](#fork-the-demo-repository)
  - [Install GitHub App on Your Fork](#install-github-app-on-your-fork)
- [Onboard Your Component](#onboard-your-component)
- [Build Your Component](#build-your-component)
- [Inspect the Build Artifacts](#inspect-the-build-artifacts)
- [Integration Tests](#integration-tests)
- [Releasing Your Component](#releasing-your-component)
- [Understanding the Policy](#understanding-the-policy)
- [Next Steps](#next-steps)

## Pre-requisites

All commands in this guide assume you are in the root directory of the slsa-konflux-example repository unless otherwise specified.

Before being able to explore SLSA with Konflux, you will need to have a running instance of it. The simplest way to get started is using the [konflux-ci](https://github.com/konflux-ci/konflux-ci) deployment script:

```bash
# Clone the konflux-ci repository
git clone https://github.com/konflux-ci/konflux-ci.git
cd konflux-ci

# Deploy Konflux operator with default configuration
./scripts/deploy-local.sh
```

This script automatically:
- Creates a Kind cluster
- Deploys the Konflux operator
- Creates the `default-tenant` namespace with demo users (user1@konflux.dev, user2@konflux.dev)
- Configures webhooks for Pipelines as Code

After the operator is deployed, return to this repository and run the prerequisites script to complete the setup:

```bash
cd /path/to/slsa-konflux-example
./scripts/setup-prerequisites.sh
```

The prerequisites script:
- Creates the `managed-tenant` namespace for privileged release operations
- Applies custom SLSA pipeline configuration to the build service

For detailed deployment options, see the [Operator Deployment Guide](https://github.com/konflux-ci/konflux-ci/blob/main/docs/operator-deployment.md).

Install these CLI tools for the demo: [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl) for cluster interaction, [cosign](https://github.com/sigstore/cosign?tab=readme-ov-file#installation) for inspecting OCI artifact attestations, [helm](https://github.com/helm/helm?tab=readme-ov-file#install) for deploying resources to the Kind cluster, [tkn](https://github.com/tektoncd/cli?tab=readme-ov-file#installing-tkn) for viewing Tekton pipelines, and optionally [gh](https://cli.github.com/) for GitHub CLI operations.

**NOTE:** You will need to configure your repository with the Pipelines as Code application, so make sure you don't lose track of it when you create it.

### Demo Authentication

The Konflux operator automatically configures demo users for accessing the UI. The default deployment includes:

- **user1@konflux.dev** / `password` - Has admin access to the `default-tenant` namespace (created by operator)
- **user2@konflux.dev** / `password` - Has admin access to the `managed-tenant` namespace (created by prerequisites script)

**WARNING:** These are insecure demo credentials for testing only. For production deployments, configure proper authentication using the [Demo Users Configuration Guide](https://github.com/konflux-ci/konflux-ci/blob/main/docs/demo-users.md).

You can verify the demo users are configured:

```bash
kubectl get konfluxui konflux-ui -n konflux-ui -o jsonpath='{.spec.dex.config.staticPasswords}' | jq
```

### Accessing the Konflux UI

After Konflux deployment completes, you can view pipeline runs and builds in the Konflux web UI at https://localhost:9443

### Accessing the Kind Cluster Registry

This demo uses the internal Kind registry by default. For complete registry configuration options (including external registries like Quay.io), see [Registry Configuration](https://github.com/konflux-ci/konflux-ci/blob/main/docs/registry-configuration.md).

The internal registry is accessible at:
- From host: `localhost:5001`
- Within cluster: `registry-service.kind-registry.svc.cluster.local`

Pull an image from the registry:
```bash
podman pull localhost:5001/repository/image:tag
```

### Tips

**Recovering kubeconfig:** If you lose your kubeconfig connection to the Kind cluster:
```bash
kind export kubeconfig -n konflux
```

For more troubleshooting, see [Troubleshooting Guide](https://github.com/konflux-ci/konflux-ci/blob/main/docs/troubleshooting.md).

## Workflow Overview

Konflux automates the build-to-release pipeline. When you onboard a component, build-service automatically creates a pull request in your repository with Tekton pipeline definitions. Merging that PR enables the automated workflow.

The build process runs in an unprivileged tenant namespace. After the build completes, Tekton Chains generates SLSA provenance and signs the artifacts. Integration tests validate the build against policies. When you merge to the main branch, the release pipeline runs in a privileged managed namespace where Conforma performs final policy validation before promoting images to the release registry.

## Administrator Setup

Configure the build service with custom pipeline bundles for SLSA compliance. This step requires cluster admin access.

The Konflux operator deployment already created:
- The `default-tenant` namespace (for unprivileged builds)
- Demo users (user1@konflux.dev, user2@konflux.dev)

The prerequisites script completes the setup by:
- Creating the `managed-tenant` namespace (for privileged release operations)
- Applying custom SLSA pipeline configuration (`slsa-e2e-oci-ta`) to the build service

Run the prerequisites script:

```bash
./scripts/setup-prerequisites.sh
```

The script is idempotent and can be safely run multiple times.

## Setting Up Your Builds

In order to achieve [SLSA build L3](https://slsa.dev/spec/v1.1/requirements), we need to ensure that builds are properly isolated
both from other builds as well as from the secrets used to sign the provenance. Konflux relies on Kubernetes pods, as orchestrated by
Tekton, to ensure that parallel builds are sufficiently isolated from each other. It also relies on Kubernetes namespace isolation to
ensure that the signing material that Tekton Chains uses when generating the provenance cannot be accessed by builds.

Configuring the required Tekton definition can be onerous, so we use Pipelines as Code to help push out a default definition when you
onboard a component.

## Setup Your Repository

### Fork the Demo Repository

Fork the festoji repository to your GitHub account. Navigate to https://github.com/lcarva/festoji and click Fork. Select your user or organization and create the fork. Note your fork URL for the helm installation step below: `https://github.com/ORGANIZATION/festoji`.

Konflux uses Pipelines as Code, which requires write access to create `.tekton/` directory with pipeline definitions and webhook permissions to trigger builds on pull requests and pushes.

### Install GitHub App on Your Fork

Install the GitHub App you created during Konflux deployment on your forked repository. Navigate to https://github.com/settings/apps and find the GitHub App from the "Enable Pipelines Triggering via Webhooks" step. Click the app name, then Install App. Select your user or organization, choose "Only select repositories", and select your festoji fork. Click Install.

The GitHub App webhook sends pull request and push events to your Konflux cluster's Pipelines as Code controller, which triggers pipeline runs automatically.

## Onboard Your Component

This repository provides two helm charts for setting up Konflux:

- **platform-config**: One-time setup for tenant infrastructure (policies, signing keys, permissions)
- **component-onboarding**: Repeatable per component (application, integration tests, release plan)

Both charts use these namespaces:

- `default-tenant`: The unprivileged tenant namespace where builds occur (created by Konflux operator)
- `managed-tenant`: The privileged managed namespace where releases are validated (created by prerequisites script)

### Step 1: Install Platform Configuration

Install the platform configuration **once per cluster**:

```bash
helm install platform ./charts/platform-config
```

This creates:
- EnterpriseContractPolicy for SLSA3 validation
- User role bindings for admin access
- Release pipeline service accounts
- Signing keys for release attestations

### Step 2: Onboard Components

Install the component-onboarding chart **once per component**:

```bash
export FORK_ORG="ORGANIZATION"
helm install festoji ./charts/component-onboarding \
  --set applicationName=festoji \
  --set gitRepoUrl=https://github.com/${FORK_ORG}/festoji
```

This creates:
- Application and Component resources
- IntegrationTestScenarios (policy-pr and policy-push)
- ReleasePlan and ReleasePlanAdmission

**Note:** Namespace values default to `default-tenant` and `managed-tenant`. Override if using custom namespaces, but values must match between platform-config and component-onboarding.

Verify the component was onboarded:

```bash
kubectl get component festoji -n default-tenant
kubectl get integrationtestscenario -n default-tenant
kubectl get repository -n default-tenant
```

Build-service automatically creates a pull request in your forked repository with Tekton pipeline definitions. Check your GitHub repository for the PR.

Now that you have onboarded your component, the build-service PR will show pipeline status checks, and any new PRs you open will trigger builds and you can use `tkn` to see it in the cluster!

## Build Your Component

Build-service automatically created a pull request with pipeline definitions. Before you can trigger builds:

1. **Merge the build-service PR** - This PR contains the `.tekton/` directory with pipeline definitions required for builds. Your component won't build until these pipeline definitions exist in your repository.

2. **Trigger a build** - After merging the build-service PR, open a new pull request with a code change. The GitHub App webhook will notify Pipelines as Code, which will create a PipelineRun in your tenant namespace.

Monitor the build:

```bash
# Watch pipeline runs
tkn pipelinerun list -n default-tenant

# Follow logs of the latest build
tkn pipelinerun logs -n default-tenant -f
```

## Inspect the Build Artifacts

### Inspecting the Built Image and Artifacts

Once your pipeline run completes, you can inspect the built container image and its attached artifacts (SBOM, signatures, attestations, vulnerability reports).

#### Getting the Image Reference

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

# Example output:
# IMAGE_URL=registry-service.kind-registry.svc.cluster.local/default-tenant/festoji
# IMAGE_DIGEST=sha256:abc123def456...
```

The `IMAGE_DIGEST` is the digest of the **image index** (multi-platform manifest). To inspect platform-specific artifacts, you'll need the **image manifest digest** for your platform:

```bash
# Extract the manifest digest for the first platform in the index
MANIFEST_DIGEST=$(skopeo inspect --tls-verify=false --raw \
  docker://${IMAGE_URL_EXTERNAL} | jq -r '.manifests[0].digest')

echo "Image Manifest Digest: ${MANIFEST_DIGEST}"

# Example output:
# MANIFEST_DIGEST=sha256:789ghi012jkl...
```

**Note on Artifacts:** Konflux attaches different artifacts at different levels:
- **Image Index** (`IMAGE_DIGEST`): SARIF scan results
- **Image Manifest** (`MANIFEST_DIGEST`): Trivy and Clair vulnerability reports, SBOMs, signatures

The local registry uses a self-signed certificate. For the commands below, we'll skip TLS verification using tool-specific flags.

#### Inspecting with Different Tools

<details>
<summary><b>Using skopeo and podman</b></summary>

[skopeo](https://github.com/containers/skopeo) is a command-line tool for inspecting and copying container images. [podman](https://podman.io/) is a container engine that can pull and run images.

**Inspect the image index:**
```bash
# View the raw image index (multi-platform manifest)
skopeo inspect --tls-verify=false --raw docker://${IMAGE_URL_EXTERNAL}

# View parsed image details (requires platform override for non-linux hosts)
skopeo inspect --tls-verify=false \
  --override-arch arm64 --override-os linux \
  docker://${IMAGE_URL_EXTERNAL}
```

**List image tags in the repository:**
```bash
# Extract repository from IMAGE_URL
REPO=$(echo ${IMAGE_URL_EXTERNAL} | cut -d: -f1)
skopeo list-tags --tls-verify=false docker://${REPO}
```

**Pull and run the image:**
```bash
# Pull the image
podman pull --tls-verify=false ${IMAGE_URL_EXTERNAL}

# Run a container from the image
podman run --rm ${IMAGE_URL_EXTERNAL}
```

**Inspect attached artifacts using curl:**

Since skopeo doesn't directly support the OCI Referrers API, use `curl` to check attached artifacts:

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

**Inspect the image:**
```bash
# View the image index manifest
crane manifest ${IMAGE_URL_EXTERNAL} --insecure

# View image config
crane config ${IMAGE_URL_EXTERNAL} --insecure
```

**List image tags in the repository:**
```bash
# Extract repository from IMAGE_URL
REPO=$(echo ${IMAGE_URL_EXTERNAL} | cut -d: -f1)
crane ls ${REPO} --insecure
```

**Get image digest:**
```bash
crane digest ${IMAGE_URL_EXTERNAL} --insecure
```

**Pull the image:**
```bash
# Export to podman/docker
crane pull ${IMAGE_URL_EXTERNAL} - --insecure | podman load

# Or pull to a tarball
crane pull ${IMAGE_URL_EXTERNAL} image.tar --insecure
```

**Inspect attached artifacts using curl:**

`crane` doesn't directly support the OCI Referrers API. Use `curl` to inspect attached artifacts:

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
<summary><b>Using oras</b></summary>

[oras](https://oras.land/) is the OCI Registry As Storage tool, which supports the OCI Referrers API for discovering attached artifacts like SBOMs and attestations.

**Important:** When using `oras` with the local registry, use `127.0.0.1:5001` instead of `localhost:5001`. The `oras` tool defaults to HTTP for `localhost` but uses HTTPS for IP addresses.

```bash
# Convert IMAGE_URL to use 127.0.0.1 for oras
IMAGE_URL_ORAS=$(echo ${IMAGE_URL_EXTERNAL} | sed 's/localhost/127.0.0.1/')
REPO=$(echo ${IMAGE_URL_ORAS} | cut -d: -f1)

echo "Image URL for oras: ${IMAGE_URL_ORAS}"
```

**Inspect the image manifest:**
```bash
# View the image index manifest
oras manifest fetch ${IMAGE_URL_ORAS} --insecure

# Pretty-print the manifest
oras manifest fetch ${IMAGE_URL_ORAS} --insecure --pretty
```

**List image tags in the repository:**
```bash
oras repo tags ${REPO} --insecure
```

**Discover attached artifacts (OCI Referrers API):**

This is where `oras` excels - it can discover and visualize the graph of artifacts attached to your image:

```bash
# Discover artifacts attached to the image index
oras discover ${REPO}@${IMAGE_DIGEST} --insecure

# Discover artifacts attached to the platform-specific manifest
# (This is where vulnerability reports are attached)
oras discover ${REPO}@${MANIFEST_DIGEST} --insecure
```

Example output showing the artifact tree:
```
127.0.0.1:5001/konflux-festoji@sha256:fe4b4eb7...
├── application/vnd.trivy.report+json
│   └── sha256:614b0d13...
└── application/vnd.redhat.clair-report+json
    └── sha256:a3cc9dbd...
```

**Pull specific artifacts:**
```bash
# Pull all artifacts attached to the manifest
oras pull ${REPO}@${MANIFEST_DIGEST} --insecure

# Pull only artifacts of a specific type
oras pull ${REPO}@${MANIFEST_DIGEST} --insecure \
  --artifact-type application/vnd.cyclonedx+json
```

</details>

#### Understanding Attached Artifacts

The image built by Konflux includes various attached artifacts at different levels:

**Artifacts on the Image Index** (`IMAGE_DIGEST`):
- **SARIF Reports** - Security scan results in SARIF format

**Artifacts on the Image Manifest** (`MANIFEST_DIGEST`) for each platform:
- **SBOM** - Software Bill of Materials listing all dependencies
- **Signatures** - Cryptographic signatures from Tekton Chains
- **Attestations** - SLSA provenance showing how the image was built
- **Trivy Reports** - Vulnerability scan results from Trivy
- **Clair Reports** - Vulnerability scan results from Clair

To see all artifacts, inspect both the image index and the platform-specific manifest digests.

**Note on OCI Referrers API Support:**

Konflux uses a **mixed approach** for storing artifacts due to varying tool support for the OCI Referrers API (OCI Distribution Spec 1.1.0+):

- **OCI Referrers API (modern):** Vulnerability scanners (Trivy, Clair) and SARIF reports use the `/v2/<repo>/referrers/<digest>` endpoint. Tools like `oras discover` and `curl` can query this API to find these artifacts.

- **Tag-based (backwards compatible):** Tekton Chains stores signatures, attestations, and SBOMs as special tags like `sha256-<digest>.sig`, `sha256-<digest>.att`, and `sha256-<digest>.sbom`. Tools like `cosign` and `crane ls` can discover these by listing repository tags.

**What this means:**
- `oras discover` will show vulnerability reports but NOT signatures/attestations (use tag listing instead)
- `cosign` and tag-based tools will show signatures/attestations but NOT vulnerability reports (use referrers API instead)
- To see **all artifacts**, use both approaches: the OCI Referrers API (`curl` or `oras discover`) AND tag listing (`crane ls` or `skopeo list-tags`)

This mixed scenario exists because different tasks are migrating to the OCI Referrers API at different rates. As tooling matures, more artifacts will move to the OCI Referrers API exclusively.

## Integration Tests

## Building isn't enough

Merge your onboarding PR to trigger the on-push pipeline, let the build run, and then look at what all we have configured Konflux to run.

### Build pipeline

If you look in your source repository, there will be two different PipelineRuns defined in the `.tekton` directory. One for PR events and another for push events.
By default, these are almost identical so the build you see now will largely be the same as the build you saw previously. This means that any build-time checks
(including clair-scan and sast-shell-check) will still run on every build.

After a successful build, Tekton Chains automatically generates SLSA provenance attestations and signs them. You can inspect these attestations to see detailed information about the build, including all the tasks that ran and their results.

#### Viewing SLSA Provenance

To view the attestations attached to your built image, use `cosign` (requires cosign v2+):

```bash
# Get the image digest from your PipelineRun
PIPELINERUN=$(kubectl get pipelinerun -n default-tenant \
  -l pipelines.appstudio.openshift.io/type=build \
  --sort-by=.metadata.creationTimestamp \
  -o name | tail -1)

IMAGE_DIGEST=$(kubectl get ${PIPELINERUN} -n default-tenant \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}')

# View the attestation tree (shows provenance, signatures, and SBOM)
cosign tree localhost:5001/konflux-festoji@${IMAGE_DIGEST}

# Download and view the SLSA provenance attestation
cosign download attestation localhost:5001/konflux-festoji@${IMAGE_DIGEST} \
  | jq -r '.payload' | base64 -d | jq .

# View key provenance fields
cosign download attestation localhost:5001/konflux-festoji@${IMAGE_DIGEST} \
  | jq -r '.payload' | base64 -d \
  | jq '.predicateType, .predicate.buildType, .predicate.builder.id'
```

The provenance attestation includes:
- **Predicate type**: `https://slsa.dev/provenance/v0.2` (SLSA v0.2 format)
- **Build type**: `tekton.dev/v1/PipelineRun` (Tekton pipeline execution)
- **Builder ID**: The Tekton Chains instance that generated the provenance
- **Build configuration**: All tasks executed, their parameters, and results
- **Materials**: Source code commit, base images, and other inputs

#### Viewing the SBOM

The buildah task automatically generates an SBOM during the container build process. You can download and inspect it:

```bash
# Download the SBOM (generated by buildah during build)
cosign download sbom localhost:5001/konflux-festoji@${IMAGE_DIGEST} > sbom.json

# View SBOM metadata
jq '.SPDXID, .spdxVersion, .creationInfo' sbom.json

# View packages included in the image
jq '.packages[] | {name: .name, version: .versionInfo}' sbom.json
```

The SBOM is in SPDX 2.3 format and includes:
- All packages and dependencies in the container image
- SHA256 checksums for verification
- License information
- Package relationships

### Integration tests

After Tekton Chains generates provenance, integration tests run based on the build context.

The helm chart creates two IntegrationTestScenario resources:

**policy-pr** (pull_request context): Validates PR builds at source level 1. PR source branches are not protected, so they cannot achieve higher source levels. This validates whether the resulting push will succeed.

**policy-push** (push context): Validates push builds with the same strict policy used during release. Requires source level 2+ with source-tool provenance.

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

**Note on SLSA source track**: Source verification at level 2+ only applies to push builds and releases. source-tool only generates provenance for pushes to protected branches, not PRs.

## Releasing Your Component

### Merging the PR and Triggering Auto-Release

To trigger the full flow including auto-release, merge your pull request:

```bash
# Merge via GitHub UI or gh CLI
gh pr merge <PR_NUMBER> --squash
```

When you merge to the main branch:

1. **Push event triggers**: A new PipelineRun executes for the push to main
2. **Build completes**: Image is built and signed by Chains
3. **Snapshot created**: Represents the built artifacts
4. **Integration test runs**: The `policy` scenario validates the snapshot
5. **Auto-release triggers**: A Release resource is created automatically
6. **Release pipeline executes**: In the managed namespace (`managed-tenant`)

### Pushing images elsewhere

Even if some developers want access to all credentials, to properly isolate privileged environments, we release artifacts via pipelines in separate managed namespaces.
The Release that was auto-created references a ReleasePlan in the tenant namespace which is mapped to a ReleasePlanAdmission in a specific managed namespace. When the Release
is created, a new Tekton pipeline will be created as specified in that ReleasePlanAdmission.

When we ran the `helm install` above, we created a ReleasePlanAdmission which will run a Pipeline to push this image to a separate location after verifying a specific
policy.

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

#### Manually Creating a Release

You can manually create a Release to re-release an existing Snapshot without rebuilding:

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

This is useful for:
- Testing the release pipeline without rebuilding
- Re-releasing after fixing release pipeline configuration
- Releasing an older snapshot

## Understanding the Policy

#### What's in a policy?

As we mentioned at the beginning, we are balancing flexibility with security. We use [Conforma](https://conforma.dev) as a policy engine to ensure that specific requirements
(policy rules) are met before images are released.

Our helm chart creates an EnterpriseContractPolicy resource that defines what must be validated:

```bash
# View the policy configuration
kubectl get enterprisecontractpolicy ec-policy -n managed-tenant -o yaml
```

The policy contains three key components:

**1. Policy Rules** (`spec.sources.policy`):
- **Base policy**: `oci::quay.io/enterprise-contract/ec-release-policy:konflux`
- Includes the `@slsa3` policy collection which validates:
  - SLSA Build Level 3 requirements
  - Trusted task verification (all tasks from approved bundles)
  - Signature validation
  - Build isolation and provenance completeness

**2. Policy Data** (`spec.sources.data`):
- **Local rule data**: `github.com/arewm/slsa-konflux-example//managed-context/policies/ec-policy-data/data`
  - Defines allowed registries, required labels, disallowed packages
  - CVE remediation timeframes (critical: 6 days, high: 29 days)
  - Release schedule restrictions (no releases on Fridays/weekends/holidays)
  - See `managed-context/policies/ec-policy-data/data/rule_data.yml` for full configuration
- **Acceptable bundles**: `oci::quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest`
  - List of trusted Tekton task bundles allowed in builds
  - Updated automatically when new task versions are published

**3. Signing Key** (`spec.publicKey`):
- **Key location**: `k8s://tekton-pipelines/public-key`
- Used to verify Tekton Chains signatures on attestations

The `verify-conforma` task in the release pipeline validates all of these requirements:

```bash
# View verify-conforma task results
kubectl get taskruns -n managed-tenant -l tekton.dev/pipelineTask=verify-conforma

# Check task logs for detailed policy evaluation
kubectl logs -n managed-tenant <VERIFY_CONFORMA_TASKRUN> --container=report
```

When the policy check passes:
- All SLSA Build L3 requirements are met
- All build tasks came from trusted bundles
- Attestations are properly signed
- No policy violations (disallowed packages, missing labels, etc.)
- The release pipeline continues to push the image

When the policy check fails:
- The release pipeline halts before pushing images
- The Release is marked as failed
- Policy violation details are available in task logs

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

## Next Steps

### Customizing for Your Use Case

This demo uses festoji as an example application. To adapt Konflux for your own projects:

First, install platform configuration once per cluster (if not already done):

```bash
helm install platform ./charts/platform-config \
  --set namespace=your-tenant-namespace \
  --set release.targetNamespace=your-managed-namespace
```

Then onboard your components:

```bash
helm install myapp ./charts/component-onboarding \
  --set applicationName=myapp \
  --set gitRepoUrl=https://github.com/FORK_ORG/YOUR_REPO \
  --set namespace=your-tenant-namespace \
  --set release.targetNamespace=your-managed-namespace
```

Customize the Enterprise Contract policy to match your security requirements. Edit `managed-context/policies/ec-policy-data/data/rule_data.yml` to configure allowed registries, CVE remediation timeframes, disallowed packages, and release schedules.

For hermetic builds with more accurate SBOMs, configure your build pipeline to use network isolation and generate complete dependency graphs. See the [Konflux documentation](https://konflux-ci.dev/docs/) for advanced build configurations.

To understand policy exceptions and how to handle intentional violations, see the [Conforma documentation](https://conforma.dev/docs/policy/).

### Additional Resources

- [Konflux Documentation](https://konflux-ci.dev/docs/) - Complete platform documentation
- [SLSA Specification](https://slsa.dev/spec/) - Supply-chain security framework
- [Conforma Policy Engine](https://conforma.dev) - Policy validation and enforcement
- [Tekton Chains](https://tekton.dev/docs/chains/) - Artifact signing and provenance