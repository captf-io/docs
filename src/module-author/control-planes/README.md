# Control-Plane Integration

CAPTF's cluster and machine modules are infrastructure only: they create
networks, load balancers and instances, and report state back through the
[contract](../contract/v1alpha1/README.md). Bringing up Kubernetes on top of
that infrastructure is the job of a Cluster API control-plane provider —
KubeadmControlPlane (KCP) or RKE2ControlPlane (RCP) — plus its bootstrap
provider.

Those providers read specific fields from your modules and write specific
fields back, on a specific schedule. Getting the details wrong produces a
cluster that hangs rather than one that fails loudly.

This guide set distills the verified requirements into what you need as a
module author:

- [`kubeadm.md`](kubeadm.md) — everything specific to KubeadmControlPlane /
  the kubeadm bootstrap provider (CABPK).
- [`rke2.md`](rke2.md) — everything specific to RKE2ControlPlane / the RKE2
  bootstrap provider (CAPRKE2).
- [`checklist.md`](checklist.md) — every port, health check and ordering
  rule from both guides, organized by topic, for a build-time or
  review-time reference.

Both guides cite CAPI/CAPRKE2 source paths and the contract's own module
role pages: [the cluster role](../contract/v1alpha1/cluster.md), [the
machine role](../contract/v1alpha1/machine.md) and [the common
contract](../contract/v1alpha1/common.md). Where this guide set and the
contract state the same requirement, the contract's wording is
authoritative.

## The shared creation sequence

