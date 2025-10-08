#!/bin/bash

# SLSA-Konflux Cluster Bootstrap Script
# Configures tenant and managed namespaces with all required Konflux components

set -euo pipefail

# Configuration
TENANT_NAMESPACE="${TENANT_NAMESPACE:-tenant-namespace}"
MANAGED_NAMESPACE="${MANAGED_NAMESPACE:-managed-namespace}"
REGISTRY_URL="${REGISTRY_URL:-quay.io/konflux-slsa-example}"
GITHUB_ORG="${GITHUB_ORG:-konflux-slsa}"
APPLICATION_NAME="${APPLICATION_NAME:-slsa-demo-app}"
COMPONENT_NAME="${COMPONENT_NAME:-go-app}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ️  INFO: $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ SUCCESS: $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  WARNING: $1${NC}"
}

log_error() {
    echo -e "${RED}❌ ERROR: $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check required tools
    for tool in kubectl oc jq; do
        if ! command -v $tool &> /dev/null; then
            log_error "$tool is required but not installed"
            exit 1
        fi
    done
    
    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    # Check if we're using OpenShift
    if kubectl get route &> /dev/null 2>&1; then
        IS_OPENSHIFT=true
        log_info "Detected OpenShift cluster"
    else
        IS_OPENSHIFT=false
        log_info "Detected Kubernetes cluster"
    fi
    
    log_success "Prerequisites check passed"
}

