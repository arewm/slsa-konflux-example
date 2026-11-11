# Scripts

This directory contains automation scripts for cluster configuration after Konflux is deployed.

For installation instructions and the complete workflow, see the [root README](../README.md#pre-requisites).

## Available Scripts

### setup-prerequisites.sh
Complete prerequisites setup after Konflux operator deployment. Creates the managed-tenant namespace for privileged release operations and configures the Konflux operator to use the custom SLSA pipeline via the Konflux CR's pipelineConfig field. Also installs Kyverno (via `install-kyverno.sh`); the `spire-crds` chart ships as a dependency of `charts/spiffe-spire`. Idempotent (safe to run multiple times).

### install-kyverno.sh
Installs Kyverno v1.19.2 from the vendored kustomization in `kyverno/` (Konflux v0.2.2 no longer ships it), copies `internal-registry-client-auth` into the `kyverno` namespace, and mounts trust-manager's `trusted-ca` bundle so Kyverno can verify bundles in the internal registry. Called by `setup-prerequisites.sh`.

### generate-release-signing-keys.sh
Generate cosign signing keys for managed namespace VSA signing.

```bash
# Generate keys in default managed-tenant namespace
./scripts/generate-release-signing-keys.sh

# Generate keys in custom namespace
./scripts/generate-release-signing-keys.sh my-managed-namespace

# Generate password-protected keys
COSIGN_PASSWORD="secure-password" ./scripts/generate-release-signing-keys.sh
```
