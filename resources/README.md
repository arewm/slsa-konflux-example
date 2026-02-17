# Konflux Onboarding Helm Chart

A Helm chart for onboarding applications to Konflux CI with SLSA 1.0 build L3 policy verification.

## Overview

This Helm chart creates the necessary Konflux resources to onboard a new application:
- **Application**: The top-level Konflux application resource
- **Component**: A component linked to a Git repository for building
- **IntegrationTestScenario** (two scenarios): Policy-based integration tests using Enterprise Contract for SLSA3 verification (separate scenarios for PR and push contexts)
- **EnterpriseContractPolicy**: Defines the SLSA3 policy rules for integration and release validation
- **ReleasePlan**: Defines how and where to release the application
- **ReleasePlanAdmission**: Configures the release pipeline to push images to an external registry
- **ServiceAccount**: Service account for release pipeline execution
- **RoleBinding (authenticated-view)**: Grants view permissions to all authenticated users in the managed namespace
- **RoleBinding (release-service-account)**: Grants release permissions to the service account in the managed namespace

## Prerequisites

- Kubernetes cluster with Konflux installed
- Helm 3.x
- A namespace where you want to deploy the resources
- A Git repository URL containing your application code

**Optional Requirements:**
- **Image Controller**: Required for automatic Quay.io repository creation and credential management. The Component CR includes an annotation (`image.redhat.com/generate`) that triggers ImageRepository creation, but this only works if image-controller is deployed in your cluster.
  - **Note**: The default `konflux-ci/konflux-ci` installation does **NOT** include image-controller
  - Without image-controller, you must manually specify `containerImage` in values.yaml
  - For KinD/local development, using the local registry is simplest: `registry-service.kind-registry/<app-name>:latest`
  - To deploy image-controller: `https://github.com/konflux-ci/konflux-ci/blob/main/deploy-image-controller.sh`

## Installation

### Basic Usage

Using default namespaces (`slsa-e2e-tenant` for application, `slsa-e2e-managed-tenant` for release):

```bash
helm install my-app ./konflux-onboarding \
  --set applicationName=my-application \
  --set gitRepoUrl=https://github.com/myorg/myrepo
```

Or with custom namespaces:

```bash
helm install my-app ./konflux-onboarding \
  --set applicationName=my-application \
  --set gitRepoUrl=https://github.com/myorg/myrepo \
  --set namespace=my-namespace \
  --set release.targetNamespace=managed-tenant
```

### With Custom Values File

Create a `my-values.yaml` file:

```yaml
applicationName: my-application
gitRepoUrl: https://github.com/myorg/myrepo
namespace: my-namespace
gitRevision: main
displayName: "My Application"
release:
  targetNamespace: managed-tenant
```

Install the chart:

```bash
helm install my-app ./konflux-onboarding -f my-values.yaml
```

## Configuration

### Required Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `applicationName` | Name of the application and component | `my-app` |
| `gitRepoUrl` | Git repository URL for the component | `https://github.com/myorg/myrepo` |

### Optional Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `namespace` | Kubernetes namespace to deploy resources | `slsa-e2e-tenant` |
| `gitRevision` | Git branch/tag to track | `main` |
| `gitContext` | Context directory in the repository | `.` |
| `displayName` | Display name for the application | Same as `applicationName` |
| `containerImage` | Container image for the component | `registry-service.kind-registry/rbean-festoji:latest` |
| `customContainerImage` | Custom container image URL (requires `dockerconfigjson`) | `""` |
| `dockerconfigjson` | Base64-encoded dockerconfigjson for custom image authentication | `""` |
| `release.targetNamespace` | Target namespace for ReleasePlanAdmission and EnterpriseContractPolicy | `slsa-e2e-managed-tenant` |
| `release.destination` | Release destination registry for the component | `registry-service.kind-registry/released-{applicationName}` |
| `release.environment` | Environment name for the release | `production` |
| `release.policyName` | Enterprise Contract policy name for release | `ec-policy` |
| `release.serviceAccount` | Service account for release pipeline | `release-service-account` |

## Resources Created

### 1. Application
Creates a Konflux Application resource that serves as the parent for components.

### 2. Component
Creates a Component that:
- References the Application
- Points to your Git repository
- Triggers builds when code changes

### 3. IntegrationTestScenario (two scenarios)
Creates two integration test scenarios:

**policy-pr** (pull_request context):
- Validates PR builds at source level 1
- PR source branches are not protected, so cannot achieve higher source levels
- Provides early feedback on whether push builds will succeed

**policy-push** (push context):
- Validates push builds with strict policy (same as release)
- Requires source level 2+ with source-tool provenance
- Ensures builds meet full release requirements

### 4. EnterpriseContractPolicy (named "example-policy")
Defines the SLSA3 policy for the application:
- **Namespace**: Created in the managed namespace (`release.targetNamespace`)
- **Policy Source**: `github.com/enterprise-contract/config//slsa3`
- **Collections**: Uses the `slsa3` collection of conformance rules
- Referenced by both IntegrationTestScenario and ReleasePlanAdmission

