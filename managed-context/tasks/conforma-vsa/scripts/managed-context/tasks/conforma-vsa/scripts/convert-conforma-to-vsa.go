package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"time"
)

// ConformaInput represents the structure of Conforma policy evaluation output
type ConformaInput struct {
	Success        bool                    `json:"success"`
	Components     []ConformaComponent     `json:"components"`
	Key            string                  `json:"key,omitempty"`
	Policy         ConformaPolicy          `json:"policy"`
	ECVersion      string                  `json:"ec-version"`
	EffectiveTime  string                  `json:"effective-time"`
}

type ConformaComponent struct {
	Name            string                `json:"name"`
	ContainerImage  string                `json:"containerImage"`
	Source          ConformaSource        `json:"source,omitempty"`
	Success         bool                  `json:"success"`
	Signatures      []ConformaSignature   `json:"signatures,omitempty"`
	Attestations    []ConformaAttestation `json:"attestations,omitempty"`
	Violations      []ConformaViolation   `json:"violations,omitempty"`
}

type ConformaSource struct {
	Git *ConformaGitSource `json:"git,omitempty"`
}

type ConformaGitSource struct {
	URL      string `json:"url"`
	Revision string `json:"revision"`
}

type ConformaSignature struct {
	KeyID string `json:"keyid"`
	Sig   string `json:"sig"`
}

type ConformaAttestation struct {
	Type          string `json:"type"`
	PredicateType string `json:"predicateType"`
}

type ConformaViolation struct {
	Rule    string `json:"rule"`
	Message string `json:"message"`
}

type ConformaPolicy struct {
	Sources   []ConformaPolicySource `json:"sources"`
	RekorURL  string                 `json:"rekorUrl,omitempty"`
	PublicKey string                 `json:"publicKey,omitempty"`
}

type ConformaPolicySource struct {
	Policy []string `json:"policy"`
}

// VSA structures following SLSA VSA v1.0 specification
type VSAStatement struct {
	Type          string       `json:"_type"`
	Subject       []VSASubject `json:"subject"`
	PredicateType string       `json:"predicateType"`
	Predicate     VSAPredicate `json:"predicate"`
}

type VSASubject struct {
	Name   string            `json:"name"`
	Digest map[string]string `json:"digest"`
}

type VSAPredicate struct {
	Verifier           VSAVerifier         `json:"verifier"`
	TimeVerified       string              `json:"timeVerified"`
	ResourceURI        string              `json:"resourceUri"`
	Policy             VSAPolicy           `json:"policy"`
	InputAttestations  []VSAAttestation    `json:"inputAttestations,omitempty"`
	VerificationResult string              `json:"verificationResult"`
	VerifiedLevels     []string            `json:"verifiedLevels"`
	DependencyLevels   map[string]string   `json:"dependencyLevels,omitempty"`
}

type VSAVerifier struct {
	ID      string `json:"id"`
	Version string `json:"version"`
}

type VSAPolicy struct {
	URI    string            `json:"uri"`
	Digest map[string]string `json:"digest,omitempty"`
}

type VSAAttestation struct {
	URI    string            `json:"uri"`
	Digest map[string]string `json:"digest,omitempty"`
}

// PolicyMetadata represents enhanced policy provenance information
type PolicyMetadata struct {
	PolicyBundle struct {
		URI             string `json:"uri"`
		Digest          string `json:"digest"`
		SourceURI       string `json:"sourceUri"`
		VerifierVersion string `json:"verifierVersion"`
	} `json:"policyBundle"`
	Validation struct {
		Result    string `json:"result"`
		Timestamp string `json:"timestamp"`
	} `json:"validation"`
}

// ConversionConfig holds configuration for the conversion process
type ConversionConfig struct {
	VerifierID       string
	VerifierVersion  string
	InputFile        string
	OutputFile       string
	SubjectOverride  string
	PolicyURI        string
	PolicyDigest     string
	PolicyMetadataFile string
}

func main() {
	config := parseFlags()
	
	if err := convertConformaToVSA(config); err != nil {
		log.Fatalf("Conversion failed: %v", err)
	}
	
	fmt.Printf("Successfully converted Conforma evaluation to VSA: %s\n", config.OutputFile)
}

