#
# METADATA
# title: SLSA Source Track Verification
# description: >-
#   Validates that verify-source task runs correctly for all source repositories
#   and achieves the required SLSA source level.
#
package slsa_source_verification

import rego.v1

import data.lib
import data.lib.tekton

# METADATA
# title: Required SLSA source level achieved
# description: >-
#   Ensure that the verify-source task achieved the minimum required SLSA source level.
#   Defaults to level 1 if not specified in rule_data.
# custom:
#   short_name: required_level_achieved
#   failure_msg: 'verify-source task achieved level %s, but minimum required level is %s'
#   solution: >-
#     Ensure your source repository meets the requirements for the configured SLSA source level.
#     See https://slsa.dev/spec/v1.2/source-requirements for details on each level.
#   collections:
#   - slsa_source
#   depends_on:
#   - tasks.required_tasks_found
#
deny contains result if {
	min_level := _slsa_source_min_level

	# Find the verify-source task
	some att in lib.pipelinerun_attestations
	some task in tekton.tasks(att)
	some task_name in tekton.task_names(task)
	task_name == "verify-source"

	# Get the actual level achieved
	achieved_level_raw := tekton.task_result(task, "SLSA_SOURCE_LEVEL_ACHIEVED")

	# Parse the level number from "SLSA_SOURCE_LEVEL_N" format
	achieved_level := _parse_level(achieved_level_raw)

	# Compare levels (both should be strings like "1", "2", "3")
	to_number(achieved_level) < to_number(min_level)

	result := lib.result_helper_with_term(
		rego.metadata.chain(),
		[achieved_level, min_level],
		"verify-source",
	)
}

# METADATA
# title: verify-source task provides SLSA_SOURCE_LEVEL_ACHIEVED result
# description: >-
#   Ensure that the verify-source task provides the SLSA_SOURCE_LEVEL_ACHIEVED result.
# custom:
#   short_name: result_provided
#   failure_msg: 'verify-source task did not provide SLSA_SOURCE_LEVEL_ACHIEVED result'
#   solution: >-
#     Ensure you are using verify-source task version 0.1 or later which provides this result.
#   collections:
#   - slsa_source
#   depends_on:
#   - tasks.required_tasks_found
#
deny contains result if {
	# Find the verify-source task
	some att in lib.pipelinerun_attestations
	some task in tekton.tasks(att)
	some task_name in tekton.task_names(task)
	task_name == "verify-source"

	# Check if the result exists
	not tekton.task_result(task, "SLSA_SOURCE_LEVEL_ACHIEVED")

	result := lib.result_helper_with_term(
		rego.metadata.chain(),
		[],
		"verify-source",
	)
}

# METADATA
# title: verify-source parameters match git-clone results
# description: >-
#   Ensure that the verify-source task receives the same repository URL and revision
#   as the git-clone task produced.
# custom:
#   short_name: parameters_match_git_clone
#   failure_msg: 'verify-source task parameter %s=%q does not match git-clone result %s=%q'
#   solution: >-
#     Ensure the verify-source task receives its url and revision parameters from the
#     git-clone task results. The url parameter should use $(tasks.git-clone.results.url)
#     and revision should use $(tasks.git-clone.results.commit).
#   collections:
#   - slsa_source
#   depends_on:
#   - tasks.required_tasks_found
#   - provenance_materials.git_clone_task_found
#
deny contains result if {
	some att in lib.pipelinerun_attestations

	# Find a verify-source task
	some verify_source_task in _verify_source_tasks(att)

	# Get verify-source parameters
	verify_url := tekton.task_param(verify_source_task, "url")
	verify_revision := tekton.task_param(verify_source_task, "revision")

	# Check if there's ANY git-clone task that matches these parameters
	matching_git_clones := [task |
		some task in tekton.git_clone_tasks(att)
		git_url := tekton.task_result(task, "url")
		git_commit := tekton.task_result(task, "commit")
		_normalize_git_url(git_url) == _normalize_git_url(verify_url)
		git_commit == verify_revision
	]

	# No matching git-clone found - this is an error
	count(matching_git_clones) == 0

	# Find first git-clone to report in error message
	some first_git_clone in tekton.git_clone_tasks(att)
	git_url := tekton.task_result(first_git_clone, "url")
	git_commit := tekton.task_result(first_git_clone, "commit")

	mismatch := _parameter_mismatch(git_url, git_commit, verify_url, verify_revision)
	count(mismatch) > 0

	result := lib.result_helper_with_term(
		rego.metadata.chain(),
		[mismatch.param_name, mismatch.param_value, mismatch.result_name, mismatch.result_value],
		"verify-source",
	)
}

