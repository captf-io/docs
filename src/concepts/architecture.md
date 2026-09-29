# Architecture

This page describes CAPTF's components, what runs where, and how one apply
flows through them. It is for anyone who needs to understand how CAPTF
works before reading a more specific page.

## Components

**The manager Deployment** is CAPTF's one Deployment and one container
image. It runs the controllers that reconcile every kind except
`TerraformClusterTemplate` and `TerraformMachinePoolTemplate`, which have
no reconciler of their own, and it serves the validating webhooks for all
seven kinds from the same process, on a separate port. It watches every
namespace by default: `clusterctl init` never sets a namespace
restriction. See [Configuration](../operator-guide/configuration.md) for
how to scope or tune it.

**The validating webhooks** reject an invalid or disallowed change to a
`Terraform*` object before it is persisted: an immutable field, a malformed
image reference, a `spec.variables` name that collides with a contract
input, or (for `TerraformClusterIdentity`) a Secret the requester cannot
read. There are no mutating webhooks — CAPTF resolves every default at
reconcile time instead of writing it back onto the object. See
[Security Model](security-model.md) for the trust boundary a webhook
decision sits inside, and [RBAC](../operator-guide/rbac.md) for who can
change what.

**A runner Job** is a `batch/v1` Job the manager creates for one operation
(apply, destroy, drift, refresh, restore or plan) on one `Terraform*`
object, in that object's own namespace. Kubernetes never retries a Job pod;
the manager owns retries itself, one attempt per Job name. See
[The Reconcile Lifecycle](lifecycle.md) for how the manager decides which
operation runs next.

**The module image** is the OCI image a `Terraform*` object's
`spec.source.image` names. It bundles a Terraform or OpenTofu module
written to CAPTF's contract for one role (`cluster`, `machine` or
`machinepool`) together with the runtime binary that runs it, at fixed
paths, and optionally a provider filesystem mirror. It never bundles the
runner. See [Image Contract](../module-author/image-contract.md).

**The runner binary** is copied into each Job's pod by an init container,
rather than shipped in the module image. The manager's own image bundles
both `/manager` and a static `/runner` binary; the init container runs
`/runner copy /captf/bin/runner` into an `emptyDir` the module container
also mounts, so by default the runner every Job executes is exactly the
build of the manager that created the Job; an operator can point it at a
different image instead (see
[Configuration](../operator-guide/configuration.md#--runner-image)). The
module container then runs that copy as its command, against the module
and runtime the image provides. The init container's resources are fixed
and not configurable, since it only copies one static binary and never
varies with the module.

**The Kubernetes state backend** is the Terraform/OpenTofu `kubernetes`
backend, which the manager configures for every generated root module.
State lives in Secrets in the `Terraform*` object's own namespace, chunked
when it is large, and labeled by the object's immutable identity —
namespace, kind and name, never its UID — so state survives a `clusterctl
move` and a changed identity is never mistaken for existing state. See
[Terraform State](state.md).

## What runs where

| Component | Runs as | Namespace |
| --- | --- | --- |
| manager, webhooks | One Deployment, one container | The provider's own namespace (`captf-system` by default) |
| runner Job | One `batch/v1` Job per operation | The `Terraform*` object's own namespace |
| runner binary, module | Init and main containers of the Job's pod | Same pod as the Job |
| state | Secrets | The `Terraform*` object's own namespace |

## The data flow of one apply

The manager reconciles a `TerraformCluster`, `TerraformMachine` or
`TerraformMachinePool` through a shared core (externally-managed check,
owner lookup, finalizer, pause) and decides that an apply is the next
operation. It renders that object's inputs into a generated root module —
`main.tf.json`, which configures the `kubernetes` backend and calls the
module image's role module with exactly the contract inputs, and
`terraform.tfvars.json`, the input values — and writes them to a durable
inputs Secret and a per-run Secret, hashing the inputs as it does. See
[Job Inputs](inputs.md) for exactly where each value comes from.

The manager then builds and creates the Job: the init container that copies
the runner binary, and the module container that mounts the per-run Secret
read-only, the identity's mirrored credentials Secret, and empty scratch
volumes. Once the pod starts, the runner initializes the backend, plans and
applies against the module's runtime, and — for a `TerraformCluster` apply —
stops before a plan that deletes or replaces a resource unless that plan
was already approved (see [Plan Approval](../user-guide/plan-approval.md)).
The generated root re-exports the module's contract outputs, so they land
in state alongside everything else the runtime tracks.

The runner reports how the Job finished as its pod's termination message.
The manager reads that message, and — once the Job has finished — the state
Secrets themselves, to set the object's status and conditions and, after a
successful apply, to adopt (re-label) the new state Secrets as its own.

## What a module author provides versus what an operator provides

A **module author** writes and builds the OCI image: the role module (and
any local modules it calls), pinned to the [module
contract](../module-author/contract/README.md) and the [image
contract](../module-author/image-contract.md), optionally with a provider
mirror baked in. They check it with
[tfcapi-lint](../module-author/tfcapi-lint.md) before publishing it.

An **operator** installs the manager
([Installation](../operator-guide/installation.md)), creates the
`TerraformClusterIdentity` credentials CAPTF's objects reference
([Identities and Credentials](../user-guide/identities.md)), and creates the
`Terraform*` objects — directly or through [templates and
ClusterClass](../user-guide/clusterclass.md) — that name a module author's
image. They tune Job resources, deadlines and security contexts per object
([Tuning Jobs](../user-guide/job-tuning.md)), and watch the conditions,
events and alerts the manager and runner produce
([Observability](../operator-guide/observability.md)).