func parseFlags() ConversionConfig {
	var config ConversionConfig
	
	flag.StringVar(&config.InputFile, "input", "", "Path to Conforma evaluation JSON file (required)")
	flag.StringVar(&config.OutputFile, "output", "", "Path to output VSA JSON file (required)")
	flag.StringVar(&config.SubjectOverride, "subject", "", "Override subject image URL (optional)")
	flag.StringVar(&config.VerifierID, "verifier-id", "https://managed.konflux.example.com/conforma-vsa", "Verifier ID for VSA")
	flag.StringVar(&config.VerifierVersion, "verifier-version", "v1.0.0", "Verifier version for VSA")
	flag.StringVar(&config.PolicyURI, "policy-uri", "", "Policy bundle URI for provenance (optional)")
	flag.StringVar(&config.PolicyDigest, "policy-digest", "", "Policy bundle digest for verification (optional)")
	flag.StringVar(&config.PolicyMetadataFile, "policy-metadata", "", "Path to policy metadata JSON file (optional)")
	
	flag.Parse()
	
	if config.InputFile == "" || config.OutputFile == "" {
		fmt.Fprintf(os.Stderr, "Usage: %s -input <file> -output <file> [options]\n", os.Args[0])
		flag.PrintDefaults()
		os.Exit(1)
	}
	
	return config
}

func convertConformaToVSA(config ConversionConfig) error {
	// Read and parse Conforma input
	inputData, err := os.ReadFile(config.InputFile)
	if err != nil {
		return fmt.Errorf("failed to read input file: %w", err)
	}
	
	var conformaInput ConformaInput
	if err := json.Unmarshal(inputData, &conformaInput); err != nil {
		return fmt.Errorf("failed to parse Conforma JSON: %w", err)
	}
	
	// Validate input
	if err := validateConformaInput(&conformaInput); err != nil {
		return fmt.Errorf("invalid Conforma input: %w", err)
	}
	
	// Convert to VSA
	vsa, err := convertToVSA(&conformaInput, config)
	if err != nil {
		return fmt.Errorf("conversion failed: %w", err)
	}
	
	// Validate VSA output
	if err := validateVSAOutput(vsa); err != nil {
		return fmt.Errorf("invalid VSA output: %w", err)
	}
	
	// Write output
	outputData, err := json.MarshalIndent(vsa, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal VSA JSON: %w", err)
	}
	
	if err := os.WriteFile(config.OutputFile, outputData, 0644); err != nil {
		return fmt.Errorf("failed to write output file: %w", err)
	}
	
	return nil
}

func validateConformaInput(input *ConformaInput) error {
	if input.EffectiveTime == "" {
		return fmt.Errorf("effective-time is required")
	}
	
	if len(input.Components) == 0 {
		return fmt.Errorf("at least one component is required")
	}
	
	for i, component := range input.Components {
		if component.Name == "" {
			return fmt.Errorf("component[%d]: name is required", i)
		}
		if component.ContainerImage == "" {
			return fmt.Errorf("component[%d]: containerImage is required", i)
		}
		if !strings.Contains(component.ContainerImage, "@sha256:") {
			return fmt.Errorf("component[%d]: containerImage must include sha256 digest", i)
		}
	}
	
	return nil
}

