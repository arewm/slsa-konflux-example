#!/bin/bash
set -e

echo "==> Setting up SLSA Konflux Example Prerequisites"

# Create managed tenant namespace
echo "Creating managed-tenant namespace..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: managed-tenant
  labels:
    konflux-ci.dev/type: tenant
EOF

# Patch build-pipeline-config to use custom SLSA pipeline
# This patches the operator-managed ConfigMap to prevent reconciliation
echo "Patching build-pipeline-config with custom SLSA pipeline..."
./scripts/patch-pipeline-config.sh

echo ""
echo "==> Prerequisites setup complete!"
echo ""
echo "The following namespaces are now configured:"
echo "  - default-tenant (created by Konflux operator)"
echo "  - managed-tenant (created by this script)"
echo ""
echo "Demo users (configured by Konflux operator):"
echo "  - user1@konflux.dev / password"
echo "  - user2@konflux.dev / password"
echo ""
echo "Next steps:"
echo "  1. Install the application: helm install festoji ./resources --set applicationName=festoji --set gitRepoUrl=https://github.com/FORK_ORG/festoji"
echo "  2. Access the UI at https://localhost:9443 and login with demo credentials"
echo "  3. Create a pull request to trigger a build"
echo ""
