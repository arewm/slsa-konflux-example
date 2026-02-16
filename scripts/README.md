# Scripts

This directory contains automation scripts for SLSA-Konflux installation, configuration, and testing.

## 🚀 Quick Start

### Install Konflux Operator
```bash
# Clone and deploy Konflux operator
git clone https://github.com/konflux-ci/konflux-ci.git
cd konflux-ci
./scripts/deploy-local.sh
```

### Setup Prerequisites
```bash
# Return to slsa-konflux-example repository
cd /path/to/slsa-konflux-example

# Setup prerequisites (creates managed-tenant namespace and custom pipeline config)
./scripts/setup-prerequisites.sh
```

### Onboard Your Application
```bash
# Onboard application using helm chart
helm install festoji ./resources \
  --set applicationName=festoji \
  --set gitRepoUrl=https://github.com/YOUR_ORG/festoji

# Verify onboarding
kubectl get application,component -n default-tenant
```

## 📄 Available Scripts

### ✅ **setup-prerequisites.sh**
**Purpose**: Complete prerequisites setup after Konflux operator deployment

**Features**:
- Creates managed-tenant namespace for privileged release operations
- Applies custom SLSA pipeline configuration (slsa-e2e-oci-ta) to build service
- Idempotent (safe to run multiple times)

### ✅ **generate-release-signing-keys.sh**
**Purpose**: Generate cosign signing keys for managed namespace VSA signing

**Features**:
- Generates cosign key-pair for release attestation signing
- Creates Kubernetes secret in managed namespace
- Supports password-protected keys (via COSIGN_PASSWORD env var)
- Provides instructions for key usage

**Usage**:
```bash
# Generate keys in default managed-tenant namespace
./scripts/generate-release-signing-keys.sh

# Generate keys in custom namespace
./scripts/generate-release-signing-keys.sh my-managed-namespace

# Generate password-protected keys
COSIGN_PASSWORD="secure-password" ./scripts/generate-release-signing-keys.sh
```

## 📋 Prerequisites

These scripts require:
- Konflux operator deployed (via konflux-ci/scripts/deploy-local.sh)
- kubectl configured for your cluster
- Helm for chart installation
- Git for source code management

## 🔧 Complete Workflow

```bash
# 1. Deploy Konflux operator
git clone https://github.com/konflux-ci/konflux-ci.git
cd konflux-ci
./scripts/deploy-local.sh

# 2. Setup prerequisites
cd /path/to/slsa-konflux-example
./scripts/setup-prerequisites.sh

# 3. Onboard your application
helm install festoji ./resources \
  --set applicationName=festoji \
  --set gitRepoUrl=https://github.com/YOUR_ORG/festoji

# 4. Monitor builds and releases
kubectl get pipelineruns -n default-tenant -w
kubectl get releases -n default-tenant
```

## 📖 Development

Scripts follow patterns from the Konflux project and maintain compatibility with the operator-based deployment model. The operator handles cluster-level resources while these scripts manage tenant-specific customizations.