func convertToVSA(input *ConformaInput, config ConversionConfig) (*VSAStatement, error) {
	// Parse effective time
	timeVerified, err := parseTime(input.EffectiveTime)
	if err != nil {
		return nil, fmt.Errorf("failed to parse effective-time: %w", err)
	}
	
	// Build subjects from components
	subjects := make([]VSASubject, 0, len(input.Components))
	for _, component := range input.Components {
		subject, err := buildSubject(component, config.SubjectOverride)
		if err != nil {
			return nil, fmt.Errorf("failed to build subject for component %s: %w", component.Name, err)
		}
		subjects = append(subjects, subject)
	}
	
	// Determine overall verification result
	verificationResult := "PASSED"
	if !input.Success {
		verificationResult = "FAILED"
	}
	
	// Determine verified levels based on success and component analysis
	verifiedLevels := determineVerifiedLevels(input)
	
	// Build policy information with enhanced provenance
	policy, err := buildPolicy(input.Policy, config)
	if err != nil {
		return nil, fmt.Errorf("failed to build policy: %w", err)
	}
	
	// Build input attestations
	inputAttestations := buildInputAttestations(input.Components)
	
	// Build resource URI (use first component if no override)
	resourceURI := subjects[0].Name
	if strings.Contains(subjects[0].Name, "@") {
		resourceURI = subjects[0].Name
	} else {
		if digest, ok := subjects[0].Digest["sha256"]; ok {
			resourceURI = subjects[0].Name + "@sha256:" + digest
		}
	}
	
	vsa := &VSAStatement{
		Type:          "https://in-toto.io/Statement/v1",
		Subject:       subjects,
		PredicateType: "https://slsa.dev/verification_summary/v1",
		Predicate: VSAPredicate{
			Verifier: VSAVerifier{
				ID:      config.VerifierID,
				Version: determineVerifierVersion(input.ECVersion, config.VerifierVersion),
			},
			TimeVerified:       timeVerified,
			ResourceURI:        resourceURI,
			Policy:             policy,
			InputAttestations:  inputAttestations,
			VerificationResult: verificationResult,
			VerifiedLevels:     verifiedLevels,
			DependencyLevels:   make(map[string]string),
		},
	}
	
	return vsa, nil
}

func parseTime(timeStr string) (string, error) {
	// Try parsing as RFC3339 first
	if t, err := time.Parse(time.RFC3339, timeStr); err == nil {
		return t.UTC().Format(time.RFC3339), nil
	}
	
	// Try parsing without timezone
	if t, err := time.Parse("2006-01-02T15:04:05", timeStr); err == nil {
		return t.UTC().Format(time.RFC3339), nil
	}
	
	return "", fmt.Errorf("unsupported time format: %s", timeStr)
}

func buildSubject(component ConformaComponent, subjectOverride string) (VSASubject, error) {
	imageRef := component.ContainerImage
	if subjectOverride != "" {
		imageRef = subjectOverride
	}
	
	// Parse image reference to extract name and digest
	parts := strings.Split(imageRef, "@sha256:")
	if len(parts) != 2 || parts[1] == "" {
		return VSASubject{}, fmt.Errorf("invalid image reference format: %s", imageRef)
	}
	
	name := parts[0]
	digest := parts[1]
	
	return VSASubject{
		Name: name,
		Digest: map[string]string{
			"sha256": digest,
		},
	}, nil
}

func determineVerifiedLevels(input *ConformaInput) []string {
	if !input.Success {
		return []string{}
	}
	
	// Analyze components for SLSA level determination
	hasViolations := false
	hasWarnings := false
	
	for _, component := range input.Components {
		if !component.Success || len(component.Violations) > 0 {
			hasViolations = true
		}
		// Note: Conforma doesn't have explicit warnings in this structure
		// but we could add logic here to detect warning conditions
	}
	
	if hasViolations {
		return []string{}
	} else if hasWarnings {
		return []string{"SLSA_BUILD_LEVEL_2"}
	} else {
		return []string{"SLSA_BUILD_LEVEL_3"}
	}
}

