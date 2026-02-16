#!/bin/bash
set -e

echo "==> Patching build-pipeline-config to use only custom SLSA pipeline"

# Patch the ConfigMap data to replace all pipelines with just slsa-e2e-oci-ta
# Using --field-manager to take ownership away from the operator
kubectl patch configmap build-pipeline-config -n build-service \
  --type=merge \
  --field-manager=slsa-example-manager \
  --patch '
apiVersion: v1
kind: ConfigMap
metadata:
  name: build-pipeline-config
  namespace: build-service
data:
  config.yaml: |
    default-pipeline-name: slsa-e2e-oci-ta
    pipelines:
    - name: slsa-e2e-oci-ta
      bundle: quay.io/arewm/pipeline-slsa-e2e-oci-ta:latest
'

# # Remove owner references to prevent operator reconciliation
# echo "Removing owner references..."
# kubectl patch configmap build-pipeline-config -n build-service \
#   --type=json \
#   -p='[{"op": "remove", "path": "/metadata/ownerReferences"}]' 2>/dev/null || echo "No owner references to remove"

# # Remove the konflux owner label that triggers reconciliation
# echo "Removing owner label..."
# kubectl label configmap build-pipeline-config -n build-service \
#   konflux.konflux-ci.dev/owner- 2>/dev/null || echo "No owner label to remove"

echo ""
echo "==> Successfully patched build-pipeline-config"
echo ""
echo "Verification:"
kubectl get configmap build-pipeline-config -n build-service -o jsonpath='{.data.config\.yaml}' | grep -E 'default-pipeline-name|name:'
echo ""
