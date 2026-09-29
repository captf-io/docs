# MachinePool Role

Implements the CAPI InfraMachinePool contract
([`infra-machinepool.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machinepool.md);
MachinePool types in
[`machinepool_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/machinepool_types.go))
for a `TerraformMachinePool`. One workspace/state per
`TerraformMachinePool`. The module manages a **native scaling group** (an
ASG, VMSS, MIG, instance pool, or similar) and reports the group id, the
list of provider IDs currently in it, and the desired capacity. Mutable:
re-applied on spec or replica changes.

The v1 controller implements fixed replicas and native autoscaling
(`autoscaling.enabled`). It does not watch the bootstrap Secret: a rotated
token reaches the pool at its next reconcile, at the latest one
membership-refresh interval later (see "Bootstrap rotation" below). Drift
relies entirely on the module's own `ignore_changes`: the drift Job already
runs `apply -refresh-only` then `plan -detailed-exitcode` for every kind,
and the controller does no plan-JSON filtering of the result — an
autoscaled pool's module MUST put its desired-count attribute under
`lifecycle { ignore_changes = [...] }` (see Lifecycle and the
`autoscaling` input) or a cloud-side scale reports as drift.

MachinePool Machines
(`status.infrastructureMachineKind`; optional,
[`infra-machinepool.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machinepool.md)
"MachinePoolMachines support") are out of scope. Two consequences follow:
there is **no drain** on scale-down, replacement or version roll — drain
exists only for Machines
([`infra-machinepool.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machinepool.md)
"MachinePoolMachines support ... draining a node before scale down"), so
modules SHOULD use native lifecycle hooks or termination handlers instead —
and MachineHealthCheck never selects pool instances.

## Inputs