func buildPolicy(policy ConformaPolicy, config ConversionConfig) (VSAPolicy, error) {
	vsaPolicy := VSAPolicy{}
	
	// Priority 1: Use config parameters from command line/task parameters
	if config.PolicyURI != "" {
		vsaPolicy.URI = config.PolicyURI
		
		// Add digest if provided
		if config.PolicyDigest != "" {
			// Normalize digest format
			digest := config.PolicyDigest
			if strings.HasPrefix(digest, "sha256:") {
				digest = strings.TrimPrefix(digest, "sha256:")
			}
			vsaPolicy.Digest = map[string]string{
				"sha256": digest,
			}
		}
	} else if len(policy.Sources) > 0 && len(policy.Sources[0].Policy) > 0 {
		// Priority 2: Use policy from Conforma input
		policyURI := policy.Sources[0].Policy[0]
		vsaPolicy.URI = policyURI
		
		// If the policy URI is an OCI reference with digest, extract it
		if strings.Contains(policyURI, "@sha256:") {
			parts := strings.Split(policyURI, "@sha256:")
			if len(parts) == 2 {
				vsaPolicy.Digest = map[string]string{
					"sha256": parts[1],
				}
			}
		}
	} else {
		return VSAPolicy{}, fmt.Errorf("policy source is required")
	}
	
	// Load additional policy metadata if available
	if config.PolicyMetadataFile != "" {
		if metadata, err := loadPolicyMetadata(config.PolicyMetadataFile); err == nil {
			// Override with metadata if available
			if metadata.PolicyBundle.URI != "" {
				vsaPolicy.URI = metadata.PolicyBundle.URI
			}
			if metadata.PolicyBundle.Digest != "" {
				digest := metadata.PolicyBundle.Digest
				if strings.HasPrefix(digest, "sha256:") {
					digest = strings.TrimPrefix(digest, "sha256:")
				}
				vsaPolicy.Digest = map[string]string{
					"sha256": digest,
				}
			}
		}
	}
	
	return vsaPolicy, nil
}

func loadPolicyMetadata(filename string) (*PolicyMetadata, error) {
	data, err := os.ReadFile(filename)
	if err != nil {
		return nil, fmt.Errorf("failed to read policy metadata file: %w", err)
	}
	
	var metadata PolicyMetadata
	if err := json.Unmarshal(data, &metadata); err != nil {
		return nil, fmt.Errorf("failed to parse policy metadata JSON: %w", err)
	}
	
	return &metadata, nil
}

func buildInputAttestations(components []ConformaComponent) []VSAAttestation {
	attestations := []VSAAttestation{}
	
	for _, component := range components {
		if len(component.Attestations) > 0 {
			// Create a reference to the component's attestations
			attestation := VSAAttestation{
				URI: component.Name + "-attestations",
				// Note: In a real implementation, we would compute or extract
				// the actual digest of the attestations bundle
				Digest: map[string]string{
					"sha256": "computed-from-attestations",
				},
			}
			attestations = append(attestations, attestation)
		}
	}
	
	return attestations
}

func determineVerifierVersion(ecVersion, defaultVersion string) string {
	if ecVersion != "" {
		return ecVersion
	}
	return defaultVersion
}

func validateVSAOutput(vsa *VSAStatement) error {
	// Basic VSA structure validation
	if vsa.Type != "https://in-toto.io/Statement/v1" {
		return fmt.Errorf("invalid statement type: %s", vsa.Type)
	}
	
	if vsa.PredicateType != "https://slsa.dev/verification_summary/v1" {
		return fmt.Errorf("invalid predicate type: %s", vsa.PredicateType)
	}
	
	if len(vsa.Subject) == 0 {
		return fmt.Errorf("at least one subject is required")
	}
	
	// Validate subjects
	for i, subject := range vsa.Subject {
		if subject.Name == "" {
			return fmt.Errorf("subject[%d]: name is required", i)
		}
		if len(subject.Digest) == 0 {
			return fmt.Errorf("subject[%d]: digest is required", i)
		}
		if _, ok := subject.Digest["sha256"]; !ok {
			return fmt.Errorf("subject[%d]: sha256 digest is required", i)
		}
	}
	
	// Validate predicate
	if vsa.Predicate.Verifier.ID == "" {
		return fmt.Errorf("verifier ID is required")
	}
	
	if vsa.Predicate.TimeVerified == "" {
		return fmt.Errorf("timeVerified is required")
	}
	
	if vsa.Predicate.ResourceURI == "" {
		return fmt.Errorf("resourceUri is required")
	}
	
	if vsa.Predicate.Policy.URI == "" {
		return fmt.Errorf("policy URI is required")
	}
	
	validResults := map[string]bool{
		"PASSED": true,
		"FAILED": true,
	}
	if !validResults[vsa.Predicate.VerificationResult] {
		return fmt.Errorf("invalid verification result: %s", vsa.Predicate.VerificationResult)
	}
	
	return nil
}