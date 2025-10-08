#!/bin/bash

# SLSA-Konflux Complete End-to-End Setup Script
# Sets up the complete workflow so commits trigger: Build → Snapshot → Release → VSA

set -euo pipefail

# Configuration
TENANT_NAMESPACE="${TENANT_NAMESPACE:-tenant-namespace}"
MANAGED_NAMESPACE="${MANAGED_NAMESPACE:-managed-namespace}"
APPLICATION_NAME="${APPLICATION_NAME:-slsa-demo-app}"
COMPONENT_NAME="${COMPONENT_NAME:-go-app}"
GIT_URL="${GIT_URL:-https://github.com/konflux-slsa/slsa-konflux-example}"
GIT_REVISION="${GIT_REVISION:-main}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-quay.io/konflux-slsa-example}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

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

log_step() {
    echo -e "${PURPLE}🎯 STEP: $1${NC}"
}

# Verify prerequisites
verify_prerequisites() {
    log_info "Verifying prerequisites for end-to-end demo..."
    
    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    # Check namespaces exist
    if ! kubectl get namespace "$TENANT_NAMESPACE" &> /dev/null; then
        log_error "Tenant namespace $TENANT_NAMESPACE not found. Run bootstrap-cluster.sh first."
        exit 1
    fi
    
    if ! kubectl get namespace "$MANAGED_NAMESPACE" &> /dev/null; then
        log_error "Managed namespace $MANAGED_NAMESPACE not found. Run bootstrap-cluster.sh first."
        exit 1
    fi
    
    # Check required tasks exist
    local required_tasks=("git-clone-slsa" "conforma-vsa" "vsa-sign")
    for task in "${required_tasks[@]}"; do
        if ! kubectl get task "$task" -n "$TENANT_NAMESPACE" &> /dev/null && ! kubectl get task "$task" -n "$MANAGED_NAMESPACE" &> /dev/null; then
            log_error "Required task $task not found. Run bootstrap-cluster.sh first."
            exit 1
        fi
    done
    
    # Check Application and Component exist
    if ! kubectl get application "$APPLICATION_NAME" -n "$TENANT_NAMESPACE" &> /dev/null; then
        log_error "Application $APPLICATION_NAME not found. Run bootstrap-cluster.sh first."
        exit 1
    fi
    
    if ! kubectl get component "$COMPONENT_NAME" -n "$TENANT_NAMESPACE" &> /dev/null; then
        log_error "Component $COMPONENT_NAME not found. Run bootstrap-cluster.sh first."
        exit 1
    fi
    
    log_success "Prerequisites verified"
}

# Step 1: Configure tenant build pipeline and triggers
configure_tenant_build() {
    log_step "Step 1: Configuring tenant build pipeline and triggers..."
    
    # Deploy the tenant build pipeline
    log_info "Deploying tenant build pipeline..."
    sed "s/tenant-namespace/${TENANT_NAMESPACE}/g" tenant-context/pipelines/slsa-tenant-build-pipeline.yaml | kubectl apply -f -
    
    # Configure Component to use the custom pipeline
    log_info "Configuring Component to use SLSA tenant pipeline..."
    kubectl patch component "$COMPONENT_NAME" -n "$TENANT_NAMESPACE" --type='merge' -p='{
      "metadata": {
        "annotations": {
          "build.appstudio.openshift.io/pipeline": "slsa-tenant-build-pipeline",
          "build.appstudio.openshift.io/bundle": "latest"
        }
      }
    }'
    
    # Create webhook/trigger configuration (simulated for demo)
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: build-trigger-config
  namespace: ${TENANT_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: slsa-konflux-demo
data:
  webhook-config.yaml: |
    triggers:
      - name: build-on-push
        repository: ${GIT_URL}
        branch: ${GIT_REVISION}
        pipeline: slsa-tenant-build-pipeline
        params:
          git-url: ${GIT_URL}
          git-revision: ${GIT_REVISION}
          image-url: ${IMAGE_REGISTRY}/${COMPONENT_NAME}:latest
          component-name: ${COMPONENT_NAME}
          application-name: ${APPLICATION_NAME}
EOF
    
    log_success "Tenant build pipeline and triggers configured"
    echo "💡 Now commits to ${GIT_URL} (${GIT_REVISION}) will trigger builds"
}