# Create namespaces
create_namespaces() {
    log_info "Creating namespaces..."
    
    # Create tenant namespace
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${TENANT_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: slsa-konflux
    konflux.dev/context: tenant
    security.slsa.dev/level: "3"
  annotations:
    argocd.argoproj.io/sync-wave: "0"
    konflux.dev/description: "Tenant context for SLSA build operations"
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${MANAGED_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: slsa-konflux
    konflux.dev/context: managed
    security.slsa.dev/level: "3"
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    konflux.dev/description: "Managed context for SLSA release operations"
EOF
    
    log_success "Namespaces created: ${TENANT_NAMESPACE}, ${MANAGED_NAMESPACE}"
}

# Install Tekton tasks
install_tekton_tasks() {
    log_info "Installing Tekton tasks..."
    
    # Install tenant context tasks
    log_info "Installing tenant context tasks..."
    kubectl apply -f tenant-context/tasks/git-clone-slsa/0.1/git-clone-slsa.yaml -n ${TENANT_NAMESPACE}
    
    # Install managed context tasks
    log_info "Installing managed context tasks..."
    kubectl apply -f managed-context/tasks/conforma-vsa/0.1/conforma-vsa.yaml -n ${MANAGED_NAMESPACE}
    kubectl apply -f managed-context/tasks/vsa-sign/0.1/vsa-sign.yaml -n ${MANAGED_NAMESPACE}
    
    # Install managed pipeline
    kubectl apply -f managed-context/pipelines/slsa-managed-pipeline/0.1/slsa-managed-pipeline.yaml -n ${MANAGED_NAMESPACE}
    
    log_success "Tekton tasks and pipelines installed"
}

# Create RBAC configurations
setup_rbac() {
    log_info "Setting up RBAC configurations..."
    
    # Tenant namespace service account
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tenant-pipeline-sa
  namespace: ${TENANT_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: slsa-konflux
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-pipeline-binding
  namespace: ${TENANT_NAMESPACE}
subjects:
- kind: ServiceAccount
  name: tenant-pipeline-sa
  namespace: ${TENANT_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: edit
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: managed-pipeline-sa
  namespace: ${MANAGED_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: slsa-konflux
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: managed-pipeline-binding
  namespace: ${MANAGED_NAMESPACE}
subjects:
- kind: ServiceAccount
  name: managed-pipeline-sa
  namespace: ${MANAGED_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: edit
  apiGroup: rbac.authorization.k8s.io
EOF
    
    log_success "RBAC configurations created"
}

# Generate and configure signing keys
setup_signing_keys() {
    log_info "Setting up signing keys for managed namespace..."
    
    # Check if cosign is available
    if ! command -v cosign &> /dev/null; then
        log_warning "cosign not found. Installing cosign..."
        # Install cosign
        curl -O -L "https://github.com/sigstore/cosign/releases/latest/download/cosign-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m | sed 's/x86_64/amd64/')"
        sudo mv cosign-* /usr/local/bin/cosign
        sudo chmod +x /usr/local/bin/cosign
    fi
    
    # Check if keys already exist
    if kubectl get secret vsa-signing-config -n "${MANAGED_NAMESPACE}" &> /dev/null; then
        log_info "Signing keys already exist, skipping generation"
        return 0
    fi
    
    # Generate cosign key pair
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    log_info "Generating cosign key pair for VSA signing..."
    # Generate keys without password for demo (use COSIGN_PASSWORD="" for keyless)
    COSIGN_PASSWORD="" cosign generate-key-pair
    
    # Verify key generation
    if [[ ! -f "cosign.key" ]] || [[ ! -f "cosign.pub" ]]; then
        log_error "Failed to generate cosign key pair"
        cd - > /dev/null
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    log_info "Creating signing secrets in managed namespace..."
    
    # Create signing secret for general use
    kubectl create secret generic vsa-signing-config \
        --from-file=cosign.key=cosign.key \
        --from-file=cosign.pub=cosign.pub \
        --namespace="${MANAGED_NAMESPACE}"
    
    # Create secret for vsa-sign task (with expected naming)
    kubectl create secret generic vsa-signing-key \
        --from-file=vsa-primary-key.key=cosign.key \
        --from-file=vsa-primary-key.pub=cosign.pub \
        --namespace="${MANAGED_NAMESPACE}"
    
    # Label secrets for identification
    kubectl label secret vsa-signing-config -n "${MANAGED_NAMESPACE}" app.kubernetes.io/part-of=slsa-konflux
    kubectl label secret vsa-signing-key -n "${MANAGED_NAMESPACE}" app.kubernetes.io/part-of=slsa-konflux
    
    # Display public key for reference
    log_info "Generated VSA signing public key:"
    echo "$(cat cosign.pub)"
    
    # Save public key for reference with read access
    kubectl create configmap vsa-public-key \
        --from-file=cosign.pub=cosign.pub \
        --namespace="${MANAGED_NAMESPACE}" || true
    kubectl label configmap vsa-public-key -n "${MANAGED_NAMESPACE}" app.kubernetes.io/part-of=slsa-konflux || true
    
    # Create RBAC to allow authenticated users to read the public key
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: ${MANAGED_NAMESPACE}
  name: vsa-public-key-reader
  labels:
    app.kubernetes.io/part-of: slsa-konflux
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["vsa-public-key"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: vsa-public-key-readers
  namespace: ${MANAGED_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: slsa-konflux
subjects:
- kind: Group
  name: system:authenticated
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: vsa-public-key-reader
  apiGroup: rbac.authorization.k8s.io
EOF
    
    # Cleanup
    cd - > /dev/null
    rm -rf "$TEMP_DIR"
    
    log_success "Signing keys generated and configured"
    echo "💡 Public key stored in configmap 'vsa-public-key' for verification"
}

# Create Application and Component for Konflux
create_konflux_application() {
    log_info "Creating Konflux Application and Component..."
    
    # Create Application
    cat <<EOF | kubectl apply -f -
apiVersion: appstudio.redhat.com/v1alpha1
kind: Application
metadata:
  name: ${APPLICATION_NAME}
  namespace: ${TENANT_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: slsa-konflux
  annotations:
    application.thumbnail: "1"
    konflux.dev/slsa-policy: "enterprise-contract-slsa3"
spec:
  displayName: "SLSA Demo Application"
  description: "Demo application for SLSA-Konflux integration"
  gitOpsRepository:
    url: "https://github.com/${GITHUB_ORG}/gitops"
    branch: "main"
    context: "./"
---
apiVersion: appstudio.redhat.com/v1alpha1
kind: Component
metadata:
  name: ${COMPONENT_NAME}
  namespace: ${TENANT_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: slsa-konflux
    app.kubernetes.io/name: ${APPLICATION_NAME}
  annotations:
    build.appstudio.openshift.io/pipeline: "slsa-tenant-pipeline"
    build.appstudio.openshift.io/bundle: "latest"
    konflux.dev/source-type: "git"
    konflux.dev/slsa-source-verification: "enabled"
spec:
  componentName: ${COMPONENT_NAME}
  application: ${APPLICATION_NAME}
  source:
    git:
      url: "https://github.com/${GITHUB_ORG}/slsa-demo-app"
      revision: "main"
      context: "./examples/go-app"
  containerImage: "${REGISTRY_URL}/${COMPONENT_NAME}:latest"
  buildEnvironment:
    type: "tekton"
    values:
      - name: "slsa-verification"
        value: "enabled"
      - name: "trust-artifacts"
        value: "enabled"
EOF
    
    log_success "Application and Component created"
}

# Create image repository if registry operator is available
create_image_repository() {
    log_info "Creating ImageRepository if registry operator is available..."
    
    # Check if ImageRepository CRD exists
    if kubectl get crd imagerepositories.registry.redhat.io &> /dev/null; then
        cat <<EOF | kubectl apply -f -
apiVersion: registry.redhat.io/v1alpha1
kind: ImageRepository
metadata:
  name: ${COMPONENT_NAME}
  namespace: ${TENANT_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: slsa-konflux
    app.kubernetes.io/component: ${COMPONENT_NAME}
spec:
  image:
    name: ${REGISTRY_URL}/${COMPONENT_NAME}
  visibility: public
  credentials:
    regenerate-token: false
EOF
        log_success "ImageRepository created"
    else
        log_warning "ImageRepository CRD not found, skipping image repository creation"
    fi
}

# Create Release Plan and Release Plan Admission
create_release_configuration() {
    log_info "Creating Release Plan and Release Plan Admission..."
    
    # Release Plan (in managed namespace)
    cat <<EOF | kubectl apply -f -
apiVersion: appstudio.redhat.com/v1alpha1
kind: ReleasePlan
metadata:
  name: ${APPLICATION_NAME}-release-plan
  namespace: ${TENANT_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: slsa-konflux
    release.appstudio.openshift.io/application: ${APPLICATION_NAME}
spec:
  application: ${APPLICATION_NAME}
  target: ${MANAGED_NAMESPACE}
  releaseGracePeriodDays: 7
  data:
    slsa:
      level: "3"
      vsa:
        enabled: true
        signingKey: "vsa-primary-key"
    publication:
      registry: "${REGISTRY_URL}"
      namespace: "production"
    policy:
      bundle: "oci://quay.io/konflux/ec-policy-data:latest"
      strict: false
---
apiVersion: appstudio.redhat.com/v1alpha1
kind: ReleasePlanAdmission
metadata:
  name: ${APPLICATION_NAME}-release-admission
  namespace: ${MANAGED_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: slsa-konflux
spec:
  applications:
    - ${APPLICATION_NAME}
  origin: ${TENANT_NAMESPACE}
  policy: "enterprise-contract-slsa3"
  pipeline:
    pipelineRef:
      resolver: "bundles"
      params:
        - name: "bundle"
          value: "quay.io/konflux-ci/tekton-catalog/pipeline-slsa-managed:latest"
        - name: "name"
          value: "slsa-managed-pipeline"
    serviceAccountName: "managed-pipeline-sa"
  data:
    slsa:
      verification:
        strict: false
      vsa:
        signingKey: "vsa-primary-key"
        verifierId: "https://managed.konflux.example.com"
    conforma:
      policyBundle: "oci://quay.io/konflux/ec-policy-data:latest"
      strictMode: false
EOF
    
    log_success "Release Plan and Release Plan Admission created"
}

# Create ConfigMaps for VSA converter tool
create_configmaps() {
    log_info "Creating ConfigMaps for VSA converter..."
    
    kubectl apply -f managed-context/tasks/conforma-vsa/0.1/vsa-convert-tool-configmap.yaml -n ${MANAGED_NAMESPACE}
    
    log_success "ConfigMaps created"
}

# Create workspaces for pipelines
create_workspaces() {
    log_info "Creating workspace PVCs..."
    
    # Shared workspace PVC template
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-workspace-pvc
  namespace: ${TENANT_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: slsa-konflux
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: managed-workspace-pvc
  namespace: ${MANAGED_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: slsa-konflux
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
EOF
    
    log_success "Workspace PVCs created"
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."
    
    # Check if all tasks are available
    log_info "Checking Tekton tasks..."
    kubectl get tasks -n ${TENANT_NAMESPACE} | grep -E "(git-clone-slsa)" || log_warning "git-clone-slsa task not found"
    kubectl get tasks -n ${MANAGED_NAMESPACE} | grep -E "(conforma-vsa|vsa-sign)" || log_warning "VSA tasks not found"
    
    # Check if Application and Component exist
    log_info "Checking Konflux resources..."
    kubectl get application ${APPLICATION_NAME} -n ${TENANT_NAMESPACE} &> /dev/null && log_success "Application found" || log_warning "Application not found"
    kubectl get component ${COMPONENT_NAME} -n ${TENANT_NAMESPACE} &> /dev/null && log_success "Component found" || log_warning "Component not found"
    
    # Check release configuration
    kubectl get releaseplan -n ${TENANT_NAMESPACE} &> /dev/null && log_success "ReleasePlan found" || log_warning "ReleasePlan not found"
    kubectl get releaseplanadmission -n ${MANAGED_NAMESPACE} &> /dev/null && log_success "ReleasePlanAdmission found" || log_warning "ReleasePlanAdmission not found"
    
    # Check signing keys
    kubectl get secret vsa-signing-config -n ${MANAGED_NAMESPACE} &> /dev/null && log_success "Signing keys configured" || log_warning "Signing keys not found"
    
    log_success "Installation verification completed"
}

# Test basic functionality
test_functionality() {
    log_info "Testing basic functionality..."
    
    # Test if we can create a simple PipelineRun
    cat <<EOF | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: test-functionality-
  namespace: ${TENANT_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: slsa-konflux
spec:
  pipelineSpec:
    tasks:
      - name: test
        taskSpec:
          steps:
            - name: test
              image: registry.redhat.io/ubi9/ubi:latest
              script: |
                #!/bin/bash
                echo "✅ Basic functionality test passed"
                echo "Tenant namespace: ${TENANT_NAMESPACE}"
                echo "Managed namespace: ${MANAGED_NAMESPACE}"
                echo "Current time: \$(date)"
  timeouts:
    pipeline: "5m0s"
EOF
    
    log_success "Test PipelineRun created"
}

# Print summary
print_summary() {
    echo ""
    echo "=========================================="
    log_success "SLSA-Konflux Cluster Bootstrap Complete!"
    echo "=========================================="
    echo ""
    echo "📋 Configuration Summary:"
    echo "  • Tenant Namespace: ${TENANT_NAMESPACE}"
    echo "  • Managed Namespace: ${MANAGED_NAMESPACE}"
    echo "  • Application: ${APPLICATION_NAME}"
    echo "  • Component: ${COMPONENT_NAME}"
    echo "  • Registry: ${REGISTRY_URL}"
    echo ""
    echo "🔧 Installed Components:"
    echo "  ✅ Tekton tasks (git-clone-slsa, conforma-vsa, vsa-sign)"
    echo "  ✅ Managed pipeline (slsa-managed-pipeline)"
    echo "  ✅ RBAC configurations and service accounts"
    echo "  ✅ Signing keys for VSA generation"
    echo "  ✅ Application and Component definitions"
    echo "  ✅ Release Plan and Release Plan Admission"
    echo "  ✅ Workspace PVCs"
    echo ""
    echo "🚀 Next Steps:"
    echo "  1. Run: ./scripts/test-end-to-end.sh"
    echo "  2. Trigger a build: kubectl create -f examples/go-app/.tekton/pipeline-run-example.yaml"
    echo "  3. Monitor: kubectl get pipelineruns -n ${TENANT_NAMESPACE}"
    echo "  4. Check VSA: kubectl get pipelineruns -n ${MANAGED_NAMESPACE}"
    echo ""
    echo "📖 Documentation:"
    echo "  • Architecture: docs/trust-model.md"
    echo "  • Troubleshooting: docs/troubleshooting.md"
    echo "  • Examples: examples/README.md"
    echo ""
    echo "🔍 Verification Commands:"
    echo "  kubectl get all -n ${TENANT_NAMESPACE}"
    echo "  kubectl get all -n ${MANAGED_NAMESPACE}"
    echo "  kubectl get applications,components -n ${TENANT_NAMESPACE}"
    echo "  kubectl get releaseplans -n ${TENANT_NAMESPACE}"
    echo "  kubectl get releaseplanadmissions -n ${MANAGED_NAMESPACE}"
    echo ""
}

# Main execution
main() {
    log_info "Starting SLSA-Konflux cluster bootstrap..."
    echo "Target namespaces: ${TENANT_NAMESPACE}, ${MANAGED_NAMESPACE}"
    echo ""
    
    check_prerequisites
    create_namespaces
    setup_rbac
    install_tekton_tasks
    setup_signing_keys
    create_configmaps
    create_workspaces
    create_konflux_application
    create_image_repository
    create_release_configuration
    verify_installation
    test_functionality
    print_summary
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --tenant-namespace)
            TENANT_NAMESPACE="$2"
            shift 2
            ;;
        --managed-namespace)
            MANAGED_NAMESPACE="$2"
            shift 2
            ;;
        --registry-url)
            REGISTRY_URL="$2"
            shift 2
            ;;
        --application-name)
            APPLICATION_NAME="$2"
            shift 2
            ;;
        --component-name)
            COMPONENT_NAME="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --tenant-namespace NAME     Tenant namespace (default: tenant-namespace)"
            echo "  --managed-namespace NAME    Managed namespace (default: managed-namespace)"
            echo "  --registry-url URL          Container registry URL (default: quay.io/konflux-slsa-example)"
            echo "  --application-name NAME     Application name (default: slsa-demo-app)"
            echo "  --component-name NAME       Component name (default: go-app)"
            echo "  --help                      Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  TENANT_NAMESPACE            Override tenant namespace"
            echo "  MANAGED_NAMESPACE           Override managed namespace"
            echo "  REGISTRY_URL                Override registry URL"
            echo "  APPLICATION_NAME            Override application name"
            echo "  COMPONENT_NAME              Override component name"
            echo ""
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Run main function
main "$@"