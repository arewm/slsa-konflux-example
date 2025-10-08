# Scripts

This directory contains automation scripts for SLSA-Konflux installation, configuration, and testing.

## 🚀 Quick Start

### Bootstrap External Cluster
```bash
# Bootstrap tenant and managed namespaces on external cluster
./scripts/bootstrap-cluster.sh

# With custom configuration
./scripts/bootstrap-cluster.sh \
  --tenant-namespace my-tenant \
  --managed-namespace my-managed \
  --registry-url quay.io/my-org/slsa-demo
```

### Setup End-to-End Workflow  
```bash
# Setup complete SLSA workflow (after bootstrap)
./scripts/setup-end-to-end-demo.sh

# Setup with custom configuration
./scripts/setup-end-to-end-demo.sh \
  --tenant-namespace my-tenant \
  --managed-namespace my-managed \
  --git-url https://github.com/my-org/my-repo

# Test individual components
./scripts/test-end-to-end.sh
```

## 📄 Available Scripts

### ✅ **bootstrap-cluster.sh** (READY)
**Purpose**: Complete cluster setup for SLSA-Konflux demonstration

**Features**:
- ✅ Creates tenant and managed namespaces
- ✅ Installs all Tekton tasks (git-clone-slsa, conforma-vsa, vsa-sign)
- ✅ Sets up RBAC and service accounts
- ✅ Generates and configures signing keys
- ✅ Creates Konflux Application and Component
- ✅ Configures Release Plans and Release Plan Admissions
- ✅ Sets up workspace PVCs
- ✅ Validates installation

### ✅ **test-end-to-end.sh** (READY)
**Purpose**: Comprehensive testing of SLSA-Konflux workflow

**Features**:
- ✅ Tests tenant VSA generation (conforma-vsa task)
- ✅ Tests managed VSA signing (vsa-sign task)
- ✅ Tests complete managed pipeline
- ✅ Validates trust boundary separation
- ✅ Verifies VSA output and validation
- ✅ Generates detailed test reports
- ✅ Automatic cleanup of test resources

### ✅ **setup-end-to-end-demo.sh** (READY)
**Purpose**: Sets up complete SLSA-Konflux workflow for commit-triggered demos

**Features**:
- ✅ Deploys tenant build pipeline with SLSA verification
- ✅ Configures release automation (ReleasePlan/ReleasePlanAdmission)
- ✅ Deploys managed release pipeline with VSA generation
- ✅ Configures Component to use custom SLSA pipeline
- ✅ Validates all configuration components
- ✅ Provides instructions for triggering via git commits

### 🔄 **install-konflux.sh** *(Coming Soon)*
ARM/macOS compatible Konflux installation with enhanced UX

### 🔄 **validate-slsa-compliance.sh** *(Coming Soon)*
Comprehensive SLSA compliance verification

## 📋 Prerequisites

These scripts require:
- Kubernetes cluster (local or cloud)
- Docker/compatible container runtime
- kubectl configured for your cluster
- Git for source code management

## 🔧 Usage

```bash
# Complete setup
./scripts/install-konflux.sh
./scripts/bootstrap-managed-namespace.sh
./scripts/run-demo.sh

# Validation
./scripts/test-trust-boundaries.sh
./scripts/validate-slsa-compliance.sh
```

## 📖 Development

Scripts are based on patterns from:
- `.internal/repositories/konflux-ci/` - Installation automation
- `.internal/repositories/build-service/` - Component onboarding
- `.internal/repositories/release-service/` - Managed namespace setup

All scripts maintain ARM/macOS compatibility and follow Konflux conventions.