package main

import (
	"encoding/json"
	"os"
	"testing"
)

func TestParseTime(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		wantErr  bool
		expected string
	}{
		{
			name:     "RFC3339 format",
			input:    "2024-01-15T14:30:00Z",
			wantErr:  false,
			expected: "2024-01-15T14:30:00Z",
		},
		{
			name:     "RFC3339 with timezone",
			input:    "2024-01-15T14:30:00-05:00",
			wantErr:  false,
			expected: "2024-01-15T19:30:00Z", // Converted to UTC
		},
		{
			name:     "Format without timezone",
			input:    "2024-01-15T14:30:00",
			wantErr:  false,
			expected: "2024-01-15T14:30:00Z",
		},
		{
			name:    "Invalid format",
			input:   "invalid-time",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := parseTime(tt.input)
			if tt.wantErr {
				if err == nil {
					t.Errorf("parseTime() expected error but got none")
				}
				return
			}
			if err != nil {
				t.Errorf("parseTime() unexpected error: %v", err)
				return
			}
			if result != tt.expected {
				t.Errorf("parseTime() = %v, want %v", result, tt.expected)
			}
		})
	}
}

func TestBuildSubject(t *testing.T) {
	tests := []struct {
		name            string
		component       ConformaComponent
		subjectOverride string
		wantErr         bool
		expectedName    string
		expectedDigest  string
	}{
		{
			name: "Valid container image",
			component: ConformaComponent{
				Name:           "test-app",
				ContainerImage: "quay.io/test/app@sha256:a1b2c3d4e5f6789012345678901234567890abcdef1234567890abcdef123456",
			},
			wantErr:        false,
			expectedName:   "quay.io/test/app",
			expectedDigest: "a1b2c3d4e5f6789012345678901234567890abcdef1234567890abcdef123456",
		},
		{
			name: "With subject override",
			component: ConformaComponent{
				Name:           "test-app",
				ContainerImage: "quay.io/test/app@sha256:old",
			},
			subjectOverride: "quay.io/override/app@sha256:new123456789012345678901234567890abcdef1234567890abcdef123456",
			wantErr:         false,
			expectedName:    "quay.io/override/app",
			expectedDigest:  "new123456789012345678901234567890abcdef1234567890abcdef123456",
		},
		{
			name: "Invalid image format - no digest",
			component: ConformaComponent{
				Name:           "test-app",
				ContainerImage: "quay.io/test/app:latest",
			},
			wantErr: true,
		},
		{
			name: "Invalid image format - malformed digest",
			component: ConformaComponent{
				Name:           "test-app",
				ContainerImage: "quay.io/test/app@sha256:",
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := buildSubject(tt.component, tt.subjectOverride)
			if tt.wantErr {
				if err == nil {
					t.Errorf("buildSubject() expected error but got none")
				}
				return
			}
			if err != nil {
				t.Errorf("buildSubject() unexpected error: %v", err)
				return
			}
			if result.Name != tt.expectedName {
				t.Errorf("buildSubject() name = %v, want %v", result.Name, tt.expectedName)
			}
			if result.Digest["sha256"] != tt.expectedDigest {
				t.Errorf("buildSubject() digest = %v, want %v", result.Digest["sha256"], tt.expectedDigest)
			}
		})
	}
}

