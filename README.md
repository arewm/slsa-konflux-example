# SLSA End-to-End Example (Konflux style)

This repository demonstrates how to achieve end-to-end SLSA (Supply-chain Levels for Software Artifacts) compliance using [Konflux](https://konflux-ci.dev).
It is created in response to the SLSA [request for examples](https://slsa.dev/blog/2025/07/slsa-e2e).

If you are not familiar with Konflux, it is an open source, cloud-native software factory focused on software supply chain security. We understand that there
are often competing interests between software developers and security professionals, but we try to strike a balance. By hardening our platform so that we can
achieve SLSA Build L3 out of the box, we give developers the flexibility to build what they need to while also ensuring that the necessary requirements are
met before those artifacts are pushed anywhere outside their control.

After you complete the prerequisites, this repository provides a self-contained example for how to configure a Konflux tenant, onboard a component, and release
it while ensuring that we meet all required policies. We will show you along the way how we leverage guidance from many of SLSA's tracks.

## Table of contents

TODO: complete

## Pre-requisites

Before being able to explore SLSA with Konflux, you will need to have a running instance of it. We have [instructions](https://github.com/konflux-ci/konflux-ci?tab=readme-ov-file#trying-out-konflux). While these instructions describe the process for building artifacts, we will also do that here. So you can stop after you complete the following:
- [Installing Software Dependencies](https://github.com/konflux-ci/konflux-ci?tab=readme-ov-file#installing-software-dependencies)
- [Bootstrapping the cluster](https://github.com/konflux-ci/konflux-ci?tab=readme-ov-file#bootstrapping-the-cluster)
- [Enabling Pipelines Triggering via Webhooks](https://github.com/konflux-ci/konflux-ci?tab=readme-ov-file#enable-pipelines-triggering-via-webhooks)

Install the required CLI tools for this demo:
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl) to interact with the Kubernetes cluster
- [cosign](https://github.com/sigstore/cosign?tab=readme-ov-file#installation), a tool for fetching attestations for OCI artifacts
- [helm](https://github.com/helm/helm?tab=readme-ov-file#install) to deploy the resources to the Kind cluster
- [tkn](https://github.com/tektoncd/cli?tab=readme-ov-file#installing-tkn) to view Tekton pipelines

**NOTE:** You will need to configure your repository with the Pipelines as Code application, so make sure you don't lose track of it when you create it.

**NOTE:** If you lose your kubeconfig to connect to your KinD cluster, you can re-establish it with

```bash
$ kind export kubeconfig -n konflux
```

### Configure demo authentication

After deploying Konflux (with `DEPLOY_DEMO_RESOURCES=0`), configure Dex with demo users to access the UI:

```bash
# Apply demo user configuration
kubectl apply -f dex-users.yaml
kubectl patch deployment dex -n dex --type=json -p='[{"op": "replace", "path": "/spec/template/spec/volumes/0/configMap/name", "value": "dex"}]'
kubectl rollout restart deployment/dex -n dex
```

This creates two demo users:
- **user1@konflux.dev** / password (for tenant namespace access)
- **user2@konflux.dev** / password (for managed namespace access)

Use `user1@konflux.dev` to onboard components and view tenant builds.

**WARNING:** These are insecure demo credentials for testing only. Do not use in production.

### Accessing the Konflux UI

You can view pipeline runs and builds in the Konflux web UI at https://localhost:9443

### Accessing the Kind Cluster Registry

The KinD cluster includes a local registry accessible at `localhost:5001` by default. This registry is used for storing container images built and released within the cluster.

To access images built by Konflux in the registry:
```bash
# Pull an image from the registry
podman pull localhost:5001/repository/image:tag
```

Within the cluster, the registry is accessible as `registry-service.kind-registry`.

**Note:** When deploying Konflux using the konflux-ci repository, set `DEPLOY_DEMO_RESOURCES=0` in your `scripts/deploy-e2e.env` file to skip the default demo namespace creation. The helm chart in this repository will create the necessary namespaces and user permissions for the SLSA example.

**Note on image registries:** This demo uses the in-cluster Kind registry (`registry-service.kind-registry`) by default. If you want to use external registries (e.g., Quay.io), you'll need to configure `dockerconfigjson` credentials in the helm values and optionally deploy image-controller (see konflux-ci deployment options with `QUAY_TOKEN`).

## Setting up your builds

In order to achieve [SLSA build L3](https://slsa.dev/spec/v1.1/requirements), we need to ensure that builds are properly isolated
both from other builds as well as from the secrets used to sign the provenance. Konflux relies on Kubernetes pods, as orchestrated by
Tekton, to ensure that parallel builds are sufficiently isolated from each other. It also relies on Kubernetes namespace isolation to
ensure that the signing material that Tekton Chains uses when generating the provenance cannot be accessed by builds.

Configuring the required Tekton definition can be onerous, so we use Pipelines as Code to help push out a default definition when you
onboard a component.

## Setup your repository

In this phase, we will walk you through what is needed to get your source repository ready to explore SLSA, Konflux style.

### Pick a repository

If you don't have a repository you want to build a container image from, you can pick one and fork it. If you don't have one, you
can always make [seasonally festive emojis](https://github.com/lcarva/festoji).

Once you have a repository under your control, you will need to install the GitHub application that you previously created. If you
have forgotten what your app is to install on your repository, you can see the apps that you have created 
[here](https://github.com/settings/apps).

### Onboard to source-tool

TODO: instructions

## Onboard the component

The helm chart in this repository creates and configures the necessary namespaces for the SLSA example:

- `slsa-e2e-tenant`: The unprivileged tenant namespace where builds occur
- `slsa-e2e-managed-tenant`: The privileged managed namespace where releases are validated

The chart automatically creates:
- Namespaces with proper labels (`konflux-ci.dev/type: tenant`)
- User role bindings for admin access (defaults to `user1@konflux.dev`)
- Cluster role bindings for self-access review
- Release pipeline service account in the tenant namespace
- All application, component, and release configuration

If you need to connect to the cluster, you can export the kubeconfig:

```bash
# By default, the cluster name is konflux
kind export kubeconfig -n konflux
```

Once your Konflux instance is deployed, configure the build-service pipeline bundles (this requires admin access):

```bash
# Delete any existing non-Helm managed ConfigMap
kubectl delete configmap build-pipeline-config -n build-service

# Install the build configuration via Helm
helm upgrade --install build-config ./admin
```

Then, onboard your component using the helm chart. The chart will create both namespaces and configure all necessary resources:

```bash
export FORK_ORG="yourfork"
# The helm chart creates namespaces, users, and onboards the component
# Use --force to re-onboard an existing component
helm upgrade --install festoji ./resources \
  --set applicationName=festoji \
  --set gitRepoUrl=https://github.com/${FORK_ORG}/festoji \
  --set namespace=slsa-e2e-tenant \
  --set release.targetNamespace=slsa-e2e-managed-tenant
```

Now that you have onboarded your component, your PR will report a running build and you can use `tkn` to see it in the cluster!

### Inspecting the Built Image and Artifacts

Once your pipeline run completes, you can inspect the built container image and its attached artifacts (SBOM, signatures, attestations, vulnerability reports).

#### Getting the Image Reference

First, get the output image reference from your completed build PipelineRun:

```bash
# Find your latest build PipelineRun (filter by type=build to exclude policy checks)
PIPELINERUN=$(kubectl get pipelinerun -n slsa-e2e-tenant \
  -l pipelines.appstudio.openshift.io/type=build \
  --sort-by=.metadata.creationTimestamp \
  -o name | tail -1)

# Get the IMAGE_URL and IMAGE_DIGEST from the PipelineRun results
IMAGE_URL=$(kubectl get ${PIPELINERUN} -n slsa-e2e-tenant \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}')
IMAGE_DIGEST=$(kubectl get ${PIPELINERUN} -n slsa-e2e-tenant \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}')

# Convert internal registry service name to external localhost address
IMAGE_URL_EXTERNAL=$(echo ${IMAGE_URL} | sed 's/registry-service.kind-registry/localhost:5001/')

echo "Image URL: ${IMAGE_URL_EXTERNAL}"
echo "Image Index Digest: ${IMAGE_DIGEST}"
```

The `IMAGE_DIGEST` is the digest of the **image index** (multi-platform manifest). To inspect platform-specific artifacts, you'll need the **image manifest digest** for your platform:

```bash
# Extract the manifest digest for the first platform in the index
MANIFEST_DIGEST=$(skopeo inspect --tls-verify=false --raw \
  docker://${IMAGE_URL_EXTERNAL} | jq -r '.manifests[0].digest')

echo "Image Manifest Digest: ${MANIFEST_DIGEST}"
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
# Artifacts attached to the image index
curl -sk https://localhost:5001/v2/konflux-festoji/referrers/${IMAGE_DIGEST} | jq

# Artifacts attached to the platform-specific manifest
curl -sk https://localhost:5001/v2/konflux-festoji/referrers/${MANIFEST_DIGEST} | jq
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
# Artifacts attached to the image index
curl -sk https://localhost:5001/v2/konflux-festoji/referrers/${IMAGE_DIGEST} | jq

# Artifacts attached to the platform-specific manifest
curl -sk https://localhost:5001/v2/konflux-festoji/referrers/${MANIFEST_DIGEST} | jq
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

## Building isn't enough

Let's merge that PR, let the build run, and then look at what all we have configured Konflux to run.

### Build pipeline

If you look in your source repository, there will be two different PipelineRuns defined in the `.tekton` directory. One for PR events and another for push events.
By default, these are almost identical so the build you see now will largely be the same as the build you saw previously. This means that any build-time checks
(including clair-scan and sast-shell-check) will still run on every build.

After a successful build, Tekton Chains automatically generates SLSA provenance attestations and signs them. You can inspect these attestations to see detailed information about the build, including all the tasks that ran and their results.

#### Viewing SLSA Provenance

To view the attestations attached to your built image, use `cosign` (requires cosign v2+):

```bash
# Get the image digest from your PipelineRun
IMAGE_DIGEST=$(kubectl get pipelinerun <PIPELINERUN_NAME> -n slsa-e2e-tenant \
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

Once Tekton Chains has finished processing the Pipeline Run and generating provenance for the artifacts, the integration service will trigger any tests that are configured.

Our helm chart creates an IntegrationTestScenario that runs Conforma validation **before** any release is triggered. This provides early feedback about whether the build will pass release policies:

```bash
# View the integration test scenario
kubectl get integrationtestscenario policy -n slsa-e2e-tenant -o yaml
```

This scenario runs the Enterprise Contract (Conforma) policy check against the snapshot:
- **Test name**: `policy`
- **Policy**: References `slsa-e2e-managed-tenant/ec-policy` (the same policy used during release)
- **Strict mode**: Enabled - any policy violation fails the test

When a build completes on a push event:

1. **Snapshot created**: After Chains signs the artifacts
2. **Integration test runs**: The `policy` scenario executes Conforma validation
3. **Test passes**: If all policy rules are satisfied
4. **Auto-release triggers**: A Release is automatically created (when `auto-release: "true"`)

View integration test results:

```bash
# Find the snapshot for your build
kubectl get snapshots -n slsa-e2e-tenant --sort-by=.metadata.creationTimestamp

# Check test status
kubectl get snapshot <SNAPSHOT_NAME> -n slsa-e2e-tenant \
  -o jsonpath='{.metadata.annotations.test\.appstudio\.openshift\.io/status}' | jq .

# View the policy test PipelineRun
kubectl get pipelineruns -n slsa-e2e-tenant -l test.appstudio.openshift.io/scenario=policy
```

This pre-release validation ensures you know immediately if a build will pass release policies, without waiting for the actual release pipeline.

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
6. **Release pipeline executes**: In the managed namespace (`slsa-e2e-managed-tenant`)

### Pushing images elsewhere

Even if some developers want access to all credentials, to properly isolate privileged environments, we release artifacts via pipelines in separate managed namespaces.
The Release that was auto-created references a ReleasePlan in the tenant namespace which is mapped to a ReleasePlanAdmission in a specific managed namespace. When the Release
is created, a new Tekton pipeline will be created as specified in that ReleasePlanAdmission.

When we ran the `helm install` above, we created a ReleasePlanAdmission which will run a Pipeline to push this image to a separate location after verifying a specific
policy.

View your release configuration:

```bash
# View the ReleasePlan in the tenant namespace
kubectl get releaseplan festoji-release -n slsa-e2e-tenant -o yaml

# View the ReleasePlanAdmission in the managed namespace
kubectl get releaseplanadmission festoji-release-admission -n slsa-e2e-managed-tenant -o yaml

# View releases
kubectl get releases -n slsa-e2e-tenant

# Check release pipeline runs
kubectl get pipelineruns -n slsa-e2e-managed-tenant -l release.appstudio.openshift.io/name=<RELEASE_NAME>
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
  namespace: slsa-e2e-tenant
spec:
  releasePlan: festoji-release
  snapshot: <SNAPSHOT_NAME>
EOF
```

This is useful for:
- Testing the release pipeline without rebuilding
- Re-releasing after fixing release pipeline configuration
- Releasing an older snapshot

#### What's in a policy?

As we mentioned at the beginning, we are balancing flexibility with security. We use [Conforma](https://conforma.dev) as a policy engine to ensure that specific requirements
(policy rules) are met before images are released.

Our helm chart creates an EnterpriseContractPolicy resource that defines what must be validated:

```bash
# View the policy configuration
kubectl get enterprisecontractpolicy ec-policy -n slsa-e2e-managed-tenant -o yaml
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
kubectl get taskruns -n slsa-e2e-managed-tenant -l tekton.dev/pipelineTask=verify-conforma

# Check task logs for detailed policy evaluation
kubectl logs -n slsa-e2e-managed-tenant <VERIFY_CONFORMA_TASKRUN> --container=report
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

View released images and their attestations:

```bash
# Check released images
cosign tree localhost:5001/released-festoji:latest

# Download attestation from released image
cosign download attestation localhost:5001/released-festoji@${IMAGE_DIGEST} \
  | jq -r '.payload' | base64 -d | jq .
```

The released image includes the same attestations as the build image, ensuring provenance is preserved through the release process.

## What else can this pipeline do?

TODO: change to hermetic with more acurate SBOM

## What else can Conforma do?

TODO: introduce vulnerability, have policy exception

## Additional references

### Development
For information about building and testing custom tasks and pipelines, see [docs/building-tasks-pipelines.md](docs/building-tasks-pipelines.md).

### Documentation
### Recordings
### Controllers