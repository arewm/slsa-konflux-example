#!/bin/bash
#
# Generate release signing keys and create Kubernetes secrets
#
# This script generates a cosign key-pair for signing release-time attestations including:
#   - Verification Summary Attestations (VSAs)
#   - Release SBOM attestations
#   - Other release signatures
#
# This key is separate from the build-time Tekton Chains signing key to maintain
# proper trust boundary separation between tenant (build) and managed (release) contexts.
#
# Usage:
#   ./generate-release-signing-keys.sh [NAMESPACE]
#
# Arguments:
#   NAMESPACE   - Kubernetes namespace for the signing key secret (default: managed-tenant)
#
# Environment Variables:
#   COSIGN_PASSWORD - Password for encrypting the private key (optional, default: no password)
#
# Examples:
#   # Generate keys without password in default namespace
#   ./generate-release-signing-keys.sh
#
#   # Generate keys in custom namespace
#   ./generate-release-signing-keys.sh my-managed-namespace
#
#   # Generate keys with password protection
#   COSIGN_PASSWORD="my-secure-password" ./generate-release-signing-keys.sh
#

set -euo pipefail

# Configuration
NAMESPACE="${1:-managed-tenant}"
SECRET_NAME="release-signing-key"
TEMP_DIR=$(mktemp -d)

# Cleanup on exit
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if cosign is available
    if ! command -v cosign &> /dev/null; then
        log_error "cosign not found. Installing cosign..."

        # Detect OS and architecture
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        ARCH=$(uname -m)

        # Map architecture names
        case "$ARCH" in
            x86_64) ARCH="amd64" ;;
            aarch64|arm64) ARCH="arm64" ;;
        esac

        # Download cosign
        COSIGN_URL="https://github.com/sigstore/cosign/releases/latest/download/cosign-${OS}-${ARCH}"
        curl -o cosign -L "$COSIGN_URL"
        chmod +x cosign
        sudo mv cosign /usr/local/bin/

        log_info "cosign installed successfully"
    else
        log_info "cosign is already installed: $(cosign version --short 2>&1 | head -1)"
    fi

    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is required but not found. Please install kubectl."
        exit 1
    fi

    # Check if namespace exists
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_error "Namespace '$NAMESPACE' does not exist."
        log_info "Creating namespace '$NAMESPACE'..."
        kubectl create namespace "$NAMESPACE"
    fi
}

# Generate cosign key-pair
generate_keys() {
    log_info "Generating VSA signing key-pair..."

    cd "$TEMP_DIR"

    # Generate keys
    # If COSIGN_PASSWORD is not set, use empty password (not recommended for production)
    if [[ -z "${COSIGN_PASSWORD:-}" ]]; then
        log_warning "No COSIGN_PASSWORD set. Generating unencrypted keys (suitable for demos only)."
        log_warning "For production, set COSIGN_PASSWORD environment variable to encrypt keys."
        export COSIGN_PASSWORD=""
    else
        log_info "Using COSIGN_PASSWORD to encrypt private key."
    fi

    cosign generate-key-pair

    # Verify key generation
    if [[ ! -f "cosign.key" ]] || [[ ! -f "cosign.pub" ]]; then
        log_error "Failed to generate cosign key-pair"
        exit 1
    fi

    log_info "Key-pair generated successfully!"
    echo ""
    log_info "Public key contents:"
    echo "---"
    cat cosign.pub
    echo "---"
    echo ""
}

# Create Kubernetes secret
create_secret() {
    log_info "Creating Kubernetes secret '$SECRET_NAME' in namespace '$NAMESPACE'..."

    # Check if secret already exists
    if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_warning "Secret '$SECRET_NAME' already exists in namespace '$NAMESPACE'."
        read -p "Do you want to replace it? (yes/no): " -r
        echo
        if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
            log_info "Keeping existing secret. Exiting."
            exit 0
        fi
        log_info "Deleting existing secret..."
        kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE"
    fi

    # Create secret from generated keys
    kubectl create secret generic "$SECRET_NAME" \
        --from-file=cosign.key="$TEMP_DIR/cosign.key" \
        --from-file=cosign.pub="$TEMP_DIR/cosign.pub" \
        --namespace="$NAMESPACE"

    log_info "Secret '$SECRET_NAME' created successfully in namespace '$NAMESPACE'!"
}

# Print usage instructions
print_instructions() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "VSA Signing Keys Setup Complete!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "Secret Details:"
    echo "  Namespace: $NAMESPACE"
    echo "  Secret Name: $SECRET_NAME"
    echo "  Contents: cosign.key (private key), cosign.pub (public key)"
    echo ""
    log_info "To retrieve the public key for VSA verification:"
    echo ""
    echo "  kubectl get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.cosign\.pub}' | base64 -d"
    echo ""
    log_info "To use in Tekton tasks:"
    echo ""
    echo "  - name: VSA_SIGNING_KEY"
    echo "    value: \"k8s://$NAMESPACE/$SECRET_NAME\""
    echo ""
    log_info "For production deployments, consider:"
    echo "  - Use encrypted keys (set COSIGN_PASSWORD)"
    echo "  - Implement key rotation policies"
    echo "  - Use keyless signing with Fulcio/SPIFFE for better security"
    echo "  - Restrict secret access with RBAC"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Main execution
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  VSA Signing Key Generation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    check_prerequisites
    generate_keys
    create_secret
    print_instructions
}

main
