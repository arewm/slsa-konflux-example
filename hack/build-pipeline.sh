#!/usr/bin/env bash
# Builds and pushes the SLSA e2e pipeline bundle with pinned task references
# Usage: build-pipeline.sh [pipeline-name]
# Example: build-pipeline.sh slsa-e2e-oci-ta

set -e -o pipefail

PIPELINE_NAME="${1:-slsa-e2e-oci-ta}"

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
        digest=$(retry skopeo inspect --no-tags "docker://${bundle}" 2>/dev/null | grep -o '"Digest"[[:space:]]*:[[:space:]]*"sha256:[a-f0-9]*"' | head -1 | grep -o 'sha256:[a-f0-9]*')
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

        # Update the bundle value with digest - escape special characters for yq
        local escaped_bundle="${pinned_bundle//\\/\\\\}"
        escaped_bundle="${escaped_bundle//\"/\\\"}"
        yq e -i "(.spec.tasks[${i}].taskRef.params[] | select(.name == \"bundle\") | .value) = \"${escaped_bundle}\"" "$output_yaml"

        # Save to bundle list for acceptable bundles
        echo "$pinned_bundle" >> "$bundle_list_file"
    done
}

# Navigate to repository root
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$SCRIPTDIR/.." || exit 1

# Pipeline bundle output file
OUTPUT_PIPELINE_BUNDLE_LIST="${OUTPUT_PIPELINE_BUNDLE_LIST:-pipeline-bundle-list}"
rm -f "${OUTPUT_PIPELINE_BUNDLE_LIST}"

PIPELINE_DIR="managed-context/slsa-e2e-pipeline"
PIPELINE_YAML="${PIPELINE_DIR}/slsa-e2e-pipeline.yaml"

if [ ! -f "$PIPELINE_YAML" ]; then
    echo "Error: Pipeline file not found: $PIPELINE_YAML"
    exit 1
fi

echo "Building pipeline bundle for: $PIPELINE_NAME"

pipeline_name=$(yq e '.metadata.name' "$PIPELINE_YAML")
pipeline_description=$(yq e '.spec.description' "$PIPELINE_YAML" | head -n 1)

# Create temporary file for pinned pipeline
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
pinned_pipeline="${WORKDIR}/pinned-pipeline.yaml"
task_bundle_list="${WORKDIR}/task-bundles.txt"

# Pin all task bundles to their digests
pin_task_bundles "$PIPELINE_YAML" "$pinned_pipeline" "$task_bundle_list"

repository=${TEST_REPO_NAME:-pipeline-${pipeline_name}}
tag=${TEST_REPO_NAME:+${pipeline_name}-}$BUILD_TAG
pipeline_bundle=${REGISTRY}/${REGISTRY_NAMESPACE}/${repository}:${tag}

# Build annotations for the bundle
ANNOTATIONS=()
ANNOTATIONS+=("org.opencontainers.image.source=${VCS_URL}")
ANNOTATIONS+=("org.opencontainers.image.revision=${VCS_REF}")
ANNOTATIONS+=("org.opencontainers.image.url=${VCS_URL}/tree/${VCS_REF}/${PIPELINE_DIR}")

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
echo "Bundle reference saved to: $OUTPUT_PIPELINE_BUNDLE_LIST"
cat "$OUTPUT_PIPELINE_BUNDLE_LIST"
