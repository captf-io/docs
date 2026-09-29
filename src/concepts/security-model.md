# Security Model

This page states CAPTF's trust boundary: what creating a `TerraformCluster`,
`TerraformMachine` or `TerraformMachinePool` grants, what the Job that runs
it can read, and what CAPTF keeps out of status, events and logs. Read it
before deciding who may create or update a `Terraform*` object, and before
deciding whether two tenants can share a namespace. For the mechanics behind
each control, see [Identities and Credentials](../user-guide/identities.md),
[RBAC](../operator-guide/rbac.md) and [Secrets](../operator-guide/secrets.md).

## A `Terraform*` object is a Pod

Once its Cluster API owner references it, a `TerraformCluster`,
`TerraformMachine` or `TerraformMachinePool` makes CAPTF run Jobs whose main
container runs `spec.source.image`, with `jobs.env`, as the namespace's
`captf-runner` ServiceAccount (or an opted-in override named by
`jobs.serviceAccountName`), with the resolved identity's credentials
injected as environment variables and mounted as read-only files
([Identities and Credentials](../user-guide/identities.md)). An object no
owner references runs nothing (see
[Owner references are checked](#owner-references-are-checked-against-the-owner)).
Running a Job is equivalent to granting whoever controls the image
everything the Pod runs with: the runner's access to Secrets in the
namespace (below) and the identity's cloud credentials. Module code, and so
any image a `Terraform*` object names, runs with that access; a
`provider "kubernetes" {}` block or a `local-exec` provisioner can use it
directly.

Consequences:

- **The source image is the trust boundary.** Whoever may set
  `spec.source.image` on an owned `Terraform*` object in a namespace, or on
  the template it is cloned from, already has, in effect, the Secret access
  described below and the cloud credentials of every identity allowed in
  that namespace. `TerraformCluster` and `TerraformMachinePool` are
  mutable, so `update` on them is enough. Restrict `create`/`update` on
  `terraform*` kinds and their templates to principals who already hold
  that. The controller
  checks only that `spec.source.image` is a syntactically valid image
  reference; it does not police which registry or repository it names. An
  admission policy on `spec.source.image` by registry prefix is the
  recommended control for restricting which images a namespace may run.
- **One identity and one workload cluster per tenant namespace.** Every
  `Terraform*` object in a namespace, and every image any of them names, can
  read the Secrets described below, including the credential mirrors of
  every other identity in use in that namespace and the state and inputs of
  every other object there. A namespace is the boundary between tenants;
  sharing one namespace between two tenants' clusters or identities gives
  each tenant everything described in this page for the other's cluster
  too.
- **Pod Security Admission applies to Jobs like any workload.** A namespace
  that enforces it gets the defaults described in
  [Pod security](#pod-security).

## Owner references are checked against the owner

CAPTF treats a Cluster API object as the owner of a `Terraform*` object only
when the owner references it back. For a `TerraformMachine`, the `Machine`
named by its `Machine`-kind `ownerReferences` entry must pass three checks:

- The Machine's `spec.infrastructureRef` names this `TerraformMachine`:
  matching `apiGroup`, `kind: TerraformMachine` and `name`. Cluster API
  sets it before it adds the owner reference, so every `TerraformMachine`
  Cluster API creates passes.
- When the `ownerReferences` entry carries a UID, it equals the Machine's
  UID.
- When the `TerraformMachine` has a `cluster.x-k8s.io/cluster-name` label,
  it equals the Machine's `spec.clusterName`.

`TerraformMachinePool` applies the same checks to its `MachinePool`, using
`spec.template.spec.infrastructureRef`, and `TerraformCluster` to its
`Cluster`, using `spec.infrastructureRef`.

An owner that fails any check is not an owner:
`DependenciesReady=False`/`OwnerMismatch` names the failed check, no Job
runs, and CAPTF writes nothing to that object or its Cluster: no
remediation annotation on a Machine, no replica count on a MachinePool.
Deleting the `Terraform*` object works as it does when its owner is gone:
destroy runs from the durable inputs.

The `TerraformMachine` delete webhook uses the same checks. It refuses a
direct delete only while an owner that passes them exists and is not being
deleted, so an object whose `ownerReferences` name a Machine that does not
own it can always be deleted.

`create` on a `terraform*` kind alone therefore runs nothing: a Job starts
only once a Cluster API object that references the new object exists. Who
may create those, and who may set `spec.source.image` on an owned object,
is what the section above describes.

## What the runner can read, and why

The runner ServiceAccount's permissions come from a single, static
ClusterRole bound namespace-by-namespace; see [RBAC](../operator-guide/rbac.md)
for the exact rules and how a custom ServiceAccount opts in. On Secrets, it
holds `get`, `list`, `create`, `update` and `delete`, and none of that is
scoped by name or label: the Terraform and OpenTofu Kubernetes state
backend needs `list` to enumerate its state chunks and workspaces on every
read and write, and `list` (like `create`) cannot be restricted to named
Secrets at all. `get`, `update` and `delete` could in principle be scoped
with `resourceNames`, but the backend names each state chunk itself, per
apply and per workspace, so no fixed rule can list them in advance. The
runner, and therefore any module image, can as a result read, replace or
delete every Secret in its namespace, which includes:

- the state and inputs Secrets of every `Terraform*` object in the
  namespace, not only the one the running Job belongs to;
- the credential mirrors (`captf-creds-*`) of every identity in use in the
  namespace, not only the one the running Job was given
  ([Secrets](../operator-guide/secrets.md) lists every Secret CAPTF reads or
  writes and its sensitivity);
- any CAPI core Secret in the namespace, such as a cluster's kubeconfig,
  certificate authority (CA) or a Machine's bootstrap data. Write access
  here means a hostile module can substitute a cluster's CA or kubeconfig,
  not only read them.

This is why one identity and one workload cluster per namespace, above, is
the only real isolation CAPTF offers between tenants sharing a management
cluster. The manager itself can also read every Secret in the cluster, as
any CAPI infrastructure provider that runs the Kubernetes state backend
effectively can.

## Image pinning by digest

The first time an apply Job of a `Terraform*` object **succeeds**, the
controller records the image digest the kubelet actually ran (read from the
pod's container status, not from `spec.source.image`) as `captf.io/image-digest`
on the object's durable inputs Secret; a failed apply pins nothing. See
[Annotations, Labels and Finalizers](../reference/annotations-labels.md) for
the annotation.

- `TerraformMachine` is immutable ([the kinds](kinds.md)): once pinned,
  every later drift check and destroy Job for that machine runs
  `repo@sha256:…`, never the tag in `spec.source.image`. A tag that moves
  after the successful apply can therefore never change the code that
  destroys an existing machine.
- `TerraformCluster` and `TerraformMachinePool` are mutable: each
  spec-driven apply re-resolves the tag and re-pins the digest it ran.

Pinning guards against an accident — a tag moved out from under a running
cluster changing what a later destroy runs — not against a hostile image:
the pinned digest is whichever image `spec.source.image` named when the
apply succeeded, and that image's own runtime computed the plan and ran the
providers. Approving a blocked destructive plan or a Manual-policy plan
preview is exactly as privileged as setting `spec.source.image`, since both
need `update` on the object; see
[Plan Approval](../user-guide/plan-approval.md).

CAPTF's own manager image is not signed, and nothing in CAPTF verifies a
module image's signature before running it: digest pinning fixes which
image ran after the fact, it does not check who published it.

## Pod security

The Job's pod defaults satisfy the Pod Security `baseline` profile without
any configuration: seccomp defaults to `RuntimeDefault`, and `fsGroup`
defaults to `65532` so a non-root image user can read the credential
files, mounted at mode `0440`, through that supplementary group
regardless of the image's own user or group. The main
container additionally defaults to `allowPrivilegeEscalation: false`,
`capabilities.drop: [ALL]` and `readOnlyRootFilesystem: true`, and the
runner's own init container is fixed non-root, fully locked down, and never
configurable. `runAsNonRoot` is **not** defaulted at the pod level, because
an image built `FROM hashicorp/terraform` runs as root unless it sets
`USER`; reaching the `restricted` profile needs an image that tolerates
`runAsNonRoot: true`, set through `jobs.podSecurityContext` or
`jobs.securityContext`.

Regardless of profile, the admission webhook rejects `privileged: true`,
`allowPrivilegeEscalation: true` and any `capabilities.add` in
`jobs.securityContext`, on every object and template that carries a jobs
policy (`spec.jobs`, `spec.defaults.jobs` on a `TerraformCluster`, and the
same field on a `TerraformMachine`, `TerraformMachinePool` and all three
`*Template` kinds), because that container holds the resolved identity's
cloud credentials. Pod Security Admission remains the namespace-wide control
for everything else a jobs policy does not set, such as host namespaces and
volume types.

## What CAPTF keeps out of status, events and logs

`Terraform*` object status is readable by anyone who can `get` the object —
far more people, in general, than can read Secrets in the namespace — so it
never carries raw process output. `status.lastRun.error.summary` is the
runner's own short description of a failure, at most 512 bytes, never the
failing step's stderr; the full output stays in the Job's own logs, which
need `pods/log` access to read. The events the runner emits on the object
(`RunStarted`, `StepStarted`, …, `RunFinished`; see
[Observability](../operator-guide/observability.md)) carry step names, exit
codes, durations and resource-change counts, and, on failure, the same
curated summary as status — never tfvars, plan output or resource values.

A module variable sourced from a Secret
([Module Variables](../user-guide/variables.md)) is automatically declared
`sensitive = true` in the generated root — one sourced from a ConfigMap or
given inline never is — so Terraform redacts it from the Job's own plan and
apply output and the controller redacts it from its own trace-level logs.
That redaction stops there: like every other input, the value is written
in clear into the object's durable and per-run inputs Secrets and into
the Terraform state Secret, so anyone who can read
Secrets in the namespace can read it in either place
([Secrets](../operator-guide/secrets.md),
[Job Inputs](inputs.md)). Cloud credentials never go through this path at
all: the resolved identity's credentials are mounted into the Job and never
rendered into a variable, so they never reach the inputs Secrets or the
state.

## Network exposure

CAPTF ships no `NetworkPolicy` by default; applying one is an opt-in step
covered in [Installation](../operator-guide/installation.md). Without it,
nothing restricts which pods the manager or a Job can reach, or which pods
can reach them, beyond whatever the cluster otherwise enforces.

The manager needs only inbound traffic to its webhook, metrics and
health-probe ports, and outbound traffic to DNS, the API server and the
registries it reads module image metadata from. A Job's pod is the more
sensitive workload: it holds the resolved identity's cloud credentials and
a ServiceAccount token that can write every Secret in its namespace
(above), so its egress is worth restricting to DNS, the API server, and the
specific provider and registry endpoints the module it runs needs — nothing
reaches it inbound. A `NetworkPolicy` only has an effect on a CNI that
enforces one.

## See also

- [Identities and Credentials](../user-guide/identities.md)
- [RBAC](../operator-guide/rbac.md)
- [Secrets](../operator-guide/secrets.md)
- [The Kinds](kinds.md)
