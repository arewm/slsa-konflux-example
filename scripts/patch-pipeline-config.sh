#!/bin/bash
set -e

echo "==> Patching build-pipeline-config to use custom SLSA pipeline"

# The operator reconciles the ConfigMap faster than we can patch it, so we
# scale down the operator, replace the ConfigMap, then scale back up.
# Workaround for https://github.com/konflux-ci/konflux-ci/issues/6673

echo "Scaling down Konflux operator..."
kubectl scale deployment konflux-operator-controller-manager -n konflux-operator --replicas=0
kubectl wait --for=jsonpath='{.status.availableReplicas}'=0 \
  deployment/konflux-operator-controller-manager -n konflux-operator --timeout=30s 2>/dev/null || sleep 3

echo "Replacing build-pipeline-config..."
kubectl delete configmap build-pipeline-config -n build-service --ignore-not-found
kubectl create -f - <<'MANIFEST'
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
      bundle: quay.io/slsa-konflux-example/pipeline-slsa-e2e-oci-ta:latest@sha256:ddb04c99c69247fc61709d76759bd16df4d8b227419acbe80cde73ad743e7bb1
MANIFEST

echo "Scaling operator back up..."
kubectl scale deployment konflux-operator-controller-manager -n konflux-operator --replicas=1

echo ""
echo "==> Successfully patched build-pipeline-config"
echo ""
echo "Verification:"
kubectl get configmap build-pipeline-config -n build-service -o jsonpath='{.data.config\.yaml}' | grep -E 'default-pipeline-name|name:'
echo ""