func TestDetermineVerifiedLevels(t *testing.T) {
	tests := []struct {
		name     string
		input    *ConformaInput
		expected []string
	}{
		{
			name: "All successful - SLSA Build Level 3",
			input: &ConformaInput{
				Success: true,
				Components: []ConformaComponent{
					{Success: true, Violations: []ConformaViolation{}},
					{Success: true, Violations: []ConformaViolation{}},
				},
			},
			expected: []string{"SLSA_BUILD_LEVEL_3"},
		},
		{
			name: "Has violations - no levels",
			input: &ConformaInput{
				Success: true,
				Components: []ConformaComponent{
					{Success: false, Violations: []ConformaViolation{{Rule: "test", Message: "failed"}}},
				},
			},
			expected: []string{},
		},
		{
			name: "Overall failure - no levels",
			input: &ConformaInput{
				Success: false,
				Components: []ConformaComponent{
					{Success: true, Violations: []ConformaViolation{}},
				},
			},
			expected: []string{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := determineVerifiedLevels(tt.input)
			if len(result) != len(tt.expected) {
				t.Errorf("determineVerifiedLevels() length = %v, want %v", len(result), len(tt.expected))
				return
			}
			for i, level := range result {
				if level != tt.expected[i] {
					t.Errorf("determineVerifiedLevels()[%d] = %v, want %v", i, level, tt.expected[i])
				}
			}
		})
	}
}

func TestBuildPolicy(t *testing.T) {
	tests := []struct {
		name     string
		policy   ConformaPolicy
		wantErr  bool
		expected VSAPolicy
	}{
		{
			name: "OCI policy with digest",
			policy: ConformaPolicy{
				Sources: []ConformaPolicySource{
					{Policy: []string{"oci://registry.example.com/policies/enterprise-contract@sha256:abc123"}},
				},
			},
			wantErr: false,
			expected: VSAPolicy{
				URI:    "oci://registry.example.com/policies/enterprise-contract@sha256:abc123",
				Digest: map[string]string{"sha256": "abc123"},
			},
		},
		{
			name: "Git policy without digest",
			policy: ConformaPolicy{
				Sources: []ConformaPolicySource{
					{Policy: []string{"git::https://github.com/enterprise/policies.git"}},
				},
			},
			wantErr: false,
			expected: VSAPolicy{
				URI: "git::https://github.com/enterprise/policies.git",
			},
		},
		{
			name: "No policy sources",
			policy: ConformaPolicy{
				Sources: []ConformaPolicySource{},
			},
			wantErr: true,
		},
		{
			name: "Empty policy array",
			policy: ConformaPolicy{
				Sources: []ConformaPolicySource{
					{Policy: []string{}},
				},
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := buildPolicy(tt.policy)
			if tt.wantErr {
				if err == nil {
					t.Errorf("buildPolicy() expected error but got none")
				}
				return
			}
			if err != nil {
				t.Errorf("buildPolicy() unexpected error: %v", err)
				return
			}
			if result.URI != tt.expected.URI {
				t.Errorf("buildPolicy() URI = %v, want %v", result.URI, tt.expected.URI)
			}
			if len(result.Digest) != len(tt.expected.Digest) {
				t.Errorf("buildPolicy() digest length = %v, want %v", len(result.Digest), len(tt.expected.Digest))
			}
			for k, v := range tt.expected.Digest {
				if result.Digest[k] != v {
					t.Errorf("buildPolicy() digest[%s] = %v, want %v", k, result.Digest[k], v)
				}
			}
		})
	}
}