### 5. Secret (conditional)
When using a custom container image, a pull secret is automatically created:
- **Name**: `<applicationName>-pull-secret`
- **Type**: `kubernetes.io/dockerconfigjson`
- Only created when `customContainerImage` is provided

### 6. ReleasePlan
Creates a ReleasePlan that:
- References the Application
- Targets the namespace where ReleasePlanAdmission is located
- Triggers release workflows when builds complete

### 7. ReleasePlanAdmission
Creates a ReleasePlanAdmission that:
- Configures the push-to-external-registry pipeline
- Maps the component to a destination registry
- Uses Enterprise Contract for release policy validation
- Default destination: `registry-service.kind-registry/released-<applicationName>`

### 8. ServiceAccount
Creates a ServiceAccount in the managed namespace:
- **Name**: Configurable via `release.serviceAccount` (default: `release-service-account`)
- Used by the release pipeline for authentication and authorization
- Created in the same namespace as the ReleasePlanAdmission

### 9. RoleBinding (authenticated-view)
Creates a RoleBinding in the managed namespace:
- **Name**: `authenticated-view`
- Grants the `view` ClusterRole to the `system:authenticated` group
- Allows all authenticated users to view resources in the managed namespace

### 10. RoleBinding (release-service-account)
Creates a RoleBinding in the managed namespace:
- **Name**: `{release.serviceAccount}-binding`
- Grants the `release-pipeline-resource-role` ClusterRole to the release service account
- Allows the release pipeline to manage resources in the managed namespace

## Using Custom Container Images

By default, components use the image `registry-service.kind-registry/rbean-festoji:latest`. If you need to use a different container image (e.g., from a private registry), you must provide both `customContainerImage` and `dockerconfigjson`.

### Generating dockerconfigjson

First, create a docker config with your registry credentials:

```bash
# Log in to your registry
docker login registry.example.com

# Get the base64-encoded dockerconfigjson
cat ~/.docker/config.json | base64 -w 0
```

### Example with Custom Image

```bash
# Get your dockerconfigjson
DOCKER_CONFIG=$(cat ~/.docker/config.json | base64 -w 0)

# Install with custom image
helm install my-app ./konflux-onboarding \
  --set applicationName=my-application \
  --set gitRepoUrl=https://github.com/myorg/myrepo \
  --set namespace=my-namespace \
  --set release.targetNamespace=managed-tenant \
  --set customContainerImage=registry.example.com/myorg/myimage:v1.0 \
  --set dockerconfigjson="$DOCKER_CONFIG"
```

Or using a values file:

```yaml
applicationName: my-application
gitRepoUrl: https://github.com/myorg/myrepo
namespace: my-namespace
customContainerImage: registry.example.com/myorg/myimage:v1.0
dockerconfigjson: eyJhdXRocyI6eyJyZWdpc3RyeS5leGFtcGxlLmNvbSI6eyJ1c2VybmFtZSI6InVzZXIiLCJwYXNzd29yZCI6InBhc3MiLCJhdXRoIjoiZFhObGNqcHdZWE56In19fQ==
release:
  targetNamespace: managed-tenant
```

**Note**: When `customContainerImage` is provided, the chart automatically creates a pull secret and references it in the Component spec.

## Configuring Releases

The chart automatically creates ReleasePlan and ReleasePlanAdmission resources to enable automatic releases of your application to an external registry.

The chart uses two separate namespaces by default:
- **Application namespace** (`namespace`): Default is `slsa-e2e-tenant` - where the Application, Component, IntegrationTestScenario, and ReleasePlan are created
- **Managed namespace** (`release.targetNamespace`): Default is `slsa-e2e-managed-tenant` - where the EnterpriseContractPolicy, ReleasePlanAdmission, ServiceAccount, and RoleBindings are created

You can override these defaults as needed for your environment.

### Default Release Behavior

When builds complete successfully and pass integration tests, the release workflow:
1. Validates the build artifacts against Enterprise Contract policies
2. Pushes the component image to the destination registry
3. Default destination: `registry-service.kind-registry/released-<applicationName>`

### Customizing Release Destination

To release to a different registry:

```bash
helm install my-app ./konflux-onboarding \
  --set applicationName=my-application \
  --set gitRepoUrl=https://github.com/myorg/myrepo \
  --set namespace=my-namespace \
  --set release.targetNamespace=managed-tenant \
  --set release.destination=quay.io/myorg/myapp
```

Or in a values file:

```yaml
applicationName: my-application
gitRepoUrl: https://github.com/myorg/myrepo
namespace: my-namespace
release:
  targetNamespace: managed-tenant
  destination: quay.io/myorg/myapp
  environment: production
```

### Using Separate Namespaces

You can deploy the ReleasePlanAdmission to a different "managed" namespace:

```yaml
applicationName: my-application
gitRepoUrl: https://github.com/myorg/myrepo
namespace: dev-namespace
release:
  targetNamespace: managed-release-namespace
  destination: quay.io/myorg/myapp
```

