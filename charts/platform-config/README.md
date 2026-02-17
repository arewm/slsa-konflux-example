# Platform Config Helm Chart

Platform configuration for Konflux - install once per cluster to set up policies, signing keys, and permissions.

## Overview

This chart creates the shared infrastructure resources that components will use:
- **EnterpriseContractPolicy**: SLSA3 policy for integration tests and releases
- **ServiceAccounts**: For release pipeline execution in both tenant and managed namespaces
- **RoleBindings**: Admin access for users, release pipeline permissions
- **ClusterRoleBindings**: Self-access permissions for authenticated users
- **Signing Keys**: Cosign key-pair for release attestation signing (VSAs, SBOMs)
- **Trusted Artifacts Secret**: OCI registry credentials for intermediate artifacts

Install this chart **once per cluster** before onboarding any components.

## Prerequisites

- Kubernetes cluster with Konflux installed
- Helm 3.x
- Tenant namespace created (e.g., `default-tenant` by Konflux operator)
- Managed namespace created (e.g., `managed-tenant` by setup-prerequisites.sh)

## Installation

Basic installation with defaults:

```bash
helm install platform ./charts/platform-config
```

With custom namespaces:

```bash
helm install platform ./charts/platform-config \
  --set namespace=my-tenant \
  --set release.targetNamespace=my-managed-tenant
```

## Important Values

These values **must match** between platform-config and component-onboarding charts:

| Value | Default | Description |
|-------|---------|-------------|
| `namespace` | `default-tenant` | Tenant namespace for builds |
| `release.targetNamespace` | `managed-tenant` | Managed namespace for releases |
| `release.policyName` | `ec-policy` | EnterpriseContractPolicy name |
| `release.serviceAccount` | `release-service-account` | ServiceAccount for release pipeline |

## Configuration

### User Access

```yaml
users:
  - user1  # Admin access in tenant namespace
targetUsers:
  - user2  # Admin access in managed namespace
```

### Policy Configuration

```yaml
release:
  policy:
    policyBundle: "quay.io/conforma/release-policy:konflux"
    acceptableBundles: "oci::quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest"
    slsaSourceMinLevel: ""  # Leave empty to use policy data default (2)
```

### Signing Keys

```yaml
signing:
  enableSigning: true
  signingSecretName: "release-signing-key"
  regenerateKeys: false  # WARNING: true invalidates all previous signatures
```

### Trusted Artifacts

For external registries:

```yaml
release:
  trustedArtifacts:
    ociStorage: "quay.io/myorg/trusted-artifacts"
    username: "myuser"
    password: "mytoken"
```

## After Installation

1. Verify resources were created:

```bash
kubectl get enterprisecontractpolicy -n managed-tenant
kubectl get serviceaccount release-pipeline -n default-tenant
kubectl get serviceaccount release-service-account -n managed-tenant
kubectl get secret release-signing-key -n managed-tenant
```

2. Install component-onboarding chart(s) to onboard components

## Upgrading

To upgrade the platform configuration:

```bash
helm upgrade platform ./charts/platform-config
```

**Note**: By default, signing keys are preserved across upgrades (`regenerateKeys: false`). Change this only if you need new keys and understand the consequences.

## Uninstalling

```bash
helm uninstall platform
```

**WARNING**: This removes the EnterpriseContractPolicy and signing keys. Ensure no components are still using these resources before uninstalling.
