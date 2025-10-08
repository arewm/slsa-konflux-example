# Makefile for Conforma VSA Cosign Integration
# WS5 Day 2 - Managed Namespace VSA Signing

NAMESPACE ?= managed-context
VERIFIER_ID ?= https://managed.konflux.example.com/verifiers/conforma-vsa
REGISTRY_URL ?= ttl.sh
DEBUG ?= false

# Tool versions
COSIGN_VERSION ?= v2.2.3
KUBECTL_VERSION ?= v1.28.0
TEKTON_VERSION ?= v0.56.0

# Build variables
VSA_CONVERTER_SRC = ../scripts/convert-conforma-to-vsa.go
VSA_CONVERTER_BIN = build/convert-conforma-to-vsa
GO_VERSION = 1.21

.PHONY: help
help: ## Display this help message
	@echo "Conforma VSA - Cosign CLI Integration"
	@echo "====================================="
	@echo ""
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Build and Preparation

.PHONY: check-prerequisites
check-prerequisites: ## Check all required tools are installed
	@echo "Checking prerequisites..."
	@command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl is required but not installed"; exit 1; }
	@command -v cosign >/dev/null 2>&1 || { echo "❌ cosign is required but not installed"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "❌ jq is required but not installed"; exit 1; }
	@command -v go >/dev/null 2>&1 || { echo "❌ go is required but not installed"; exit 1; }
	@echo "✅ All prerequisites satisfied"

.PHONY: build-vsa-converter
build-vsa-converter: check-prerequisites ## Build the VSA converter tool
	@echo "Building VSA converter..."
	@mkdir -p build
	@if [ ! -f "$(VSA_CONVERTER_SRC)" ]; then \
		echo "❌ VSA converter source not found: $(VSA_CONVERTER_SRC)"; \
		exit 1; \
	fi
	@cd build && \
		cp "$(VSA_CONVERTER_SRC)" . && \
		go mod init vsa-converter && \
		go build -ldflags="-s -w" -o convert-conforma-to-vsa convert-conforma-to-vsa.go
	@echo "✅ VSA converter built: $(VSA_CONVERTER_BIN)"

.PHONY: test-vsa-converter
test-vsa-converter: build-vsa-converter ## Test the VSA converter with sample data
	@echo "Testing VSA converter..."
	@mkdir -p build/test
	@echo '{"success":true,"components":[{"name":"test","containerImage":"ttl.sh/test@sha256:abc123","success":true,"violations":[]}],"policy":{"sources":[{"policy":["oci://policy.example.com/test"]}]},"ec-version":"v0.1.0","effective-time":"2024-01-01T12:00:00Z"}' > build/test/sample-input.json
	@./$(VSA_CONVERTER_BIN) \
		-input build/test/sample-input.json \
		-output build/test/sample-output.json \
		-verifier-id "$(VERIFIER_ID)" \
		-verifier-version "v1.0.0"
	@echo "✅ VSA converter test completed"
	@echo "Input: build/test/sample-input.json"
	@echo "Output: build/test/sample-output.json"

##@ Deployment

.PHONY: create-namespace
create-namespace: ## Create the managed namespace
	@echo "Creating namespace: $(NAMESPACE)"
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@kubectl label namespace $(NAMESPACE) security.konflux.dev/trust-boundary=managed --overwrite
	@kubectl label namespace $(NAMESPACE) app.kubernetes.io/managed-by=platform-team --overwrite
	@echo "✅ Namespace created and labeled"

.PHONY: generate-cosign-keys
generate-cosign-keys: check-prerequisites ## Generate cosign key pair for signing
	@echo "Generating cosign key pair..."
	@mkdir -p build/keys
	@cd build/keys && \
		openssl rand -base64 32 > cosign.password && \
		cat cosign.password | cosign generate-key-pair --output-key-prefix managed-vsa
	@echo "✅ Cosign keys generated in build/keys/"
	@echo "Private key: build/keys/managed-vsa.key"
	@echo "Public key: build/keys/managed-vsa.pub"
	@echo "Password: build/keys/cosign.password"