func TestValidateConformaInput(t *testing.T) {
	tests := []struct {
		name    string
		input   *ConformaInput
		wantErr bool
		errMsg  string
	}{
		{
			name: "Valid input",
			input: &ConformaInput{
				EffectiveTime: "2024-01-15T14:30:00Z",
				Components: []ConformaComponent{
					{
						Name:           "test-app",
						ContainerImage: "quay.io/test/app@sha256:abc123",
					},
				},
			},
			wantErr: false,
		},
		{
			name: "Missing effective time",
			input: &ConformaInput{
				Components: []ConformaComponent{
					{Name: "test-app", ContainerImage: "quay.io/test/app@sha256:abc123"},
				},
			},
			wantErr: true,
			errMsg:  "effective-time is required",
		},
		{
			name: "No components",
			input: &ConformaInput{
				EffectiveTime: "2024-01-15T14:30:00Z",
				Components:    []ConformaComponent{},
			},
			wantErr: true,
			errMsg:  "at least one component is required",
		},
		{
			name: "Component missing name",
			input: &ConformaInput{
				EffectiveTime: "2024-01-15T14:30:00Z",
				Components: []ConformaComponent{
					{ContainerImage: "quay.io/test/app@sha256:abc123"},
				},
			},
			wantErr: true,
			errMsg:  "component[0]: name is required",
		},
		{
			name: "Component missing container image",
			input: &ConformaInput{
				EffectiveTime: "2024-01-15T14:30:00Z",
				Components: []ConformaComponent{
					{Name: "test-app"},
				},
			},
			wantErr: true,
			errMsg:  "component[0]: containerImage is required",
		},
		{
			name: "Component missing sha256 digest",
			input: &ConformaInput{
				EffectiveTime: "2024-01-15T14:30:00Z",
				Components: []ConformaComponent{
					{Name: "test-app", ContainerImage: "quay.io/test/app:latest"},
				},
			},
			wantErr: true,
			errMsg:  "component[0]: containerImage must include sha256 digest",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateConformaInput(tt.input)
			if tt.wantErr {
				if err == nil {
					t.Errorf("validateConformaInput() expected error but got none")
					return
				}
				if tt.errMsg != "" && err.Error() != tt.errMsg {
					t.Errorf("validateConformaInput() error = %v, want %v", err.Error(), tt.errMsg)
				}
				return
			}
			if err != nil {
				t.Errorf("validateConformaInput() unexpected error: %v", err)
			}
		})
	}
}

func TestValidateVSAOutput(t *testing.T) {
	// Helper function to create a deep copy of VSA for modifications
	createValidVSA := func() *VSAStatement {
		return &VSAStatement{
			Type:          "https://in-toto.io/Statement/v1",
			PredicateType: "https://slsa.dev/verification_summary/v1",
			Subject: []VSASubject{
				{
					Name:   "quay.io/test/app",
					Digest: map[string]string{"sha256": "abc123"},
				},
			},
			Predicate: VSAPredicate{
				Verifier:           VSAVerifier{ID: "test-verifier"},
				TimeVerified:       "2024-01-15T14:30:00Z",
				ResourceURI:        "quay.io/test/app@sha256:abc123",
				Policy:             VSAPolicy{URI: "oci://example.com/policy"},
				VerificationResult: "PASSED",
			},
		}
	}

	tests := []struct {
		name    string
		vsa     *VSAStatement
		wantErr bool
		errMsg  string
	}{
		{
			name:    "Valid VSA",
			vsa:     createValidVSA(),
			wantErr: false,
		},
		{
			name: "Invalid statement type",
			vsa: func() *VSAStatement {
				v := createValidVSA()
				v.Type = "invalid-type"
				return v
			}(),
			wantErr: true,
			errMsg:  "invalid statement type: invalid-type",
		},
		{
			name: "Invalid predicate type",
			vsa: func() *VSAStatement {
				v := createValidVSA()
				v.PredicateType = "invalid-predicate"
				return v
			}(),
			wantErr: true,
			errMsg:  "invalid predicate type: invalid-predicate",
		},
		{
			name: "No subjects",
			vsa: func() *VSAStatement {
				v := createValidVSA()
				v.Subject = []VSASubject{}
				return v
			}(),
			wantErr: true,
			errMsg:  "at least one subject is required",
		},
		{
			name: "Subject missing name",
			vsa: func() *VSAStatement {
				v := createValidVSA()
				v.Subject[0].Name = ""
				return v
			}(),
			wantErr: true,
			errMsg:  "subject[0]: name is required",
		},
		{
			name: "Subject missing digest",
			vsa: func() *VSAStatement {
				v := createValidVSA()
				v.Subject[0].Digest = map[string]string{}
				return v
			}(),
			wantErr: true,
			errMsg:  "subject[0]: digest is required",
		},
		{
			name: "Subject missing sha256 digest",
			vsa: func() *VSAStatement {
				v := createValidVSA()
				v.Subject[0].Digest = map[string]string{"md5": "abc123"}
				return v
			}(),
			wantErr: true,
			errMsg:  "subject[0]: sha256 digest is required",
		},
		{
			name: "Missing verifier ID",
			vsa: func() *VSAStatement {
				v := createValidVSA()
				v.Predicate.Verifier.ID = ""
				return v
			}(),
			wantErr: true,
			errMsg:  "verifier ID is required",
		},
		{
			name: "Missing time verified",
			vsa: func() *VSAStatement {
				v := createValidVSA()
				v.Predicate.TimeVerified = ""
				return v
			}(),
			wantErr: true,
			errMsg:  "timeVerified is required",
		},
		{
			name: "Missing resource URI",
			vsa: func() *VSAStatement {
				v := createValidVSA()
				v.Predicate.ResourceURI = ""
				return v
			}(),
			wantErr: true,
			errMsg:  "resourceUri is required",
		},
		{
			name: "Missing policy URI",
			vsa: func() *VSAStatement {
				v := createValidVSA()
				v.Predicate.Policy.URI = ""
				return v
			}(),
			wantErr: true,
			errMsg:  "policy URI is required",
		},
		{
			name: "Invalid verification result",
			vsa: func() *VSAStatement {
				v := createValidVSA()
				v.Predicate.VerificationResult = "INVALID"
				return v
			}(),
			wantErr: true,
			errMsg:  "invalid verification result: INVALID",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateVSAOutput(tt.vsa)
			if tt.wantErr {
				if err == nil {
					t.Errorf("validateVSAOutput() expected error but got none")
					return
				}
				if tt.errMsg != "" && err.Error() != tt.errMsg {
					t.Errorf("validateVSAOutput() error = %v, want %v", err.Error(), tt.errMsg)
				}
				return
			}
			if err != nil {
				t.Errorf("validateVSAOutput() unexpected error: %v", err)
			}
		})
	}
}

