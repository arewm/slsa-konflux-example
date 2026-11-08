package slsa_source_verification_test

import rego.v1

import data.lib
import data.slsa_source_verification

# Test: All good - verify-source achieves required level
test_all_good if {
	attestations := _attestations_with_verify_source("3", "https://github.com/example/repo.git", "abc123")
	lib.assert_empty(slsa_source_verification.deny) with input.attestations as attestations
		with data.rule_data as {"slsa_source_min_level": "3"}
}

# Test: Achieves higher level than required (level 3 when level 1 required)
test_exceeds_required_level if {
	attestations := _attestations_with_verify_source("3", "https://github.com/example/repo.git", "abc123")
	lib.assert_empty(slsa_source_verification.deny) with input.attestations as attestations
		with data.rule_data as {"slsa_source_min_level": "1"}
}

# Test: Achieves level 2 when level 1 required
test_level_2_when_1_required if {
	attestations := _attestations_with_verify_source("2", "https://github.com/example/repo.git", "abc123")
	lib.assert_empty(slsa_source_verification.deny) with input.attestations as attestations
		with data.rule_data as {"slsa_source_min_level": "1"}
}

# Test: Achieved level too low
test_level_too_low if {
	attestations := _attestations_with_verify_source("2", "https://github.com/example/repo.git", "abc123")
	expected := {{
		"code": "slsa_source_verification.required_level_achieved",
		"msg": "verify-source task achieved level 2, but minimum required level is 3",
		"term": "verify-source",
	}}
	lib.assert_equal_results(slsa_source_verification.deny, expected) with input.attestations as attestations
		with data.rule_data as {"slsa_source_min_level": "3"}
}

# Test: Level 1 when level 3 required
test_level_1_when_3_required if {
	attestations := _attestations_with_verify_source("1", "https://github.com/example/repo.git", "abc123")
	expected := {{
		"code": "slsa_source_verification.required_level_achieved",
		"msg": "verify-source task achieved level 1, but minimum required level is 3",
		"term": "verify-source",
	}}
	lib.assert_equal_results(slsa_source_verification.deny, expected) with input.attestations as attestations
		with data.rule_data as {"slsa_source_min_level": "3"}
}

# Test: Missing SLSA_SOURCE_LEVEL_ACHIEVED result
test_missing_result if {
	attestations := _attestations_with_verify_source_no_result("https://github.com/example/repo.git", "abc123")
	expected := {{
		"code": "slsa_source_verification.result_provided",
		"msg": "verify-source task did not provide SLSA_SOURCE_LEVEL_ACHIEVED result",
		"term": "verify-source",
	}}
	lib.assert_equal_results(slsa_source_verification.deny, expected) with input.attestations as attestations
		with data.rule_data as {"slsa_source_min_level": "3"}
}

# Test: URL mismatch between git-clone and verify-source
test_url_mismatch if {
	attestations := _attestations_with_mismatched_url
	# Both errors are expected: parameter mismatch AND material not verified
	expected := {
		{
			"code": "slsa_source_verification.parameters_match_git_clone",
			"msg": "verify-source task parameter url=\"https://github.com/different/repo.git\" does not match git-clone result url=\"https://github.com/example/repo.git\"",
			"term": "verify-source",
		},
		{
			"code": "slsa_source_verification.verified_all_materials",
			"msg": "No verify-source task found for repository git+https://github.com/example/repo.git at commit abc123",
			"term": "git+https://github.com/example/repo.git@abc123",
		},
	}
	lib.assert_equal_results(slsa_source_verification.deny, expected) with input.attestations as attestations
		with data.rule_data as {"slsa_source_min_level": "3"}
}

