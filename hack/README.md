# Tekton Bundle Build Scripts

This directory contains scripts for building and pushing Tekton task and pipeline bundles for the managed-context components.

## Prerequisites

- `tkn` (Tekton CLI)
- `yq` (YAML processor)
- `skopeo` or `crane` (container image tools)
- Registry authentication configured (`~/.docker/config.json` or `$XDG_RUNTIME_DIR/containers/auth.json`)

## Quick Start

```bash
export REGISTRY_NAMESPACE=your-quay-username
./hack/build-and-push.sh
```

This builds all tasks and the pipeline, pushing bundles to:
- `quay.io/your-quay-username/task-trivy-sbom-scan:<timestamp>`
- `quay.io/your-quay-username/pipeline-slsa-e2e-oci-ta:<timestamp>`

## Environment Variables

### Required
- `REGISTRY_NAMESPACE` - Quay.io namespace or username

### Optional (Auto-configured)
- `REGISTRY` - Registry URL (default: `quay.io`)
- `BUILD_TAG` - Tag for bundles (default: timestamp `YYYY-MM-DD-HHMMSS`)
- `OUTPUT_TASK_BUNDLE_LIST` - Output file for task bundle references (default: `task-bundle-list`)
- `OUTPUT_PIPELINE_BUNDLE_LIST` - Output file for pipeline bundle references (default: `pipeline-bundle-list`)

## Usage

### Build Everything (Tasks + Pipeline)

```bash
export REGISTRY_NAMESPACE=your-username
./hack/build-and-push.sh
```

Output:
```
quay.io/your-username/task-trivy-sbom-scan:2025-11-06-123456@sha256:abc...
quay.io/your-username/pipeline-slsa-e2e-oci-ta:2025-11-06-123456@sha256:def...
```

### Build Only Tasks

```bash
./hack/build-and-push.sh tasks
```

### Build Only Pipeline

```bash
./hack/build-and-push.sh pipeline
```

**Note:** Pipeline build automatically fetches and pins the latest task bundle digests.

### Build Specific Task

```bash
./hack/build-and-push.sh task trivy-sbom-scan 0.1
```

## Output Files

The scripts generate digest-pinned bundle references:

- **`task-bundle-list`** - Task bundle references
  ```
  quay.io/your-username/task-trivy-sbom-scan:2025-11-06-123456@sha256:abc123...
  ```

- **`pipeline-bundle-list`** - Pipeline bundle references
  ```
  quay.io/your-username/pipeline-slsa-e2e-oci-ta:2025-11-06-123456@sha256:def456...
  ```

These digest-pinned references ensure reproducibility and can be used in:
- Enterprise Contract policy configurations
- Kubernetes deployment manifests
- Pipeline references

## Bundle Tagging Strategy (ADR/0054)

Following [Konflux ADR/0054](https://konflux-ci.dev/architecture/ADR/0054-task-versioning/):

**Tasks:** Version-based floating tags
- Tag matches the task version from `app.kubernetes.io/version` label
- Example: `quay.io/your-username/task-trivy-sbom-scan:0.1@sha256:abc...`
- The `:0.1` tag is updated each time that version is rebuilt
- **Overwrite protection:** Script checks if tag exists and prevents accidental overwrites

**Pipelines:** Latest tag
- Always tagged as `:latest`
- Example: `quay.io/your-username/pipeline-slsa-e2e-oci-ta:latest@sha256:def...`

**Versioning Guidelines:**
- For `0.x` versions: Breaking changes → bump minor (`0.1` → `0.2`), Non-breaking → bump patch (`0.1` → `0.1.1`)
- For `1.0+` versions: Follow semantic versioning strictly

## Script Details

### `build-and-push.sh`
Main orchestrator that coordinates building tasks and pipelines.

**Usage:**
```bash
./hack/build-and-push.sh [all|tasks|pipeline|task <name> <version>]
```

### `build-task.sh`
Builds and pushes individual Tekton task bundles.

**Usage:**
```bash
./hack/build-task.sh <task-name> <version>
```

Example:
```bash
./hack/build-task.sh trivy-sbom-scan 0.1
```

**Task location:** `managed-context/tasks/<name>/<version>/<name>.yaml`

### `build-pipeline.sh`
Builds and pushes the SLSA e2e pipeline bundle with digest-pinned task references.

**Features:**
- Fetches latest digests for all referenced task bundles
- Updates pipeline YAML with pinned bundle references
- Ensures reproducible pipeline builds

**Usage:**
```bash
./hack/build-pipeline.sh [pipeline-name]
```

## Adding New Tasks

To add a new task to the build process:

1. Create the task directory and YAML:
   ```
   managed-context/tasks/<task-name>/<version>/<task-name>.yaml
   ```

2. Update `hack/build-and-push.sh` TASKS array:
   ```bash
   TASKS=(
       "trivy-sbom-scan:0.1"
       "your-new-task:0.1"
   )
   ```

3. Build:
   ```bash
   ./hack/build-and-push.sh
   ```

## Trust Boundaries

These scripts build **managed-context** components only:
- Tasks that run in the managed namespace with access to signing keys
- Pipeline that orchestrates the managed release workflow
- All bundles use digest pinning for cryptographic verification

For tenant-context components, use separate build processes that maintain trust boundary separation.

## Examples

### First Time / Bootstrap
```bash
export REGISTRY_NAMESPACE=my-quay-username
export FORCE_PUSH=true  # Required for initial push
./hack/build-and-push.sh
```

Creates:
- `quay.io/my-quay-username/task-trivy-sbom-scan:0.1@sha256:abc...`
- `quay.io/my-quay-username/pipeline-slsa-e2e-oci-ta:latest@sha256:def...`

### Normal Development (tag already exists)
```bash
export REGISTRY_NAMESPACE=my-username
./hack/build-and-push.sh task trivy-sbom-scan 0.1
```

If tag `:0.1` already exists, you'll see:
```
ERROR: Bundle tag already exists: quay.io/my-username/task-trivy-sbom-scan:0.1

If you need to:
  - Fix a bug: Increment patch version (0.1 → 0.1.1)
  - Make breaking changes: Increment minor version (0.1 → 0.2)
  - Bootstrap/force overwrite: Set FORCE_PUSH=true
```

### Force Overwrite (use carefully)
```bash
export REGISTRY_NAMESPACE=my-username
export FORCE_PUSH=true
./hack/build-and-push.sh
```

This bypasses the tag existence check. Use for:
- Initial bootstrapping
- Fixing critical bugs in the same version
- Development/testing (not production)

## Troubleshooting

### Authentication Issues
Ensure you're logged into the registry:
```bash
podman login quay.io
# or
docker login quay.io
```

### Missing Commands
Install required tools:
```bash
# macOS
brew install tektoncd-cli yq skopeo

# Linux
# Install from respective package managers
```

### Bundle Push Failures
- Verify `REGISTRY_NAMESPACE` is correct
- Check registry permissions (need push access)
- Verify network connectivity to registry