This creates:
- Application, Component, IntegrationTestScenario, ReleasePlan in `dev-namespace`
- EnterpriseContractPolicy, ReleasePlanAdmission, ServiceAccount, RoleBinding in `managed-release-namespace`

## Integration Test Details

This chart creates two IntegrationTestScenario resources for policy-driven development:

**policy-pr** (pull_request context):
- Validates PR builds at source level 1 (PR source branches are not protected)
- Overrides policy with `EXTRA_RULE_DATA: "slsa_source_min_level=1"`
- Provides early feedback on whether push builds will succeed

**policy-push** (push context):
- Validates push builds with strict policy (same as release)
- Uses policy defaults without overrides
- Requires source level 2+ with source-tool provenance

Both scenarios use:
- **Pipeline**: Enterprise Contract pipeline from Konflux build-definitions
- **Policy**: `{targetNamespace}/{policyName}` EnterpriseContractPolicy
- **Mode**: Strict enforcement (builds fail on policy violations)

The EnterpriseContractPolicy uses:
- **Policy Source**: `github.com/enterprise-contract/config//slsa3`
- **Collections**: `slsa3` (SLSA v0.1 levels 1, 2 & 3 rules plus basic Konflux checks)
- **Data Source**: Acceptable Tekton bundles from `quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles`

## Example: Complete Deployment

```bash
# Create or use an existing namespace
kubectl create namespace my-app-dev

# Install the chart
helm install my-application ./konflux-onboarding \
  --set applicationName=my-application \
  --set gitRepoUrl=https://github.com/myorg/myrepo \
  --set namespace=my-app-dev \
  --set release.targetNamespace=my-app-managed \
  --set gitRevision=develop \
  --set displayName="My Application"

# Verify resources were created
kubectl get applications,components,integrationtestscenarios,releaseplans,releaseplanadmissions -n my-app-dev
```

## Uninstalling

```bash
helm uninstall my-app
```

Note: This will remove the Helm release but may not delete all Konflux-generated resources. You may need to manually clean up builds, snapshots, and other dynamically created resources.

## Customization

### Using a Different Policy

To use a different Enterprise Contract policy, you can modify the EnterpriseContractPolicy after deployment:

```bash
kubectl edit enterprisecontractpolicy example-policy -n managed-tenant
```

You can modify:
- `spec.sources[].policy`: Change the policy source URL
- `spec.configuration.collections`: Change the collection (e.g., from `slsa3` to another collection)
- `spec.configuration.include/exclude`: Add or remove specific policy rules

### Adding Multiple Components

This chart creates a single component. For multiple components in the same application, you can:
1. Install the chart multiple times with different component names
2. Create a custom values file with component arrays
3. Manually create additional Component resources

## Troubleshooting

### Check Application Status
```bash
kubectl get application my-application -n my-namespace -o yaml
```

### Check Component Status
```bash
kubectl get component my-application -n my-namespace -o yaml
```

### Check Integration Test Status
```bash
kubectl get integrationtestscenario -n my-namespace
kubectl get integrationtestscenario policy-pr -n my-namespace -o yaml
kubectl get integrationtestscenario policy-push -n my-namespace -o yaml
```

### Check EnterpriseContractPolicy Status
```bash
# Check in the managed namespace
kubectl get enterprisecontractpolicy example-policy -n managed-tenant -o yaml
```

### Check ReleasePlan Status
```bash
kubectl get releaseplan my-application-release -n my-namespace -o yaml
```

### Check ReleasePlanAdmission Status
```bash
# Check in the target namespace (may be different from application namespace)
kubectl get releaseplanadmission my-application-release-admission -n my-namespace -o yaml
```

### View Release Status
```bash
# List all releases for your application
kubectl get releases -n my-namespace

# View details of a specific release
kubectl get release <release-name> -n my-namespace -o yaml
```

### View Build Logs
```bash
# List pipeline runs
kubectl get pipelineruns -n my-namespace

# View logs for a specific pipeline run
kubectl logs -n my-namespace pipelinerun/<pipelinerun-name> --all-containers
```

## Creating Releases

This chart includes a helper script to manually create releases from the latest snapshot:

```bash
# Basic usage with defaults
./create-release.sh <application-name> <namespace> <author> [managed-tenant]

# Example
./create-release.sh festoji slsa-e2e-tenant user1 slsa-e2e-managed-tenant
```

The script will:
1. Find the latest snapshot for the application
2. Create a Release resource with the proper author attribution
3. Link it to the application's ReleasePlan

Check release status:
```bash
kubectl get release -n my-namespace --sort-by=.metadata.creationTimestamp
kubectl get release <release-name> -n my-namespace -o yaml
```

**Note**: The author label is automatically set to the current Kubernetes user by the release-service webhook, ensuring proper attribution for manual releases.

## License

This Helm chart is provided as-is for use with Konflux CI.

## Contributing

Issues and pull requests are welcome.