# Test: Revision mismatch between git-clone and verify-source
test_revision_mismatch if {
	attestations := _attestations_with_mismatched_revision
	# Both errors are expected: parameter mismatch AND material not verified
	expected := {
		{
			"code": "slsa_source_verification.parameters_match_git_clone",
			"msg": "verify-source task parameter revision=\"def456\" does not match git-clone result commit=\"abc123\"",
			"term": "verify-source",
		},
		{
			"code": "slsa_source_verification.verified_all_materials",
			"msg": "No verify-source task found for repository git+https://github.com/example/repo.git at commit abc123",
			"term": "git+https://github.com/example/repo.git@abc123",
		},
	}
	lib.assert_equal_results(slsa_source_verification.deny, expected) with input.attestations as attestations
		with data.rule_data as {"slsa_source_min_level": "3"}
}

# Test: URL normalization handles .git suffix variations
test_url_normalization_git_suffix if {
	# git-clone returns URL without .git, verify-source has .git
	attestations := [{"statement": {
		"predicateType": "https://slsa.dev/provenance/v0.2",
		"predicate": {
			"buildConfig": {"tasks": [
				_git_clone_task("https://github.com/example/repo", "abc123"),
				_verify_source_task("3", "https://github.com/example/repo.git", "abc123"),
			]},
			"materials": [{
				"uri": "git+https://github.com/example/repo.git",
				"digest": {"sha1": "abc123"},
			}],
		},
	}}]

	lib.assert_empty(slsa_source_verification.deny) with input.attestations as attestations
		with data.rule_data as {"slsa_source_min_level": "3"}
}

# Test: Multi-repo build - all repos verified
test_multi_repo_all_verified if {
	attestations := _attestations_multi_repo_verified
	lib.assert_empty(slsa_source_verification.deny) with input.attestations as attestations
		with data.rule_data as {"slsa_source_min_level": "3"}
}

# Test: Multi-repo build - missing verification for second repo
test_multi_repo_missing_verification if {
	attestations := _attestations_multi_repo_missing
	expected := {{
		"code": "slsa_source_verification.verified_all_materials",
		"msg": "No verify-source task found for repository git+https://github.com/example/lib.git at commit def456",
		"term": "git+https://github.com/example/lib.git@def456",
	}}
	lib.assert_equal_results(slsa_source_verification.deny, expected) with input.attestations as attestations
		with data.rule_data as {"slsa_source_min_level": "3"}
}

# Test: SLSA v1.0 attestation format
test_slsa_v1_format if {
	attestations := _attestations_slsa_v1
	lib.assert_empty(slsa_source_verification.deny) with input.attestations as attestations
		with data.rule_data as {"slsa_source_min_level": "3"}
}

# Test helper: Create attestations with verify-source task
_attestations_with_verify_source(level, url, revision) := [{"statement": {
	"predicateType": "https://slsa.dev/provenance/v0.2",
	"predicate": {
		"buildType": "tekton.dev/v1/PipelineRun",
		"buildConfig": {"tasks": [
			_git_clone_task(url, revision),
			_verify_source_task(level, url, revision),
		]},
		"materials": [{
			"uri": sprintf("git+%s", [url]),
			"digest": {"sha1": revision},
		}],
	},
}}]

# Test helper: Create attestations with verify-source task missing result
_attestations_with_verify_source_no_result(url, revision) := [{"statement": {
	"predicateType": "https://slsa.dev/provenance/v0.2",
	"predicate": {
		"buildType": "tekton.dev/v1/PipelineRun",
		"buildConfig": {"tasks": [
			_git_clone_task(url, revision),
			_verify_source_task_no_result(url, revision),
		]},
		"materials": [{
			"uri": sprintf("git+%s", [url]),
			"digest": {"sha1": revision},
		}],
	},
}}]

# Test helper: Attestations with URL mismatch
_attestations_with_mismatched_url := [{"statement": {
	"predicateType": "https://slsa.dev/provenance/v0.2",
	"predicate": {
		"buildType": "tekton.dev/v1/PipelineRun",
		"buildConfig": {"tasks": [
			_git_clone_task("https://github.com/example/repo.git", "abc123"),
			_verify_source_task("3", "https://github.com/different/repo.git", "abc123"),
		]},
		"materials": [{
			"uri": "git+https://github.com/example/repo.git",
			"digest": {"sha1": "abc123"},
		}],
	},
}}]