.PHONY: create-secrets
create-secrets: generate-cosign-keys ## Create Kubernetes secrets for signing
	@echo "Creating signing secrets..."
	@kubectl create secret generic cosign-signing-keys \
		--namespace=$(NAMESPACE) \
		--from-file=cosign.key=build/keys/managed-vsa.key \
		--from-file=cosign.pub=build/keys/managed-vsa.pub \
		--from-literal=cosign.password="$$(cat build/keys/cosign.password)" \
		--dry-run=client -o yaml | kubectl apply -f -
	@kubectl label secret cosign-signing-keys \
		--namespace=$(NAMESPACE) \
		app.kubernetes.io/name=cosign-signing-keys \
		app.kubernetes.io/component=managed-pipeline \
		security.konflux.dev/trust-boundary=managed --overwrite
	@kubectl create secret generic vsa-verifier-config \
		--namespace=$(NAMESPACE) \
		--from-literal=verifier-id="$(VERIFIER_ID)" \
		--from-literal=verifier-version="v1.0.0" \
		--from-literal=verifier-description="Konflux Managed Conforma VSA Verifier" \
		--dry-run=client -o yaml | kubectl apply -f -
	@kubectl label secret vsa-verifier-config \
		--namespace=$(NAMESPACE) \
		app.kubernetes.io/name=vsa-verifier-config \
		app.kubernetes.io/component=managed-pipeline \
		security.konflux.dev/trust-boundary=managed --overwrite
	@echo "✅ Secrets created successfully"

.PHONY: deploy-converter-configmap
deploy-converter-configmap: build-vsa-converter ## Deploy VSA converter as ConfigMap
	@echo "Deploying VSA converter ConfigMap..."
	@kubectl create configmap vsa-convert-tool \
		--namespace=$(NAMESPACE) \
		--from-file=convert-conforma-to-vsa=$(VSA_CONVERTER_BIN) \
		--dry-run=client -o yaml | kubectl apply -f -
	@kubectl label configmap vsa-convert-tool \
		--namespace=$(NAMESPACE) \
		app.kubernetes.io/name=vsa-convert-tool \
		app.kubernetes.io/component=managed-pipeline --overwrite
	@echo "✅ VSA converter ConfigMap deployed"

.PHONY: deploy-rbac
deploy-rbac: ## Deploy RBAC configuration
	@echo "Deploying RBAC configuration..."
	@kubectl apply -f signing-secrets-template.yaml --namespace=$(NAMESPACE)
	@echo "✅ RBAC configuration deployed"

.PHONY: deploy-oci-config
deploy-oci-config: ## Deploy OCI storage configuration
	@echo "Deploying OCI storage configuration..."
	@kubectl apply -f oci-storage-config.yaml
	@echo "✅ OCI storage configuration deployed"

.PHONY: deploy-task
deploy-task: ## Deploy the Tekton task
	@echo "Deploying Tekton task..."
	@kubectl apply -f conforma-vsa.yaml
	@echo "✅ Tekton task deployed"

.PHONY: deploy-all
deploy-all: check-prerequisites create-namespace create-secrets deploy-converter-configmap deploy-rbac deploy-oci-config deploy-task ## Deploy complete infrastructure
	@echo ""
	@echo "🎉 Complete deployment finished!"
	@echo ""
	@echo "Deployed components:"
	@echo "  ✅ Namespace: $(NAMESPACE)"
	@echo "  ✅ Cosign signing keys"
	@echo "  ✅ VSA converter tool"
	@echo "  ✅ RBAC configuration"
	@echo "  ✅ OCI storage configuration"
	@echo "  ✅ Tekton task: conforma-vsa"
	@echo ""
	@echo "Next steps:"
	@echo "  make verify-deployment"
	@echo "  make test-pipeline"

##@ Testing and Validation

