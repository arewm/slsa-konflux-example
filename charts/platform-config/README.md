# Platform Config Helm Chart

Install once per cluster to configure policies, signing keys, and permissions for SLSA-compliant releases.

## Overview

This chart creates shared infrastructure that all onboarded components use:
- **EnterpriseContractPolicy** defining SLSA3 validation rules for integration tests and releases
- **ServiceAccounts** for release pipeline execution in tenant and managed namespaces
- **RoleBindings** granting admin access to users and release pipeline permissions
- **ClusterRoleBindings** enabling self-access review for authenticated users
- **Signing Keys** (cosign key-pair) for signing release attestations
- **Trusted Artifacts Secret** storing OCI registry credentials for intermediate artifacts

## Prerequisites

- Kubernetes cluster with Konflux installed
- Helm 3.x
- Tenant namespace created (e.g., `default-tenant` by Konflux operator)
- Managed namespace created (e.g., `managed-tenant` by setup-prerequisites.sh)

## Installation

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

These values **must match** between platform-config and component-onboarding charts. Mismatched values cause component releases to reference non-existent policies or service accounts.

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
    slsaSourceMinLevel: ""  # Empty uses policy data default (currently 2)
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

```bash
helm upgrade platform ./charts/platform-config
```

Signing keys are preserved across upgrades (`regenerateKeys: false`). Setting `regenerateKeys: true` invalidates all previous signatures.

## Uninstalling

```bash
helm uninstall platform
```

**WARNING**: This removes the EnterpriseContractPolicy and signing keys. Verify no components depend on these resources before uninstalling.
