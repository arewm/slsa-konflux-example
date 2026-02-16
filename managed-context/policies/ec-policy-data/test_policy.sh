#!/bin/env bash
# Test the SLSA source verification policy
#
# This script automatically locates the upstream policy library dependencies
# required for testing custom policies.
#
# Usage:
#   ./test_policy.sh [opa test arguments]
#
# Environment variables:
#   EC_POLICY_LIB_PATH    - Path to upstream policy library (optional)
#   EC_CLI                - Path to ec/conforma CLI (optional, defaults to 'ec' in PATH)

set -euo pipefail

cd "$(dirname "$0")"

# Find the ec/conforma CLI
if [ -n "${EC_CLI:-}" ]; then
    CLI="$EC_CLI"
elif command -v ec &> /dev/null; then
    CLI="ec"
else
    echo "Error: Cannot find 'ec' CLI tool" >&2
    echo "Please install it or set EC_CLI environment variable" >&2
    echo "  Example: export EC_CLI=~/conforma/cli/cli" >&2
    exit 1
fi

# Try to find the upstream policy library
POLICY_LIB_PATH="${EC_POLICY_LIB_PATH:-}"

if [ -z "$POLICY_LIB_PATH" ]; then
    # Try common relative paths
    SEARCH_PATHS=(
        "../../../../../../conforma/policy/policy"
        "../../../../../conforma/policy/policy"
        "../../../../conforma/policy/policy"
        "../../../policy"
        "../../policy"
    )
    
    for path in "${SEARCH_PATHS[@]}"; do
        if [ -d "$path/lib" ] && [ -d "$path/release/lib" ]; then
            POLICY_LIB_PATH="$(cd "$path" && pwd)"
            echo "Found policy library at: $POLICY_LIB_PATH" >&2
            break
        fi
    done
fi

# If still not found, try to download from OCI bundle
if [ -z "$POLICY_LIB_PATH" ]; then
    echo "Attempting to fetch policy library from OCI bundle..." >&2
    
    # Create a temporary directory
    TEMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TEMP_DIR"' EXIT
    
    # Try to fetch the default policy bundle
    # This matches the bundle typically used in ECP configurations
    if $CLI opa bundle fetch \
        --bundle oci::quay.io/conforma/release-policy:latest \
        --output "$TEMP_DIR/bundle.tar.gz" 2>/dev/null; then
        
        tar -xzf "$TEMP_DIR/bundle.tar.gz" -C "$TEMP_DIR"
        
        if [ -d "$TEMP_DIR/policy/lib" ]; then
            POLICY_LIB_PATH="$TEMP_DIR/policy"
            echo "Downloaded policy library from OCI bundle" >&2
        fi
    fi
fi

# Verify we found the library
if [ -z "$POLICY_LIB_PATH" ]; then
    cat >&2 <<EOM
Error: Cannot find upstream policy library

The policy tests require the upstream Conforma policy library
which provides helper functions like 'lib.result_helper' and 'tekton.tasks'.

Options to fix this:

1. Set the EC_POLICY_LIB_PATH environment variable:
   export EC_POLICY_LIB_PATH=~/conforma/policy/policy
   ./test_policy.sh

2. Clone the policy repository in a sibling directory:
   cd ~/workspace/git/gh
   git clone https://github.com/conforma/policy.git conforma/policy
   
3. The script will attempt to download the policy bundle from OCI if available

For more information, see:
  https://github.com/conforma/policy
EOM
    exit 1
fi

if [ ! -d "$POLICY_LIB_PATH/lib" ]; then
    echo "Error: $POLICY_LIB_PATH/lib directory not found" >&2
    exit 1
fi

if [ ! -d "$POLICY_LIB_PATH/release/lib" ]; then
    echo "Error: $POLICY_LIB_PATH/release/lib directory not found" >&2
    exit 1
fi

# Run the tests
echo "Running tests with policy library from: $POLICY_LIB_PATH" >&2
echo "" >&2

exec "$CLI" opa test \
    "$POLICY_LIB_PATH/lib" \
    "$POLICY_LIB_PATH/release/lib" \
    policy/custom/slsa_source_verification \
    "$@"
