# Scripts

This directory contains automation scripts for SLSA-Konflux installation, configuration, and testing.

## Quick Start

### Install Konflux Operator
```bash
git clone https://github.com/konflux-ci/konflux-ci.git
cd konflux-ci
./scripts/deploy-local.sh
```

### Setup Prerequisites
```bash
cd /path/to/slsa-konflux-example
./scripts/setup-prerequisites.sh
```

### Onboard Your Component
```bash
helm install festoji ./charts/component-onboarding \
  --set componentName=festoji \
  --set gitRepoUrl=https://github.com/FORK_ORG/festoji

kubectl get application,component -n default-tenant
```

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

## Prerequisites

These scripts require:
- Konflux operator deployed (via konflux-ci/scripts/deploy-local.sh)
- kubectl configured for your cluster
- Helm for chart installation

## Complete Workflow

```bash
# 1. Deploy Konflux operator
git clone https://github.com/konflux-ci/konflux-ci.git
cd konflux-ci
./scripts/deploy-local.sh

# 2. Setup prerequisites
cd /path/to/slsa-konflux-example
./scripts/setup-prerequisites.sh

# 3. Install platform config
helm install platform ./charts/platform-config

# 4. Onboard your component
helm install festoji ./charts/component-onboarding \
  --set componentName=festoji \
  --set gitRepoUrl=https://github.com/FORK_ORG/festoji

# 5. Monitor builds and releases
kubectl get pipelineruns -n default-tenant -w
kubectl get releases -n default-tenant
```