func TestConvertToVSA(t *testing.T) {
	config := ConversionConfig{
		VerifierID:      "https://test.example.com/verifier",
		VerifierVersion: "v1.0.0",
	}

	tests := []struct {
		name    string
		input   *ConformaInput
		wantErr bool
	}{
		{
			name: "Successful conversion",
			input: &ConformaInput{
				Success:       true,
				EffectiveTime: "2024-01-15T14:30:00Z",
				ECVersion:     "v0.3.0",
				Components: []ConformaComponent{
					{
						Name:           "test-app",
						ContainerImage: "quay.io/test/app@sha256:a1b2c3d4e5f6789012345678901234567890abcdef1234567890abcdef123456",
						Success:        true,
					},
				},
				Policy: ConformaPolicy{
					Sources: []ConformaPolicySource{
						{Policy: []string{"oci://registry.example.com/policies/enterprise-contract:v1.0"}},
					},
				},
			},
			wantErr: false,
		},
		{
			name: "Failed conversion due to invalid time",
			input: &ConformaInput{
				Success:       true,
				EffectiveTime: "invalid-time-format",
				Components: []ConformaComponent{
					{
						Name:           "test-app",
						ContainerImage: "quay.io/test/app@sha256:abc123",
						Success:        true,
					},
				},
				Policy: ConformaPolicy{
					Sources: []ConformaPolicySource{
						{Policy: []string{"oci://example.com/policy"}},
					},
				},
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := convertToVSA(tt.input, config)
			if tt.wantErr {
				if err == nil {
					t.Errorf("convertToVSA() expected error but got none")
				}
				return
			}
			if err != nil {
				t.Errorf("convertToVSA() unexpected error: %v", err)
				return
			}

			// Validate basic structure
			if result.Type != "https://in-toto.io/Statement/v1" {
				t.Errorf("convertToVSA() Type = %v, want %v", result.Type, "https://in-toto.io/Statement/v1")
			}
			if result.PredicateType != "https://slsa.dev/verification_summary/v1" {
				t.Errorf("convertToVSA() PredicateType = %v, want %v", result.PredicateType, "https://slsa.dev/verification_summary/v1")
			}
			if len(result.Subject) != len(tt.input.Components) {
				t.Errorf("convertToVSA() subject count = %v, want %v", len(result.Subject), len(tt.input.Components))
			}

			// Validate verification result mapping
			expectedResult := "PASSED"
			if !tt.input.Success {
				expectedResult = "FAILED"
			}
			if result.Predicate.VerificationResult != expectedResult {
				t.Errorf("convertToVSA() VerificationResult = %v, want %v", result.Predicate.VerificationResult, expectedResult)
			}
		})
	}
}

