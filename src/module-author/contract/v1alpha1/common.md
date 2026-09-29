# Common

Applies to every role. Inputs here are injected by the controller; modules
MUST declare them (they may ignore them). Outputs here MUST be declared by
every role.

## Inputs

| Name | Type | Required | Value source |
| --- | --- | --- | --- |
| `captf_contract` | `string` | yes | Literal `"v1alpha1"`; lets a module assert the contract it was generated for |
| `captf_cluster` | `object` (below) | yes | The owning CAPI `Cluster` |
| `captf_object` | `object` (below) | yes | The Terraform* object being reconciled |
| `captf_cluster_outputs` | `any` | machine, machinepool only | The cluster role's `exports` output, read from the cluster state (below) |
| `captf_tags` | `map(string)` | yes | Fixed tag keys the controller always sets (below) |

```hcl
variable "captf_contract" { type = string }

variable "captf_cluster" {
  type = object({
    name      = string
    namespace = string
  })
}

variable "captf_object" {
  type = object({
    kind      = string        # TerraformCluster | TerraformMachine | TerraformMachinePool
    name      = string
    namespace = string
  })
}

variable "captf_cluster_outputs" {
  type    = any
  default = null
}

variable "captf_tags" { type = map(string) }
```

### `captf_cluster_outputs`