Common inputs apply ([`common.md`](common.md#inputs)), including
`captf_cluster_outputs`.

| Name | Type | Required | Value source |
| --- | --- | --- | --- |
| `machinepool_name` | `string` | yes | Owning CAPI `MachinePool.metadata.name` |
| `replicas` | `number` | yes | The desired capacity of the group (below) |
| `bootstrap_data` | `string`, `sensitive` | yes | Base64 of the bootstrap Secret's `value` key (below) |
| `bootstrap_format` | `string` | yes | as machine role; the `format` key is kubeadm-specific, not contract (see [`machine.md`](machine.md#bootstrap_format)) |
| `failure_domains` | `list(string)` | yes (may be `[]`) | `MachinePool.spec.failureDomains` (below) |
| `cluster_failure_domains` | `list(string)` | yes (may be `[]`) | Names from the cluster's own state (below) |
| `kubernetes_version` | `string` or `null` | yes (may be null) | `MachinePool.spec.template.spec.version` (below) |
| `node_labels` | `map(string)` | yes (may be `{}`) | `MachinePool.spec.template.metadata.labels` verbatim (below) |
| `autoscaling` | `object({enabled=bool, min=number, max=number})` | yes | Parsed from the MachinePool autoscaler annotations (below) |

### `replicas` (input)

The **desired capacity** of the group.

- With `autoscaling.enabled = false`: `MachinePool.spec.replicas`,
  authoritative and in the inputs hash (`*int32`, "Defaults to 1"; the
  pointer distinguishes an explicit 0 from unset, and 0 is allowed).
- With `autoscaling.enabled = true`: `TerraformMachinePool.status.replicas`
  (the *observed* desired capacity from the last refresh) once one exists,
  else `MachinePool.spec.replicas` for the first apply before any refresh
  has run — either way **clamped into `[autoscaling.min, autoscaling.max]`**
  so a render never asks the cloud for an out-of-range desired count. The
  clamp applies only to this rendered input; the write-back (Lifecycle)
  always writes the raw observed value, unclamped.

`replicas` is excluded from the inputs hash while `autoscaling.enabled`, so
a non-replica-triggered apply (bootstrap rotation, module change, `exports`
change) never fights the native autoscaler, and an observed-count change
alone never triggers `InputsChanged`; a fixed-replica pool hashes
`replicas` exactly as before.

### `bootstrap_data` (input)

**Base64** of the raw bytes of the `value` key of the bootstrap Secret
named by `MachinePool.spec.template.spec.bootstrap.dataSecretName`
(`template` is `MachineTemplateSpec`; see
[`bootstrap-config.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/bootstrap-config.md)),
encoded by the controller for every bootstrap provider exactly as for the
machine role (see [`machine.md`](machine.md#bootstrap_data)
`bootstrap_data`: CAPRKE2 `gzipUserData: true` makes `value` raw gzip
bytes that cannot be a `string`).

Modules pass it to a base64-taking launch-configuration argument (for
example `aws_launch_template.user_data`, which expects base64) or
`base64decode()` it for a plain-text argument (UTF-8 payloads only).
Hashed by content; `dataSecretName: ""` is treated as nil
(`WaitingForBootstrapData`).

**Rotates.** For MachinePools the kubeadm bootstrap provider re-creates the
join token when it is past half its TTL (default TTL 15m, checked every
TTL/3) and rewrites the same Secret in place, roughly every 7.5 minutes
([`token.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/bootstrap/kubeadm/reconcilers/kubeadmconfig/token.go)
`refreshBootstrapTokenIfNeeded`/`recreateBootstrapToken`;
`kubeadmconfig_controller.go` `storeBootstrapData`). See Lifecycle for what
that requires from modules.

### `failure_domains` (input)

`MachinePool.spec.failureDomains` (at most 100 items, each 1–256 chars).
`[]` means the module chooses. To make that choice informed, the cluster's
failure-domain names are injected as `cluster_failure_domains` (below); the
full `attributes` maps are only available through `exports`.

### `cluster_failure_domains` (input)

Names read from the cluster's own state, off the `failure_domains` output
(see [`cluster.md`](cluster.md#outputs)) at render time — **not** from
`TerraformCluster.status.failureDomains` — so a pool module can spread
across all of them when `failure_domains` is `[]` without depending on
`exports` conventions. Sourcing it from state rather than status keeps it
stable across `clusterctl move` (status is not moved, and is empty until
the target's first cluster reconcile); it stays in the inputs hash.

### `kubernetes_version` (input)

`MachinePool.spec.template.spec.version`. A change MUST roll the instances
(see Lifecycle). As with the machine role, the value may carry a
control-plane-provider-specific distro suffix (RKE2: `vX.Y.Z+rke2rN`, for
example `v1.31.4+rke2r1`); the controller passes it to the module
**verbatim**, and a module that needs it for an image lookup or a semver
comparison MUST strip the `+…` suffix itself (see
[`machine.md`](machine.md#kubernetes_version-input) and [the RKE2ControlPlane
guide](../../control-planes/rke2.md)).

### `node_labels` (input)

`MachinePool.spec.template.metadata.labels` verbatim (absent maps to
`{}`). Pool instances have no Machine objects, so core CAPI never syncs
labels onto their Nodes; the module MUST render these into kubelet
registration (`--node-labels`) itself. `node_labels` is in the inputs
hash, so an edit re-applies: new members pick it up, and existing members
keep their registration.

**The precise requirement and why it is not simple.** `bootstrap_data` is
opaque (see [`machine.md`](machine.md#bootstrap_data) "the module MUST NOT
need to parse the payload") and, depending on the bootstrap provider and
its settings, may be plain cloud-config, plain Ignition, or gzip of
either. The module cannot edit the kubelet flags *inside* that payload
without parsing it, which the contract forbids. The realistic options,
in order of how much of `bootstrap_data` they need to understand:

- **Cloud-config, uncompressed (`bootstrap_format == "cloud-config"`,
  CAPRKE2 `gzipUserData` unset or `false`):** wrap `bootstrap_data` and a
  second, module-generated part in a `multipart/mixed` MIME message (for
  example Terraform's `cloudinit_config` data source, or an equivalent
  built by hand) so cloud-init runs both parts at boot. The second part
  writes a kubelet drop-in with `--node-labels`:

  ```hcl
  data "cloudinit_config" "node" {
    gzip          = false
    base64_encode = true

    part {
      content_type = "text/cloud-config"
      # bootstrap_data is base64 of the raw payload (machine.md); decode it
      # only because this part must stay unmodified UTF-8 cloud-config, not
      # to parse or edit it.
      content = base64decode(var.bootstrap_data)
    }

    part {
      content_type = "text/cloud-config"
      content = yamlencode({
        write_files = [{
          path    = "/etc/systemd/system/kubelet.service.d/20-node-labels.conf"
          content = "[Service]\nEnvironment=\"KUBELET_EXTRA_ARGS=--node-labels=${join(",", [for k, v in var.node_labels : "${k}=${v}"])}\"\n"
        }]
      })
    }
  }
  # data.cloudinit_config.node.rendered is base64 multipart/mixed; pass it
  # to the same user-data argument bootstrap_data alone would have gone to.
  ```

  RKE2's agent config has the same shape through a second part that drops
  a file under `/etc/rancher/rke2/config.yaml.d/*.yaml` with a
  `node-label:` list, merged by the RKE2 agent at boot alongside the
  bootstrap part's own `/etc/rancher/rke2/config.yaml`.
- **Ignition (`bootstrap_format == "ignition"`) or a gzipped payload
  (CAPRKE2 `gzipUserData: true`):** neither is multipart-mixable the same
  way — Ignition has its own merge/append config mechanism, and a gzipped
  payload must be decompressed, edited or merged, and recompressed (or
  passed through a launch-configuration field that decompresses it
  itself). These need format-aware handling specific to the format; there
  is no one wrapper that covers them.
- A module MAY instead declare, in its own documentation, only the
  `bootstrap_format`/compression combinations it supports, and fail loudly
  (a precondition, or an unsupported-value error) on the others, rather
  than silently dropping `node_labels`.

Labels the kubelet may not self-assign (the `node-role.kubernetes.io/*`
and other restricted `kubernetes.io`/`k8s.io` prefixes under
`NodeRestriction`) are the module's to filter.

There is no taints input: the v1.14.2 MachinePool webhook rejects any
`spec.template.spec.taints` ("taints feature for MachinePools is not yet
implemented",
[`machinepool.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/webhooks/admission/machinepool.go#L171-L175);
`MachineTaintPropagation` is off by default,
[`feature.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/feature/feature.go#L111)).

### `autoscaling` (input)

Parsed from the MachinePool annotations
`cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size` and
`-max-size`
(`AutoscalerMinSizeAnnotation`/`AutoscalerMaxSizeAnnotation`,
[`common_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/common_types.go)).
This is the pool's **only** autoscaling switch; there is no separate drift
flag.

`enabled=true` with both `min`/`max` parsed if and only if both annotations
are present and `0 ≤ min ≤ max`; otherwise `{enabled=false, min=0, max=0}`
(no annotations sets `AutoscalingActive=False/AutoscalingDisabled`), plus,
when an annotation is present but the pair is incomplete, unparsable or
`min > max`, the condition `AutoscalingActive=False/AutoscalingAnnotationsInvalid`
(the pool still applies without autoscaling; `AutoscalingActive` never
feeds `Ready`).

**How this differs from CAPI's own reading of the same annotations.** CAPI
already reads these annotations on MachinePools, but only in a narrower
path than ours: the MachinePool admission webhook defaults and clamps
`spec.replicas` from them **only when `spec.replicas` is nil** (an explicit
value, including 0, is left alone), **requires both annotations to be
present**, rejects the create/update outright if either annotation is
unparsable, and does **not** reject `min > max` — our controller does,
via `AutoscalingAnnotationsInvalid`
([`machinepool.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/webhooks/admission/machinepool.go#L187-L252),
`calculateMachinePoolReplicas`, called from `Default`) — which is what
makes them a sound source for the initial size. Our controller does not
rely on the webhook: it reads the annotations itself on every reconcile
for `autoscaling.min`/`.max`, and treats a missing or invalid annotation as
`enabled=false` plus `AutoscalingActive=False/AutoscalingAnnotationsInvalid`
rather than rejecting anything.

**`enabled` means the module owns the desired count and its scaling
policy:** it sets the group's min/max to these values, configures whatever
native scaling policy it wants (target tracking, scheduled, and so on),
and MUST put the group's desired-count attribute under
`lifecycle { ignore_changes = [...] }` so an apply never resets what the
cloud autoscaler decided.

On the CAPI side the controller then claims
`cluster.x-k8s.io/replicas-managed-by: captf` on the MachinePool when the
annotation is absent or `"false"` (`ReplicasManagedByAnnotation`; CAPI
counts the annotation as set for **any value except the literal string
`"false"`**, `hasTruthyAnnotationValue`,
[`helpers.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/util/annotations/helpers.go#L133-L141),
called by `ReplicasManagedByExternalAutoscaler` — a foreign truthy value is
left alone, never overwritten), and, on every reconcile pass on which
`status.replicas` is known and differs from `MachinePool.spec.replicas`,
writes the raw observed desired capacity back to `MachinePool.spec.replicas`.
The InfraMachinePool docs make this the provider's job
([`machine-pool.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/core/controllers/machine-pool.md)
"It is the provider's responsibility to update Cluster API's Spec.Replicas
property to the value observed"); see Lifecycle "Write-back" for the exact
rules. With the annotation set, the MachinePool controller reports phase
`Scaling` instead of `ScalingUp`/`ScalingDown`
([`machinepool_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machinepool/machinepool_controller_phases.go)).

The Kubernetes Cluster Autoscaler does not act on these pools: its
`clusterapi` provider requires MachinePool Machines
([`README.md`](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/clusterapi/README.md)),
which this role excludes. Running it against a CAPTF pool anyway is
unsupported, because its `spec.replicas` patches would be overwritten by
the write-back.

## Outputs

Common outputs apply (`health`).

| Name | Type | Required | Maps to |
| --- | --- | --- | --- |
| `provider_id` | `string` or `null` | yes (may be null) | `TerraformMachinePool.spec.providerID`, the scaling-group id (below) |
| `provider_id_list` | `list(string)` | yes (may be `[]`) | `TerraformMachinePool.spec.providerIDList` → `MachinePool.spec.providerIDList` (below) |
| `replicas` | `number` | yes | The group's observed desired capacity (below) |
| `instances` | `list(object({provider_id=string, instance_id=optional(string), addresses=optional(list(object({type=string, address=string})), []), failure_domain=optional(string), state=optional(string)}))` | yes (may be `[]`) | `TerraformMachinePool.status.instances` (below) |

### `provider_id` (output)

Maps to `TerraformMachinePool.spec.providerID` — the scaling-group id;
optional in the contract and not used by core CAPI, 1–512 chars
([`infra-machinepool.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machinepool.md)
"InfraMachinePool: providerID"). May stay null for group-less
implementations.

### `provider_id_list` (output)

Maps to `TerraformMachinePool.spec.providerIDList` →
`MachinePool.spec.providerIDList` (mandatory; at most 10000 items, each
1–512 chars;
[`infra-machinepool.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machinepool.md)
"InfraMachinePool: providerIDList"). Rules:

1. It MUST contain **every non-terminated member** of the group regardless
   of health — pending, starting, standby, rebooting or unhealthy
   instances included — because CAPI deletes the Node of any providerID
   that leaves the list
   ([`machinepool_controller_noderef.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machinepool/machinepool_controller_noderef.go)
   `deleteRetiredNodes`; only an empty list with `status.replicas != 0` is
   guarded,
   [`machinepool_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machinepool/machinepool_controller_phases.go)).
   Listing only "running" or "healthy" instances kills live Nodes.
2. Each entry MUST equal the Node's `spec.providerID` exactly
   ([`machinepool_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/machinepool_types.go)
   `providerIDList` "must match the provider IDs as seen on the node
   objects"; see [`machine.md`](machine.md#node-providerid-matching-module-authors)
   "Node providerID matching"), otherwise Nodes never get a nodeRef, keep
   the `node.cluster.x-k8s.io/uninitialized:NoSchedule` taint that the
   kubeadm bootstrap provider applies, and are eventually deleted.
3. Order is irrelevant to CAPI: the controller sorts and de-duplicates
   before writing, since CAPI compares the list with `reflect.DeepEqual`
   and any reorder churns status (CAPD sorts too). `tfcapi-lint` still
   warns (`output/provider-id-list-shape`) when the output's own
   expression is not wrapped in `sort()` or `distinct()`, because a module
   is applied and refreshed independently of the controller's write path:
   an unsorted expression makes `provider_id_list` reorder between
   identical `apply -refresh-only` runs, which is a plan diff (and, for a
   module whose desired-count is not `ignore_changes`d, spurious drift)
   even though the controller's own write is stable. Wrap the output's
   `value` expression itself — the check inspects that expression
   directly, not a local it reads from:

   ```hcl
   output "provider_id_list" {
     value = sort(local.raw_ids) # or distinct(...), or both
   }
   ```

   `value = local.sorted_ids` does not satisfy the check even when
   `sorted_ids` is itself `sort(...)`-derived, and JSON-syntax modules are
   not scanned at all. Either `sort()` or `distinct()` alone satisfies it;
   the controller sorts and de-duplicates regardless of which the module
   uses.

### `replicas` (output)

The group's **desired capacity** as observed at refresh, not a count of
running instances. Maps to `TerraformMachinePool.status.replicas` →
`MachinePool.status.replicas`
([`infra-machinepool.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machinepool.md)
"InfraMachinePool: replicas"; read in
[`machinepool_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machinepool/machinepool_controller_phases.go)).
Without MachinePool Machines, CAPI sets the MachinePool's
`readyReplicas`/`availableReplicas` equal to this value
([`machinepool_controller_status.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machinepool/machinepool_controller_status.go));
only the deprecated v1beta1 `readyReplicas` is Node-based.

Outside a scaling transition it MUST equal `length(provider_id_list)`; the
controller derives `status.replicas` from this output and serializes `0`
explicitly (a missing value would make CAPI keep the old count and block
scale-to-zero forever,
[`machinepool_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machinepool/machinepool_controller_phases.go)).

### `instances` (output)

Maps to `TerraformMachinePool.status.instances` — optional, provider-defined
shape, not used by core CAPI
([`infra-machinepool.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machinepool.md)
"InfraMachinePool: instances"; the contract's own example shape is
`{addresses, instanceName, providerID, version, ready}`, ours differs,
which is allowed).

One Go type, `MachinePoolInstance{ProviderID, InstanceID, Addresses
[]MachineAddress, FailureDomain, State}`, maps field by field:
`provider_id`→`providerID`, `instance_id`→`instanceID`,
`addresses`→`addresses` (validated like the machine role's),
`failure_domain`→`failureDomain`, `state`→`state` (the `health.state`
enum).

**Size.** `providerIDList` alone may reach 10000×512 bytes, and an object
must stay under the etcd request limit of roughly 1.5 MiB, so the
controller caps `status.instances` at 1000 entries (reported as
`OutputsValid=True/InstancesTruncated` when it does), and the documented
practical pool size is at most 2000 members.

### Provisioned rule

`status.initialization.provisioned = true` — and, for as long as CAPI
v1.14 reads it, `status.ready = true`; the MachinePool controller decides
provisioning solely from `status.ready`
([`machinepool_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machinepool/machinepool_controller_phases.go)
via `external.IsReady`, and CAPD still sets it) — when the state Secret
carries the inputs-hash annotation of a successful apply and
`health.state != "pending"`. `provider_id` is **not** required, since the
contract makes it optional. `provider_id_list` may legitimately be empty
when `replicas == 0`, and a 0-member group reports `running`/healthy (see
[`common.md`](common.md#outputs)).

**Latched.** The formula applies only until it first holds; once true,
`provisioned` and `status.ready` stay true for the object's life, whatever
later health or outputs say. It is derived from state only, so it is
rebuilt after `clusterctl move` (the formula is re-evaluated once on the
target, then latched again); CAPI does not latch its copy, so the
MachinePool shows `infrastructureProvisioned=false` briefly after a move
until the first reconcile on the target.

Separately, CAPI copies `TerraformMachinePool.spec.providerIDList`/`status.replicas`
to the MachinePool only after `ClusterCache.GetClient` succeeds — that is,
only once the workload cluster is reachable
([`machinepool_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machinepool/machinepool_controller_phases.go#L297-L300));
until then the TerraformMachinePool side is correct but the MachinePool
does not reflect it.

## Lifecycle

- **Mutable.** Re-apply on: a `spec.source` change (image, pull policy); a
  `replicas` change on the MachinePool (unless `autoscaling.enabled`, where
  `replicas` is excluded from the inputs hash and a user edit of
  `MachinePool.spec.replicas` is overwritten by the write-back, surfaced as
  an event); a `failure_domains` change; a `node_labels` change (applied
  like `bootstrap_data`: a launch-configuration update, no instance
  replacement); a `kubernetes_version` change; a `bootstrap_data` change;
  or a `captf_cluster_outputs` content change. Every apply, including a
  drift `Remediate`, re-renders the **current** inputs; nothing is
  replayed from an older run.
- **Bootstrap rotation.** Because the kubeadm bootstrap provider rewrites
  the pool's bootstrap Secret roughly every 7.5 minutes (`bootstrap_data`
  above), a pool is re-applied at that cadence for the life of the pool.
  The controller does not watch the bootstrap Secret — it is not
  `captf.io/managed`, so it is not in the cache — so a rotated token
  reaches the pool at its next reconcile, at the latest one
  membership-refresh interval later, and is then coalesced into the next
  apply. Module rules that make this cheap and safe:
  - a `bootstrap_data` change MUST be applied as an in-place update of the
    group's launch configuration (a launch template version, instance
    template, or VMSS model) so that *new* members get the current token,
    and MUST NOT replace existing instances;
  - a `kubernetes_version` change MUST roll (replace) the instances,
    because a ClusterClass upgrade completes only when the Nodes' kubelet
    versions match
    ([`upgrade.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/internal/topology/check/upgrade.go)
    `IsMachinePoolUpgrading`; CAPD's DevMachinePool rolls on version only
    and never on bootstrap data,
    [`dockermachinepool_backend.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/test/infrastructure/docker/internal/controllers/backends/docker/dockermachinepool_backend.go));
  - modules SHOULD expose no other trigger that replaces instances on an
    apply with unchanged `kubernetes_version`.

  Each rotation re-applies the pool, so a module that never converges (see
  below) is applied roughly every 7.5 minutes indefinitely, on top of its
  30s refresh cadence.
- **Membership refresh.** `provider_id_list`, `replicas`, `instances` and
  `health` are only as fresh as the last apply or refresh, and a Node
  joining the group is unschedulable until its providerID appears in
  `MachinePool.spec.providerIDList` — CAPI removes the kubeadm-applied
  `node.cluster.x-k8s.io/uninitialized:NoSchedule` taint only then
  ([`machinepool_controller_noderef.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machinepool/machinepool_controller_noderef.go)).
  The controller therefore runs `apply -refresh-only` on its own
  **membership-refresh interval**, `spec.membershipRefreshIntervalSeconds`
  (default 60, 15–86400, may not be 0), and additionally right after every
  apply and repeatedly (every 30s) while `health.state == "pending"` or
  `length(provider_id_list) != replicas` — a module that never converges is
  therefore refreshed every 30s indefinitely. `drift.intervalSeconds: 0` is
  rejected by the CRD schema (minimum 1) for a pool's own field, by
  contrast with a machine's or the cluster's `drift.intervalSeconds`, where
  0 is a valid setting that disables drift; an inherited
  `defaults.drift.intervalSeconds: 0` (unset) falls back to the
  controller's default drift interval (`--drift-default-interval`, 30m)
  rather than to 0. Drift may be sparse but membership never is.
- **Drift order.** Drift for a pool is the same job every other kind
  runs — `apply -refresh-only` first, then `plan -detailed-exitcode`
  ([`internal/runner/plan.go`](https://github.com/scrothers/cluster-api-provider-terraform/blob/main/internal/runner/plan.go))
  — and the controller does no plan-JSON filtering of the result: whatever the
  refreshed plan reports is drift. This is why the desired-count
  `lifecycle { ignore_changes = [...] }` in the `autoscaling` input is
  load-bearing, not optional: with `autoscaling.enabled`, the module owns
  the desired count, and a module that does not `ignore_changes` it
  reports every cloud-side scale as drift. With `Remediate` a detected
  diff re-applies the pool; with `autoscaling.enabled = false` that scales
  the group back to `MachinePool.spec.replicas` — the only mode where the
  module doesn't already `ignore_changes` the desired count.
- **Write-back (`autoscaling.enabled`).** On every reconcile pass, one
  patch (`SyncReplicas`): the controller claims
  `cluster.x-k8s.io/replicas-managed-by: captf` on the MachinePool when the
  annotation is absent or `"false"` (a foreign truthy value already means
  another controller manages it, and is left untouched), and when
  `status.replicas` is known and differs from `MachinePool.spec.replicas`,
  writes the raw observed value (unclamped by `[min,max]`, unlike the
  rendered `replicas` input) to `spec.replicas` in the same patch. A
  `ReplicasWrittenBack` Normal event is emitted on the
  TerraformMachinePool whenever a write happens. With
  `autoscaling.enabled = false`, the controller removes
  `replicas-managed-by` only if it still carries `captf` (never a foreign
  value), and never writes `spec.replicas`. Without the write-back, CAPI
  would report `ScalingUp`/`ScalingDown` forever and `upToDateReplicas`
  would follow the stale spec
  ([`machinepool_controller_status.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machinepool/machinepool_controller_status.go)).
  A ClusterClass-managed MachinePool MUST leave `replicas` unset in the
  topology for this to work — the topology controller would otherwise
  reassert it every reconcile, fighting the write-back.

  **Module note.** Because `lifecycle { ignore_changes }` cannot be
  conditional on a variable, a module that supports both
  `autoscaling.enabled = true` and `= false` from the same scaling-group
  resource should, when disabled, pin the group's `min_size`/`max_size` to
  `var.replicas` — not to `var.autoscaling.min`/`.max`, which are `0` when
  disabled — so the same `ignore_changes` block still lets the group track
  `replicas` exactly.
- **Health.** `health` feeds conditions only; there is no remediation for
  pools in v1 (MHC selects Machines, and pool replicas only have Machines
  under MachinePool Machines, which this role excludes;
  [`infra-machinepool.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machinepool.md)
  "MachinePoolMachines support"). Instances terminated by the cloud simply
  leave `provider_id_list` at the next refresh, and CAPI deletes their
  Nodes.
- **Delete.** A `destroy` Job renders from the object-owned
  `captf-inputs-<kindshort>-<name>` Secret, not from the bootstrap Secret:
  CAPI deletes the bootstrap config and the InfraMachinePool in the same
  pass
  ([`machinepool_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machinepool/machinepool_controller_phases.go)
  `reconcileDeleteExternal`), so the bootstrap Secret is usually already
  gone when destroy runs. Then the controller drops state, the Lease and
  the inputs Secret, and removes the finalizer.

  **Node cleanup is partial.** On MachinePool deletion, CAPI deletes only
  the Nodes whose providerIDs are *absent* from the last-seen
  `providerIDList` (`reconcileDeleteNodes` → `deleteRetiredNodes`,
  [`machinepool_controller_noderef.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machinepool/machinepool_controller_noderef.go));
  Nodes still listed survive and are removed by the cloud-controller-manager
  once their instances are gone, or remain as orphans without a CCM. A
  module MAY empty `provider_id_list` on the final refresh before destroy,
  but the controller does not depend on it.

## Minimal skeleton

A block written on one line may hold at most one argument
([`OneLineBlock`](https://github.com/hashicorp/hcl/blob/main/hclsyntax/spec.md);
`tofu validate` reports "Invalid single-argument block definition" on a
violation), so a variable that needs both `type` and `sensitive`, or
`type` and `default`, must use the multi-line block form below.

```hcl
variable "captf_contract"        { type = string }
variable "captf_cluster"         { type = object({ name = string, namespace = string }) }
variable "captf_object"          { type = object({ kind = string, name = string, namespace = string }) }
variable "captf_cluster_outputs" {
  type    = any
  default = null
}
variable "captf_tags" { type = map(string) }

variable "machinepool_name" { type = string }
variable "replicas" { type = number }
variable "bootstrap_data" { # base64 of the bootstrap Secret's `value`; e.g. launch template user_data = var.bootstrap_data
  type      = string
  sensitive = true
}
variable "bootstrap_format" { type = string }
variable "node_labels" { type = map(string) }
variable "failure_domains" { type = list(string) } # always set, may be []; no default (input/default)
variable "cluster_failure_domains" { type = list(string) } # always set, may be []; no default (input/default)
variable "kubernetes_version" {
  type    = string
  default = null
}
variable "autoscaling" { type = object({ enabled = bool, min = number, max = number }) }

# Tag every cloud resource this module creates with captf_tags (common.md
# "captf_tags"); this stub only has to reference it, not create anything.
resource "terraform_data" "tags" { input = var.captf_tags }

locals {
  # Unsorted; provider_id_list must wrap sort()/distinct() directly in its
  # own output expression: see "provider_id_list order" below.
  raw_ids = [for i in range(var.replicas) : "noop:///${var.captf_object.namespace}/${var.captf_object.name}/${i}"]
}

output "provider_id"      { value = "noop-group:///${var.captf_object.namespace}/${var.captf_object.name}" }
output "provider_id_list" { value = sort(local.raw_ids) }
output "replicas"         { value = var.replicas }
output "instances"        { value = [for id in sort(local.raw_ids) : { provider_id = id, state = "running" }] }
output "health"           { value = { state = "running", healthy = true, message = null, reasons = [] } }
```

A real module with `autoscaling.enabled` sets the group's
`min_size`/`max_size` from `var.autoscaling`, its `desired_capacity` from
`var.replicas`, and declares `lifecycle { ignore_changes = [desired_capacity] }`
on the group resource; `output "replicas"` then reads the group's
*current* desired capacity from the resource (refreshed by
`apply -refresh-only`), not `var.replicas`.

## Per-instance state

`instances[*].state` uses the `health.state` enum (see
[`common.md`](common.md#outputs)) so per-instance conditions can be
derived later.

**Deriving group `health` from mixed instance states.** The controller does
not aggregate `instances[*].state` into `health` itself: `health` is copied
to the `InfrastructureHealthy` condition, and `instances` is copied to
`status.instances` (capped, see "Size" above), with no cross-referencing
between the two — a module that reports a healthy `health` and a list full
of `degraded` instances gets a healthy `InfrastructureHealthy` and a
degraded-looking `status.instances`, since nothing else reconciles the
difference. A pool module SHOULD derive `health` from the instances it is
about to report:

- `healthy = true`, `state = "running"` when the group has reached its
  desired capacity and every counted instance's own state is `running`;
- `healthy = false`, `state` reflecting the worst instance (for example
  `degraded` if any instance is `degraded`, else `stopped`, and so on down
  the enum) with `reasons` naming the affected instances, when some
  instances are not `running`;
- `state = "pending"` only while the group itself does not yet exist or
  has no members to report at all — not merely while some members are
  still starting, since `length(provider_id_list) != replicas` already
  forces the controller's fast (30s) refresh loop on its own (see
  "Membership refresh" below), so a module does not need `health.state =
  "pending"` to get that cadence during a scale-up or scale-down.

This is a SHOULD, not a MUST: a module that cannot observe per-instance
health may still report `{state="running", healthy=true}` as long as the
group itself is healthy (see [`common.md`](common.md#outputs)).
