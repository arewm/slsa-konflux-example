#!/bin/bash
set -euo pipefail

# test-policy-provenance.sh
# Test script for policy provenance implementation in the VSA converter

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
TESTDATA_DIR="$SCRIPT_DIR/testdata"

echo "=== Policy Provenance VSA Converter Test ==="

# Create build directory if it doesn't exist
mkdir -p "$BUILD_DIR"

# Build the enhanced converter
echo "Building enhanced VSA converter..."
cd "$SCRIPT_DIR"
go build -o "$BUILD_DIR/convert-conforma-to-vsa" convert-conforma-to-vsa.go

# Test 1: Basic conversion with policy URI
echo ""
echo "Test 1: Basic conversion with policy URI"
"$BUILD_DIR/convert-conforma-to-vsa" \
  -input "$TESTDATA_DIR/conforma-success.json" \
  -output "$BUILD_DIR/vsa-basic-policy.json" \
  -subject "quay.io/konflux-ci/example-app@sha256:abcd1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab" \
  -verifier-id "https://managed.konflux.example.com/conforma-vsa" \
  -verifier-version "v1.0.0" \
  -policy-uri "oci://quay.io/konflux-ci/enterprise-contract-policy:v1.0"

echo "✓ Basic policy URI conversion successful"
jq '.predicate.policy.uri' "$BUILD_DIR/vsa-basic-policy.json"

# Test 2: Conversion with policy URI and digest
echo ""
echo "Test 2: Conversion with policy URI and digest"
"$BUILD_DIR/convert-conforma-to-vsa" \
  -input "$TESTDATA_DIR/conforma-success.json" \
  -output "$BUILD_DIR/vsa-policy-digest.json" \
  -subject "quay.io/konflux-ci/example-app@sha256:abcd1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab" \
  -verifier-id "https://managed.konflux.example.com/conforma-vsa" \
  -verifier-version "v1.0.0" \
  -policy-uri "oci://quay.io/konflux-ci/enterprise-contract-policy:v1.0" \
  -policy-digest "sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"

echo "✓ Policy URI with digest conversion successful"
jq '.predicate.policy' "$BUILD_DIR/vsa-policy-digest.json"

# Test 3: Conversion with policy metadata file
echo ""
echo "Test 3: Conversion with policy metadata file"
"$BUILD_DIR/convert-conforma-to-vsa" \
  -input "$TESTDATA_DIR/conforma-success.json" \
  -output "$BUILD_DIR/vsa-policy-metadata.json" \
  -subject "quay.io/konflux-ci/example-app@sha256:abcd1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab" \
  -verifier-id "https://managed.konflux.example.com/conforma-vsa" \
  -verifier-version "v1.0.0" \
  -policy-metadata "$TESTDATA_DIR/policy-metadata-example.json"

echo "✓ Policy metadata file conversion successful"
jq '.predicate.policy' "$BUILD_DIR/vsa-policy-metadata.json"

# Test 4: Backward compatibility - no policy parameters
echo ""
echo "Test 4: Backward compatibility test"
"$BUILD_DIR/convert-conforma-to-vsa" \
  -input "$TESTDATA_DIR/conforma-success.json" \
  -output "$BUILD_DIR/vsa-backward-compat.json" \
  -subject "quay.io/konflux-ci/example-app@sha256:abcd1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab" \
  -verifier-id "https://managed.konflux.example.com/conforma-vsa" \
  -verifier-version "v1.0.0"

echo "✓ Backward compatibility conversion successful"
jq '.predicate.policy.uri' "$BUILD_DIR/vsa-backward-compat.json"

# Validation Tests
echo ""
echo "=== Validation Tests ==="

# Validate all generated VSAs have correct structure
for vsa_file in "$BUILD_DIR"/vsa-*.json; do
  echo "Validating $(basename "$vsa_file")..."
  
  # Check required fields
  if ! jq -e '._type == "https://in-toto.io/Statement/v1"' "$vsa_file" >/dev/null; then
    echo "❌ Invalid _type in $vsa_file"
    exit 1
  fi
  
  if ! jq -e '.predicateType == "https://slsa.dev/verification_summary/v1"' "$vsa_file" >/dev/null; then
    echo "❌ Invalid predicateType in $vsa_file"
    exit 1
  fi
  
  if ! jq -e '.predicate.policy.uri' "$vsa_file" >/dev/null; then
    echo "❌ Missing policy.uri in $vsa_file"
    exit 1
  fi
  
  echo "✓ $(basename "$vsa_file") validation passed"
done

# Test policy provenance features
echo ""
echo "=== Policy Provenance Feature Tests ==="

# Check that policy digest is included when provided
POLICY_DIGEST=$(jq -r '.predicate.policy.digest.sha256' "$BUILD_DIR/vsa-policy-digest.json")
if [[ "$POLICY_DIGEST" == "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef" ]]; then
  echo "✓ Policy digest correctly included in VSA"
else
  echo "❌ Policy digest not correctly included: $POLICY_DIGEST"
  exit 1
fi

# Check that metadata file overrides work
METADATA_URI=$(jq -r '.predicate.policy.uri' "$BUILD_DIR/vsa-policy-metadata.json")
if [[ "$METADATA_URI" == "oci://quay.io/konflux-ci/enterprise-contract-policy:v1.0" ]]; then
  echo "✓ Policy metadata file correctly overrides URI"
else
  echo "❌ Policy metadata file override failed: $METADATA_URI"
  exit 1
fi

# Check backward compatibility
COMPAT_URI=$(jq -r '.predicate.policy.uri' "$BUILD_DIR/vsa-backward-compat.json")
if [[ "$COMPAT_URI" != "null" && "$COMPAT_URI" != "" ]]; then
  echo "✓ Backward compatibility maintained"
else
  echo "❌ Backward compatibility broken: $COMPAT_URI"
  exit 1
fi

echo ""
echo "🎉 All policy provenance tests passed!"
echo ""
echo "Generated test files:"
ls -la "$BUILD_DIR"/vsa-*.json
echo ""
echo "To inspect the enhanced VSA format:"
echo "jq '.predicate.policy' $BUILD_DIR/vsa-policy-digest.json"