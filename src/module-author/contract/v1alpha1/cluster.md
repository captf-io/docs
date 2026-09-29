# Cluster Role

Implements the CAPI InfraCluster contract
([`infra-cluster.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-cluster.md))
for a `TerraformCluster`. One workspace/state per `TerraformCluster`.
Typically owns the cluster-wide substrate: network, subnets, security
groups, load balancer / control-plane endpoint, shared images/keys. Values
that machine/pool modules need are handed over through the `exports`
output, injected into them as `captf_cluster_outputs`.

## Inputs

Common inputs apply ([`common.md`](common.md#inputs)), except
`captf_cluster_outputs`: it is not passed to this role. The skeleton below
declares it with `default = null`, which is safe; a declaration without a
default fails `validate`.

| Name | Type | Required | Value source |
| --- | --- | --- | --- |
| `control_plane_endpoint` | `object({host=string, port=number})` or `null` | yes (may be null) | Any endpoint the module does **not** own (below) |
| `kubernetes_version` | `string` or `null` | yes (may be null) | `Cluster.spec.topology.version`; `null` without ClusterClass (below) |
| `control_plane_initialized` | `bool` | yes | `Cluster.status.initialization.controlPlaneInitialized`, latched (below) |
| `cluster_network` | `object({pods=list(string), services=list(string), service_domain=string, api_server_port=number})` or `null` | yes (may be null) | `Cluster.spec.clusterNetwork` (below) |

### `control_plane_endpoint` (input)

Value = `Cluster.spec.controlPlaneEndpoint` whenever the annotation
`captf.io/endpoint-source` is not `module` — whether the user set it before
the first apply or a control-plane provider (hosted control planes) sets it
later
([`cluster_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/cluster/cluster_controller_phases.go#L330-L340)).
While the Cluster field is not yet valid (`APIEndpoint.IsValid`, host and
port both set), the input falls back to a valid
`TerraformCluster.spec.controlPlaneEndpoint` (the two are equal once CAPI
copies ours,
[`cluster_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/cluster/cluster_controller_phases.go#L217-L228),
so the copy never changes the hash); else `null`. It is always `null` when
`endpoint-source=module`.

Non-null means "use this endpoint, don't create one": the contract allows
the endpoint to come from the user, the control plane provider, or the
infra provider
([`infra-cluster.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-cluster.md)
"InfraCluster: control plane endpoint"). Shape =
`APIEndpoint{host 1–512 chars, port 1–65535}`
([`cluster_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/cluster_types.go)).

**Provenance** (`captf.io/endpoint-source`): `user` is written before the
first apply when either field holds a valid endpoint; `module` is written
when the controller first copies a non-null module output (from an apply
whose rendered input was null) into `TerraformCluster.spec.controlPlaneEndpoint`;
otherwise the annotation is absent. Once written it never changes. With
`module` the input stays `null` for the life of the object even after CAPI
copies the module's endpoint to `Cluster.spec`: feeding it back would tell
the module to drop the load balancer it created, and would change the
inputs hash. In the inputs hash: an endpoint set later by a control-plane
provider therefore re-applies the cluster once, which is how the module
learns it.

### `kubernetes_version` (input)

`Cluster.spec.topology.version`
([`cluster_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/cluster_types.go#L567));
`null` when the Cluster has no `topology` (no ClusterClass). For modules
that provision managed/hosted control planes or version-dependent cluster
resources. Passed verbatim (it may carry a distro suffix such as
`+rke2r1`; strip it as the machine role does). In the inputs hash, so a
topology upgrade re-applies the cluster.

### `control_plane_initialized` (input)

`Cluster.status.initialization.controlPlaneInitialized`
([`cluster_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/cluster_types.go#L1492);
nil maps to `false`). In the inputs hash, so the cluster re-applies exactly
once when the control plane comes up (CAPI latches the field).

The controller latches it too: the rendered value is `true` when the
Cluster field is true **or** the last rendered value in the durable inputs
Secret (`captf-inputs-c-<name>`, which moves) is true; it is never rendered
`false` after an apply with `true`. Cluster status is not moved by
`clusterctl move`, so without this a first reconcile on the target could
render `false` and destroy every gated resource.

Modules that need a live workload API server (in-cluster add-ons,
cloud-controller secrets, DNS records pointing at registered nodes) gate
those resources on it, for example
`count = var.control_plane_initialized ? 1 : 0`.

### `cluster_network` (input)

`Cluster.spec.clusterNetwork` (`pods.cidrBlocks`, `services.cidrBlocks`,
`serviceDomain`, `apiServerPort`;
[`cluster_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/cluster_types.go)
`ClusterNetwork`, `NetworkRanges`); `null` when the Cluster sets none of
them; missing attributes are null or `[]`.

**`api_server_port` is not the kube-apiserver bind port with KCP** —
CABPK/KCP never read `Cluster.spec.clusterNetwork.apiServerPort`; the real
bind port is KubeadmConfig `localAPIEndpoint.bindPort` (default 6443,
[`workload_cluster.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/controlplane/kubeadm/pkg/workload_cluster.go#L281-L291)).
By convention the module's LB backend port is
`cluster_network.api_server_port ?? 6443`, and templates must keep
`apiServerPort` and `bindPort` equal — the controller has no way to
enforce this.

## Outputs

Common outputs apply (`health`).

| Name | Type | Required | Maps to |
| --- | --- | --- | --- |
| `control_plane_endpoint` | `object({host=string, port=number})` or `null` | yes (may be null) | `TerraformCluster.spec.controlPlaneEndpoint` → `Cluster.spec.controlPlaneEndpoint` (below) |
| `failure_domains` | `list(object({name=string, control_plane=optional(bool, true), attributes=optional(map(string), {})}))` or `null` | yes (may be null or `[]`) | `TerraformCluster.status.failureDomains` (below) |
| `exports` | `any` (object recommended) | yes (may be null, treated as `{}`) | Injected verbatim into machine/pool modules as `captf_cluster_outputs` (below) |

### `control_plane_endpoint` (output)

Maps to `TerraformCluster.spec.controlPlaneEndpoint` →
`Cluster.spec.controlPlaneEndpoint`, surfaced once InfraCluster
initialization completes
([`infra-cluster.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-cluster.md)).
It is written only when all of the following hold: the output is non-null;
the field is still empty; and the apply's rendered `control_plane_endpoint`
input was null (the first such write records
`captf.io/endpoint-source=module`).

It is written only when the output is **valid**: CAPI's copy-to-`Cluster.spec`
path only fires once `APIEndpoint.IsValid()` is true, which requires both
`host` and `port` to be set
([`cluster_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/cluster_types.go#L1664)),
so a half-set output (only one of the two present) is treated as
`OutputsValid=False/OutputsInvalid`, not partially written. CAPI copies the
InfraCluster endpoint only while `Cluster.spec.controlPlaneEndpoint` is not
yet valid, so later changes are never propagated
([`cluster_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/cluster/cluster_controller_phases.go)
`reconcileInfrastructure`); CAPI's Cluster admission webhook has no
immutability rule for it
([`cluster.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/webhooks/admission/cluster.go)).

**Once emitted, the value MUST be stable for the life of the object.** CAPI
never updates `Cluster.spec.controlPlaneEndpoint` after the first valid
copy
([`cluster_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/cluster/cluster_controller_phases.go#L217-L228)),
so a module that later replaces its load balancer (a new DNS name or IP)
breaks every existing kubeconfig and the apiserver certificate SANs, with
no way for CAPI to notice or recover. Keeping it stable is the module
author's responsibility first: the controller blocks, but cannot fix, a
planned replacement.

Every TerraformCluster apply (a re-apply, a new image tag, a drift
remediation) stops before a plan that deletes or replaces any resource,
sets `ApplyJobSucceeded=False/DestructivePlanBlocked` with the affected
addresses, and applies it only once the `captf.io/approve-destructive-plan`
annotation names that apply's inputs hash; see
[Plan Approval](../../../user-guide/plan-approval.md) for the destructive-plan
guard. With `spec.applyPolicy: Manual` every re-apply instead waits for the
approval of its plan, which covers its deletes; see
[Plan Approval](../../../user-guide/plan-approval.md) for plan preview. An
operator can still approve a plan that replaces the endpoint's resource;
`lifecycle { prevent_destroy = true }` on the resource behind the endpoint
turns such a plan into a failed Job even when approved, instead of a lost
cluster.

When no user endpoint exists, the module MUST emit this output no later
than the apply that makes the cluster `provisioned` (see `EndpointAvailable`
below).

### `failure_domains` (output)

Maps to `TerraformCluster.status.failureDomains` (v1beta2 list shape:
`listType=map`, `listMapKey=name`, `MaxItems=100`;
`FailureDomain{name 1–256 chars, controlPlane *bool, attributes map[string]string}`;
[`infra-cluster.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-cluster.md)
"InfraCluster: failure domains",
[`cluster_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/cluster_types.go)).
CAPI's `controlPlane` has no default; `optional(bool, true)` is our
default, applied by the controller. `null` and `[]` both clear the field.

### `exports` (output)

Injected verbatim into machine/pool modules as `captf_cluster_outputs`. May
be marked `sensitive`: the generated root re-exports it `"sensitive": true`
regardless, so this has no effect on the controller (see
[`README.md`](README.md#type-conventions) "Type conventions"). Put secrets
in the identity, not here. Convention: publish the load balancer
target/backend-pool id(s) here for control-plane machine modules to
register against (see
[`machine.md`](machine.md#control-plane-machines) "Control-plane
machines").

### Provisioned rule

`status.initialization.provisioned` is the v1beta2 contract field:
`status.initialization.provisioned = true` when the state Secret carries
the inputs-hash annotation of a successful apply, the required outputs are
valid, and `health.state != "pending"`.

**Latched.** The formula applies only until it first holds; once
`provisioned` is true it stays true for the object's life, whatever later
health or outputs say (CAPI never flips `infrastructureProvisioned` back;
[`machine_controller_phases.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machine/machine_controller_phases.go)
"should not flip back").

There is **no endpoint gate on `provisioned`**: a null
`control_plane_endpoint` output with no endpoint on the Cluster is
allowed, because hosted-control-plane providers set the endpoint only
after infrastructure is provisioned. Provisioned is derived from state,
never from Job history, so it is rebuilt identically after `clusterctl
move` (status is not moved; the target evaluates the formula once, then
latches).

### Hairpin reachability

The control-plane endpoint MUST be reachable from the first control-plane
node itself, not only from the management cluster and other nodes.
kubeadm's `getKubeConfigSpecsBase` (kubernetes/kubernetes release-1.33,
`cmd/kubeadm/app/phases/kubeconfig/kubeconfig.go` around lines 582-626)
sets the server URL of `admin.conf`, `super-admin.conf` and `kubelet.conf`
to `GetControlPlaneEndpoint(cfg.ControlPlaneEndpoint, &cfg.LocalAPIEndpoint)`
— that is, the endpoint, not the node's local address — while only
`controller-manager.conf`/`scheduler.conf` use `GetLocalAPIEndpoint`.
Because kubeadm's post-init phases and the first node's own kubelet talk to
the workload cluster through `admin.conf`/`kubelet.conf`, the load
balancer or VIP that backs `control_plane_endpoint` must hairpin: the
control-plane instance that is itself a backend must be able to reach the
frontend it was just registered behind.

### `EndpointAvailable` condition

Cluster only, not part of `Ready`: `False/WaitingForEndpoint` once
`provisioned` is true and neither the module's `control_plane_endpoint`
output nor `Cluster.spec.controlPlaneEndpoint` is a valid `APIEndpoint`
(host and port both set); `True/EndpointAvailable` otherwise.

With KCP this case is not cosmetic: KCP creates no Machine at all until
`Cluster.spec.controlPlaneEndpoint.IsValid()`
([`kubeadmcontrolplane_controller.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/kubeadmcontrolplane_controller.go#L316)
— "Waiting for Cluster spec.controlPlaneEndpoint to be set"), so a module
that outputs `null` with no user-provided endpoint silently stalls the
cluster forever with no other signal. `tfcapi-lint` warns
(`output/endpoint-never-set`) when a module's `control_plane_endpoint`
output is a literal `null` with no conditional path to a value.

## Lifecycle

- **Mutable.** Any change to `spec.source.image` (a pull-policy change
  alone only affects how the next Job pulls, and starts none), a
  non-module `control_plane_endpoint` (including one set later by a
  control-plane provider), `cluster_network`, `kubernetes_version`
  (`Cluster.spec.topology.version`), or `control_plane_initialized`
  flipping true starts a new apply Job (detected by the hash of the
  rendered spec-derived inputs; labels, uid, and controller-written fields
  are neither rendered nor hashed, see
  [`common.md`](common.md#what-is-hashed) "What is hashed").
- **Externally managed.** A TerraformCluster carrying
  `cluster.x-k8s.io/managed-by` is skipped entirely: no Jobs, no status
  writes
  ([`infra-cluster.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-cluster.md)
  "Externally managed infrastructure"). Machines and pools of that Cluster
  receive `captf_cluster_outputs = {}`.
- **Drift.** On `spec.drift.intervalSeconds`: `apply -refresh-only` first
  (so outputs, health and `exports` refresh and the plan compares against
  current remote values), then `plan -detailed-exitcode` (0 = no changes, 1
  = error, 2 = changes; see
  [OpenTofu docs: `cli/commands/plan/`](https://opentofu.org/docs/cli/commands/plan/)).
  Exit 2 sets `DriftDetected=True`; with `action: Report` (the default)
  that is all, and an operator decides; with `action: Remediate` the
  controller applies, re-rendering the *current* inputs. A changed
  `exports` value re-applies pools (mutable) but not machines (immutable).
  Drift results and drift-Job outcomes never feed `Ready`, and after first
  provisioning neither does a failed re-apply: it is
  `ApplyJobSucceeded=False` plus `DriftDetected`, never `Ready=False`,
  because Cluster `InfrastructureReady=False` would suspend every
  MachineHealthCheck of the cluster
  ([`machinehealthcheck_targets.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/machinehealthcheck/machinehealthcheck_targets.go#L103-L107)).
- **Delete ordering (enforced by the controller).** Destroy is blocked with
  `DeletionBlocked=True/DependentsExist` (requeue) while any
  TerraformMachine or TerraformMachinePool labeled
  `cluster.x-k8s.io/cluster-name=<cluster>` (`ClusterNameLabel`,
  [`common_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/common_types.go))
  exists in the namespace, since their modules depend on cluster resources
  via `exports`. CAPI's own Cluster deletion already removes
  Machines/MachinePools first — it requeues while descendants, including
  MachinePools, exist, then deletes the control plane object, then the
  InfraCluster
  ([`cluster_controller.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/core/reconcilers/cluster/cluster_controller.go)
  `reconcileDelete`, `clusterDescendants`) — so this guard only covers
  out-of-band deletions of the TerraformCluster. Then a `destroy` Job runs;
  success drops the state Secret(s) and Lease, and removes the finalizer.
  Module authors may rely on this ordering.
- The module MUST be idempotent under repeated apply with unchanged inputs
  (plan must be empty). `tfcapi-lint` can't check this, and no automated
  test does yet; the module author must.

## Control-plane provider requirements

What a control-plane provider needs from the cluster module, and how
KubeadmControlPlane (KCP) and RKE2ControlPlane (RCP) differ. The KCP column
draws on [the KubeadmControlPlane integration guide](../../control-planes/kubeadm.md);
the RCP column draws on [the RKE2ControlPlane integration guide](../../control-planes/rke2.md).

| Requirement | KubeadmControlPlane | RKE2ControlPlane |
| --- | --- | --- |
| Endpoint required before any Machine | Yes: KCP creates no Machine until `Cluster.spec.controlPlaneEndpoint.IsValid()` ([`kubeadmcontrolplane_controller.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/kubeadmcontrolplane_controller.go#L316); see the KubeadmControlPlane guide) | Yes: RCP returns before creating *any* Machine while `!IsValid()` ([`rke2controlplane_controller.go`](https://github.com/rancher/cluster-api-provider-rke2/blob/v0.25.2/controlplane/internal/controllers/rke2controlplane_controller.go#L421-L440); see the RKE2ControlPlane guide) |
| LB listeners | `endpoint.port` → CP nodes `:bindPort` (default 6443); one frontend | `endpoint.port` → CP nodes `:6443`, **and** `:9345` → CP nodes `:9345` on the **same host** as the endpoint (the join URL is `https://<endpoint.host>:9345`, port ignored); two frontends |
| Health checks | TCP on the backend port, or HTTPS `/readyz`/`/healthz` without certificate verification; must go green with a single backend | 9345: TLS `GET /v1-rke2/readyz` expecting **403** (unauthenticated), or plain TCP; 6443: TCP, or HTTPS `/healthz` only if anonymous auth is enabled |
| Backend membership | Module registers/deregisters CP instances in its own state; instance MUST be in the LB backend before `kubeadm init`/`join` finishes, or `controlPlaneInitialized` never latches ([`infra-machine.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machine.md)) | Same registration contract; module MUST add a CP node before its Machine is Ready (joins through the LB during bring-up) and MUST tolerate a backend whose supervisor is not yet up |
| SG / firewall ports | Backend port (bindPort) from LB, nodes and management; 2379–2380 and 10250 between CP nodes; 10250 from CP to workers | CP↔CP 2379-2381; all→CP 6443 and 9345; all↔all 10250, NodePort range; CNI ports for the chosen `serverConfig.cni` (default canal: 8472/udp, 9099); egress to `get.rke2.io`/GitHub releases unless air-gapped |
| `cluster_network.api_server_port` / `service_domain` | `api_server_port` is **not** wired to the kube-apiserver bind port by CABPK/KCP either — the real bind port is KubeadmConfig `localAPIEndpoint.bindPort` (default 6443); backend port is `api_server_port ?? 6443` by convention only | **No effect** under RKE2: the domain comes from `serverConfig.clusterDomain`, and the API server is always 6443 on nodes; RKE2 never reads either field |
| `failure_domains[].control_plane` default | KCP filters to entries with `controlPlane == true`; a nil `controlPlane` counts as false, so our `optional(bool, true)` default is required for domains to be visible | Same: RCP only uses entries with `controlPlane: true` (nil counts as false); our default `true` is compatible with both providers |

See the [KubeadmControlPlane](../../control-planes/kubeadm.md) and
[RKE2ControlPlane](../../control-planes/rke2.md) guides for the reasoning
and exact citations behind each row.

## Minimal skeleton

A block written on one line may hold at most one argument
([`OneLineBlock`](https://github.com/hashicorp/hcl/blob/main/hclsyntax/spec.md);
`tofu validate` reports "Invalid single-argument block definition" on a
violation), so a variable that needs both `type` and `default` (like
`captf_cluster_outputs` below) must use the multi-line block form:

```hcl
variable "captf_contract"        { type = string }
variable "captf_cluster"         { type = object({ name = string, namespace = string }) }
variable "captf_object"          { type = object({ kind = string, name = string, namespace = string }) }
variable "captf_cluster_outputs" {
  type    = any
  default = null
}
variable "captf_tags" { type = map(string) }

variable "control_plane_endpoint" {
  type    = object({ host = string, port = number })
  default = null
}

variable "kubernetes_version" {
  type    = string
  default = null
}
variable "control_plane_initialized" { type = bool }

variable "cluster_network" {
  # Every attribute is always present when cluster_network is non-null
  # (an unset CIDR list renders as [], an unset scalar as null), so the
  # type matches the Inputs table exactly: none of the four is optional().
  type = object({
    pods            = list(string)
    services        = list(string)
    service_domain  = string
    api_server_port = number
  })
  default = null
}

# Tag every cloud resource this module creates with captf_tags (common.md
# "captf_tags"); this stub only has to reference it, not create anything.
resource "terraform_data" "tags" { input = var.captf_tags }

output "control_plane_endpoint" { value = var.control_plane_endpoint != null ? var.control_plane_endpoint : { host = "...", port = 6443 } }
output "failure_domains"        { value = [] }
output "health"                 { value = { state = "running", healthy = true, message = null, reasons = [] } }

# Handed to machine/pool modules as captf_cluster_outputs:
output "exports" { value = { network_id = "...", subnet_ids = ["..."] } }
```