The value of the cluster role's `exports` output
([`cluster.md`](cluster.md#outputs)), read from the cluster state. Nothing
else from the cluster state is injected.

- **Not passed to the cluster role.** Its generated root declares no such
  variable and its tfvars carry no key, so a cluster module either leaves it
  undeclared or declares it with `default = null`, as the skeleton below
  does. A declaration without a default fails `validate`.
- **`{}` when the TerraformCluster is externally managed** (the
  `cluster.x-k8s.io/managed-by` annotation; the provider then never runs the
  cluster module, so there is no cluster state to read).
- A machine/pool whose owning Cluster's `spec.infrastructureRef` is not kind
  `TerraformCluster` is never rendered at all: it sets
  `DependenciesReady=False/ClusterNotTerraform` and does nothing, since
  there is no cluster state to read `exports` from.
- This is how a machine/pool module gets network ids, security groups,
  subnet ids and similar cluster-wide values. The cluster module puts them
  in its `exports` output; the controller reads the cluster state and
  injects exactly that value. `exports` may be marked `sensitive`: the
  generated root re-exports every contract output with `"sensitive": true`
  regardless, so a sensitive `exports` never fails `plan`, and sensitivity
  has no effect on the controller — the state Secret still stores the value
  in cleartext; only CLI display is affected (see
  [`README.md`](README.md#type-conventions) "Type conventions"). Machine/pool
  apply is gated on the cluster being provisioned and `exports` readable, so
  the value is complete by then.
- Because `captf_cluster_outputs` is `any`, a change in its content is
  **not** treated as a spec change for machines (immutable) but **is** for
  pools and clusters (a value change triggers a re-apply). See each role's
  Lifecycle section.

### `captf_tags`

Fixed keys the controller always sets: `captf.io/cluster` (Cluster name),
`captf.io/namespace`, `captf.io/kind` (the Terraform\* kind),
`captf.io/name` (the Terraform\* object name), `captf.io/managed-by` =
`captf`, and `captf.io/template`.

- **`captf.io/template`** is the value of the object's
  `cluster.x-k8s.io/cloned-from-name` annotation — the template it was
  cloned from by `external.GenerateTemplate`
  ([`util.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/controllers/external/util.go#L193-L245),
  [`common_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/common_types.go#L132-L136))
  — when present, else `""`. The key is always present: it is read from the
  Terraform* object's own metadata, so an object created directly gets
  `""`. It is hashed like the other keys even though annotations in general
  are not: `GenerateTemplate` writes it once at clone time, but for a
  TerraformCluster or TerraformMachinePool managed by topology, a
  ClusterClass rebase onto a differently named template rewrites the
  annotation through SSA, which re-applies that object once; for immutable
  machines it is pinned at first apply.
- Modules MUST apply these tags to every cloud resource they create that
  supports tags or labels, so resources can be attributed and
  garbage-collected out of band. This follows the CAPI provider best
  practices: a tagging/labeling mechanism for identifying cloud objects
  "MUST always be provided"
  ([`best-practices.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/best-practices.md);
  [`security-guidelines.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/security-guidelines.md),
  housekeeping).

### What is hashed

The controller re-applies mutable kinds when the hash of the rendered
inputs changes. **Rendered inputs are hashed inputs**: the hash covers a
canonical struct of exactly the *spec-derived* inputs the module receives,
and nothing is rendered outside it (the one special case is pool `replicas`
while `autoscaling.enabled`, rendered as the module's own observed desired
capacity; see [`machinepool.md`](machinepool.md#inputs)).

`captf_cluster` and `captf_object` therefore carry only kind, name and
namespace:

- no `uid` — a `clusterctl move` re-creates objects with new UIDs, and
  hashing them would re-apply every cluster and pool after a move;
- no `generation` — it changes whenever the controller itself writes
  `spec.providerID`, `providerIDList` or `controlPlaneEndpoint`;
- no `annotations` — they toggle around every Job
  (`clusterctl.cluster.x-k8s.io/block-move`) or are edited by GitOps tools;
- no `labels` — a metadata edit must never reconcile live infrastructure.

Cloud tags come only from `captf_tags`, whose keys are fixed. Drift for
mutable kinds renders the current hashed set; immutable machines render
drift and destroy from the durable inputs Secret below.

### Durable inputs

The rendered inputs (including `bootstrap_data`) are stored in a Secret
owned by the Terraform* object (`captf-inputs-<kindshort>-<name>`), so
drift and destroy of immutable machines re-feed exactly the values used at
apply, and the Secret moves with the object. The resolved image digest
(`captf.io/image-digest`, see
[`image-contract.md`](../../image-contract.md#versioning-and-pinning)
"Versioning and pinning") and the identity are pinned there too, so an
immutable machine's drift and destroy always run the exact image that
created it.

## User variables

Everything a module is parameterized by beyond the contract inputs
(instance type, disk size, subnets, a database password) is an ordinary
Terraform variable of the module. The object's owner sets it through
`spec.variables` (inline JSON) or `spec.variablesFrom` (ConfigMaps and
Secrets labeled `captf.io/variables=true`) on the TerraformCluster,
TerraformMachine or their templates; see
[Module Variables](../../../user-guide/variables.md) for the operator side.
For module authors:

- **Declare each one as an ordinary variable, with a type and a `default`.**
  The generated root passes a user variable as a named argument of
  `module "role"`, declared in the root **without a type**, so your
  declaration's type converts the value: a `number` variable accepts `40`
  inline and `"40"` from a ConfigMap. A variable nobody sets gets its
  `default`; without one, every object that does not set it fails `plan` on
  the missing argument. `tfcapi-lint` reports such a variable as
  `input/user-variable-default` (a warning: a module may deliberately
  require it).
- **Mark secrets `sensitive = true` in the module.** The root declares a
  variable `sensitive` only when its value came from a Secret; your
  declaration makes the value sensitive inside the module whatever its
  source. A value that arrives sensitive stays sensitive in everything
  derived from it: an output built from it must be declared
  `sensitive = true` (or `plan` fails with "Output refers to sensitive
  values"), and it cannot drive `for_each`. Either way the value is stored
  in cleartext in the inputs Secrets and in the state, like every input
  (see [Module Variables](../../../user-guide/variables.md)); credentials
  the module *runs with* come from the identity, never from a variable.
- **Names.** User variables are Terraform identifiers
  (`^[a-zA-Z_][a-zA-Z0-9_-]*$`). Reserved, and rejected before anything is
  rendered: every `captf_` name, every contract input of the module's role
  (`machine_name` on a machine, `control_plane_initialized` on a cluster,
  and so on) and the module meta-arguments `source`, `version`,
  `providers`, `count`, `for_each`, `depends_on`, `lifecycle`, `locals`. Do
  not rely on a user variable to carry a contract input's value.
- **Unknown names fail the apply.** A variable the object sets and the
  module does not declare is rejected by Terraform/OpenTofu (`Unsupported
  argument`; for the JSON root, `Extraneous JSON object property`). The
  controller does not check names against the image.
- **Hashing.** User variables are part of the inputs hash only when the
  object sets some, so modules and objects without them hash exactly as
  before. For a TerraformCluster a changed variable re-applies (guarded by
  the destructive-plan approval, see
  [`cluster.md`](cluster.md#lifecycle)); a TerraformMachine reads its
  variables until it is provisioned, and its later runs use the ones pinned
  in its durable inputs Secret, like every other input.
- The role input schemas (`schemas/*-inputs.json`) describe the contract
  inputs only; the rendered `terraform.tfvars.json` carries the user
  variables next to them.

## Outputs

| Name | Type | Required | Maps to |
| --- | --- | --- | --- |
| `health` | `object` (below) | yes | `Ready` condition; machine remediation; drift reporting |

```hcl
output "health" {
  value = {
    state   = "running"   # closed enum: pending | running | degraded | stopped | terminated | unknown
    healthy = true
    message = null        # optional string, surfaced in condition message
    reasons = []          # optional list(string), machine-readable
  }
}
```

`state` is a **closed enum**. Any other string is
`OutputsValid=False/OutputsInvalid`.

**Controller-side semantics.** `health` is written to the
`InfrastructureHealthy` condition. `InfrastructureHealthy` is one of the
explicitly listed inputs to the `Ready` summary; so is `Deleting` (negative
polarity, so `Ready=False` while a destroy runs). Drift results, drift-Job
outcomes, `Paused` and `DeletionBlocked` are not, so `Ready` — and therefore
the Cluster/Machine `InfrastructureReady` mirror that MachineHealthCheck
acts on — reflects infrastructure health, not controller housekeeping.

| `state` | `healthy` | `InfrastructureHealthy` | Effect |
| --- | --- | --- | --- |
| `pending` | any | `False/InstancePending` | Provisioning in progress; object not marked provisioned even if other outputs are set. While pending, the controller refreshes (`apply -refresh-only`) regardless of `drift.intervalSeconds`, so provisioning never waits for a drift tick: for cluster and machine, 30s after the last refresh, then 1m, 2m, 4m and at most every 5m while the readings stay pending (plus the object's jitter); for a machinepool, every 30s flat, since a pending pool is also not converged (see [`machinepool.md`](machinepool.md#lifecycle) "Membership refresh") |
| `running` | `true` | `True/Healthy` | `Ready=True` once role outputs are satisfied |
| `running` | `false` | `False/InstanceUnhealthy` | machine: remediation candidate |
| `degraded` | any | `False/InstanceDegraded` | machine: remediation candidate |
| `stopped` | any | `False/InstanceStopped` | machine: remediation candidate |
| `terminated` | any | `False/InstanceTerminated` | machine: remediation candidate; object stays provisioned and `spec.providerID` is kept |
| `unknown` | any | `Unknown/HealthUnknown` | `Ready=Unknown`; no remediation |

Once provisioned, the Machine controller treats an empty InfraMachine
`spec.providerID` as "waiting" and logs it; it is not a hard error, but
clearing it would stall the Machine
([`machine_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machine/machine_controller_phases.go)
`reconcileInfrastructure`), so a `terminated` reading keeps `providerID`
rather than clearing it.

- `health` is re-read on every refresh (`apply -refresh-only`, which
  updates state and root output values to match remote objects; see
  [OpenTofu docs: `cli/commands/plan/`](https://opentofu.org/docs/cli/commands/plan/)
  "Planning Modes"): the pending refresh loop above, every drift tick, and
  for pools the membership refresh (see
  [`machinepool.md`](machinepool.md#lifecycle)). For immutable machines
  that is the only way it changes after apply. Modules that cannot observe
  health return `{state="running", healthy=true}` (the no-op module does
  this) or `unknown`.
- **Out-of-band termination.** If, after provisioning, a refresh makes
  `provider_id` come back `null` (the resource vanished from state) or the
  refresh itself fails because the instance is gone, the controller treats
  that as `terminated`: `InfrastructureHealthy=False/InstanceTerminated`,
  `spec.providerID` kept. Modules SHOULD still report `terminated`
  explicitly where the cloud API exposes it, because detection through a
  vanished resource is slower (drift interval plus a Job) and CAPI's
  Node-based checks will usually fire first.
- A group with zero members (pool role, `replicas == 0`) reports
  `{state="running", healthy=true}`.
- Only the machine role triggers remediation. Cluster/pool `health` feeds
  conditions only.

## Role-specific inputs

`kubernetes_version` is a role input, not a common one: for machines/pools
it comes from `Machine.spec.version` / `MachinePool.spec.template.spec.version`
(authoritative for nodes); for the cluster role it comes from
`Cluster.spec.topology.version` (null without ClusterClass; see
[`cluster.md`](cluster.md#inputs)). `cluster_network`,
`control_plane_initialized` and the non-module `control_plane_endpoint`
(including one set later by a control-plane provider) are cluster-role
inputs (see [`cluster.md`](cluster.md#inputs)); machine/pool modules get
endpoint-derived values through `exports`.
