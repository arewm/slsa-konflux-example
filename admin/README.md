# Build Service Configuration Helm Chart

**ADMIN-ONLY** Helm chart for configuring Konflux build-service pipeline bundles.

> **STATUS**: This Helm chart is currently **not used** in the installation process.
> The Konflux operator manages the `build-pipeline-config` ConfigMap and does not yet
> support disabling this management. Custom pipeline configuration is currently applied
> via direct `kubectl apply` (see `admin/build-pipeline-config.yaml`).
> This chart will be useful once the operator supports external ConfigMap management.

## Overview

This Helm chart manages the `build-pipeline-config` ConfigMap in the `build-service` namespace, which controls which Tekton pipeline bundles are used for building components in Konflux.

**WARNING**: This chart modifies cluster-wide configuration and requires administrator privileges. It is intended for use when running Konflux on custom clusters (like kind) where you need to override the default pipeline bundles.

## Purpose

The build-service uses the `build-pipeline-config` ConfigMap to determine which pipeline bundles to use for different build types. This chart allows you to:

1. Override specific pipeline bundle references (e.g., to use local or custom pipelines)
2. Replace the default pipeline used by components
3. Add custom pipeline definitions

This is particularly useful for:
- Local development with kind clusters
- Testing custom pipeline modifications
- Using pipeline bundles from alternative registries
- Implementing custom build workflows

## Prerequisites

- Kubernetes cluster with Konflux installed
- Helm 3.x
- Administrator access to the cluster
- Access to the `build-service` namespace

## Installation

### Basic Usage (Override Specific Pipeline)

To override a single pipeline bundle:

```bash
helm install build-config ./admin \
  --set pipelines[0].name=docker-build-oci-ta \
  --set pipelines[0].bundle=localhost:5000/tekton-catalog/pipeline-docker-build-oci-ta@sha256:abc123...
```

### Using a Values File

Create a `custom-values.yaml` file:

```yaml
namespace: build-service
defaultPipelineName: docker-build-oci-ta

pipelines:
  - name: docker-build-oci-ta
    bundle: localhost:5000/tekton-catalog/pipeline-docker-build-oci-ta@sha256:817f9c709df00fd7d21c9e3be2f18db2039e5f5995d24512af644d787ad7c7b6
  - name: docker-build
    bundle: quay.io/myorg/tekton-catalog/pipeline-docker-build@sha256:d7e9f4670436107551ea8b0fd022df7af60256a2cbc179bb34759a32c0e8a64c
```

Install the chart:

```bash
helm install build-config ./admin -f custom-values.yaml
```

### Complete Configuration Override

If you need full control over the entire ConfigMap, use `fullConfig`:

```yaml
namespace: build-service
fullConfig: |
  default-pipeline-name: docker-build-oci-ta
  pipelines:
  - name: fbc-builder
    bundle: quay.io/konflux-ci/tekton-catalog/pipeline-fbc-builder@sha256:d6fd96a7bb6fe67082518ea59a916dde15a9584b3b2e109e48fc2ca104d8e8e5
  - name: docker-build
    bundle: quay.io/konflux-ci/tekton-catalog/pipeline-docker-build@sha256:d7e9f4670436107551ea8b0fd022df7af60256a2cbc179bb34759a32c0e8a64c
  - name: docker-build-oci-ta
    bundle: localhost:5000/custom-pipelines/docker-build-oci-ta@sha256:abc123...
  - name: tekton-bundle-builder
    bundle: quay.io/konflux-ci/tekton-catalog/pipeline-tekton-bundle-builder@sha256:792a5ca1a41c238a953fa2af4a3823a199d0d1b81084a26adb862aa6158b6723
  - name: tekton-bundle-builder-oci-ta
    bundle: quay.io/konflux-ci/tekton-catalog/pipeline-tekton-bundle-builder-oci-ta@sha256:4ab59c8ba98801a6f0ba1070e690297c65fd09471e0536696bd6708bb3f9b878
```

## Configuration

### Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `namespace` | Namespace where build-service is installed | `build-service` |
| `configMapName` | Name of the ConfigMap to create/update | `build-pipeline-config` |
| `defaultPipelineName` | Default pipeline used when component doesn't specify one | `docker-build-oci-ta` |
| `pipelines` | Array of pipeline bundle overrides | `[]` |
| `fullConfig` | Complete YAML configuration (overrides individual settings) | `""` |

### Pipeline Entry Format

Each entry in the `pipelines` array should have:

```yaml
- name: pipeline-name          # The pipeline identifier
  bundle: registry/path@sha256:digest  # The OCI bundle reference
```

## Common Use Cases

### 1. Local Kind Registry

When running Konflux on kind with a local registry:

```yaml
pipelines:
  - name: docker-build-oci-ta
    bundle: localhost:5000/tekton-catalog/pipeline-docker-build-oci-ta@sha256:817f9c709df00fd7d21c9e3be2f18db2039e5f5995d24512af644d787ad7c7b6
```

### 2. Custom Pipeline Development

Testing a modified pipeline:

```yaml
pipelines:
  - name: docker-build-oci-ta
    bundle: quay.io/myorg/custom-pipeline@sha256:abc123...
```

### 3. Alternative Registry

Using bundles from a private registry:

```yaml
pipelines:
  - name: docker-build-oci-ta
    bundle: registry.example.com/tekton/pipeline-docker-build-oci-ta@sha256:def456...
  - name: docker-build
    bundle: registry.example.com/tekton/pipeline-docker-build@sha256:ghi789...
```

## Verification

After installing the chart, verify the ConfigMap was updated:

```bash
# View the ConfigMap
kubectl get configmap build-pipeline-config -n build-service -o yaml

# Or use oc neat for cleaner output
oc get -n build-service configmap build-pipeline-config -o yaml | oc neat
```

## Updating Configuration

To update the configuration after initial installation:

```bash
# Update using new values
helm upgrade build-config ./admin -f updated-values.yaml

# Or update specific values
helm upgrade build-config ./admin \
  --set pipelines[0].bundle=new-registry/path@sha256:newdigest
```

## Rollback

If you need to restore the original configuration:

```bash
# Rollback to previous release
helm rollback build-config

# Or reinstall with default values
helm uninstall build-config
helm install build-config ./admin
```

## Troubleshooting

### Check Current Configuration

```bash
# View the ConfigMap content
kubectl get cm build-pipeline-config -n build-service -o jsonpath='{.data.config\.yaml}'
```

### Verify Pipeline Bundle References

Ensure your bundle references are:
1. Valid OCI registry paths
2. Include SHA256 digests (not tags)
3. Accessible from the cluster

### Common Issues

**Issue**: Builds fail with "pipeline not found"
- **Solution**: Verify the pipeline name in the ConfigMap matches what components are requesting

**Issue**: Bundle pull errors
- **Solution**: Check registry authentication and network access from the cluster

**Issue**: Changes not taking effect
- **Solution**: The build-service may need to be restarted to pick up ConfigMap changes:
  ```bash
  kubectl rollout restart deployment/build-service-controller -n build-service
  ```

## Security Considerations

- This chart requires admin privileges to modify the build-service namespace
- Only trusted administrators should have access to modify this configuration
- Bundle references should use SHA256 digests, not mutable tags
- Ensure pipeline bundles come from trusted sources
- Consider using admission controllers to prevent unauthorized modifications

## Uninstalling

```bash
helm uninstall build-config
```

**Note**: This removes the Helm release but leaves the ConfigMap in place. To restore the default configuration, you may need to manually edit or recreate the ConfigMap with the original Konflux defaults.

## Related Resources

- [User-level Konflux onboarding chart](../resources/) - For deploying applications and components
- [Konflux build-service documentation](https://konflux-ci.dev/docs/how-tos/configuring-builds/)
- [Tekton pipeline bundles](https://tekton.dev/docs/pipelines/pipelines/#tekton-bundles)

## License

This Helm chart is provided as-is for use with Konflux CI.
