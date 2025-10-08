GO_VERSION := 1.21
BINARY_NAME := convert-conforma-to-vsa
BUILD_DIR := build
TEST_DATA_DIR := testdata

.PHONY: all build test test-policy-provenance clean run-example lint

all: build test

build:
	@echo "Building $(BINARY_NAME)..."
	@mkdir -p $(BUILD_DIR)
	go build -o $(BUILD_DIR)/$(BINARY_NAME) .

test:
	@echo "Running tests..."
	go test -v -race -cover ./...

test-policy-provenance: build
	@echo "Running policy provenance tests..."
	./test-policy-provenance.sh

test-coverage:
	@echo "Running tests with coverage..."
	go test -v -race -coverprofile=coverage.out ./...
	go tool cover -html=coverage.out -o coverage.html
	@echo "Coverage report generated: coverage.html"

clean:
	@echo "Cleaning build artifacts..."
	rm -rf $(BUILD_DIR)
	rm -f coverage.out coverage.html

run-example: build
	@echo "Running example conversion..."
	./$(BUILD_DIR)/$(BINARY_NAME) \
		-input $(TEST_DATA_DIR)/conforma-success.json \
		-output $(BUILD_DIR)/vsa-output-success.json \
		-verifier-id "https://managed.konflux.example.com/conforma-vsa" \
		-verifier-version "v1.0.0"
	@echo "Success example output:"
	@cat $(BUILD_DIR)/vsa-output-success.json | jq '.'
	@echo ""
	@echo "Validating success example..."
	@./validate-vsa.sh $(BUILD_DIR)/vsa-output-success.json
	
	@echo ""
	@echo "Running failure example..."
	./$(BUILD_DIR)/$(BINARY_NAME) \
		-input $(TEST_DATA_DIR)/conforma-failure.json \
		-output $(BUILD_DIR)/vsa-output-failure.json \
		-verifier-id "https://managed.konflux.example.com/conforma-vsa" \
		-verifier-version "v1.0.0"
	@echo "Failure example output:"
	@cat $(BUILD_DIR)/vsa-output-failure.json | jq '.'
	@echo ""
	@echo "Validating failure example..."
	@./validate-vsa.sh $(BUILD_DIR)/vsa-output-failure.json

lint:
	@echo "Running linter..."
	@if command -v golangci-lint >/dev/null 2>&1; then \
		golangci-lint run; \
	else \
		echo "golangci-lint not found, running go vet and go fmt instead"; \
		go vet ./...; \
		go fmt ./...; \
	fi

benchmark:
	@echo "Running benchmarks..."
	go test -bench=. -benchmem ./...

install: build
	@echo "Installing $(BINARY_NAME) to /usr/local/bin..."
	sudo cp $(BUILD_DIR)/$(BINARY_NAME) /usr/local/bin/

help:
	@echo "Available targets:"
	@echo "  build       - Build the enhanced VSA converter with policy provenance support"
	@echo "  test        - Run unit tests"
	@echo "  test-policy-provenance - Run policy provenance feature tests"
	@echo "  test-coverage - Run tests with coverage report"
	@echo "  clean       - Remove build artifacts"
	@echo "  run-example - Build and run example conversions with validation"
	@echo "  lint        - Run linter"
	@echo "  benchmark   - Run performance benchmarks"
	@echo "  install     - Install binary to /usr/local/bin"
	@echo "  help        - Show this help message"
	@echo ""
	@echo "Policy Provenance Features:"
	@echo "  - OCI policy bundle resolution with 'oci://' URIs"
	@echo "  - Cryptographic digest pinning and validation"
	@echo "  - Complete policy metadata traceability in VSA"
	@echo "  - Backward compatibility with existing workflows"
	@echo ""
	@echo "Additional utilities:"
	@echo "  ./validate-vsa.sh <file.json> - Validate VSA file against SLSA v1.0"
	@echo "  ./test-policy-provenance.sh   - Test policy provenance features"