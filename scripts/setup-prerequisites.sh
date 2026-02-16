#!/bin/bash
set -e

echo "==> Setting up SLSA Konflux Example Prerequisites"
echo ""
echo "Note: This script assumes the Konflux operator is already deployed"
echo "and has created the 'default-tenant' namespace with demo users."
echo ""

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

echo "✓ Managed tenant namespace created"

# Apply custom pipeline configuration
echo "Applying custom SLSA pipeline configuration..."
kubectl apply -f admin/build-pipeline-config.yaml

echo "✓ Custom pipeline configuration applied"
echo ""
echo "NOTE: This ConfigMap adds the custom SLSA pipeline (slsa-e2e-oci-ta) to the"
echo "standard Konflux pipelines. The script is idempotent and safe to re-run."

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
echo "  1. Install the application: helm install festoji ./resources --set applicationName=festoji --set gitRepoUrl=https://github.com/YOUR_ORG/festoji"
echo "  2. Access the UI at https://localhost:9443 and login with demo credentials"
echo "  3. Create a pull request to trigger a build"
echo ""
