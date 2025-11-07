# SLSA End-to-End Example (Konflux style)

This repository demonstrates how to achieve end-to-end SLSA (Supply-chain Levels for Software Artifacts) compliance using [Konflux](https://konflux-ci.dev).
It is created in response to the SLSA [request for examples](https://slsa.dev/blog/2025/07/slsa-e2e).

If you are not familiar with Konflux, it is an open source, cloud-native software factory focused on software supply chain security. We understand that there
are often competing interests between software developers and security professionals, but we try to strike a balance. By hardening our platform so that we can
achieve SLSA Build L3 out of the box, we give developers the flexibility to build what they need to while also ensuring that the necessary requirements are
met before those artifacts are pushed anywhere outside their control.

After you complete the prerequisites, this repository provides a self-contained example for how to configure a Konflux tenant, onboard a component, and release
it while ensuring that we meet all required policies. We will show you along the way how we leverage guidance from many of SLSA's tracks.

## Table of contents

TODO: complete

## Pre-requisites

Before being able to explore SLSA with Konflux, you will need to have a running instance of it. We have [instructions](https://github.com/konflux-ci/konflux-ci?tab=readme-ov-file#trying-out-konflux). While these instructions describe the process for building artifacts, we will also do that here. So you can stop after you complete the following:
- [Installing Software Dependencies](lux-ci?tab=readme-ov-file#installing-software-dependencies)
- [Bootstrapping the cluster](https://github.com/konflux-ci/konflux-ci?tab=readme-ov-file#bootstrapping-the-cluster)
- [Enabling Pipelines Triggering via Webhooks](https://github.com/konflux-ci/konflux-ci?tab=readme-ov-file#enable-pipelines-triggering-via-webhooks)

**NOTE:** You will need to configure your repository with the Pipelines as Code application, so make sure you don't lose track of it when you create it.

**NOTE:** If you lose your kubeconfig to connect to your KinD cluster, you can re-establish it with

```bash
$ kind export kubeconfig -n konflux
```

**Accessing the Konflux UI:**

You can view pipeline runs and builds in the Konflulix web UI at https://localhost:9443

Default user accounts:
- **Tenant namespace** (`user-ns1`):
  - Username: `user1@konflux.dev`
  - Password: `password`
- **Managed namespace** (`user-ns2`):
  - Username: `user2@konflux.dev`
  - Password: `password`

Use `user1@konflux.dev` to onboard components and view tenant builds.

Create two namespaces on your cluster.
  - One is a tenant namespace where the artifact builds will occur
  - One is a managed namespace which will be where privileged operations occur

Install the required cli tools for this demo:
- [cosign](https://github.com/sigstore/cosign?tab=readme-ov-file#installation), a tool for fetching attestations for OCI artifacts
- [helm](https://github.com/helm/helm?tab=readme-ov-file#install) to deploy the resources to the KindD cluster
- [tkn](https://github.com/tektoncd/cli?tab=readme-ov-file#installing-tkn) to view Tekton pipelines

- (Optional) create push credentials for two different image repositories.

## Setting up your builds

In order to achieve [SLSA build L3](https://slsa.dev/spec/v1.1/requirements), we need to ensure that builds are properly isolated
both from other builds as well as from the secrets used to sign the provenance. Konflux relies on Kubernetes pods, as orchestrated by
Tekton, to ensure that parallel builds are sufficiently isolated from each other. It also relies on Kubernetes namespace isolation to
ensure that the signing material that Tekton Chains uses when generating the provenance cannot be accessed by builds.

Configuring the required Tekton definition can be onerous, so we use Pipelines as Code to help push out a default definition when you
onboard a component.

## Setup your repository

In this phase, we will walk you through what is needed to get your source repository ready to explore SLSA, Konflux style.

### Pick a repository

If you don't have a repository you want to build a container image from, you can pick one and fork it. If you don't have one, you
can always make [seasonally festive emojis](https://github.com/lcarva/festoji).

Once you have a repository under your control, you will need to install the GitHub application that you previously created. If you
have forgotten what your app is to install on your repository, you can see the apps that you have created 
[here](https://github.com/settings/apps).

### Onboard to source-tool

TODO: instructions

## Onboard the component

If you installed Konflux using the instructions [above](#pre-requisites), we will use the two namespaces created for you

- `user-ns1`: This will be the unprivileged tenant namespace
- `user-ns2`: This will be the privileged managed namespace

If you need to connect to the cluster, you can export the kubeconfig:

```bash
# By default, the cluster name is konflux
kind export kubeconfig -n konflux 
```

Once your Konflux instance is deployed, we need to make sure that your tenant and managed namespaces are configured. This not only includes
configuring Pipelines as Code so that you can create builds from your git commits, but also ensuring that we have the necessary configuration
to test and release all of the artifacts you build.

First, configure the build-service pipeline bundles (this requires admin access):

```bash
# Delete any existing non-Helm managed ConfigMap
kubectl delete configmap build-pipeline-config -n build-service

# Install the build configuration via Helm
helm upgrade --install build-config ./admin
```

Then, onboard your component:

```bash
export FORK_ORG="yourfork"
helm upgrade --install festoji ./resources \
  --set applicationName=festoji \
  --set gitRepoUrl=https://github.com/${FORK_ORG}/festoji \
  --set namespace=user-ns1 \
  --set release.targetNamespace=user-ns2
```

Now that you have onboarded your component, your PR will report a running build and you can use `tkn` to see it in the cluster!

## Building isn't enough

Let's merge that PR, let the build run, and then look at what all we have configured Konflux to run.

### Build pipeline

If you look in your source repository, there will be two different PipelineRuns defined in the `.tekton` directory. One for PR events and another for push events.
By default, these are almost identical so the build you see how will largely be the same as the build you saw previously. This means that any build-time checks
(including clair-in-ci and clamAV) will still run on every build. If we inspect the provenance, we can see the results of these scans.

```bash
cosign download [...] | jq [...]
```

We didn't just build the artifact, however, this build task also created an SBOM for you by running `syft`.

```bash
[...]
```

### Integration tests

Once Tekton Chains has finished processing the Pipeline Run and generating provenance for the artifacts, the integration service will trigger any tests that are configured.
If you have enabled auto-releasing after all required tests pass, a new Release will be created to trigger the next step.

### Pushing images elsewhere

Even if some developers want access to all credentials, to properly isolate privileged environments, we can release artifacts via pipelines in separate managed namespaces.
The Release that was auto-created references a ReleasePlan in the tenant namespace which is mapped to a ReleasePlanAdmission in a specific managed namespace. When the Release
is created, a new Tekton pipeline will be created as specified in that ReleasePlanAdmission.

When we ran the `helm install` above, we created a simple ReleasePlanAdmission which will run a Pipeline to push this image to a separate location after verifying a specific
policy.

```bash
kubectl get [...]
```

#### What's in a policy?

As we mentioned at the beginning, we are balancing flexibility with security. We use [Conforma](https://conforma.dev) as a policy engine to ensure that specific requirements
(policy rules) are met. Conforma can consume [...]

TODO: Talk more about what Conforma can consume and how to construct the policy. Briefly review the policy that we created on cluster. Talk about policy-driven-development using the manged policy

## What else can this pipeline do?

TODO: change to hermetic with more acurate SBOM

## What else can Conforma do?

TODO: introduce vulnerability, have policy exception

## Additional references

### Documentation
### Recordings
### Controllers