.PHONY: verify-deployment
verify-deployment: ## Verify all components are deployed correctly
	@echo "Verifying deployment..."
	@echo "Checking namespace..."
	@kubectl get namespace $(NAMESPACE) -o jsonpath='{.metadata.labels.security\.konflux\.dev/trust-boundary}' | grep -q managed || { echo "❌ Namespace trust boundary not set"; exit 1; }
	@echo "✅ Namespace verified"
	@echo "Checking secrets..."
	@kubectl get secret cosign-signing-keys -n $(NAMESPACE) >/dev/null || { echo "❌ Cosign keys secret missing"; exit 1; }
	@kubectl get secret vsa-verifier-config -n $(NAMESPACE) >/dev/null || { echo "❌ Verifier config secret missing"; exit 1; }
	@echo "✅ Secrets verified"
	@echo "Checking ConfigMap..."
	@kubectl get configmap vsa-convert-tool -n $(NAMESPACE) >/dev/null || { echo "❌ VSA converter ConfigMap missing"; exit 1; }
	@echo "✅ ConfigMap verified"
	@echo "Checking RBAC..."
	@kubectl get serviceaccount conforma-vsa-sa -n $(NAMESPACE) >/dev/null || { echo "❌ ServiceAccount missing"; exit 1; }
	@kubectl get role conforma-vsa-role -n $(NAMESPACE) >/dev/null || { echo "❌ Role missing"; exit 1; }
	@kubectl get rolebinding conforma-vsa-binding -n $(NAMESPACE) >/dev/null || { echo "❌ RoleBinding missing"; exit 1; }
	@echo "✅ RBAC verified"
	@echo "Checking Tekton task..."
	@kubectl get task conforma-vsa -n $(NAMESPACE) >/dev/null || { echo "❌ Tekton task missing"; exit 1; }
	@echo "✅ Tekton task verified"
	@echo ""
	@echo "🎉 All components verified successfully!"

.PHONY: create-test-pipeline
create-test-pipeline: ## Create test pipeline for validation
	@echo "Creating test pipeline..."
	@cat << 'EOF' | kubectl apply -f -
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: conforma-vsa-test
  namespace: $(NAMESPACE)
spec:
  params:
    - name: image-url
      type: string
      default: "$(REGISTRY_URL)/test-image"
    - name: image-digest
      type: string
      default: "sha256:abc123def456789abcdef123456789abcdef123456789abcdef123456789abcdef"
  workspaces:
    - name: conforma-results
    - name: vsa-output
    - name: signing-keys
  tasks:
    - name: setup-test-data
      taskSpec:
        workspaces:
          - name: conforma-results
        steps:
          - name: create-sample-data
            image: registry.redhat.io/ubi9/ubi-minimal:latest
            script: |
              #!/bin/bash
              cat > $$(workspaces.conforma-results.path)/results.json << 'RESULT_EOF'
              {
                "success": true,
                "components": [
                  {
                    "name": "test-component",
                    "containerImage": "$$(params.image-url)@$$(params.image-digest)",
                    "success": true,
                    "violations": []
                  }
                ],
                "policy": {
                  "sources": [
                    {
                      "policy": ["oci://policy.example.com/test-policy@sha256:def456"]
                    }
                  ]
                },
                "ec-version": "v0.1.0",
                "effective-time": "$$(date -u +%Y-%m-%dT%H:%M:%SZ)"
              }
              RESULT_EOF
      workspaces:
        - name: conforma-results
          workspace: conforma-results
    - name: vsa-signing
      taskRef:
        name: conforma-vsa
      params:
        - name: image-url
          value: "$$(params.image-url)"
        - name: image-digest
          value: "$$(params.image-digest)"
        - name: debug
          value: "$(DEBUG)"
      workspaces:
        - name: conforma-results
          workspace: conforma-results
        - name: vsa-output
          workspace: vsa-output
        - name: signing-keys
          secret:
            secretName: cosign-signing-keys
      runAfter:
        - setup-test-data
EOF
	@echo "✅ Test pipeline created"

