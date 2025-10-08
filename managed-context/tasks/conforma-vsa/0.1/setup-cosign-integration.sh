#!/bin/bash
set -euo pipefail

# Setup script for cosign CLI integration in managed namespace VSA signing
# This script implements the WS5 Day 2 requirements for complete VSA signing workflow

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-managed-context}"
VERIFIER_ID="${VERIFIER_ID:-https://managed.konflux.example.com/verifiers/conforma-vsa}"
VERIFIER_VERSION="${VERIFIER_VERSION:-v1.0.0}"
DEBUG="${DEBUG:-false}"

echo "=== Konflux Managed VSA Signing Setup ==="
echo "Namespace: $NAMESPACE"
echo "Verifier ID: $VERIFIER_ID"
echo "Debug: $DEBUG"

# Function to check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."
    
    if ! command -v kubectl &> /dev/null; then
        echo "ERROR: kubectl is required but not installed"
        exit 1
    fi
    
    if ! command -v cosign &> /dev/null; then
        echo "ERROR: cosign is required but not installed"
        echo "Install with: go install github.com/sigstore/cosign/v2/cmd/cosign@latest"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        echo "ERROR: jq is required but not installed"
        exit 1
    fi
    
    if ! command -v go &> /dev/null; then
        echo "ERROR: go is required to build the VSA converter"
        exit 1
    fi
    
    echo "Prerequisites check completed"
}

# Function to create namespace if it doesn't exist
create_namespace() {
    echo "Creating managed namespace..."
    
    if kubectl get namespace "$NAMESPACE" &> /dev/null; then
        echo "Namespace $NAMESPACE already exists"
    else
        kubectl create namespace "$NAMESPACE"
        kubectl label namespace "$NAMESPACE" \
            security.konflux.dev/trust-boundary=managed \
            app.kubernetes.io/managed-by=platform-team
    fi
}

# Function to generate cosign key pair
generate_cosign_keys() {
    echo "Generating cosign key pair..."
    
    local temp_dir
    temp_dir=$(mktemp -d)
    
    # Generate key pair with password
    local password
    password=$(openssl rand -base64 32)
    
    cd "$temp_dir"
    
    # Generate the key pair
    echo "$password" | cosign generate-key-pair --output-key-prefix managed-vsa
    
    # Store keys securely
    echo "Generated cosign keys in: $temp_dir"
    echo "Private key: $temp_dir/managed-vsa.key"
    echo "Public key: $temp_dir/managed-vsa.pub"
    echo "Password: $password"
    
    # Export for secret creation
    export COSIGN_PRIVATE_KEY="$temp_dir/managed-vsa.key"
    export COSIGN_PUBLIC_KEY="$temp_dir/managed-vsa.pub"
    export COSIGN_PASSWORD="$password"
    
    cd - > /dev/null
}

# Function to create signing secrets
create_signing_secrets() {
    echo "Creating signing secrets..."
    
    # Create cosign signing keys secret
    kubectl create secret generic cosign-signing-keys \
        --namespace="$NAMESPACE" \
        --from-file=cosign.key="$COSIGN_PRIVATE_KEY" \
        --from-file=cosign.pub="$COSIGN_PUBLIC_KEY" \
        --from-literal=cosign.password="$COSIGN_PASSWORD" \
        --dry-run=client -o yaml | \
        kubectl apply -f -
    
    # Label the secret
    kubectl label secret cosign-signing-keys \
        --namespace="$NAMESPACE" \
        app.kubernetes.io/name=cosign-signing-keys \
        app.kubernetes.io/component=managed-pipeline \
        security.konflux.dev/trust-boundary=managed
    
    # Create verifier config secret
    kubectl create secret generic vsa-verifier-config \
        --namespace="$NAMESPACE" \
        --from-literal=verifier-id="$VERIFIER_ID" \
        --from-literal=verifier-version="$VERIFIER_VERSION" \
        --from-literal=verifier-description="Konflux Managed Conforma VSA Verifier" \
        --dry-run=client -o yaml | \
        kubectl apply -f -
    
    # Label the verifier config secret
    kubectl label secret vsa-verifier-config \
        --namespace="$NAMESPACE" \
        app.kubernetes.io/name=vsa-verifier-config \
        app.kubernetes.io/component=managed-pipeline \
        security.konflux.dev/trust-boundary=managed
}

# Function to build and deploy VSA converter tool
build_and_deploy_converter() {
    echo "Building VSA converter tool..."
    
    local converter_src="$SCRIPT_DIR/../scripts/convert-conforma-to-vsa.go"
    local temp_dir
    temp_dir=$(mktemp -d)
    
    if [[ ! -f "$converter_src" ]]; then
        echo "ERROR: VSA converter source not found: $converter_src"
        exit 1
    fi
    
    # Build the converter
    cd "$temp_dir"
    cp "$converter_src" .
    go mod init vsa-converter
    go build -o convert-conforma-to-vsa convert-conforma-to-vsa.go
    
    # Create ConfigMap with the binary
    kubectl create configmap vsa-convert-tool \
        --namespace="$NAMESPACE" \
        --from-file=convert-conforma-to-vsa \
        --dry-run=client -o yaml | \
        kubectl apply -f -
    
    # Label the ConfigMap
    kubectl label configmap vsa-convert-tool \
        --namespace="$NAMESPACE" \
        app.kubernetes.io/name=vsa-convert-tool \
        app.kubernetes.io/component=managed-pipeline
    
    cd - > /dev/null
    rm -rf "$temp_dir"
    
    echo "VSA converter tool deployed successfully"
}

