#!/usr/bin/env bash
# Main build orchestrator for managed-context Tekton bundles
# Usage:
#   ./hack/build-and-push.sh              # Build all tasks and pipeline
#   ./hack/build-and-push.sh tasks        # Build only tasks
#   ./hack/build-and-push.sh pipeline     # Build only pipeline (assumes tasks exist)
#   ./hack/build-and-push.sh task <name> <version>  # Build specific task

set -e -o pipefail

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$SCRIPTDIR/.." || exit 1

MODE="${1:-all}"

# Registry configuration check
if [ -z "$REGISTRY_NAMESPACE" ]; then
    echo "Error: REGISTRY_NAMESPACE is not set."
    echo ""
    echo "Required environment variables:"
    echo "  REGISTRY_NAMESPACE - Quay.io namespace (e.g., your-username)"
    echo ""
    echo "Optional environment variables:"
    echo "  REGISTRY           - Registry URL (default: quay.io)"
    echo "  BUILD_TAG          - Tag for bundles (default: timestamp)"
    echo "  TEST_REPO_NAME     - Single repo for all bundles (for testing)"
    echo "  FORCE_PUSH         - Skip tag existence check (default: false)"
    echo ""
    echo "Example:"
    echo "  export REGISTRY_NAMESPACE=arewm"
    echo "  ./hack/build-and-push.sh"
    echo ""
    echo "Bootstrap/force overwrite:"
    echo "  export REGISTRY_NAMESPACE=arewm"
    echo "  export FORCE_PUSH=true"
    echo "  ./hack/build-and-push.sh"
    exit 1
fi

# List of tasks to build
TASKS=(
    "trivy-sbom-scan:0.1"
)

build_tasks() {
    echo "========================================"
    echo "Building Tasks"
    echo "========================================"

    for task_spec in "${TASKS[@]}"; do
        IFS=':' read -r task_name task_version <<< "$task_spec"
        echo ""
        echo "Building task: $task_name v$task_version"
        "$SCRIPTDIR/build-task.sh" "$task_name" "$task_version"
    done
}

build_specific_task() {
    local task_name="$1"
    local task_version="$2"

    if [ -z "$task_name" ] || [ -z "$task_version" ]; then
        echo "Usage: $0 task <task-name> <task-version>"
        echo "Example: $0 task trivy-sbom-scan 0.1"
        exit 1
    fi

    echo "========================================"
    echo "Building Specific Task"
    echo "========================================"
    echo ""
    "$SCRIPTDIR/build-task.sh" "$task_name" "$task_version"
}

build_pipeline() {
    echo "========================================"
    echo "Building Pipeline"
    echo "========================================"
    echo ""
    "$SCRIPTDIR/build-pipeline.sh"
}

# Main execution
case "$MODE" in
    all)
        build_tasks
        build_pipeline
        echo ""
        echo "========================================"
        echo "Build Complete!"
        echo "========================================"
        echo ""
        echo "Task bundles:"
        cat task-bundle-list 2>/dev/null || echo "  (none)"
        echo ""
        echo "Pipeline bundles:"
        cat pipeline-bundle-list 2>/dev/null || echo "  (none)"
        ;;
    tasks)
        build_tasks
        echo ""
        echo "Task bundles:"
        cat task-bundle-list 2>/dev/null || echo "  (none)"
        ;;
    pipeline)
        build_pipeline
        echo ""
        echo "Pipeline bundles:"
        cat pipeline-bundle-list 2>/dev/null || echo "  (none)"
        ;;
    task)
        build_specific_task "$2" "$3"
        echo ""
        echo "Task bundle:"
        cat task-bundle-list 2>/dev/null || echo "  (none)"
        ;;
    *)
        echo "Usage: $0 [all|tasks|pipeline|task <name> <version>]"
        echo ""
        echo "Examples:"
        echo "  $0              # Build everything"
        echo "  $0 all          # Build everything"
        echo "  $0 tasks        # Build only tasks"
        echo "  $0 pipeline     # Build only pipeline"
        echo "  $0 task trivy-sbom-scan 0.1  # Build specific task"
        exit 1
        ;;
esac
