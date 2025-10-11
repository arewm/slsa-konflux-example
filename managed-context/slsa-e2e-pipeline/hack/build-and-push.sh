#!/bin/bash

# Build and push script for slsa-e2e-pipeline
# This script creates a Tekton bundle for the custom SLSA e2e pipeline
# and references existing task bundles from konflux-ci/tekton-catalog

set -e -o pipefail

VCS_URL=https://github.com/arewm/slsa-konflux-example
VCS_REF=$(git rev-parse HEAD)

# Registry configuration
: "${REGISTRY:=quay.io}"
: "${REGISTRY_NAMESPACE:=}"
: "${BUILD_TAG:=}"
: "${TEST_REPO_NAME:=}"

# Determine auth file location and set DOCKER_CONFIG
AUTH_JSON=
if [ -e "$HOME/.docker/config.json" ]; then
    AUTH_JSON="$HOME/.docker/config.json"
    export DOCKER_CONFIG="$HOME/.docker"
elif [ -n "$XDG_RUNTIME_DIR" ] && [ -e "$XDG_RUNTIME_DIR/containers/auth.json" ]; then
    AUTH_JSON="$XDG_RUNTIME_DIR/containers/auth.json"
    export DOCKER_CONFIG="$XDG_RUNTIME_DIR/containers"
else
    echo "Warning: Cannot find registry authentication file. Attempting unauthenticated push." 1>&2
fi

if [ -z "$REGISTRY_NAMESPACE" ]; then
    echo "REGISTRY_NAMESPACE is not set, skip this build."
    exit 0
fi

if [ -z "$BUILD_TAG" ]; then
    BUILD_TAG=$(date +"%Y-%m-%d-%H%M%S")
    echo "BUILD_TAG is not defined, using $BUILD_TAG"
fi