# Function to apply RBAC configuration
apply_rbac() {
    echo "Applying RBAC configuration..."
    
    # Apply the RBAC from the template
    kubectl apply -f "$SCRIPT_DIR/signing-secrets-template.yaml" --namespace="$NAMESPACE"
    
    echo "RBAC configuration applied"
}

# Function to deploy the Tekton task
deploy_tekton_task() {
    echo "Deploying Tekton task..."
    
    kubectl apply -f "$SCRIPT_DIR/conforma-vsa.yaml"
    
    echo "Tekton task deployed successfully"
}

# Function to verify deployment
verify_deployment() {
    echo "Verifying deployment..."
    
    # Check secrets
    if ! kubectl get secret cosign-signing-keys -n "$NAMESPACE" &> /dev/null; then
        echo "ERROR: cosign-signing-keys secret not found"
        exit 1
    fi
    
    if ! kubectl get secret vsa-verifier-config -n "$NAMESPACE" &> /dev/null; then
        echo "ERROR: vsa-verifier-config secret not found"
        exit 1
    fi
    
    # Check ConfigMap
    if ! kubectl get configmap vsa-convert-tool -n "$NAMESPACE" &> /dev/null; then
        echo "ERROR: vsa-convert-tool ConfigMap not found"
        exit 1
    fi
    
    # Check Tekton task
    if ! kubectl get task conforma-vsa -n "$NAMESPACE" &> /dev/null; then
        echo "ERROR: conforma-vsa Task not found"
        exit 1
    fi
    
    # Check ServiceAccount
    if ! kubectl get serviceaccount conforma-vsa-sa -n "$NAMESPACE" &> /dev/null; then
        echo "ERROR: conforma-vsa-sa ServiceAccount not found"
        exit 1
    fi
    
    echo "Deployment verification completed successfully"
}

# Function to create sample pipeline for testing
create_sample_pipeline() {
    echo "Creating sample pipeline for testing..."
    
    cat << 'EOF' | kubectl apply -f -
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: conforma-vsa-test
  namespace: managed-context
spec:
  params:
    - name: image-url
      type: string
      default: "ttl.sh/test-image"
    - name: image-digest
      type: string
      default: "sha256:abc123def456789abcdef123456789abcdef123456789abcdef123456789abcdef"
  workspaces:
    - name: conforma-results
    - name: vsa-output
    - name: signing-keys
  tasks:
    - name: setup-test-data
      taskSpec:
        workspaces:
          - name: conforma-results
        steps:
          - name: create-sample-conforma-results
            image: registry.redhat.io/ubi9/ubi-minimal:latest
            script: |
              #!/bin/bash
              cat > $(workspaces.conforma-results.path)/results.json << 'RESULT_EOF'
              {
                "success": true,
                "components": [
                  {
                    "name": "test-component",
                    "containerImage": "$(params.image-url)@$(params.image-digest)",
                    "success": true,
                    "violations": []
                  }
                ],
                "policy": {
                  "sources": [
                    {
                      "policy": ["oci://policy.example.com/test-policy@sha256:def456"]
                    }
                  ]
                },
                "ec-version": "v0.1.0",
                "effective-time": "2024-01-01T12:00:00Z"
              }
              RESULT_EOF
      workspaces:
        - name: conforma-results
          workspace: conforma-results
    
    - name: vsa-signing
      taskRef:
        name: conforma-vsa
      params:
        - name: image-url
          value: "$(params.image-url)"
        - name: image-digest
          value: "$(params.image-digest)"
        - name: debug
          value: "true"
      workspaces:
        - name: conforma-results
          workspace: conforma-results
        - name: vsa-output
          workspace: vsa-output
        - name: signing-keys
          secret:
            secretName: cosign-signing-keys
      runAfter:
        - setup-test-data
EOF
    
    echo "Sample pipeline created successfully"
}

# Function to show usage instructions
show_usage_instructions() {
    echo ""
    echo "=== Setup Completed Successfully ==="
    echo ""
    echo "The cosign CLI integration for VSA signing has been deployed to namespace: $NAMESPACE"
    echo ""
    echo "Key components deployed:"
    echo "  - Tekton Task: conforma-vsa"
    echo "  - Secrets: cosign-signing-keys, vsa-verifier-config"
    echo "  - ConfigMap: vsa-convert-tool"
    echo "  - RBAC: ServiceAccount, Role, RoleBinding, NetworkPolicy"
    echo "  - Sample Pipeline: conforma-vsa-test"
    echo ""
    echo "To test the setup:"
    echo "  kubectl create pipelinerun conforma-vsa-test-run \\"
    echo "    --from=pipeline/conforma-vsa-test \\"
    echo "    --namespace=$NAMESPACE \\"
    echo "    --workspace=name=conforma-results,emptyDir= \\"
    echo "    --workspace=name=vsa-output,emptyDir= \\"
    echo "    --workspace=name=signing-keys,secret=cosign-signing-keys"
    echo ""
    echo "To view logs:"
    echo "  tkn pipelinerun logs -f conforma-vsa-test-run -n $NAMESPACE"
    echo ""
    echo "Verifier ID configured: $VERIFIER_ID"
    echo "Cosign public key: $COSIGN_PUBLIC_KEY"
    echo ""
    
    if [[ "$DEBUG" == "true" ]]; then
        echo "=== Debug Information ==="
        echo "Cosign private key: $COSIGN_PRIVATE_KEY"
        echo "Cosign password: $COSIGN_PASSWORD"
        echo ""
    fi
}

# Main execution
main() {
    check_prerequisites
    create_namespace
    generate_cosign_keys
    create_signing_secrets
    build_and_deploy_converter
    apply_rbac
    deploy_tekton_task
    verify_deployment
    create_sample_pipeline
    show_usage_instructions
}

# Run main function
main "$@"