# METADATA
# title: verify-source run for all source materials
# description: >-
#   Ensure that a verify-source task was run for each git repository in the
#   attestation materials.
# custom:
#   short_name: verified_all_materials
#   failure_msg: 'No verify-source task found for repository %s at commit %s'
#   solution: >-
#     Ensure that for each git repository cloned in the build, there is a corresponding
#     verify-source task that validates it. Multi-repo builds should have multiple
#     verify-source task invocations.
#   collections:
#   - slsa_source
#   depends_on:
#   - attestation_type.known_attestation_type
#
deny contains result if {
	some att in lib.pipelinerun_attestations

	# Get all git materials from the attestation
	some material in _git_materials(att)

	# Check if there's a verify-source task for this material
	verify_tasks := [task |
		some task in _verify_source_tasks(att)
		url := tekton.task_param(task, "url")
		revision := tekton.task_param(task, "revision")
		_materials_match(material, url, revision)
	]

	count(verify_tasks) == 0

	result := lib.result_helper_with_term(
		rego.metadata.chain(),
		[material.uri, material.digest.sha1],
		sprintf("%s@%s", [material.uri, material.digest.sha1]),
	)
}

# Get the minimum required level from rule data
# Default to "1" if we don't find it
_slsa_source_min_level := min_level if {
  min_level := lib.rule_data("slsa_source_min_level")
  to_number(min_level)
} else := "1"

# Helper: Get all verify-source tasks
_verify_source_tasks(attestation) := [task |
	some task in tekton.tasks(attestation)
	some task_name in tekton.task_names(task)
	task_name == "verify-source"
]

# Helper: Get all git materials from attestation
_git_materials(att) := materials if {
	# SLSA v0.2
	materials := [m |
		some m in att.statement.predicate.materials
		m.uri
		m.digest.sha1
		startswith(m.uri, "git+")
	]
} else := materials if {
	# SLSA v1.0
	materials := [m |
		some m in att.statement.predicate.buildDefinition.resolvedDependencies
		m.uri
		m.digest.sha1
		startswith(m.uri, "git+")
	]
}

# Helper: Check if parameters match git-clone results
_parameter_mismatch(git_url, git_commit, verify_url, verify_revision) := mismatch if {
	_normalize_git_url(git_url) != _normalize_git_url(verify_url)
	mismatch := {
		"param_name": "url",
		"param_value": verify_url,
		"result_name": "url",
		"result_value": git_url,
	}
} else := mismatch if {
	git_commit != verify_revision
	mismatch := {
		"param_name": "revision",
		"param_value": verify_revision,
		"result_name": "commit",
		"result_value": git_commit,
	}
}

# Helper: Check if material matches verify-source task parameters
_materials_match(material, url, revision) if {
	_normalize_git_url(material.uri) == _normalize_git_url(url)
	material.digest.sha1 == revision
}

# Helper: Normalize git URLs for comparison (handle .git suffix variations)
_normalize_git_url(url) := normalized if {
	# Remove git+ prefix if present
	without_prefix := trim_prefix(url, "git+")
	# Already has .git suffix
	endswith(without_prefix, ".git")
	normalized := without_prefix
} else := normalized if {
	# Add .git suffix
	without_prefix := trim_prefix(url, "git+")
	normalized := concat("", [without_prefix, ".git"])
}

# Helper: Parse level number from verify-source result
# Handles formats like "SLSA_SOURCE_LEVEL_1" or "SLSA_SOURCE_LEVEL_1\n"
# Returns just the level number as a string ("1", "2", "3")
_parse_level(result_value) := level if {
	# Remove whitespace and newlines
	trimmed := trim_space(result_value)
	# Check if it starts with the expected prefix
	startswith(trimmed, "SLSA_SOURCE_LEVEL_")
	# Extract just the level number
	level := trim_prefix(trimmed, "SLSA_SOURCE_LEVEL_")
} else := result_value if {
	# If it doesn't match the expected format, return as-is
	# This handles cases where the result is already just a number
	true
}
