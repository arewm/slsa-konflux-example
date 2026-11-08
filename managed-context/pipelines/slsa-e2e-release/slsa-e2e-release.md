# slsa-e2e-release pipeline

Tekton pipeline to release Snapshots to an external registry.

This is a simple release pipeline to illustrate performing privileged operations after verifying a Snapshot. A majority of
its tasks come from https://github.com/konflux-ci/release-service-catalog.git.

IMPORTANT: You need to set the `ociStorage` parameter to an OCI repository where the managed pipeline has permissions to store
intermediate artifacts.

## Parameters

| Name                            | Description                                                                                                                        | Optional | Default value                                             |
|---------------------------------|------------------------------------------------------------------------------------------------------------------------------------|----------|-----------------------------------------------------------|
| release                         | The namespaced name (namespace/name) of the Release custom resource initiating this pipeline execution                             | No       | -                                                         |
| releasePlan                     | The namespaced name (namespace/name) of the releasePlan                                                                            | No       | -                                                         |
| releasePlanAdmission            | The namespaced name (namespace/name) of the releasePlanAdmission                                                                   | No       | -                                                         |
| releaseServiceConfig            | The namespaced name (namespace/name) of the releaseServiceConfig                                                                   | No       | -                                                         |
| snapshot                        | The namespaced name (namespace/name) of the snapshot                                                                               | No       | -                                                         |
| enterpriseContractPolicy        | JSON representation of the EnterpriseContractPolicy                                                                                | No       | -                                                         |
| enterpriseContractExtraRuleData | Extra rule data to be merged into the policy specified in params.enterpriseContractPolicy. Use syntax "key1=value1,key2=value2..." | Yes      | pipeline_intention=release                                |
| verify_ec_task_git_url          | The git url to the repo where the verify-conforma task is stored                                                                   | Yes      | https://github.com/arewm/slsa-konflux-example             |
| verify_ec_task_git_revision     | The git revision to be used when consuming the verify-conforma task                                                                | Yes      | main                                                      |
| taskGitUrl                      | The url to the git repo where the release-service-catalog tasks to be used are stored                                              | Yes      | https://github.com/konflux-ci/release-service-catalog.git |
| demoTasksGitUrl                 | The url to the git repo where custom demo release tasks are stored                                                                 | Yes      | https://github.com/arewm/slsa-konflux-example             |
| demoTasksGitRevision            | The git revision to use for custom demo release tasks                                                                              | Yes      | main                                                      |
| ociStorage                      | The OCI repository where the Trusted Artifacts are stored                                                                          | Yes      | registry-service.kind-registry/trusted-artifacts          |
| orasOptions                     | oras options to pass to Trusted Artifacts calls                                                                                    | Yes      | --insecure                                                |
| trustedArtifactsDebug           | Flag to enable debug logging in trusted artifacts. Set to a non-empty string to enable                                             | Yes      | true                                                      |
| dataDir                         | The location where data will be stored                                                                                             | Yes      | /var/workdir/release                                      |