// Integration test with sample files
func TestFullConversion(t *testing.T) {
	// Create sample Conforma input
	conformaInput := ConformaInput{
		Success:       true,
		EffectiveTime: "2024-01-15T14:30:00Z",
		ECVersion:     "v0.3.0",
		Components: []ConformaComponent{
			{
				Name:           "test-app",
				ContainerImage: "quay.io/test/app@sha256:a1b2c3d4e5f6789012345678901234567890abcdef1234567890abcdef123456",
				Success:        true,
				Source: ConformaSource{
					Git: &ConformaGitSource{
						URL:      "https://github.com/example/test-app",
						Revision: "abc123def456",
					},
				},
				Attestations: []ConformaAttestation{
					{
						Type:          "https://in-toto.io/Statement/v0.1",
						PredicateType: "https://slsa.dev/provenance/v0.2",
					},
				},
			},
		},
		Policy: ConformaPolicy{
			Sources: []ConformaPolicySource{
				{Policy: []string{"oci://registry.example.com/policies/enterprise-contract@sha256:def456"}},
			},
		},
	}

	// Create temporary input file
	inputFile, err := os.CreateTemp("", "conforma-input-*.json")
	if err != nil {
		t.Fatalf("Failed to create temp input file: %v", err)
	}
	defer os.Remove(inputFile.Name())

	inputData, err := json.Marshal(conformaInput)
	if err != nil {
		t.Fatalf("Failed to marshal input: %v", err)
	}

	if _, err := inputFile.Write(inputData); err != nil {
		t.Fatalf("Failed to write input file: %v", err)
	}
	inputFile.Close()

	// Create temporary output file
	outputFile, err := os.CreateTemp("", "vsa-output-*.json")
	if err != nil {
		t.Fatalf("Failed to create temp output file: %v", err)
	}
	defer os.Remove(outputFile.Name())
	outputFile.Close()

	// Run conversion
	config := ConversionConfig{
		InputFile:       inputFile.Name(),
		OutputFile:      outputFile.Name(),
		VerifierID:      "https://test.example.com/verifier",
		VerifierVersion: "v1.0.0",
	}

	err = convertConformaToVSA(config)
	if err != nil {
		t.Fatalf("convertConformaToVSA() failed: %v", err)
	}

	// Read and validate output
	outputData, err := os.ReadFile(outputFile.Name())
	if err != nil {
		t.Fatalf("Failed to read output file: %v", err)
	}

	var vsa VSAStatement
	if err := json.Unmarshal(outputData, &vsa); err != nil {
		t.Fatalf("Failed to unmarshal VSA output: %v", err)
	}

	// Validate key fields
	if vsa.Predicate.VerificationResult != "PASSED" {
		t.Errorf("Expected PASSED result, got %v", vsa.Predicate.VerificationResult)
	}

	if len(vsa.Subject) != 1 {
		t.Errorf("Expected 1 subject, got %v", len(vsa.Subject))
	}

	if vsa.Subject[0].Name != "quay.io/test/app" {
		t.Errorf("Expected subject name 'quay.io/test/app', got %v", vsa.Subject[0].Name)
	}

	if len(vsa.Predicate.VerifiedLevels) == 0 {
		t.Errorf("Expected verified levels, got empty array")
	}

	if vsa.Predicate.Verifier.Version != "v0.3.0" {
		t.Errorf("Expected verifier version 'v0.3.0', got %v", vsa.Predicate.Verifier.Version)
	}
}