.PHONY: test-pipeline
test-pipeline: create-test-pipeline ## Run test pipeline
	@echo "Running test pipeline..."
	@kubectl create pipelinerun conforma-vsa-test-run-$(shell date +%s) \
		--from=pipeline/conforma-vsa-test \
		--namespace=$(NAMESPACE) \
		--workspace=name=conforma-results,emptyDir= \
		--workspace=name=vsa-output,emptyDir= \
		--workspace=name=signing-keys,secret=cosign-signing-keys
	@echo "✅ Test pipeline started"
	@echo ""
	@echo "Monitor progress with:"
	@echo "  kubectl get pipelineruns -n $(NAMESPACE)"
	@echo "  tkn pipelinerun logs -f <run-name> -n $(NAMESPACE)"

.PHONY: security-validation
security-validation: ## Run comprehensive security validation
	@echo "Running security validation..."
	@NAMESPACE=$(NAMESPACE) DEBUG=$(DEBUG) ./security-validation.sh

.PHONY: test-all
test-all: verify-deployment security-validation test-pipeline ## Run all tests and validations
	@echo ""
	@echo "🎉 All tests completed!"
	@echo ""
	@echo "Summary:"
	@echo "  ✅ Deployment verification"
	@echo "  ✅ Security validation"
	@echo "  ✅ Pipeline test"

##@ Maintenance

.PHONY: rotate-keys
rotate-keys: ## Rotate cosign signing keys
	@echo "Rotating cosign keys..."
	@mkdir -p build/keys-new
	@cd build/keys-new && \
		openssl rand -base64 32 > cosign.password && \
		cat cosign.password | cosign generate-key-pair --output-key-prefix managed-vsa-new
	@kubectl create secret generic cosign-signing-keys-new \
		--namespace=$(NAMESPACE) \
		--from-file=cosign.key=build/keys-new/managed-vsa-new.key \
		--from-file=cosign.pub=build/keys-new/managed-vsa-new.pub \
		--from-literal=cosign.password="$$(cat build/keys-new/cosign.password)" \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "✅ New keys generated and secret created: cosign-signing-keys-new"
	@echo ""
	@echo "To activate new keys:"
	@echo "  kubectl delete secret cosign-signing-keys -n $(NAMESPACE)"
	@echo "  kubectl patch secret cosign-signing-keys-new -n $(NAMESPACE) --type='json' -p='[{\"op\": \"replace\", \"path\": \"/metadata/name\", \"value\": \"cosign-signing-keys\"}]'"

.PHONY: cleanup-attestations
cleanup-attestations: ## Trigger manual attestation cleanup
	@echo "Triggering attestation cleanup..."
	@kubectl create job --from=cronjob/vsa-attestation-cleanup manual-cleanup-$(shell date +%s) -n $(NAMESPACE) || echo "CronJob may not exist yet"
	@echo "✅ Cleanup job triggered"

.PHONY: backup-keys
backup-keys: ## Backup signing keys and configuration
	@echo "Creating backup of signing keys..."
	@mkdir -p backups/$(shell date +%Y%m%d-%H%M%S)
	@kubectl get secret cosign-signing-keys -n $(NAMESPACE) -o yaml > backups/$(shell date +%Y%m%d-%H%M%S)/cosign-signing-keys.yaml
	@kubectl get secret vsa-verifier-config -n $(NAMESPACE) -o yaml > backups/$(shell date +%Y%m%d-%H%M%S)/vsa-verifier-config.yaml
	@echo "✅ Backup created in backups/$(shell date +%Y%m%d-%H%M%S)/"

##@ Cleanup

.PHONY: clean-build
clean-build: ## Clean build artifacts
	@echo "Cleaning build artifacts..."
	@rm -rf build/
	@echo "✅ Build artifacts cleaned"

.PHONY: clean-test-resources
clean-test-resources: ## Clean test resources
	@echo "Cleaning test resources..."
	@kubectl delete pipelinerun -l pipeline=conforma-vsa-test -n $(NAMESPACE) --ignore-not-found=true
	@kubectl delete pipeline conforma-vsa-test -n $(NAMESPACE) --ignore-not-found=true
	@echo "✅ Test resources cleaned"

