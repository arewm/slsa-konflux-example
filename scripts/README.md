# Scripts

This directory contains automation scripts for cluster configuration after Konflux is deployed.

For installation instructions and the complete workflow, see the [root README](../README.md#pre-requisites).

## Available Scripts

### setup-prerequisites.sh
Complete prerequisites setup after Konflux operator deployment. Creates the managed-tenant namespace for privileged release operations and configures the Konflux operator to use the custom SLSA pipeline via the Konflux CR's pipelineConfig field. Idempotent (safe to run multiple times).

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
