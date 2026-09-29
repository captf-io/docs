# KubeadmControlPlane

What KubeadmControlPlane (KCP) and the kubeadm bootstrap provider (CABPK)
require of your CAPTF cluster and machine modules, and why this is the
case.

Citations below prefixed `capi/` are files in the CAPI v1.14.2 tree
(`https://github.com/kubernetes-sigs/cluster-api/tree/v1.14.2`). See also
[the shared creation sequence](README.md#the-shared-creation-sequence)
and [the requirements checklist](checklist.md) for every requirement in
one place.

## What KubeadmControlPlane reads from your modules

- **`Cluster.spec.controlPlaneEndpoint`.** KCP has no endpoint field of its
  own; it only reads the Cluster's. It gates all Machine creation on this
  field being valid (`host != ""` and `port != 0`) — see [networking and
  load balancer](#networking-and-load-balancer). The endpoint
  can come from the user, your `TerraformCluster` (copied once while the
  Cluster field is not yet valid), or a control-plane provider; KCP never
  supplies one itself
  (`capi/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/kubeadmcontrolplane_controller.go:316,439`;
  `capi/core/reconcilers/cluster/cluster_controller_phases.go:210-238`).
- **`Machine.status.addresses`.** Not read by KCP or CABPK at all. Only
  the core Machine controller copies it from the InfraMachine; apiserver
  certificate SANs come from kubeadm's own node-IP detection, not from
  CAPI addresses
  (`capi/core/reconcilers/machine/machine_controller_phases.go:339-346`).
- **`providerID` / `nodeRef`.** The Machine controller links a Node to a
  Machine only on an exact `providerID` match (see
  [`../contract/v1alpha1/machine.md`](../contract/v1alpha1/machine.md)
  "Node providerID matching"). KCP then gates almost everything on the
  resulting `nodeRef`: etcd-member matching, static-pod health, and
  scale-up/scale-down preflight all require every existing control-plane
  Machine to have one
  (`capi/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/preflight.go:193-203`;
  `capi/controlplane/kubeadm/pkg/workload_cluster_conditions.go:136,390,434`).
- **Failure domains.** KCP only sees `Cluster.status.failureDomains`
  entries with `controlPlane == true`; a nil `controlPlane` counts as
  `false`. This is why the cluster module's `failure_domains[].control_plane`
  default of `true` matters
  (`capi/controlplane/kubeadm/pkg/control_plane.go:171-184`).
- **`cluster_network.api_server_port`.** Not read by CABPK or KCP at all
  in CAPI v1.14.2. The real kube-apiserver bind port is the KubeadmConfig
  `localAPIEndpoint.bindPort` (default 6443)
  (`capi/controlplane/kubeadm/pkg/workload_cluster.go:281-291`). Treat
  `api_server_port ?? 6443` as a documentation-only convention, not a
  wired-through value (see [networking and load
  balancer](#networking-and-load-balancer)).
- **InfraMachineTemplate rotation.** KCP triggers a rollout when a
  Machine's InfraMachine carries a `cluster.x-k8s.io/cloned-from-name`/
  `-groupkind` annotation different from the current
  `machineTemplate.spec.infrastructureRef`. Template **content** is never
  diffed — CAPTF's template immutability already matches this expectation
  (`capi/controlplane/kubeadm/pkg/filters.go:183-227`).

## What KCP and CABPK write

- **Bootstrap Secret.** Named after the KubeadmConfig (== the Machine
  name). Keys `value` and `format` are always both written; `format`
  defaults to `cloud-config` (Ignition requires the alpha feature gate
  `KubeadmBootstrapFormatIgnition`, off by default)
  (`capi/bootstrap/kubeadm/reconcilers/kubeadmconfig/kubeadmconfig_controller.go:1405-1437`;
  `capi/api/bootstrap/kubeadm/v1beta2/kubeadmconfig_types.go:27-36,117-120`;
  `capi/feature/feature.go:108`). See
  [`../contract/v1alpha1/machine.md`](../contract/v1alpha1/machine.md)
  `bootstrap_format` for how CAPTF surfaces this.
- **Payload contents.** Control-plane init and join payloads embed the
  cluster CA, etcd CA, service-account and front-proxy key material as
  files, uncompressed
  (`capi/bootstrap/kubeadm/pkg/cloudinit/controlplane_init.go:63`,
  `controlplane_join.go:61`). See [module checklist](#module-checklist)
  for what this means for your module.
- **Labels and hooks.** Every KCP Machine, InfraMachine and KubeadmConfig
  gets `cluster.x-k8s.io/cluster-name`, `cluster.x-k8s.io/control-plane: ""`
  and a `pre-terminate.delete.hook.machine.cluster.x-k8s.io/kcp-cleanup: ""`
  annotation
  (`capi/controlplane/kubeadm/pkg/desiredstate/desired_state.go:324-340,110-135`).
  CAPTF's own metadata-update path already allows these (label/annotation
  edits are excluded from TerraformMachine's immutability checks).
- **`KubeadmControlPlane.status.initialization.controlPlaneInitialized`.**
  Latches `true` once the `kubeadm-config` ConfigMap is readable
  **through the endpoint** — the reason the endpoint's hairpin
  reachability matters (see [networking and load
  balancer](#networking-and-load-balancer))
  (`capi/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/status.go:176-210`).
  This mirrors into `Cluster.status.initialization.controlPlaneInitialized`
  and drives one cluster re-apply
  (`capi/core/reconcilers/cluster/cluster_controller_status.go:80-81,450-551`).
- **Conditions.** KCP writes `Initialized`, `Available`,
  `CertificatesAvailable`, `EtcdClusterHealthy`,
  `ControlPlaneComponentsHealthy`, `MachinesReady`, `MachinesUpToDate`,
  `RollingOut`, `ScalingUp`/`ScalingDown`, `Remediating`, `Deleting`, plus
  per-Machine pod/etcd-member conditions
  (`capi/api/controlplane/kubeadm/v1beta2/kubeadm_control_plane_types.go:74-421,504-517`).
  None of these read anything from your module beyond what is described
  above.

## Lifecycle constraints

- **Init ordering.** KCP creates nothing until the Cluster is both
  `infrastructureProvisioned` and has a valid endpoint; CABPK waits on the
  same gate. The first control-plane Machine gets init data; every other
  Machine (control-plane or worker) waits on
  `Cluster.status.initialization.controlPlaneInitialized`
  (`capi/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/kubeadmcontrolplane_controller.go:316,413,439`;
  `capi/bootstrap/kubeadm/reconcilers/kubeadmconfig/kubeadmconfig_controller.go:289-298,352-368,466-495`).
- **Join is serialized.** Scale-up preflight requires certificates
  available, no Machine deleting, and **every** existing control-plane
  Machine already healthy with a `nodeRef`. A failed preflight requeues
  after 15s, so control-plane joins are serialized on your apply time plus
  kubeadm join time
  (`capi/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/scale.go:60-97`;
  `preflight.go:61-218`).
- **Rollout.** `maxSurge` is 0 or 1 (default 1): with 1, KCP scales up
  then down, one Machine at a time; with 0 it scales down first
  (`capi/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/update.go:103-120`).
  Rotation is by creating a new `TerraformMachineTemplate` name; edits to
  an existing template's content are never detected.
- **Deleting blocks everything.** While any control-plane Machine has a
  deletion timestamp, KCP pauses scale-up, scale-down, rollout and
  remediation
  (`capi/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/preflight.go:111-122`).
  A slow or stuck machine-module destroy therefore freezes the whole
  control plane, not just that Machine.
- **Remediation gates and retries.** Post-initialization remediation
  needs more than one replica, no Machine still provisioning without a
  Node, no Machine deleting, and preserved etcd quorum; one remediation
  runs at a time
  (`capi/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/remediation.go:138-313`).
  `remediation.maxRetry` defaults to unlimited and `retryPeriodSeconds`
  defaults to `0` (retry immediately)
  (`capi/api/controlplane/kubeadm/v1beta2/kubeadm_control_plane_types.go:631-673`).
  See [module checklist](#module-checklist) for the template defaults
  this motivates.
- **No built-in control-plane MHC.** KCP does its own remediation and is
  not configured through a MachineHealthCheck object. Ship a plain
  MachineHealthCheck selecting `cluster.x-k8s.io/control-plane: ""` (or a
  ClusterClass `controlPlane.healthCheck`) if you want MHC-driven
  remediation in addition to KCP's own
  (`capi/docs/book/src/tasks/automated-machine-management/healthchecking.md:76-99`).
- **Version skew.** `KubeadmControlPlane.spec.version` must be valid
  semver with a `v` prefix, and an update may move at most one minor
  version
  (admission webhook, `capi/controlplane/kubeadm/webhooks/admission/kubeadmcontrolplane.go:322-328,619-662`).
- **Cluster deletion.** Workers and MachinePools are deleted first; once
  only control-plane Machines remain, KCP deletes **all** of them in
  parallel, with no drain
  (`capi/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/kubeadmcontrolplane_controller.go:720-813`).
  Expect concurrent destroy Jobs on cluster teardown.
- **Failed create cleanup.** KCP creates the InfraMachine before the
  Machine object. If KubeadmConfig or Machine creation then fails, KCP
  deletes the InfraMachine directly, with no Machine owner reference at
  all
  (`capi/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/helpers.go:160-219`).
  CAPTF's delete webhook already allows a delete with no Machine owner
  reference for exactly this reason (see
  [`../contract/v1alpha1/machine.md`](../contract/v1alpha1/machine.md)
  "Delete") — nothing further is required of your module.

## Networking and load balancer

- **Endpoint before any Machine.** KCP creates no Machine at all until
  `Cluster.spec.controlPlaneEndpoint.IsValid()`
  (`capi/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/kubeadmcontrolplane_controller.go:438-457`).
- **Frontend port.** `control_plane_endpoint.port`, any value 1-65535.
- **Backend port.** The kube-apiserver bind port, i.e. KubeadmConfig
  `localAPIEndpoint.bindPort` (default 6443). CABPK/KCP never read
  `Cluster.spec.clusterNetwork.apiServerPort`, so treat
  `api_server_port ?? 6443` as a convention your templates must keep in
  sync with `bindPort` yourselves
  (`capi/controlplane/kubeadm/pkg/workload_cluster.go:281-291`).
- **Reachability, including hairpin.** The endpoint must be reachable
  from the management cluster, from every control-plane and worker node
  (join discovery, kubelet), and from the first control-plane Machine
  itself. This last point is the hairpin requirement: kubeadm's
  `getKubeConfigSpecsBase` sets the server URL of `admin.conf`,
  `super-admin.conf` and `kubelet.conf` to the control-plane endpoint, not
  the node's own local address, so the node that is itself an LB backend
  must be able to reach the frontend it was just registered behind (see
  [`../contract/v1alpha1/cluster.md`](../contract/v1alpha1/cluster.md)
  "Hairpin reachability", citing kubeadm's
  `cmd/kubeadm/app/phases/kubeconfig/kubeconfig.go` ~L582-626,
  kubernetes/kubernetes release-1.33).
- **Backend membership.** Your machine module MUST register (and on
  destroy deregister) each control-plane instance in the LB backend from
  its own state
  (`capi/docs/book/src/developer/providers/contracts/infra-machine.md:633,645`;
  [`../contract/v1alpha1/machine.md`](../contract/v1alpha1/machine.md)
  "Control-plane machines"). The instance MUST be in the backend before
  `kubeadm init`/`kubeadm join` finishes on it, or
  `controlPlaneInitialized` never latches
  (`capi/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/status.go:195-207`).
- **Health check.** Either plain TCP, or HTTPS `/readyz`/`/healthz`
  without certificate verification, works; the check must be able to go
  green with a single backend during init. CAPD's reference LB uses
  haproxy `option httpchk GET /healthz` with `check-ssl verify none`
  against backend 6443
  (`capi/test/infrastructure/docker/internal/loadbalancer/config.go:81-83`).
- **Security groups / firewall.** Backend port (bindPort) from the LB,
  from all nodes, and from the management cluster; TCP 2379-2380 and
  10250 between control-plane nodes; 10250 from control-plane nodes to
  workers. KCP itself reaches etcd only through an apiserver pod
  port-forward, so the management cluster needs no direct etcd or kubelet
  port
  (`capi/controlplane/kubeadm/pkg/etcd_client_generator.go:53`;
  `capi/controlplane/kubeadm/pkg/proxy/dial.go:72-120`).

## Module checklist

### Cluster module

- MUST output a valid `control_plane_endpoint` (host and port) no later
  than the apply that makes the cluster `provisioned`, when no user
  endpoint is given — there is no other source with KCP
  (`capi/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/kubeadmcontrolplane_controller.go:316,439`;
  see [what KubeadmControlPlane
  reads](#what-kubeadmcontrolplane-reads-from-your-modules)).
  `tfcapi-lint`'s `output/endpoint-never-set` check warns on a module
  that never emits one (see [cluster.md's `EndpointAvailable`
  condition](../contract/v1alpha1/cluster.md#endpointavailable-condition)
  and the
  [tfcapi-lint CLI reference](../../reference/tfcapi-lint-cli.md)).
- MUST keep the emitted `control_plane_endpoint` stable for the life of
  the object: CAPI never updates `Cluster.spec.controlPlaneEndpoint`
  after the first valid copy
  (`capi/core/reconcilers/cluster/cluster_controller_phases.go:217-228`),
  so replacing the LB behind it (new DNS name or IP) breaks every
  kubeconfig and the API server certificate SANs. The controller
  neither detects nor prevents such a replacement;
  `lifecycle { prevent_destroy = true }` on the resource behind the
  endpoint turns it into a failed Job instead of a lost cluster
  ([`../contract/v1alpha1/cluster.md`](../contract/v1alpha1/cluster.md)
  `control_plane_endpoint` output).
- MUST create a stable LB or VIP reachable from the management cluster,
  all nodes, and the control-plane nodes themselves (hairpin, see
  [networking and load balancer](#networking-and-load-balancer)).
- MUST use a frontend on `control_plane_endpoint.port` and a backend on
  `api_server_port ?? 6443`, kept equal to the KubeadmConfig `bindPort`
  your templates configure
  (`capi/controlplane/kubeadm/pkg/workload_cluster.go:281-291`; see
  [networking and load balancer](#networking-and-load-balancer)).
- SHOULD publish the LB target/backend-pool id in `exports` for machine
  modules to register against — a CAPTF convention built on the
  contract's `exports` field, not a CAPI-mandated shape
  (`../contract/v1alpha1/cluster.md` `exports`).
- SHOULD leave `failure_domains[].control_plane` at its default `true`
  (`capi/controlplane/kubeadm/pkg/control_plane.go:171-184`; see [what
  KubeadmControlPlane reads](#what-kubeadmcontrolplane-reads-from-your-modules));
  a nil value is invisible to KCP.

### Machine module

- MUST register the control-plane instance in the LB target/backend-pool
  from `captf_cluster_outputs`, in the module's own state, before
  `kubeadm init`/`join` finishes on it
  (`capi/docs/book/src/developer/providers/contracts/infra-machine.md:633,645`;
  `capi/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/status.go:195-207`;
  see [networking and load balancer](#networking-and-load-balancer) and
  one of the three patterns in [README.md's LB-membership
  patterns](README.md#lb-membership-patterns)).
- MUST accept `bootstrap_data` opaquely as base64 and MUST NOT need to
  parse it, per
  [`../contract/v1alpha1/machine.md`](../contract/v1alpha1/machine.md)
  `bootstrap_data`.
- Control-plane payloads embed cluster CA and service-account private key
  material and are not compressed by CABPK (see [what KCP and CABPK
  write](#what-kcp-and-cabpk-write)). Payload size limits (for example a
  cloud's user-data cap) and keeping key material out of readable
  instance metadata are the module's responsibility: gzip the payload,
  or stage it in a secret store and pass only a small stub through
  `bootstrap_data`/user-data.
- MUST emit `provider_id` exactly matching the Node's `spec.providerID`;
  KCP gates join preflight, etcd-member matching and remediation on the
  resulting `nodeRef` (see [what KubeadmControlPlane
  reads](#what-kubeadmcontrolplane-reads-from-your-modules)).
- `addresses` are informational only for KCP — no KCP or CABPK code
  reads them.
- MUST make `failure_domain` output equal the `failure_domain` input when
  the input is non-null (`../contract/v1alpha1/machine.md` `failure_domain`
  output).

### Templates and health checks

- Bring-up time for N control-plane replicas is approximately
  N × (apply + boot + join), because every join is serialized on the
  previous Machine's `nodeRef` (see [lifecycle
  constraints](#lifecycle-constraints)). A rollout adds
  (apply + join + destroy) per replica.
- Ship `KubeadmControlPlane.spec.remediation.maxRetry` (e.g. `3`) and a
  non-zero `retryPeriodSeconds` in your templates: the unbounded defaults
  turn a control-plane module whose apply always fails into an endless
  create/destroy loop of cloud resources (see [lifecycle
  constraints](#lifecycle-constraints)).
- Ship a control-plane MachineHealthCheck (selector
  `cluster.x-k8s.io/control-plane: ""`, or a ClusterClass
  `controlPlane.healthCheck`). Its `InfrastructureReady=False` timeout
  MUST exceed apply time plus one drift interval — the same rule as any
  other machine module
  (`../contract/v1alpha1/machine.md` "Health → remediation").

## Open questions

- **Bootstrap payload size and secrecy.** The contract leaves the
  gzip/stub strategy to the module (see [module
  checklist](#module-checklist)); there is no CAPTF-side size or secrecy
  check today.
- **Unbounded remediation retry.** Combined with a deterministically
  failing module, KCP's default unlimited `maxRetry` causes
  cloud-resource churn. The [module checklist](#module-checklist)'s
  template-default recommendation is the only mitigation; there is no
  CAPTF-side guard against it.

## See also

- [`README.md`](README.md) — the shared creation sequence and the
  LB-membership patterns.
- [`rke2.md`](rke2.md) — the same requirements under RKE2ControlPlane.
- [`checklist.md`](checklist.md) — every requirement from both guides in
  one place.
- [The machine role](../contract/v1alpha1/machine.md) — the normative
  contract this guide builds on.