Both control-plane providers drive the same shape of sequence against a
CAPTF cluster module and one or more CAPTF machine modules. The sequence
below is the kubeadm case; RKE2's differences are called out inline and
detailed in [`rke2.md`](rke2.md), in [what it reads from your
modules](rke2.md#what-rke2controlplane-reads-from-your-modules) and
[lifecycle constraints](rke2.md#lifecycle-constraints).

1. A user (or a ClusterClass topology) creates the `Cluster`,
   `TerraformCluster`, control-plane object (`KubeadmControlPlane` or
   `RKE2ControlPlane`) and `TerraformMachineTemplate`.
2. The CAPI Cluster controller reconciles the `infrastructureRef`, setting
   its owner reference to the `TerraformCluster`.
3. The `TerraformCluster` controller runs the cluster module's first
   apply. At this point `control_plane_endpoint` is rendered `null` and
   `control_plane_initialized` is rendered `false`. The module returns
   `control_plane_endpoint`, `failure_domains`, `exports` and `health`.
4. The controller copies `control_plane_endpoint` onto
   `TerraformCluster.spec.controlPlaneEndpoint` and `failure_domains`
   onto `TerraformCluster.status.failureDomains`; CAPI in turn copies
   them onto `Cluster.spec.controlPlaneEndpoint` and
   `Cluster.status.initialization.infrastructureProvisioned = true`.
5. The control-plane provider gates all further work on: a valid
   `Cluster.spec.controlPlaneEndpoint` **and**
   `infrastructureProvisioned = true`. Neither KCP nor RCP creates a single
   Machine before both are true (see [what KubeadmControlPlane
   reads](kubeadm.md#what-kubeadmcontrolplane-reads-from-your-modules) and
   [what RKE2ControlPlane
   reads](rke2.md#what-rke2controlplane-reads-from-your-modules)).
6. For control-plane machine `i = 1..N`, in strict order — the provider
   creates machine `i+1` only after machine `i` has a `nodeRef`:
   1. The control-plane provider creates the bootstrap config (init for
      `i=1`, join for `i>1`) and the `Machine` (labeled
      `cluster.x-k8s.io/control-plane`) plus a `TerraformMachine` cloned
      from the template.
   2. The bootstrap provider writes the bootstrap Secret (`value`,
      `format`); `Machine.spec.bootstrap.dataSecretName` is set.
   3. The `TerraformMachine` controller reconciles machine `i`, gated on:
      the cluster's `infrastructureProvisioned`, the cluster's `exports`
      being readable, and the bootstrap Secret existing.
   4. The machine module's apply runs once (immutable): it receives
      `bootstrap_data` (base64), `control_plane = true`,
      `captf_cluster_outputs` (the cluster's `exports`), `failure_domain`
      and `kubernetes_version`. In this same apply the module creates the
      instance **and** registers it in the control-plane LB backend, or
      does neither of the latter under [Pattern
      C](#pattern-c-kube-vip-style-vip) below. It returns `provider_id`,
      `addresses`, `failure_domain`, `interruptible` and `health`.
   5. The `TerraformMachine` controller writes `spec.providerID` and
      `status.addresses` on the `TerraformMachine`, and marks it
      provisioned and `Ready`. The CAPI Machine controller then copies
      both onto `Machine.spec.providerID` and `Machine.status.addresses`.
   6. cloud-init on the instance runs `kubeadm init` (`i=1`) or
      `kubeadm join` (`i>1`); post-init phases go through the endpoint
      (hairpin — see [kubeadm.md's networking
      section](kubeadm.md#networking-and-load-balancer)). Under RKE2's
      default registration method the join target is the endpoint host
      itself, but the join cannot proceed until at least one **Ready**
      control-plane Machine already exists, since
      `RCP.status.availableServerIPs` stays empty without one (see
      [what RKE2ControlPlane
      reads](rke2.md#what-rke2controlplane-reads-from-your-modules) and
      [rke2.md's lifecycle constraints](rke2.md#lifecycle-constraints)).
   7. The Node registers with `spec.providerID` set (by a
      cloud-controller-manager or `kubelet --provider-id`); the Machine
      controller matches `nodeRef` by an exact `providerID` match.
   8. When `i = 1` and the control plane finishes initializing,
      `Cluster.status.initialization.controlPlaneInitialized` flips
      `true`. This triggers exactly one cluster re-apply, for resources
      gated on a live workload API server.
7. Workers follow the same machine path (`MachineDeployment` →
   `MachineSet` → `Machine` → `TerraformMachine`, `control_plane = false`),
   gated on `ControlPlaneInitialized` because the bootstrap provider writes
   worker join data only after that. A worker fleet backed by a
   `MachinePool` instead goes straight from `MachinePool` to
   `TerraformMachinePool` — one infrastructure object for the whole group,
   with no per-replica `Machine` or `TerraformMachine`; see [Machine
   Pools](../../user-guide/machine-pools.md).

## LB-membership patterns

The contract requires a control-plane machine module to register (and, on
destroy, deregister) its instance with the control-plane load balancer
(see [machine.md's control-plane
machines](../contract/v1alpha1/machine.md#control-plane-machines)), but
leaves how up to the module. Three patterns are sanctioned here.

### Pattern A: attachment resource in the machine module's state

The machine module creates the instance and, in the same apply, an
explicit attachment/registration resource (for example an LB target-group
attachment) pointed at the target-group or backend-pool id it received
through `captf_cluster_outputs` (see [common.md's
outputs](../contract/v1alpha1/common.md#outputs)). Because the attachment
lives in the machine module's own state, `destroy` deregisters it as an
ordinary part of tearing that state down.

This is the pattern the contract documents directly: registration is
"done in the machine module's own Terraform state, not the cluster
module's" ([machine.md's control-plane
machines](../contract/v1alpha1/machine.md#control-plane-machines), citing
`capi/docs/book/src/developer/providers/contracts/infra-machine.md:633,645`).
The instance MUST be registered before `kubeadm init`/`kubeadm join`
finishes (KCP) or before the Machine is Ready (RKE2) — see [kubeadm.md's
module checklist](kubeadm.md#module-checklist) and [rke2.md's module
checklist](rke2.md#module-checklist).

Typical fit: clouds whose load balancer exposes an explicit
target-group/backend-pool attach API (for example AWS ALB/NLB
target-group attachments, Azure Load Balancer backend-pool membership).

This is design guidance, not yet tested against a real control plane.

### Pattern B: selector/tag-based backend pools

The load balancer derives its backend membership itself, from a tag or
label selector query, rather than from an explicit per-instance attach
call — "target group by tag/label". The machine module's only job is to
apply the right tags to the instance (via `captf_tags`, see [common.md's
inputs](../contract/v1alpha1/common.md#inputs), or an additional
module-defined tag); the load balancer's own membership scan does the
rest, and removing the instance (destroy) removes it from the pool.

The same ordering requirement applies as under Pattern A: the instance
MUST be a member of the backend before `kubeadm init`/`join` finishes on
it (KCP) or before the Machine is Ready (RKE2) — see [kubeadm.md's module
checklist](kubeadm.md#module-checklist) and [rke2.md's module
checklist](rke2.md#module-checklist).

Typical fit: clouds or load balancers whose backend pool is defined by a
selector/tag query against an instance group or autoscaling group, rather
than an explicit attach call.

This is design guidance, not yet tested against a real control plane.

### Pattern C: kube-vip-style VIP

No separate load-balancer resource is created by the cluster module at
all; a virtual IP is run by the control-plane nodes themselves (implicit
via kube-vip or similar), so there is "nothing LB-wise" for the machine
module to do. The cluster module still MUST emit a valid
`control_plane_endpoint` before any Machine is created — the same gate
applies regardless of how the endpoint is realized (see [what
KubeadmControlPlane
reads](kubeadm.md#what-kubeadmcontrolplane-reads-from-your-modules) and
[kubeadm.md's networking section](kubeadm.md#networking-and-load-balancer);
[what RKE2ControlPlane
reads](rke2.md#what-rke2controlplane-reads-from-your-modules) and
[rke2.md's networking section](rke2.md#networking-and-load-balancer)).
Under this pattern the backend-membership and per-backend health-check
rows of [`checklist.md`](checklist.md) do not apply, because there is no
separate LB backend to join.

Typical fit: bare-metal, on-premises, or otherwise L2-reachable
environments without a managed load balancer in front of the control
plane.

This is design guidance, not yet tested against a real control plane.

## See also

- [The module contract](../contract/v1alpha1/README.md) — the normative
  cluster and machine roles this guide set builds on.
- [Security model](../../concepts/security-model.md) — the trust
  boundary a control-plane Job runs inside.
- [The Kinds](../../concepts/kinds.md) — how `TerraformCluster` and
  `TerraformMachine` map to Cluster API objects.