# Test helper: Attestations with revision mismatch
_attestations_with_mismatched_revision := [{"statement": {
	"predicateType": "https://slsa.dev/provenance/v0.2",
	"predicate": {
		"buildType": "tekton.dev/v1/PipelineRun",
		"buildConfig": {"tasks": [
			_git_clone_task("https://github.com/example/repo.git", "abc123"),
			_verify_source_task("3", "https://github.com/example/repo.git", "def456"),
		]},
		"materials": [{
			"uri": "git+https://github.com/example/repo.git",
			"digest": {"sha1": "abc123"},
		}],
	},
}}]

# Test helper: Multi-repo build with all repos verified
_attestations_multi_repo_verified := [{"statement": {
	"predicateType": "https://slsa.dev/provenance/v0.2",
	"predicate": {
		"buildType": "tekton.dev/v1/PipelineRun",
		"buildConfig": {"tasks": [
			_git_clone_task("https://github.com/example/repo.git", "abc123"),
			_verify_source_task("3", "https://github.com/example/repo.git", "abc123"),
			_git_clone_task("https://github.com/example/lib.git", "def456"),
			_verify_source_task("3", "https://github.com/example/lib.git", "def456"),
		]},
		"materials": [
			{
				"uri": "git+https://github.com/example/repo.git",
				"digest": {"sha1": "abc123"},
			},
			{
				"uri": "git+https://github.com/example/lib.git",
				"digest": {"sha1": "def456"},
			},
		],
	},
}}]

# Test helper: Multi-repo build with missing verification
_attestations_multi_repo_missing := [{"statement": {
	"predicateType": "https://slsa.dev/provenance/v0.2",
	"predicate": {
		"buildType": "tekton.dev/v1/PipelineRun",
		"buildConfig": {"tasks": [
			_git_clone_task("https://github.com/example/repo.git", "abc123"),
			_verify_source_task("3", "https://github.com/example/repo.git", "abc123"),
			_git_clone_task("https://github.com/example/lib.git", "def456"),
			# Missing verify-source for second repo
		]},
		"materials": [
			{
				"uri": "git+https://github.com/example/repo.git",
				"digest": {"sha1": "abc123"},
			},
			{
				"uri": "git+https://github.com/example/lib.git",
				"digest": {"sha1": "def456"},
			},
		],
	},
}}]

# Test helper: SLSA v1.0 format attestation
_attestations_slsa_v1 := [{"statement": {
	"predicateType": "https://slsa.dev/provenance/v1",
	"predicate": {
		"buildDefinition": {
			"resolvedDependencies": [{
				"uri": "git+https://github.com/example/repo.git",
				"digest": {"sha1": "abc123"},
			}],
		},
	},
}}]

# Task helper: git-clone task
_git_clone_task(url, commit) := {
	"name": "git-clone",
	"ref": {
		"name": "git-clone",
		"kind": "task",
	},
	"results": [
		{
			"name": "url",
			"value": url,
		},
		{
			"name": "commit",
			"value": commit,
		},
	],
}

# Task helper: verify-source task
# Level should be just the number ("1", "2", "3") - this helper formats it correctly
_verify_source_task(level, url, revision) := {
	"name": "verify-source",
	"ref": {
		"name": "verify-source",
		"kind": "task",
	},
	"invocation": {"parameters": {
		"url": url,
		"revision": revision,
	}},
	"results": [{
		"name": "SLSA_SOURCE_LEVEL_ACHIEVED",
		"value": sprintf("SLSA_SOURCE_LEVEL_%s\n", [level]),
	}],
}

# Task helper: verify-source task without result
_verify_source_task_no_result(url, revision) := {
	"name": "verify-source",
	"ref": {
		"name": "verify-source",
		"kind": "task",
	},
	"invocation": {"parameters": {
		"url": url,
		"revision": revision,
	}},
	"results": [],
}
