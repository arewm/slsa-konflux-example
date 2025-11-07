#!/usr/bin/env bash
# Builds and pushes a specific Tekton task bundle
# Usage: build-task.sh <task-name> <task-version>
# Example: build-task.sh trivy-sbom-scan 0.1

set -e -o pipefail

TASK_NAME="${1:-}"
TASK_VERSION="${2:-}"

if [ -z "$TASK_NAME" ] || [ -z "$TASK_VERSION" ]; then
    echo "Usage: $0 <task-name> <task-version>"
    echo "Example: $0 trivy-sbom-scan 0.1"
    exit 1
fi

VCS_URL=https://github.com/arewm/slsa-konflux-example
VCS_REF=$(git rev-parse HEAD)

# Registry configuration
: "${REGISTRY:=quay.io}"
: "${REGISTRY_NAMESPACE:=}"
: "${BUILD_TAG:=}"
: "${TEST_REPO_NAME:=}"
: "${FORCE_PUSH:=false}"

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

# Navigate to repository root
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$SCRIPTDIR/.." || exit 1

# Task bundle output file
OUTPUT_TASK_BUNDLE_LIST="${OUTPUT_TASK_BUNDLE_LIST:-task-bundle-list}"

TASK_DIR="managed-context/tasks/${TASK_NAME}/${TASK_VERSION}"
TASK_YAML="${TASK_DIR}/${TASK_NAME}.yaml"

if [ ! -f "$TASK_YAML" ]; then
    echo "Error: Task file not found: $TASK_YAML"
    exit 1
fi

echo "Building task bundle for: $TASK_NAME v$TASK_VERSION"

task_name=$(yq e '.metadata.name' "$TASK_YAML")
task_version=$(yq e '.metadata.labels."app.kubernetes.io/version"' "$TASK_YAML")
task_description=$(yq e '.spec.description' "$TASK_YAML" | head -n 1)

repository=${TEST_REPO_NAME:-task-${task_name}}
# Per ADR/0054: Use version as the tag (floating tag pattern)
tag=${TEST_REPO_NAME:+${task_name}-}${task_version}
task_bundle=${REGISTRY}/${REGISTRY_NAMESPACE}/${repository}:${tag}

# Build annotations for the bundle
ANNOTATIONS=()
ANNOTATIONS+=("org.opencontainers.image.source=${VCS_URL}")
ANNOTATIONS+=("org.opencontainers.image.revision=${VCS_REF}")
ANNOTATIONS+=("org.opencontainers.image.url=${VCS_URL}/tree/${VCS_REF}/managed-context/tasks/${TASK_NAME}/${TASK_VERSION}")

if [[ "${task_description}" != "null" ]]; then
    ANNOTATIONS+=("org.opencontainers.image.description=${task_description}")
fi

# Check if tag already exists (unless FORCE_PUSH=true)
if [ "$FORCE_PUSH" != "true" ]; then
    echo "Checking if bundle tag already exists: $task_bundle"
    if command -v skopeo >/dev/null 2>&1; then
        if skopeo inspect --no-tags "docker://${task_bundle}" >/dev/null 2>&1; then
            echo ""
            echo "ERROR: Bundle tag already exists: $task_bundle"
            echo ""
            echo "Per ADR/0054, version tags should not be overwritten unless necessary."
            echo "This tag already exists in the registry."
            echo ""
            echo "If you need to:"
            echo "  - Fix a bug in this version: Update the task and increment patch version (e.g., 0.1 → 0.1.1)"
            echo "  - Make breaking changes: Increment minor version (e.g., 0.1 → 0.2)"
            echo "  - Bootstrap/force overwrite: Set FORCE_PUSH=true"
            echo ""
            echo "Example: FORCE_PUSH=true ./hack/build-task.sh $TASK_NAME $TASK_VERSION"
            exit 1
        fi
    elif command -v crane >/dev/null 2>&1; then
        if crane digest "${task_bundle}" >/dev/null 2>&1; then
            echo ""
            echo "ERROR: Bundle tag already exists: $task_bundle"
            echo ""
            echo "Per ADR/0054, version tags should not be overwritten unless necessary."
            echo "See above for resolution options."
            exit 1
        fi
    else
        echo "Warning: Neither skopeo nor crane found. Cannot check if tag exists." 1>&2
        echo "Proceeding with push (may overwrite existing tag)..." 1>&2
    fi
else
    echo "FORCE_PUSH=true - Skipping tag existence check"
fi

ANNOTATION_FLAGS=()
for annotation in "${ANNOTATIONS[@]}"; do
    ANNOTATION_FLAGS+=("--annotate" "$(escape_tkn_bundle_arg "$annotation")")
done

echo ""
echo "Building and pushing task bundle: $task_bundle"
if [ -n "$AUTH_JSON" ]; then
    echo "Using authentication from: $DOCKER_CONFIG"
fi

retry tkn bundle push "${ANNOTATION_FLAGS[@]}" "$task_bundle" -f "${TASK_YAML}" | \
    save_ref "$task_bundle" "$OUTPUT_TASK_BUNDLE_LIST"

echo ""
echo "Task bundle pushed successfully!"
echo "Bundle reference saved to: $OUTPUT_TASK_BUNDLE_LIST"
cat "$OUTPUT_TASK_BUNDLE_LIST"
