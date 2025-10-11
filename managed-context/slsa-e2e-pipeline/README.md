# SLSA E2E Pipeline Bundle

This directory contains a custom Tekton pipeline for the SLSA e2e demo, packaged as a Tekton bundle.

## Overview

The `slsa-e2e-oci-ta` pipeline demonstrates SLSA compliance in a KinD environment using trusted artifacts. It references task bundles from the official `quay.io/konflux-ci/tekton-catalog` repository.

## Prerequisites

### Required Tools

- **`tkn`** - Tekton CLI for pushing bundles
  - Install: `brew install tektoncd-cli` (macOS) or [releases](https://github.com/tektoncd/cli/releases)

- **`yq`** - YAML processor for pipeline manipulation
  - Install: `brew install yq` (macOS) or [releases](https://github.com/mikefarah/yq/releases)

- **`skopeo`** or **`crane`** - OCI image inspection and copying (at least one required)
  - **skopeo**: `brew install skopeo` (macOS) or [installation](https://github.com/containers/skopeo/blob/main/install.md)
  - **crane**: `brew install crane` (macOS) or `go install github.com/google/go-containerregistry/cmd/crane@latest`

- **`ec`** - Enterprise Contract CLI for creating acceptable bundles data bundle
  - Install: [ec releases](https://github.com/enterprise-contract/ec-cli/releases)
  - Required for creating acceptable bundles data bundle used in policy validation

### Registry Access

- **Podman/Docker authentication** configured for your container registry (defaults to quay.io)
- **Write access** to your registry namespace for both:
  - Pipeline bundles: `${REGISTRY}/${REGISTRY_NAMESPACE}/pipeline-slsa-e2e-oci-ta`
  - Acceptable bundles: `${REGISTRY}/${REGISTRY_NAMESPACE}/slsa-e2e-data-acceptable-bundles`

## Building and Pushing from CLI

### Authentication

Ensure you're authenticated to your container registry (defaults to quay.io):

```bash
podman login quay.io
# Or for other registries:
# podman login ghcr.io
# podman login docker.io
```

### Build and Push

To build and push the pipeline bundle from the CLI:

```bash
# Set your registry namespace (required)
export REGISTRY_NAMESPACE="your-registry-username"

# Optional: Use a different registry (defaults to quay.io)
export REGISTRY="quay.io"

# Optional: Set a custom build tag (defaults to timestamp)
export BUILD_TAG="$(git rev-parse --short HEAD)"

# Build and push
./managed-context/slsa-e2e-pipeline/hack/build-and-push.sh
```

The script will:
1. **Fetch latest digests** for all task bundles from `quay.io/konflux-ci/tekton-catalog`
2. **Pin task bundles** by updating references to `repo:tag@sha256:digest` format
3. **Create pipeline bundle** from pinned pipeline with OCI annotations
4. **Push with two tags**:
   - `${REGISTRY}/${REGISTRY_NAMESPACE}/pipeline-slsa-e2e-oci-ta:${BUILD_TAG}`
   - `${REGISTRY}/${REGISTRY_NAMESPACE}/pipeline-slsa-e2e-oci-ta:latest`
5. **Create acceptable bundles** (if `ec` CLI available):
   - Contains all task bundles + pipeline bundle for policy validation
   - Tagged as `${REGISTRY}/${REGISTRY_NAMESPACE}/slsa-e2e-data-acceptable-bundles:${BUILD_TAG}` and `:latest`
6. **Save references** with digests to `pipeline-bundle-list`

### Example

```bash
export REGISTRY_NAMESPACE="arewm"
export BUILD_TAG="v1.0.0"
./managed-context/slsa-e2e-pipeline/hack/build-and-push.sh
```

Output:
```
Pinning task bundle references...
Fetching digest for: quay.io/konflux-ci/tekton-catalog/task-init:0.2
  Task 0: quay.io/konflux-ci/tekton-catalog/task-init:0.2 -> quay.io/konflux-ci/tekton-catalog/task-init:0.2@sha256:abc...
Fetching digest for: quay.io/konflux-ci/tekton-catalog/task-git-clone-oci-ta:0.1
  Task 1: quay.io/konflux-ci/tekton-catalog/task-git-clone-oci-ta:0.1 -> quay.io/konflux-ci/tekton-catalog/task-git-clone-oci-ta:0.1@sha256:def...
...

Building and pushing pipeline bundle: quay.io/arewm/pipeline-slsa-e2e-oci-ta:v1.0.0
Using authentication from: /Users/arewm/.docker
Pushed Tekton Bundle to quay.io/arewm/pipeline-slsa-e2e-oci-ta:v1.0.0@sha256:123...
Created:
quay.io/arewm/pipeline-slsa-e2e-oci-ta:v1.0.0@sha256:123...

Tagging as latest: quay.io/arewm/pipeline-slsa-e2e-oci-ta:latest

Pipeline bundle pushed successfully!
  quay.io/arewm/pipeline-slsa-e2e-oci-ta:v1.0.0
  quay.io/arewm/pipeline-slsa-e2e-oci-ta:latest
Bundle references saved to: pipeline-bundle-list

Building acceptable bundles data bundle...
Creating acceptable bundles with 10 bundles...
Acceptable bundles data bundle: quay.io/arewm/slsa-e2e-data-acceptable-bundles:v1.0.0
Acceptable bundles data bundle: quay.io/arewm/slsa-e2e-data-acceptable-bundles:latest
```

## Task References

This pipeline uses existing task bundles from `quay.io/konflux-ci/tekton-catalog`:
- `init` (0.2) - Initialize build context
- `git-clone-oci-ta` (0.1) - Clone source repository
- `verify-source` (0.1) - Verify SLSA source level via VSA git notes
- `prefetch-dependencies-oci-ta` (0.2) - Prefetch dependencies for hermetic builds
- `buildah-oci-ta` (0.6) - Build container image with buildah
- `build-image-index` (0.1) - Create multi-arch image index
- `clair-scan` (0.3) - Vulnerability scanning
- `sast-shell-check-oci-ta` (0.1) - Static analysis for shell scripts
- `apply-tags` (0.2) - Apply additional tags to built image
- `push-dockerfile-oci-ta` (0.1) - Push Dockerfile as layer

**No task bundles need to be rebuilt** - the script automatically fetches the latest digest for each task bundle and pins them in the pipeline before pushing. This ensures:
- Reproducible builds with immutable references
- Always uses the latest approved versions from konflux-ci catalog
- Task bundles are validated and tracked in the acceptable bundles data bundle

## Acceptable Bundles Data Bundle

If the `ec` CLI is installed, the script creates an acceptable bundles data bundle containing all task bundles and the pipeline bundle. This is used by Enterprise Contract for policy validation to ensure all bundles are approved.

The data bundle is pushed to:
- `${REGISTRY}/${REGISTRY_NAMESPACE}/slsa-e2e-data-acceptable-bundles:${BUILD_TAG}`
- `${REGISTRY}/${REGISTRY_NAMESPACE}/slsa-e2e-data-acceptable-bundles:latest`

To use in Enterprise Contract policies:
```yaml
sources:
  - policy:
      - github.com/enterprise-contract/ec-policies//policy/lib
      - github.com/enterprise-contract/ec-policies//policy/release
    data:
      - oci::${REGISTRY}/${REGISTRY_NAMESPACE}/slsa-e2e-data-acceptable-bundles:latest
```

## Using the Bundle

Reference the pipeline bundle in your PipelineRun:

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: my-build
spec:
  pipelineRef:
    resolver: bundles
    params:
      - name: bundle
        value: ${REGISTRY}/${REGISTRY_NAMESPACE}/pipeline-slsa-e2e-oci-ta:v1.0.0
      - name: kind
        value: pipeline
      - name: name
        value: slsa-e2e-oci-ta
  params:
    - name: git-url
      value: https://github.com/example/repo
    - name: revision
      value: main
    - name: output-image
      value: quay.io/example/app:latest
  workspaces:
    - name: git-auth
      emptyDir: {}
    - name: netrc
      emptyDir: {}
```