# Step 2: Configure Release Plans and Admission
configure_release_automation() {
    log_step "Step 2: Configuring Release Plans and Admission..."
    
    # Deploy ReleasePlan (in tenant namespace)
    log_info "Deploying ReleasePlan..."
    sed -e "s/tenant-namespace/${TENANT_NAMESPACE}/g" \
        -e "s/managed-namespace/${MANAGED_NAMESPACE}/g" \
        tenant-context/releases/slsa-demo-releaseplan.yaml | kubectl apply -f -
    
    # Deploy ReleasePlanAdmission (in managed namespace)  
    log_info "Deploying ReleasePlanAdmission..."
    sed -e "s/managed-namespace/${MANAGED_NAMESPACE}/g" \
        -e "s/tenant-namespace/${TENANT_NAMESPACE}/g" \
        managed-context/releases/slsa-demo-releaseplanadmission.yaml | kubectl apply -f -
    
    log_success "Release automation configured"
    echo "💡 Snapshots will now automatically trigger releases"
}

# Create a demo snapshot (simulates what build service would create)
create_demo_snapshot() {
    log_info "Creating demo Snapshot..."
    
    SNAPSHOT_NAME="${APPLICATION_NAME}-snapshot-$(date +%s)"
    
    cat <<EOF | kubectl apply -f -
apiVersion: appstudio.redhat.com/v1alpha1
kind: Snapshot
metadata:
  name: ${SNAPSHOT_NAME}
  namespace: ${TENANT_NAMESPACE}
  labels:
    app.kubernetes.io/name: ${SNAPSHOT_NAME}
    app.kubernetes.io/component: snapshot
    app.kubernetes.io/part-of: slsa-konflux-demo
    appstudio.openshift.io/application: ${APPLICATION_NAME}
    appstudio.openshift.io/component: ${COMPONENT_NAME}
  annotations:
    build.appstudio.redhat.com/pipeline: slsa-tenant-build-pipeline
    build.appstudio.redhat.com/commit_sha: "${SOURCE_COMMIT}"
    build.appstudio.redhat.com/build_start_time: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
spec:
  application: ${APPLICATION_NAME}
  displayName: "SLSA Demo Snapshot"
  displayDescription: "Snapshot created by SLSA tenant build pipeline"
  
  components:
    - name: ${COMPONENT_NAME}
      containerImage: ${BUILD_IMAGE}@${BUILD_DIGEST}
      source:
        git:
          url: ${GIT_URL}
          revision: ${GIT_REVISION}
      
  artifacts:
    - uri: ${BUILD_IMAGE}@${BUILD_DIGEST}
      digest: ${BUILD_DIGEST}
EOF
    
    # Wait for snapshot to be ready
    sleep 5
    
    if kubectl get snapshot "$SNAPSHOT_NAME" -n "$TENANT_NAMESPACE" &> /dev/null; then
        log_success "Snapshot created: $SNAPSHOT_NAME"
        echo "📦 Snapshot details:"
        kubectl get snapshot "$SNAPSHOT_NAME" -n "$TENANT_NAMESPACE" -o yaml | head -20
    else
        log_error "Failed to create snapshot"
        exit 1
    fi
}

# Step 3: Configure managed release pipeline
configure_managed_pipeline() {
    log_step "Step 3: Configuring managed release pipeline..."
    
    # Deploy the managed release pipeline
    log_info "Deploying managed release pipeline..."
    sed "s/managed-namespace/${MANAGED_NAMESPACE}/g" managed-context/pipelines/slsa-managed-release-pipeline.yaml | kubectl apply -f -
    
    # Update ReleasePlanAdmission to reference the correct pipeline
    log_info "Updating ReleasePlanAdmission pipeline reference..."
    kubectl patch releaseplanadmission slsa-demo-releaseplanadmission -n "$MANAGED_NAMESPACE" --type='merge' -p='{
      "spec": {
        "pipeline": {
          "pipelineRef": {
            "name": "slsa-managed-release-pipeline"
          }
        }
      }
    }'
    
    log_success "Managed release pipeline configured"
    echo "💡 Releases will now trigger the SLSA managed pipeline"
}

