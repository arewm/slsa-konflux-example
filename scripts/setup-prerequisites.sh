#!/bin/bash
set -e

echo "==> Setting up SLSA Konflux Example Prerequisites"

# Create tenant namespaces
echo "Creating tenant namespaces..."
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: slsa-e2e-tenant
  labels:
    konflux-ci.dev/type: tenant
---
apiVersion: v1
kind: Namespace
metadata:
  name: slsa-e2e-managed-tenant
  labels:
    konflux-ci.dev/type: tenant
EOF

echo "✓ Tenant namespaces created"

# Disable operator management of build-pipeline-config
echo "Configuring build-service for self-managed pipeline configuration..."
kubectl patch konflux konflux --type=merge -p '
spec:
  buildService:
    spec:
      managePipelineConfig: false
' 2>/dev/null || echo "Note: Konflux CR not found or already configured"

# Delete operator-managed ConfigMap
echo "Deleting operator-managed build-pipeline-config..."
kubectl delete configmap build-pipeline-config -n build-service --ignore-not-found=true

echo "✓ Build service configured for self-management"

# Configure demo users
echo "Configuring demo users..."
kubectl patch konfluxui konflux-ui -n konflux-ui --type=merge -p '
spec:
  dex:
    config:
      enablePasswordDB: true
      staticPasswords:
      - email: "user1@konflux.dev"
        username: "user1"
        userID: "7138d2fe-724e-4e86-af8a-db7c4b080e20"
        hash: "$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W" # gitleaks:allow
      - email: "user2@konflux.dev"
        username: "user2"
        userID: "ea8e8ee1-2283-4e03-83d4-b00f8b821b64"
        hash: "$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W" # gitleaks:allow
' 2>/dev/null || echo "Note: KonfluxUI CR not found or already configured"

echo "✓ Demo users configured"

# Install build configuration
echo "Installing build-service configuration..."
helm upgrade --install build-config ./admin \
  --set namespace=default

echo "✓ Build service configuration installed"

echo ""
echo "==> Prerequisites setup complete!"
echo ""
echo "Next steps:"
echo "  1. Install the application: helm install festoji ./resources --set ..."
echo "  2. Create a pull request to trigger a build"
echo ""
