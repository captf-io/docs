# Machine Role

Implements the CAPI InfraMachine contract
([`infra-machine.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machine.md))
for a `TerraformMachine`. One workspace/state per `TerraformMachine`. The
module creates exactly one node instance and reports its provider ID,
addresses, and health. The machine is immutable (`spec.source` and
`spec.identityRef` cannot change): apply once, refresh/drift for health,
destroy on delete.

## Inputs

Common inputs apply ([`common.md`](common.md#inputs)), including
`captf_cluster_outputs`.

| Name | Type | Required | Value source |
| --- | --- | --- | --- |
| `machine_name` | `string` | yes | Owning CAPI `Machine.metadata.name` (the TerraformMachine name may differ) |
| `bootstrap_data` | `string`, `sensitive` | yes | Base64 of the bootstrap Secret's `value` key (below) |
| `bootstrap_format` | `string` | yes | `cloud-config` or `ignition`, from the bootstrap Secret's `format` key (below) |
| `failure_domain` | `string` or `null` | yes (may be null) | `Machine.spec.failureDomain` (below) |
| `kubernetes_version` | `string` or `null` | yes (may be null) | `Machine.spec.version` (below) |
| `control_plane` | `bool` | yes | `true` when the owning Machine carries the control-plane label (below) |

### `bootstrap_data`

**Base64** (standard alphabet, padded) of the raw bytes of the `value` key
of the Secret named by `Machine.spec.bootstrap.dataSecretName`. The
bootstrap contract requires a single key `value`
([`bootstrap-config.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/bootstrap-config.md)
"BootstrapConfig: data secret"; `dataSecretName` in
[`machine_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/machine_types.go)
`Bootstrap`).

The controller base64-encodes `value` when rendering tfvars, **always and
for every bootstrap provider**: CAPRKE2 with `gzipUserData: true` writes
`value` as raw gzip bytes, which are not valid UTF-8 and so cannot be a
JSON/HCL `string` (see [the RKE2ControlPlane guide](../../control-planes/rke2.md));
encoding unconditionally keeps one rule instead of sniffing content. The
input stays `sensitive = true`.

Modules use one of two patterns:

- pass it unchanged to a `user_data_base64`-style argument (for example AWS
  `aws_instance.user_data_base64` or `aws_launch_template.user_data`, which
  both take base64); or
- `base64decode(var.bootstrap_data)` where the argument wants the plain
  payload — only valid when the payload is UTF-8, that is not gzipped:
  `base64decode` fails on non-UTF-8 bytes, so a binary payload must go to a
  base64-taking argument instead.

Apply waits until the Secret exists (the contract workflow also exits while
`dataSecretName` is nil;
[`infra-machine.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machine.md)
"Typical InfraMachine reconciliation workflow");
`dataSecretName: ""` (the field allows `MinLength=0`,
[`machine_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/machine_types.go#L792-L794))
is treated exactly like nil (`WaitingForBootstrapData`).

For control-plane Machines the payload embeds the cluster CA and service
account private keys **uncompressed**
([`controlplane_init.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/bootstrap/kubeadm/pkg/cloudinit/controlplane_init.go#L63),
[`controlplane_join.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/bootstrap/kubeadm/pkg/cloudinit/controlplane_join.go#L61)),
so it is both larger and more sensitive than a worker's. Size limits (for
example AWS's 16 KiB user-data) and keeping keys out of readable instance
metadata are module business: gzip the payload, or stage it in a secret
store and pass only a small stub through `bootstrap_data`/user-data.

### `bootstrap_format`

`cloud-config` or `ignition`, from the bootstrap Secret's `format` key;
`cloud-config` when absent.

`format` is not part of the bootstrap contract, which specifies only
`value`
([`bootstrap-config.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/bootstrap-config.md)).
It is written by the kubeadm bootstrap provider
([`kubeadmconfig_controller.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/bootstrap/kubeadm/reconcilers/kubeadmconfig/kubeadmconfig_controller.go)
writes `value` and `format`; enum `cloud-config;ignition` in
[`kubeadmconfig_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/bootstrap/kubeadm/v1beta2/kubeadmconfig_types.go)
`Format`). Other bootstrap providers need not write it. CAPRKE2 also
**always** writes both keys, with the same enum
([`rke2config_controller.go`](https://github.com/rancher/cluster-api-provider-rke2/blob/v0.25.2/bootstrap/internal/controllers/rke2config_controller.go#L1040-L1061);
see [the RKE2ControlPlane guide](../../control-planes/rke2.md)). `format`
describes the decoded payload; with CAPRKE2 `gzipUserData: true` the
decoded bytes are gzip of that format.

### `failure_domain` (input)

`Machine.spec.failureDomain` (1–256 chars;
[`machine_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/machine_types.go)).
The InfraMachine MUST be placed in this failure domain
([`infra-machine.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machine.md)
"InfraMachine: failure domain").

### `kubernetes_version` (input)

`Machine.spec.version` (optional, 1–256 chars;
[`machine_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/machine_types.go)).
The value may carry a control-plane-provider-specific distro suffix: with
RKE2 it is `vX.Y.Z+rke2rN` (for example `v1.31.4+rke2r1`), copied verbatim
from `RKE2ControlPlane.spec.version` to `Machine.spec.version` (see [the
RKE2ControlPlane guide](../../control-planes/rke2.md)). The controller
passes this input to the module **verbatim**, unstripped; a module that
uses it for an image lookup or a semver comparison MUST strip the `+…`
build-metadata suffix itself (see [the RKE2ControlPlane
guide](../../control-planes/rke2.md)).

### `control_plane` (input)

`true` when the owning Machine carries the `cluster.x-k8s.io/control-plane`
label (`MachineControlPlaneLabel`,
[`machine_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/machine_types.go);
CAPI's own `util.IsControlPlaneMachine` checks only for this label's
presence,
[`util.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/util/util.go)).
There is no role string in `MachineSpec`.

## Outputs

Common outputs apply (`health`).

| Name | Type | Required | Maps to |
| --- | --- | --- | --- |
| `provider_id` | `string` or `null` | yes (may be null until known) | `TerraformMachine.spec.providerID` → `Machine.spec.providerID` (below) |
| `addresses` | `list(object({type=string, address=string}))` | yes (may be `[]`) | `TerraformMachine.status.addresses` → `Machine.status.addresses` (below) |
| `failure_domain` | `string` or `null` | yes (may be null) | `TerraformMachine.status.failureDomain` → `Machine.status.failureDomain` (below) |
| `interruptible` | `bool` or `null` | declared by every machine module; value optional (null = `false`) | `TerraformMachine.status.interruptible` (below) |

### `provider_id` (output)

Maps to `TerraformMachine.spec.providerID` → `Machine.spec.providerID`. Must
equal the Node's `spec.providerID` exactly (see "Node providerID matching"
below). 1–512 chars
([`infra-machine.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machine.md)
"InfraMachine: provider ID"; `MinLength=1`, `MaxLength=512` markers in
[`machine_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/machine_types.go)).
`""` is treated as `null`.

Written once; a later non-null change is
`OutputsValid=False/ProviderIDChanged`. If it turns `null` after
provisioning, the instance is treated as terminated (see
[`common.md`](common.md#outputs) "Out-of-band termination") and
`spec.providerID` is kept. We latch it — never clear it once set — because
CAPI does not: the Machine controller recopies `Machine.spec.providerID`
from `TerraformMachine.spec.providerID` on every reconcile rather than
latching it once
([`machine_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machine/machine_controller_phases.go#L323-L336)),
and clearing our side would blank the Machine's field and stop
address/failure-domain copying from the InfraMachine on that same path.

### `addresses` (output)

Maps to `TerraformMachine.status.addresses` → `Machine.status.addresses`
([`infra-machine.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machine.md)
"InfraMachine: addresses"). `type` is one of `Hostname`, `ExternalIP`,
`InternalIP`, `ExternalDNS`, `InternalDNS` (`MachineAddressType` enum,
[`common_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/common_types.go));
`address` is 1–256 chars; at most 256 entries (`MachineAddress` and
`Machine.status.addresses` markers,
[`common_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/common_types.go)
and
[`machine_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/machine_types.go)).
The controller validates every mapped output against these CRD markers
before patching status; a violation is `OutputsValid=False/OutputsInvalid`,
and nothing is written.

**Canonical order.** Before writing status the controller sorts the
module's list by type precedence `InternalIP, InternalDNS, ExternalIP,
ExternalDNS, Hostname`, then by address. CAPI itself copies the list
verbatim
([`machine_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machine/machine_controller_phases.go#L339-L347)),
so an unsorted module output would otherwise reach `Machine.status.addresses`
in whatever order the module emitted it. Rationale: RKE2's
`registrationMethod: internal-first` takes the **first** address in list
order whose type is `InternalIP` or `ExternalIP` (this is what the code
does, not "internal preferred" as its own docs claim);
`internal-only-ips` needs an `InternalIP` present, and `external-only-ips`
needs an `ExternalIP` present (see [the RKE2ControlPlane
guide](../../control-planes/rke2.md)) — a fixed, sorted order makes that
first-match deterministic instead of depending on module authoring order.

### `failure_domain` (output)

Maps to `TerraformMachine.status.failureDomain` → `Machine.status.failureDomain`
(the actual placement;
[`infra-machine.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machine.md)
"InfraMachine: failure domain"). When the `failure_domain` input is
non-null the output MUST equal it: the contract says the InfraMachine MUST
be placed in the requested domain, and the controller enforces it — a
mismatch is `OutputsValid=False/FailureDomainMismatch` and `Ready=False`,
so KCP/MachineDeployment spreading can never be silently broken. The
output adds information only when no domain was requested.

### `interruptible` (output)

Maps to `TerraformMachine.status.interruptible` (`bool`); `true` for
spot/preemptible instances. CAPI reads `status.interruptible` from the
InfraMachine and, when true, sets the Node label
`cluster.x-k8s.io/interruptible` (`InterruptibleLabel`;
[`machine_controller_noderef.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machine/machine_controller_noderef.go#L129-L139)),
which termination handlers and schedulers key on. The output must be
**declared** because the generated root re-exports every contract output
unconditionally; a module without spot support declares
`output "interruptible" { value = false }`. Null is written as `false`.

### Provisioned rule

`status.initialization.provisioned = true` when the state Secret carries
the inputs-hash annotation of a successful apply, `provider_id` is
non-null, and `health.state != "pending"`; derived from state only, never
from Job history, so it is rebuilt after `clusterctl move` (evaluated once
on the target, then latched).

**Latched.** The formula applies only until it first holds; once
`provisioned` is true it stays true for the object's life, whatever later
health or outputs say (CAPI never flips `infrastructureProvisioned` back;
[`machine_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machine/machine_controller_phases.go)
"should not flip back"). A later null `provider_id` or non-running health
is reported on `InfrastructureHealthy` (for example `InstanceTerminated`),
never by un-provisioning.

While `pending`, the controller refreshes regardless of
`drift.intervalSeconds`, 30s after the last refresh and backing off to at
most 5m (not a field; see [`common.md`](common.md#outputs)). After a
successful apply it refreshes once more unless the apply's own outputs are
valid with a `health.state` other than `pending` or `unknown`. `Ready=True`
additionally requires `health.healthy` and `state == "running"`.

### Ready timeline

What CAPI mirrors into `Machine.status.conditions[InfrastructureReady]`,
which MachineHealthCheck can act on:

| Phase | `Ready` | Reason |
| --- | --- | --- |
| Waiting for owner Machine, cluster infrastructure, `exports`, bootstrap data | `Unknown` | `WaitingFor*` (on the `DependenciesReady` condition; `Ready` reason `ReadyUnknown`) |
| Apply Job started | `False` | `Provisioning` |
| Provisioned, healthy | `True` | `Ready` |
| Provisioned, `health` not running/healthy | `False` | `NotReady` (detail on `InfrastructureHealthy`) |
| Deleting | `False` | `Deleting` |

`Unknown` rather than `False` while waiting matters for MHC:
`unhealthyMachineConditions` timeouts count from the condition's
`lastTransitionTime`, and a reason change does not reset it. Workers
created alongside a slow control plane can wait a long time for bootstrap
data; starting the `False` window only at apply start means an MHC
`InfrastructureReady=False` timeout measures apply time, not control-plane
bring-up. After provisioning, `Ready` is computed from
`InfrastructureHealthy` and deletion only; drift results, drift-Job
failures, identity or RBAC problems never turn it `False` (they are
separate conditions), so a credentials outage cannot trigger fleet-wide
remediation.

## Lifecycle

- **Immutable.** Changes to `spec.source` and `spec.identityRef` after
  creation are rejected by the webhook, and `spec.providerID` can only be
  set once, by the controller. Those changes come via
  MachineDeployment/KCP rollout. `spec.jobs`, `spec.drift` and
  `spec.remediation` are operational policy and stay mutable: they change
  how the controller treats the machine (a Job deadline, drift checks,
  auto-remediation), never what was applied. `captf_cluster_outputs`
  changes do **not** trigger re-apply: the rendered inputs of the first
  apply (including `bootstrap_data` and `captf_cluster_outputs`) are
  stored in the object-owned `captf-inputs-<kindshort>-<name>` Secret and
  re-fed unchanged on drift and destroy; the effective image and identity
  are pinned there too, so a later change to `TerraformCluster.spec.defaults`
  (for example a ClusterClass in-place update) never changes what runs
  against an existing machine. Bootstrap data is read once. The kubeadm
  bootstrap provider does not rewrite a Machine's bootstrap Secret after
  creation — it only extends the join token's TTL in the workload cluster
  until the Node joins
  ([`kubeadmconfig_controller.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/bootstrap/kubeadm/reconcilers/kubeadmconfig/kubeadmconfig_controller.go)
  `refreshBootstrapTokenIfNeeded`) — so "read once" loses nothing. Pools are
  different (see [`machinepool.md`](machinepool.md#lifecycle)).
- **Gating.** Apply waits for: the owner `Machine` (looked up through the
  Machine ownerRef, `util.GetOwnerMachine`, then the Cluster through
  `cluster.x-k8s.io/cluster-name`; a TerraformMachine never has a Cluster
  ownerRef);
  `Cluster.status.initialization.infrastructureProvisioned`
  ([`cluster_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/cluster_types.go));
  the cluster's `exports` readable (`WaitingForClusterExports`); and the
  bootstrap Secret (`WaitingForBootstrapData`; the contract workflow also
  exits while `dataSecretName` is nil, and `""` counts as nil). The owning
  Cluster's `spec.infrastructureRef` must be kind `TerraformCluster`;
  otherwise `DependenciesReady=False/ClusterNotTerraform` and nothing is
  done. Once those pass, the `spec.variablesFrom` sources must exist and be
  labeled (`DependenciesReady=False/VariablesSourceNotFound`) with valid
  keys and values (`False/VariablesInvalid`); see
  [`common.md`](common.md#user-variables) "User variables". While gated,
  `Ready=Unknown` (timeline above).
- **Retry.** A state Secret that exists without the inputs-hash annotation
  (a failed or interrupted first apply) means the apply is retried with
  backoff even though the spec is immutable; each attempt gets a distinct
  Job name (attempt counter).
- **Refresh/drift.** On `spec.drift.intervalSeconds`: `apply -refresh-only`
  then `plan -detailed-exitcode`. Drift is **reported only**
  (`DriftDetected=True`, a negative-polarity condition kept out of
  `Ready`); never auto-applied for machines (`MachineDriftPolicy` has no
  `action` field: there is nothing to remediate against for an immutable
  machine). The refresh updates `addresses` and `health`. A failed drift
  Job sets `DriftJobSucceeded=False` and nothing else.
- **Health → remediation.** `health` outside `running`/`healthy` after
  provisioning sets `InfrastructureHealthy=False`, then `Ready=False/NotReady`,
  mirrored to `Machine.status.conditions[InfrastructureReady]=False`, which
  a `MachineHealthCheck` can act on. See [Machine
  Remediation](../../../user-guide/remediation.md) for configuring
  `spec.remediation`, the unhealthy threshold and sampling interval, and how
  a MachineHealthCheck reaches a replacement.

  `health` is purely cloud-side: the controller does not cross-check
  `Machine.status.nodeRef`/`nodeInfo` (Node existence,
  [`machine_controller_noderef.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machine/machine_controller_noderef.go#L119));
  a missing or NotReady Node is MHC's `nodeStartupTimeout`/Node-condition
  checks' job.
- **Delete.** Deletion of a TerraformMachine is normally initiated by the
  Machine controller after drain and pre-terminate hooks. Ordering is
  CAPI's: drain (bounded by `Machine.spec.deletion.nodeDrainTimeoutSeconds`)
  and volume detach (`nodeVolumeDetachTimeoutSeconds`) finish before the
  TerraformMachine is deleted, so `destroy` never races a running drain;
  the Node object is deleted by core-machine only after the
  TerraformMachine is gone (bounded by `nodeDeletionTimeoutSeconds`;
  [`machine_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/machine_types.go#L512-L531),
  [`machine_controller.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machine/machine_controller.go#L620)).
  No contract input carries these timeouts.

  The webhook **allows** a direct delete when the object has **no Machine
  ownerRef at all** (an orphan: KCP deletes the InfraMachine itself when
  KubeadmConfig or Machine creation failed,
  [`helpers.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/helpers.go#L185-L201)),
  when the owning Machine is itself deleting, or when the request carries
  `clusterctl.cluster.x-k8s.io/delete-for-move`; it **refuses** deletion
  otherwise, so drain and the KCP etcd-membership hook are never bypassed
  by deleting the infra object directly.

  Then a `destroy` Job runs, rendered from the
  `captf-inputs-<kindshort>-<name>` Secret (never from the bootstrap Secret
  or the Cluster, which may already be gone); on success it drops the
  state, the Lease and the inputs Secret, and removes the finalizer. If the
  owning Machine or Cluster is gone the same path runs. If there is no
  state Secret and no active Job (deleted while still gated), the
  finalizer is removed without a Job. If destroy fails, the object stays
  with `ApplyJobSucceeded=False/DestroyFailed` (`Ready=False`) and retries
  with backoff; a Lease whose holder Job no longer exists is force-unlocked
  automatically. There is no skip-destroy annotation: a permanently
  failing destroy is resolved by cleaning up out of band and removing the
  finalizer by hand, after backing up or un-owning the `tfstate-*` Secrets,
  which are otherwise garbage-collected with the object (see [the
  stuck-destroy runbook](../../../operator-guide/runbooks/stuck-destroy.md)).
  A stuck control-plane machine destroy blocks KCP remediation, scale and
  upgrade until resolved
  ([`remediation.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/remediation.go)).
- The module MUST accept `bootstrap_data` opaquely: it is base64 of the
  bootstrap payload (Inputs), passed to a base64-taking user-data argument
  or `base64decode()`d into a plain one; the module MUST NOT need to parse
  the payload.
- **Taints and labels.** `Machine.spec.taints` and Machine labels are
  applied to the Node by core-machine
  ([`machine_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/machine_types.go#L492-L507);
  [`machine_controller_noderef.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machine/machine_controller_noderef.go)),
  not by the infrastructure; the machine role has no `node_labels` input
  (pools do, see [`machinepool.md`](machinepool.md#inputs)); no role has a
  taints input.
- **In-place updates** (the CAPI `InPlaceUpdates` feature gate, alpha) are
  unsupported: no field is mutable, and the webhook rejects the
  MachineSet's SSA patch; the rollout path is a new Machine.

## Node providerID matching (module authors)

CAPI links a Machine to its Node only when `Node.spec.providerID` equals
`Machine.spec.providerID` exactly
([`machine_controller_noderef.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machine/machine_controller_noderef.go)).
Our `provider_id` output is copied to the Machine verbatim, so the module
MUST emit the same string the Node will carry:

- **With a cloud-controller-manager (CCM):** the CCM sets
  `Node.spec.providerID` in its own format (for example
  `aws:///<zone>/<instance-id>`, `azure:///subscriptions/...`,
  `openstack:///<uuid>`, `vsphere://<uuid>`). Emit exactly that format.
- **Without a CCM:** the kubelet must be started with
  `--provider-id=<value>` (via `KubeadmConfig`
  `nodeRegistration.kubeletExtraArgs`), and the value must be derivable on
  the instance at boot (an instance-metadata lookup, or a per-machine value
  baked into the module's user-data wrapper), because `bootstrap_data` is
  shared per template and opaque to the module.
- **Not supported in v1:** a controller-side patch of `Node.spec.providerID`
  once the Node registers, as CAPD does
  ([`machine.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/test/infrastructure/docker/internal/docker/machine.go)),
  would need a workload-cluster client and a manager flag; the controller
  does not implement it. In v1 the CCM or kubelet `--provider-id` must set
  it.
- **RKE2:** CAPRKE2 itself never sets kubelet `provider-id`, `node-ip` or
  `node-name` (the fields exist in its config but nothing in the repo
  writes them; see [the RKE2ControlPlane guide](../../control-planes/rke2.md)).
  Without a CCM, the image MUST set
  `agentConfig.kubelet.extraArgs: [provider-id=<same format>]` from
  instance metadata so the kubelet-registered value matches our
  `provider_id` output exactly. This matters more under RKE2 than KCP:
  every RKE2 join (control plane or worker) requires
  `RCP.status.availableServerIPs` to be non-empty, which requires at least
  one **Ready** control-plane Machine, and a Machine only becomes Ready
  once its Node exists with a matching `providerID` — so a providerID
  mismatch on the first control-plane Machine blocks every subsequent
  join, not just that one Machine's own readiness.

Autoscale-from-zero (`InfraMachineTemplate.status.capacity` / `nodeInfo`;
[`infra-machine.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machine.md)
"InfraMachineTemplate: support cluster autoscaling from zero") is supported
through the **image**: instance size is fixed inside the module, so the
image declares it with the OCI labels `io.captf.capacity` and
`io.captf.node-info` (see [`image-contract.md`](../../image-contract.md)
"OCI labels"), and a `TerraformMachineTemplate` reconciler copies them into
`status.capacity`/`status.nodeInfo`. An image without the labels leaves
both fields unset; the Cluster Autoscaler's
`capacity.cluster-autoscaler.kubernetes.io/*` annotations on the
MachineDeployment/MachineSet remain the fallback.

## Control-plane machines

When `control_plane = true`, the module is responsible for registering the
instance in the control-plane load balancer's backend or target group. The
ids it needs (load balancer, target group, backend pool — whatever the
cluster module's cloud exposes) come from `captf_cluster_outputs` (see
[`cluster.md`](cluster.md#outputs) `exports`, which describes the
publishing side of this same convention). Registration is done in the
machine module's own Terraform state, not the cluster module's, so
`destroy` on the machine deregisters it as an ordinary part of tearing down
that state
([`infra-machine.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machine.md)).

Ordering matters: the instance MUST be in the load balancer backend before
`kubeadm init`/`kubeadm join` finish on it, because the contract requires
the endpoint to be reachable through the load balancer during
control-plane bring-up
([`status.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/status.go#L195-L207);
see [the KubeadmControlPlane guide](../../control-planes/kubeadm.md) on
reachability) — `Cluster.status.initialization.controlPlaneInitialized`
never latches if the first control-plane node can't be reached at the
endpoint it just joined. In practice this means the module's apply must
register-then-boot (or register-then-poll-healthy) rather than
boot-then-register as an afterthought.

For worker Machines (`control_plane = false`) no load balancer
registration applies; `captf_cluster_outputs` is still read for any other
cluster-level values the module needs.

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

variable "machine_name" { type = string }
variable "bootstrap_data" { # base64 of the bootstrap Secret's `value`; e.g. user_data_base64 = var.bootstrap_data
  type      = string
  sensitive = true
}
variable "bootstrap_format" { type = string }
variable "failure_domain" {
  type    = string
  default = null
}
variable "kubernetes_version" {
  type    = string
  default = null
}
variable "control_plane" { type = bool }

# Tag every cloud resource this module creates with captf_tags (common.md
# "captf_tags"); this stub only has to reference it, not create anything.
resource "terraform_data" "tags" { input = var.captf_tags }

output "provider_id"    { value = "noop:///${var.captf_object.namespace}/${var.captf_object.name}" }
output "addresses"      { value = [{ type = "InternalIP", address = "10.0.0.1" }] }
output "failure_domain" { value = var.failure_domain }
output "interruptible"  { value = false }
output "health"         { value = { state = "running", healthy = true, message = null, reasons = [] } }
```