# Function to escape tkn bundle arguments
function escape_tkn_bundle_arg() {
    local arg=$1
    local escaped_arg=${arg//\"/\"\"}
    printf '"%s"' "$escaped_arg"
}

# Function to save bundle reference with digest
function save_ref() {
    local output
    output="$(< /dev/stdin)"
    echo "${output}"
    local digest
    digest="$(echo "${output}" | grep -o 'sha256:[a-f0-9]*' | head -1)"

    local tagRef="$1"
    local refFile="$2"
    echo "${tagRef}@${digest}" >> "${refFile}"
    echo "Created:"
    echo "${tagRef}@${digest}"
}

# Retry function
retry() {
    local status
    local retry=0
    local -r interval=${RETRY_INTERVAL:-5}
    local -r max_retries=5
    while true; do
        "$@" && break
        status=$?
        ((retry+=1))
        if [ $retry -gt $max_retries ]; then
            return $status
        fi
        echo "info: Waiting for a while, then retry ..." 1>&2
        sleep "$interval"
    done
}

# Function to fetch digest for a task bundle
fetch_task_digest() {
    local bundle=$1
    echo "Fetching digest for: $bundle" 1>&2
    local digest
    if command -v skopeo >/dev/null 2>&1; then
        digest=$(retry skopeo inspect --no-tags "docker://${bundle}" 2>/dev/null | grep -o '"Digest"[[:space:]]*:[[:space:]]*"sha256:[a-f0-9]*"' | grep -o 'sha256:[a-f0-9]*')
    else
        # Fallback to crane if available
        if command -v crane >/dev/null 2>&1; then
            digest=$(crane digest "${bundle}" 2>/dev/null)
        else
            echo "Error: Neither skopeo nor crane found. Please install one of them." 1>&2
            exit 1
        fi
    fi

    if [ -z "$digest" ]; then
        echo "Error: Failed to fetch digest for ${bundle}" 1>&2
        exit 1
    fi

    echo "${digest}"
}

# Function to pin task bundles in pipeline
# Returns: list of pinned bundles (one per line) to stdout
pin_task_bundles() {
    local input_yaml=$1
    local output_yaml=$2
    local bundle_list_file=$3

    cp "$input_yaml" "$output_yaml"

    echo "Pinning task bundle references..." 1>&2
    > "$bundle_list_file"  # Clear the file

    # Extract all task bundle references and pin them
    local task_count
    task_count=$(yq e '.spec.tasks | length' "$output_yaml")

    for ((i=0; i<task_count; i++)); do
        local bundle
        bundle=$(yq e ".spec.tasks[${i}].taskRef.params[] | select(.name == \"bundle\") | .value" "$output_yaml" | head -1)

        # Skip if no bundle reference found (e.g., task without taskRef)
        if [ -z "$bundle" ] || [ "$bundle" == "null" ]; then
            continue
        fi

        # Remove existing digest if present to always fetch latest
        local bundle_without_digest="${bundle%%@sha256:*}"

        local digest
        digest=$(fetch_task_digest "$bundle_without_digest")

        # Format: quay.io/org/repo:tag@sha256:digest
        local pinned_bundle="${bundle_without_digest}@${digest}"

        echo "  Task ${i}: ${bundle_without_digest} -> ${pinned_bundle}" 1>&2

        # Update the bundle value with digest
        yq e -i ".spec.tasks[${i}].taskRef.params[] |= (select(.name == \"bundle\") | .value = \"${pinned_bundle}\")" "$output_yaml"

        # Save to bundle list for acceptable bundles
        echo "$pinned_bundle" >> "$bundle_list_file"
    done
}

# Navigate to script directory
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$SCRIPTDIR/.." || exit 1

# Pipeline bundle output file
OUTPUT_PIPELINE_BUNDLE_LIST="${OUTPUT_PIPELINE_BUNDLE_LIST:-pipeline-bundle-list}"
rm -f "${OUTPUT_PIPELINE_BUNDLE_LIST}"

pipeline_yaml="slsa-e2e-pipeline.yaml"
pipeline_name=$(yq e '.metadata.name' "$pipeline_yaml")
pipeline_description=$(yq e '.spec.description' "$pipeline_yaml" | head -n 1)
pipeline_dir="slsa-e2e-pipeline/"

# Create temporary file for pinned pipeline
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
pinned_pipeline="${WORKDIR}/pinned-pipeline.yaml"
task_bundle_list="${WORKDIR}/task-bundles.txt"

# Pin all task bundles to their digests
pin_task_bundles "$pipeline_yaml" "$pinned_pipeline" "$task_bundle_list"

repository=${TEST_REPO_NAME:-pipeline-${pipeline_name}}
tag=${TEST_REPO_NAME:+${pipeline_name}-}$BUILD_TAG
pipeline_bundle=${REGISTRY}/${REGISTRY_NAMESPACE}/${repository}:${tag}

# Build annotations for the bundle
ANNOTATIONS=()
ANNOTATIONS+=("org.opencontainers.image.source=${VCS_URL}")
ANNOTATIONS+=("org.opencontainers.image.revision=${VCS_REF}")
ANNOTATIONS+=("org.opencontainers.image.url=${VCS_URL}/tree/${VCS_REF}/${pipeline_dir}")

if [[ "${pipeline_description}" != "null" ]]; then
    ANNOTATIONS+=("org.opencontainers.image.description=${pipeline_description}")
fi

ANNOTATION_FLAGS=()
for annotation in "${ANNOTATIONS[@]}"; do
    ANNOTATION_FLAGS+=("--annotate" "$(escape_tkn_bundle_arg "$annotation")")
done

echo ""
echo "Building and pushing pipeline bundle: $pipeline_bundle"
if [ -n "$AUTH_JSON" ]; then
    echo "Using authentication from: $DOCKER_CONFIG"
fi

retry tkn bundle push "${ANNOTATION_FLAGS[@]}" "$pipeline_bundle" -f "${pinned_pipeline}" | \
    save_ref "$pipeline_bundle" "$OUTPUT_PIPELINE_BUNDLE_LIST"

# Also tag with 'latest' if using skopeo or crane
latest_bundle="${pipeline_bundle%:*}:latest"
echo ""
echo "Tagging as latest: $latest_bundle"

if command -v skopeo >/dev/null 2>&1; then
    retry skopeo copy "docker://${pipeline_bundle}" "docker://${latest_bundle}"
elif command -v crane >/dev/null 2>&1; then
    retry crane copy "${pipeline_bundle}" "${latest_bundle}"
else
    echo "Warning: Neither skopeo nor crane found. Skipping 'latest' tag." 1>&2
fi

echo ""
echo "Pipeline bundle pushed successfully!"
echo "  ${pipeline_bundle}"
echo "  ${latest_bundle}"
echo "Bundle references saved to: $OUTPUT_PIPELINE_BUNDLE_LIST"

# Build acceptable bundles data bundle
echo ""
echo "Building acceptable bundles data bundle..."

if ! command -v ec >/dev/null 2>&1; then
    echo "Error: ec CLI not found. Please install it from https://github.com/enterprise-contract/ec-cli/releases" 1>&2
    exit 1
fi

DATA_BUNDLE_REPO="${REGISTRY}/${REGISTRY_NAMESPACE}/slsa-e2e-data-acceptable-bundles"
DATA_BUNDLE_TAG="${BUILD_TAG}"

# Build bundle parameters from task list
BUNDLE_PARAMS=()
while IFS= read -r bundle; do
    # Skip empty lines
    [ -z "$bundle" ] && continue
    # Verify bundle has proper format (should contain repository path)
    if [[ ! "$bundle" =~ ^[a-z0-9.-]+(/[a-z0-9._-]+)+:[a-z0-9._-]+@sha256:[a-f0-9]+$ ]]; then
        echo "Warning: Skipping malformed bundle reference: $bundle" 1>&2
        continue
    fi
    BUNDLE_PARAMS+=("--bundle=${bundle}")
done < "$task_bundle_list"

# Add the pipeline bundle itself
pipeline_digest=$(grep -o 'sha256:[a-f0-9]*' "$OUTPUT_PIPELINE_BUNDLE_LIST" | head -1)
BUNDLE_PARAMS+=("--bundle=${pipeline_bundle}@${pipeline_digest}")

echo "Creating acceptable bundles with ${#BUNDLE_PARAMS[@]} bundles..."
if [ ${#BUNDLE_PARAMS[@]} -eq 0 ]; then
    echo "Error: No valid bundle references found" 1>&2
    exit 1
fi

# Check if the latest tag exists, if not omit --input flag
EC_INPUT_FLAG=()
if command -v skopeo >/dev/null 2>&1; then
    if skopeo inspect "docker://${DATA_BUNDLE_REPO}:latest" >/dev/null 2>&1; then
        EC_INPUT_FLAG=("--input" "oci:${DATA_BUNDLE_REPO}:latest")
        echo "Using existing data bundle as base: ${DATA_BUNDLE_REPO}:latest"
    else
        echo "No existing data bundle found, creating new one"
    fi
elif command -v crane >/dev/null 2>&1; then
    if crane manifest "${DATA_BUNDLE_REPO}:latest" >/dev/null 2>&1; then
        EC_INPUT_FLAG=("--input" "oci:${DATA_BUNDLE_REPO}:latest")
        echo "Using existing data bundle as base: ${DATA_BUNDLE_REPO}:latest"
    else
        echo "No existing data bundle found, creating new one"
    fi
fi

ec track bundle --debug \
    --in-effect-days 60 \
    "${EC_INPUT_FLAG[@]}" \
    --output "oci:${DATA_BUNDLE_REPO}:${DATA_BUNDLE_TAG}" \
    --timeout "15m0s" \
    --freshen \
    --prune \
    "${BUNDLE_PARAMS[@]}"

# Tag with latest
if command -v skopeo >/dev/null 2>&1; then
    retry skopeo copy "docker://${DATA_BUNDLE_REPO}:${DATA_BUNDLE_TAG}" "docker://${DATA_BUNDLE_REPO}:latest"
elif command -v crane >/dev/null 2>&1; then
    retry crane copy "${DATA_BUNDLE_REPO}:${DATA_BUNDLE_TAG}" "${DATA_BUNDLE_REPO}:latest"
fi

echo "Acceptable bundles data bundle: ${DATA_BUNDLE_REPO}:${DATA_BUNDLE_TAG}"
echo "Acceptable bundles data bundle: ${DATA_BUNDLE_REPO}:latest"

# vim: set et sw=4 ts=4:
