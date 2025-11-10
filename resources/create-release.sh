#!/bin/bash
set -e

# Usage: ./create-release.sh <application-name> <namespace> <author> [managed-namespace]
APPLICATION_NAME=${1:-festoji}
NAMESPACE=${2:-slsa-e2e-tenant}
AUTHOR=${3:-user1}
MANAGED_NAMESPACE=${4:-slsa-e2e-managed-tenant}

echo "Creating manual release for application: $APPLICATION_NAME"
echo "Namespace: $NAMESPACE"
echo "Author: $AUTHOR"
echo "Managed namespace: $MANAGED_NAMESPACE"
echo ""

# Get the latest push snapshot for the application (exclude PR snapshots)
LATEST_SNAPSHOT=$(kubectl get snapshot -n $NAMESPACE \
  -l appstudio.openshift.io/application=$APPLICATION_NAME,pac.test.appstudio.openshift.io/event-type=push \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')

if [ -z "$LATEST_SNAPSHOT" ]; then
  echo "Error: No push snapshots found for application $APPLICATION_NAME"
  echo "Make sure a push build has completed successfully"
  exit 1
fi

echo "Latest snapshot: $LATEST_SNAPSHOT"

# Get the git SHA from the snapshot for a readable release name
GIT_SHA=$(kubectl get snapshot $LATEST_SNAPSHOT -n $NAMESPACE \
  -o jsonpath='{.spec.components[0].containerImage}' | \
  grep -oE '[a-f0-9]{7}' | head -1 || echo "")

if [ -n "$GIT_SHA" ]; then
  RELEASE_NAME="${LATEST_SNAPSHOT}-${GIT_SHA}-"
else
  RELEASE_NAME="${LATEST_SNAPSHOT}-"
fi

echo "Release name prefix: $RELEASE_NAME"
echo ""

# Create the Release resource
cat <<EOF | kubectl create -f -
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  generateName: ${RELEASE_NAME}
  namespace: $NAMESPACE
  labels:
    release.appstudio.openshift.io/author: "$AUTHOR"
spec:
  snapshot: $LATEST_SNAPSHOT
  releasePlan: ${APPLICATION_NAME}-release
EOF

echo ""
echo "Release created successfully!"
echo ""
echo "Check release status with:"
echo "  kubectl get release -n $NAMESPACE -l release.appstudio.openshift.io/author=$AUTHOR --sort-by=.metadata.creationTimestamp"
