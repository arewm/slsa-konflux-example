#!/bin/bash

# validate-vsa.sh - Validates VSA output against SLSA v1.0 specification
# Usage: ./validate-vsa.sh <vsa-file.json>

set -e

VSA_FILE="$1"

if [ -z "$VSA_FILE" ]; then
    echo "Usage: $0 <vsa-file.json>"
    exit 1
fi

if [ ! -f "$VSA_FILE" ]; then
    echo "Error: File $VSA_FILE not found"
    exit 1
fi

echo "Validating VSA file: $VSA_FILE"

# Check if jq is available
if ! command -v jq >/dev/null 2>&1; then
    echo "Warning: jq not found, skipping JSON validation"
    echo "Install jq for better validation: brew install jq"
else
    echo "✓ JSON syntax validation..."
    jq empty "$VSA_FILE" || exit 1
fi

# Basic SLSA VSA v1.0 structure validation
echo "✓ Checking SLSA VSA structure..."

# Check required top-level fields
REQUIRED_FIELDS=("_type" "subject" "predicateType" "predicate")
for field in "${REQUIRED_FIELDS[@]}"; do
    if ! jq -e "has(\"$field\")" "$VSA_FILE" >/dev/null; then
        echo "✗ Missing required field: $field"
        exit 1
    fi
done

# Check statement type
STATEMENT_TYPE=$(jq -r '._type' "$VSA_FILE")
if [ "$STATEMENT_TYPE" != "https://in-toto.io/Statement/v1" ]; then
    echo "✗ Invalid statement type: $STATEMENT_TYPE"
    echo "  Expected: https://in-toto.io/Statement/v1"
    exit 1
fi

# Check predicate type
PREDICATE_TYPE=$(jq -r '.predicateType' "$VSA_FILE")
if [ "$PREDICATE_TYPE" != "https://slsa.dev/verification_summary/v1" ]; then
    echo "✗ Invalid predicate type: $PREDICATE_TYPE"
    echo "  Expected: https://slsa.dev/verification_summary/v1"
    exit 1
fi

# Check subjects
SUBJECT_COUNT=$(jq '.subject | length' "$VSA_FILE")
if [ "$SUBJECT_COUNT" -eq 0 ]; then
    echo "✗ No subjects found"
    exit 1
fi

# Check each subject has required fields
for i in $(seq 0 $((SUBJECT_COUNT-1))); do
    if ! jq -e ".subject[$i] | has(\"name\")" "$VSA_FILE" >/dev/null; then
        echo "✗ Subject[$i] missing name field"
        exit 1
    fi
    if ! jq -e ".subject[$i] | has(\"digest\")" "$VSA_FILE" >/dev/null; then
        echo "✗ Subject[$i] missing digest field"
        exit 1
    fi
    if ! jq -e ".subject[$i].digest | has(\"sha256\")" "$VSA_FILE" >/dev/null; then
        echo "✗ Subject[$i] missing sha256 digest"
        exit 1
    fi
done

# Check predicate required fields
PREDICATE_FIELDS=("verifier" "timeVerified" "resourceUri" "policy" "verificationResult")
for field in "${PREDICATE_FIELDS[@]}"; do
    if ! jq -e ".predicate | has(\"$field\")" "$VSA_FILE" >/dev/null; then
        echo "✗ Predicate missing required field: $field"
        exit 1
    fi
done

# Check verifier structure
if ! jq -e '.predicate.verifier | has("id")' "$VSA_FILE" >/dev/null; then
    echo "✗ Verifier missing id field"
    exit 1
fi

# Check verification result is valid
VERIFICATION_RESULT=$(jq -r '.predicate.verificationResult' "$VSA_FILE")
if [[ ! "$VERIFICATION_RESULT" =~ ^(PASSED|FAILED)$ ]]; then
    echo "✗ Invalid verification result: $VERIFICATION_RESULT"
    echo "  Expected: PASSED or FAILED"
    exit 1
fi

# Check policy has URI
if ! jq -e '.predicate.policy | has("uri")' "$VSA_FILE" >/dev/null; then
    echo "✗ Policy missing uri field"
    exit 1
fi

# Validation summary
echo ""
echo "✓ VSA validation complete!"
echo "  Statement Type: $STATEMENT_TYPE"
echo "  Predicate Type: $PREDICATE_TYPE"
echo "  Subjects: $SUBJECT_COUNT"
echo "  Verification Result: $VERIFICATION_RESULT"

# Extract and display key information
echo ""
echo "VSA Summary:"
echo "============"
jq -r '.subject[] | "Subject: \(.name)@sha256:\(.digest.sha256)"' "$VSA_FILE"
echo "Verifier: $(jq -r '.predicate.verifier.id' "$VSA_FILE")"
echo "Policy: $(jq -r '.predicate.policy.uri' "$VSA_FILE")"
echo "Time Verified: $(jq -r '.predicate.timeVerified' "$VSA_FILE")"
echo "Verified Levels: $(jq -r '.predicate.verifiedLevels | join(", ")' "$VSA_FILE")"

echo ""
echo "✓ VSA file is valid and compliant with SLSA v1.0 specification"