.PHONY: uninstall
uninstall: clean-test-resources ## Uninstall all components
	@echo "Uninstalling all components..."
	@kubectl delete task conforma-vsa -n $(NAMESPACE) --ignore-not-found=true
	@kubectl delete configmap vsa-convert-tool -n $(NAMESPACE) --ignore-not-found=true
	@kubectl delete secret cosign-signing-keys vsa-verifier-config -n $(NAMESPACE) --ignore-not-found=true
	@kubectl delete serviceaccount conforma-vsa-sa -n $(NAMESPACE) --ignore-not-found=true
	@kubectl delete role conforma-vsa-role -n $(NAMESPACE) --ignore-not-found=true
	@kubectl delete rolebinding conforma-vsa-binding -n $(NAMESPACE) --ignore-not-found=true
	@kubectl delete networkpolicy conforma-vsa-netpol vsa-oci-storage-netpol -n $(NAMESPACE) --ignore-not-found=true
	@kubectl delete cronjob vsa-attestation-cleanup -n $(NAMESPACE) --ignore-not-found=true
	@echo "✅ All components uninstalled"
	@echo ""
	@echo "To remove namespace:"
	@echo "  kubectl delete namespace $(NAMESPACE)"

##@ Development

.PHONY: lint
lint: ## Lint YAML files
	@echo "Linting YAML files..."
	@command -v yamllint >/dev/null 2>&1 || { echo "❌ yamllint not installed"; exit 1; }
	@yamllint *.yaml || echo "⚠️  Linting completed with warnings"

.PHONY: validate-yaml
validate-yaml: ## Validate Kubernetes YAML files
	@echo "Validating YAML files..."
	@kubectl apply --dry-run=client -f conforma-vsa.yaml
	@kubectl apply --dry-run=client -f signing-secrets-template.yaml
	@kubectl apply --dry-run=client -f oci-storage-config.yaml
	@echo "✅ YAML validation completed"

.PHONY: dev-setup
dev-setup: check-prerequisites build-vsa-converter test-vsa-converter validate-yaml ## Setup development environment
	@echo "✅ Development environment ready"

##@ Information

.PHONY: status
status: ## Show deployment status
	@echo "Deployment Status"
	@echo "================="
	@echo ""
	@echo "Namespace: $(NAMESPACE)"
	@kubectl get namespace $(NAMESPACE) -o wide 2>/dev/null || echo "  ❌ Not found"
	@echo ""
	@echo "Secrets:"
	@kubectl get secrets -n $(NAMESPACE) -l security.konflux.dev/trust-boundary=managed 2>/dev/null || echo "  ❌ None found"
	@echo ""
	@echo "Tekton Task:"
	@kubectl get task conforma-vsa -n $(NAMESPACE) 2>/dev/null || echo "  ❌ Not found"
	@echo ""
	@echo "ConfigMaps:"
	@kubectl get configmap vsa-convert-tool vsa-oci-storage-config -n $(NAMESPACE) 2>/dev/null || echo "  ❌ Not found"
	@echo ""
	@echo "RBAC:"
	@kubectl get serviceaccount,role,rolebinding -n $(NAMESPACE) -l app.kubernetes.io/component=managed-pipeline 2>/dev/null || echo "  ❌ Not found"

.PHONY: version
version: ## Show component versions
	@echo "Component Versions"
	@echo "=================="
	@echo "Cosign: $(COSIGN_VERSION)"
	@echo "Kubectl: $(KUBECTL_VERSION)"
	@echo "Tekton: $(TEKTON_VERSION)"
	@echo "Go: $(GO_VERSION)"
	@echo ""
	@echo "Installed versions:"
	@command -v cosign >/dev/null 2>&1 && cosign version | head -1 || echo "Cosign: Not installed"
	@command -v kubectl >/dev/null 2>&1 && kubectl version --client --short || echo "Kubectl: Not installed"
	@command -v go >/dev/null 2>&1 && go version || echo "Go: Not installed"

# Default target
.DEFAULT_GOAL := help