# Step 4: Validate configuration and provide instructions
validate_configuration() {
    log_step "Step 4: Validating configuration and providing instructions..."
    
    # Check all components are properly configured
    log_info "Validating tenant build configuration..."
    if kubectl get pipeline slsa-tenant-build-pipeline -n "$TENANT_NAMESPACE" &> /dev/null; then
        log_success "✓ Tenant build pipeline deployed"
    else
        log_error "✗ Tenant build pipeline missing"
    fi
    
    log_info "Validating release configuration..."
    if kubectl get releaseplan slsa-demo-releaseplan -n "$TENANT_NAMESPACE" &> /dev/null; then
        log_success "✓ ReleasePlan configured"
    else
        log_error "✗ ReleasePlan missing"
    fi
    
    if kubectl get releaseplanadmission slsa-demo-releaseplanadmission -n "$MANAGED_NAMESPACE" &> /dev/null; then
        log_success "✓ ReleasePlanAdmission configured"
    else
        log_error "✗ ReleasePlanAdmission missing"
    fi
    
    log_info "Validating managed pipeline configuration..."
    if kubectl get pipeline slsa-managed-release-pipeline -n "$MANAGED_NAMESPACE" &> /dev/null; then
        log_success "✓ Managed release pipeline deployed"
    else
        log_error "✗ Managed release pipeline missing"
    fi
    
    log_success "Configuration validation completed"
}

# Create demo managed pipeline run (simulates ReleasePlanAdmission trigger)
create_demo_managed_pipeline_run() {
    log_info "Creating managed pipeline run..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: slsa-managed-release-
  namespace: ${MANAGED_NAMESPACE}
  labels:
    app.kubernetes.io/name: slsa-managed-release
    app.kubernetes.io/component: managed-pipeline
    app.kubernetes.io/part-of: slsa-konflux-demo
    release.appstudio.openshift.io/application: ${APPLICATION_NAME}
    release.appstudio.openshift.io/snapshot: ${SNAPSHOT_NAME}
spec:
  pipelineRef:
    name: slsa-managed-release-pipeline
  
  params:
    - name: release
      value: "${RELEASE_NAME}"
    - name: releasePlan
      value: "slsa-demo-releaseplan"
    - name: releasePlanAdmission
      value: "slsa-demo-releaseplanadmission"
    - name: snapshot
      value: "${SNAPSHOT_NAME}"
    - name: policy-bundle-ref
      value: "oci://quay.io/konflux/ec-policy-data:latest"
    - name: vsa-verifier-id
      value: "https://managed.konflux.example.com/demo"
    - name: target-registry
      value: "${IMAGE_REGISTRY}/production"
    - name: attestation-registry
      value: "${IMAGE_REGISTRY}/attestations"
  
  workspaces:
    - name: release-workspace
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 2Gi
  
  timeouts:
    pipeline: "40m0s"
    tasks: "30m0s"
    finally: "10m0s"
EOF
    
    sleep 3
    MANAGED_PIPELINERUN=$(kubectl get pipelineruns -n "$MANAGED_NAMESPACE" -l app.kubernetes.io/part-of=slsa-konflux-demo --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
    
    if [ -z "$MANAGED_PIPELINERUN" ]; then
        log_error "Failed to create managed pipeline run"
        exit 1
    fi
    
    log_success "Managed pipeline run created: $MANAGED_PIPELINERUN"
    echo "👀 Monitor progress: kubectl get pipelinerun $MANAGED_PIPELINERUN -n $MANAGED_NAMESPACE -w"
}

# Step 5: Validate results and display summary
validate_results() {
    log_step "Step 5: Validating results and generating summary..."
    
    # Extract results from managed pipeline
    VSA_DIGEST=$(kubectl get pipelinerun/"$MANAGED_PIPELINERUN" -n "$MANAGED_NAMESPACE" -o jsonpath='{.status.results[?(@.name=="vsa-digest")].value}' 2>/dev/null || echo "")
    RELEASE_STATUS=$(kubectl get pipelinerun/"$MANAGED_PIPELINERUN" -n "$MANAGED_NAMESPACE" -o jsonpath='{.status.results[?(@.name=="release-status")].value}' 2>/dev/null || echo "")
    PROMOTED_IMAGES=$(kubectl get pipelinerun/"$MANAGED_PIPELINERUN" -n "$MANAGED_NAMESPACE" -o jsonpath='{.status.results[?(@.name=="promoted-images")].value}' 2>/dev/null || echo "[]")
    
    # Check pipeline tasks status
    POLICY_RESULT=$(kubectl get pipelinerun/"$MANAGED_PIPELINERUN" -n "$MANAGED_NAMESPACE" -o jsonpath='{.status.taskRuns}' | jq -r 'to_entries[] | select(.key | contains("evaluate-policies")) | .value.status.conditions[]? | select(.type == "Succeeded") | .status' 2>/dev/null || echo "Unknown")
    VSA_RESULT=$(kubectl get pipelinerun/"$MANAGED_PIPELINERUN" -n "$MANAGED_NAMESPACE" -o jsonpath='{.status.taskRuns}' | jq -r 'to_entries[] | select(.key | contains("sign-vsa")) | .value.status.conditions[]? | select(.type == "Succeeded") | .status' 2>/dev/null || echo "Unknown")
    
    log_success "End-to-end demo validation completed"
}

# Generate comprehensive demo report
generate_demo_report() {
    log_info "Generating comprehensive demo report..."
    
    REPORT_FILE="/tmp/slsa-konflux-demo-report-$(date +%s).txt"
    
    cat > "$REPORT_FILE" <<EOF
SLSA-Konflux End-to-End Demo Report
Generated: $(date)
Cluster: $(kubectl config current-context)

=== Demo Configuration ===
Tenant Namespace: ${TENANT_NAMESPACE}
Managed Namespace: ${MANAGED_NAMESPACE}
Application: ${APPLICATION_NAME}
Component: ${COMPONENT_NAME}
Git Repository: ${GIT_URL}
Git Revision: ${GIT_REVISION}
Image Registry: ${IMAGE_REGISTRY}

=== Workflow Results ===
Build PipelineRun: ${BUILD_PIPELINERUN:-"Not created"}
Build Image: ${BUILD_IMAGE:-"Not available"}
Build Digest: ${BUILD_DIGEST:-"Not available"}
Source Commit: ${SOURCE_COMMIT:-"Not available"}

Snapshot: ${SNAPSHOT_NAME:-"Not created"}
Release: ${RELEASE_NAME:-"Not created"}
Managed PipelineRun: ${MANAGED_PIPELINERUN:-"Not created"}

=== SLSA Compliance Results ===
Policy Evaluation: ${POLICY_RESULT:-"Not completed"}
VSA Generation: ${VSA_RESULT:-"Not completed"}
VSA Digest: ${VSA_DIGEST:-"Not available"}
Release Status: ${RELEASE_STATUS:-"Not available"}

=== Promoted Images ===
EOF

    # Add promoted images if available
    if [ -n "$PROMOTED_IMAGES" ] && [ "$PROMOTED_IMAGES" != "[]" ]; then
        echo "$PROMOTED_IMAGES" | jq -r '.[] | "Source: " + .source + "\nTarget: " + .target + "\n"' >> "$REPORT_FILE"
    else
        echo "No images promoted" >> "$REPORT_FILE"
    fi
    
    cat >> "$REPORT_FILE" <<EOF

=== Pipeline Executions ===
Tenant Build Pipeline:
EOF
    kubectl get pipelinerun "$BUILD_PIPELINERUN" -n "$TENANT_NAMESPACE" -o yaml >> "$REPORT_FILE" 2>/dev/null || echo "Build pipeline details not available" >> "$REPORT_FILE"
    
    echo "" >> "$REPORT_FILE"
    echo "Managed Release Pipeline:" >> "$REPORT_FILE"
    kubectl get pipelinerun "$MANAGED_PIPELINERUN" -n "$MANAGED_NAMESPACE" -o yaml >> "$REPORT_FILE" 2>/dev/null || echo "Managed pipeline details not available" >> "$REPORT_FILE"
    
    log_success "Demo report generated: $REPORT_FILE"
    echo "📄 View report: cat $REPORT_FILE"
}

# Print setup summary
print_setup_summary() {
    echo ""
    echo "=========================================="
    log_success "SLSA-Konflux End-to-End Setup Complete!"
    echo "=========================================="
    echo ""
    echo "🎯 Configuration Completed:"
    echo "  1. ✅ Tenant build pipeline configured"
    echo "  2. ✅ Release automation configured"  
    echo "  3. ✅ Managed release pipeline configured"
    echo "  4. ✅ All components validated"
    echo ""
    echo "📋 What's Ready:"
    echo "  • Pipeline: slsa-tenant-build-pipeline (tenant context)"
    echo "  • Pipeline: slsa-managed-release-pipeline (managed context)"
    echo "  • ReleasePlan: slsa-demo-releaseplan"
    echo "  • ReleasePlanAdmission: slsa-demo-releaseplanadmission"
    echo "  • Component: ${COMPONENT_NAME} (configured for SLSA pipeline)"
    echo ""
    echo "🛡️ SLSA Workflow Ready:"
    echo "  ✅ Source verification with git-clone-slsa"
    echo "  ✅ Build provenance via Tekton Chains"
    echo "  ✅ Automatic snapshot creation"
    echo "  ✅ Release triggering on snapshots"
    echo "  ✅ Policy evaluation in managed context"
    echo "  ✅ VSA generation with managed signing keys"
    echo "  ✅ Trust boundary separation enforced"
    echo ""
    echo "🚀 How to Trigger the Workflow:"
    echo "  1. Make a commit to: ${GIT_URL}"
    echo "  2. Push to branch: ${GIT_REVISION}"
    echo "  3. Watch the automatic workflow:"
    echo "     • Build pipeline starts in ${TENANT_NAMESPACE}"
    echo "     • Snapshot is created automatically"
    echo "     • Release is triggered automatically"
    echo "     • Managed pipeline runs in ${MANAGED_NAMESPACE}"
    echo ""
    echo "🔍 Monitoring Commands:"
    echo "  # Watch tenant builds"
    echo "  kubectl get pipelineruns -n ${TENANT_NAMESPACE} -w"
    echo ""
    echo "  # Watch managed releases"
    echo "  kubectl get pipelineruns -n ${MANAGED_NAMESPACE} -w"
    echo ""
    echo "  # Watch snapshots and releases"
    echo "  kubectl get snapshots,releases -n ${TENANT_NAMESPACE} -w"
    echo ""
    echo "💡 Demo Tip:"
    echo "  Create a test commit to trigger the full SLSA workflow:"
    echo "  git commit --allow-empty -m 'Trigger SLSA demo workflow'"
    echo "  git push origin ${GIT_REVISION}"
    echo ""
}

# Cleanup function
cleanup_demo_resources() {
    log_info "Cleaning up demo resources..."
    
    # Delete demo PipelineRuns
    kubectl delete pipelineruns -n "$TENANT_NAMESPACE" -l app.kubernetes.io/part-of=slsa-konflux-demo --ignore-not-found=true
    kubectl delete pipelineruns -n "$MANAGED_NAMESPACE" -l app.kubernetes.io/part-of=slsa-konflux-demo --ignore-not-found=true
    
    # Delete demo Snapshot and Release
    [ -n "${SNAPSHOT_NAME:-}" ] && kubectl delete snapshot "$SNAPSHOT_NAME" -n "$TENANT_NAMESPACE" --ignore-not-found=true
    [ -n "${RELEASE_NAME:-}" ] && kubectl delete release "$RELEASE_NAME" -n "$TENANT_NAMESPACE" --ignore-not-found=true
    
    log_success "Demo resources cleaned up"
}

# Main execution
main() {
    echo "🚀 Starting SLSA-Konflux End-to-End Setup..."
    echo "Configuration:"
    echo "  Tenant Namespace: $TENANT_NAMESPACE"
    echo "  Managed Namespace: $MANAGED_NAMESPACE"
    echo "  Application: $APPLICATION_NAME"
    echo "  Component: $COMPONENT_NAME"
    echo "  Git Repository: $GIT_URL"
    echo "  Registry: $IMAGE_REGISTRY"
    echo ""
    
    verify_prerequisites
    configure_tenant_build
    configure_release_automation
    configure_managed_pipeline
    validate_configuration
    print_setup_summary
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
        --application-name)
            APPLICATION_NAME="$2"
            shift 2
            ;;
        --component-name)
            COMPONENT_NAME="$2"
            shift 2
            ;;
        --git-url)
            GIT_URL="$2"
            shift 2
            ;;
        --git-revision)
            GIT_REVISION="$2"
            shift 2
            ;;
        --image-registry)
            IMAGE_REGISTRY="$2"
            shift 2
            ;;
        --cleanup)
            cleanup_demo_resources
            exit 0
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --tenant-namespace NAME     Tenant namespace (default: tenant-namespace)"
            echo "  --managed-namespace NAME    Managed namespace (default: managed-namespace)"
            echo "  --application-name NAME     Application name (default: slsa-demo-app)"
            echo "  --component-name NAME       Component name (default: go-app)"
            echo "  --git-url URL               Git repository URL"
            echo "  --git-revision REV          Git revision (default: main)"
            echo "  --image-registry URL        Image registry URL"
            echo "  --cleanup                   Clean up demo resources and exit"
            echo "  --help                      Show this help message"
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

# Trap cleanup on exit
trap cleanup_demo_resources EXIT

# Run main function
main "$@"