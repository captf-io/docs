# RKE2ControlPlane

What RKE2ControlPlane (RCP) and the RKE2 bootstrap provider (CAPRKE2)
require of your CAPTF cluster and machine modules, and why this is the
case.

Citations below prefixed `rke2/` are paths in
`rancher/cluster-api-provider-rke2` at tag `v0.25.2`; `rke2docs/` is
`rancher/rke2-docs` (`main` branch); `capi/` is the CAPI v1.14.2 tree
(`https://github.com/kubernetes-sigs/cluster-api/tree/v1.14.2`).
See also [the shared creation sequence](README.md#the-shared-creation-sequence)
and [the requirements checklist](checklist.md) for every requirement in
one place.

## Version and compatibility

CAPRKE2 v0.25.2 is built against `sigs.k8s.io/cluster-api v1.13.5`
(`rke2/go.mod:33`) and its v1beta2 API is the contract version CAPTF also
targets. Its own e2e suite runs only against CAPI core v1.12.11 and
v1.13.5 (`rke2/test/e2e/config/e2e_conf.yaml:22,33`), and its
getting-started guide pins CAPI core to v1.13.5
(`rke2/docs/book/src/01_user/01_getting-started.md:56`).

CAPTF runs CAPI v1.14.2. The contract shape is unchanged, but **CAPI
v1.14 core is untested by CAPRKE2 v0.25.2** — run a compatibility smoke
test before relying on it in production; see [open
questions](#open-questions).

## What RKE2ControlPlane reads from your modules

- **`Cluster.status.initialization.infrastructureProvisioned`.** RCP
  creates nothing — not even certificates — until this is `true`; RKE2Config
  generates no bootstrap data until it is `true` either
  (`rke2/controlplane/internal/controllers/rke2controlplane_controller.go:376-394`;
  `rke2/bootstrap/internal/controllers/rke2config_controller.go:171-182`).
- **`Cluster.spec.controlPlaneEndpoint`.** A hard gate: RCP creates no
  Machine at all — including the first — while the endpoint is not valid
  (host and port both set)
  (`rke2/controlplane/internal/controllers/rke2controlplane_controller.go:421-440`).
  Only the endpoint's **host** feeds the RKE2 `tls-san` list and the init
  node's `ServerURL` (`https://<host>:9345`); the endpoint's **port is
  ignored** for the supervisor join URL, which is always 9345
  (`rke2/pkg/rke2/config.go:350`;
  `rke2/bootstrap/internal/controllers/rke2config_controller.go:66,455-473`).
- **`Cluster.spec.clusterNetwork`.** `pods`/`services.cidrBlocks` map to
  `cluster-cidr`/`service-cidr` when non-empty
  (`rke2/pkg/rke2/config.go:209-215`). `serviceDomain` and
  `api_server_port` are **not read at all**: cluster domain comes from
  RKE2's own `serverConfig.clusterDomain`, and the API server is always on
  6443 on the node (`rke2/pkg/rke2/config.go:224-225`). Do not derive an
  LB backend port from `api_server_port` under RKE2 beyond using it as the
  frontend port if your templates choose to.
- **Failure domains.** Same rule as KCP: only entries with
  `controlPlane: true` are used for scale-up/scale-down placement; a nil
  `controlPlane` counts as `false`
  (`rke2/pkg/rke2/control_plane.go:176-190`).
- **`Machine.status.addresses`.** Read only for three of the five
  `registrationMethod` values, and only from Machines whose `Ready`
  condition is already `True` (the `registrationMethod` table below;
  `rke2/controlplane/internal/controllers/status.go:80,152,158-177`). The
  contract's canonical output order for `addresses` (InternalIP,
  InternalDNS, ExternalIP, ExternalDNS, Hostname — see
  [`../contract/v1alpha1/machine.md`](../contract/v1alpha1/machine.md)
  `addresses`) is what makes RCP's first-match logic deterministic; your
  module's job is only to **emit the address type(s) each method
  requires** (below), not to order them — the controller does that.
- **`Machine.status.nodeRef`.** Used for etcd leader-move/member-removal
  ordering and remediation; `HasHealthyMachineStillProvisioning` = a
  healthy Machine with no Node yet
  (`rke2/pkg/rke2/workload_cluster_etcd.go:40-45`;
  `rke2/pkg/rke2/control_plane.go:527-529`).
- **`registrationMethod`** (immutable once set, enforced by webhook):

  | Method | `status.availableServerIPs` = | Address types your module must supply | Join URL |
  | --- | --- | --- | --- |
  | `control-plane-endpoint` (default, `""` ≡ this) | `[endpoint.host]` | none | `https://<endpoint host>:9345` |
  | `address` | `[spec.registrationAddress]` | none | `https://<registrationAddress>:9345` |
  | `internal-first` | first `InternalIP` or `ExternalIP` per Ready CP Machine, in list order | `InternalIP` and/or `ExternalIP` | `https://<ip>:9345` |
  | `internal-only-ips` | first `InternalIP` per Ready CP Machine | `InternalIP` | `https://<ip>:9345` |
  | `external-only-ips` | first `ExternalIP` per Ready CP Machine | `ExternalIP` | `https://<ip>:9345` |

  (`rke2/pkg/registration/registration.go:46,68-140`;
  `rke2/controlplane/api/v1beta2/rke2controlplane_types.go:97-100`;
  `rke2/controlplane/api/v1beta2/rke2controlplane_webhook.go:142-145,211-214`.)
  A Ready Machine with no address of the required type produces the RCP
  status error "ready but they have no IP Address available"
  (`rke2/controlplane/internal/controllers/status.go:175-177`); see
  [open questions](#open-questions).
- **`RKE2ControlPlane.spec.version`.** Must match
  `(v\d\.\d{2}\.\d+\+rke2r\d)|^$` and is copied verbatim to
  `Machine.spec.version`
  (`rke2/controlplane/api/v1beta2/rke2controlplane_types.go:79-81`;
  `rke2/controlplane/internal/controllers/scale.go:566-567,612`). See
  [`../contract/v1alpha1/machine.md`](../contract/v1alpha1/machine.md)
  `kubernetes_version` and the [module checklist](#module-checklist).

## What RCP and RKE2Config write

- **Bootstrap Secret.** Name = RKE2Config name; keys `value` and `format`
  are **always** both written (there is no case where `format` is
  absent); `format` defaults to `cloud-config`
  (`rke2/bootstrap/internal/controllers/rke2config_controller.go:1040-1061`;
  `rke2/bootstrap/api/v1beta2/rke2config_webhook.go:79-80`). See
  [`../contract/v1alpha1/machine.md`](../contract/v1alpha1/machine.md)
  `bootstrap_format`.
- **Ignition is supported** end to end (init, CP join, worker), via
  Butane → Ignition 3.3
  (`rke2/bootstrap/internal/controllers/rke2config_controller.go:552-556,798-802,927-931`).
- **`gzipUserData: true`.** For cloud-config, `value` becomes raw gzip
  bytes (not base64, not UTF-8 text); `format` stays `cloud-config`. For
  Ignition, the gzip is wrapped inside the Ignition config instead
  (`rke2/bootstrap/internal/controllers/rke2config_controller.go:1015-1037`).
  See [machine.md's `bootstrap_data`
  input](../contract/v1alpha1/machine.md#inputs) for how the contract
  resolves the binary-payload question, and the [module
  checklist](#module-checklist) for what it means for your module.
- **Cluster Secrets.** `<cluster>-ca`, `-cca` (client CA), `-peer-etcd`,
  `-etcd`, `-kubeconfig`, `-token`. No `-sa`, no `-proxy` (contrast with
  KCP's secret set, [kubeadm.md's what KCP and CABPK
  write](kubeadm.md#what-kcp-and-cabpk-write))
  (`rke2/pkg/secret/certificates.go:52-80,168-190,382-384`).
- **Machine labels/annotations.** Template labels plus forced
  `cluster.x-k8s.io/cluster-name`, `cluster.x-k8s.io/control-plane: ""`;
  a `pre-terminate.delete.hook.machine.cluster.x-k8s.io/rke2-cleanup`
  annotation on every control-plane Machine
  (`rke2/controlplane/internal/controllers/scale.go:650-666,577-578`).
- **RCP status (v1beta2).** `initialization.controlPlaneInitialized`
  (true once the workload `kube-system/rke2-serving` Secret exists, or
  once every owned Machine is Ready); `availableServerIPs`; conditions
  including `EtcdClusterHealthy`, `ControlPlaneComponentsHealthy`,
  `Remediating`
  (`rke2/controlplane/internal/controllers/status.go:98-194`;
  `rke2/controlplane/api/v1beta2/rke2controlplane_types.go:262-316`).
- **Node identity.** CAPRKE2 **never sets** kubelet `provider-id`,
  `node-ip` or `node-name` itself; the fields exist in its config but
  nothing in the repo writes them (`rke2/pkg/rke2/config.go:501-503`). See
  the [module checklist](#module-checklist) and [machine.md's node
  providerID matching](../contract/v1alpha1/machine.md#node-providerid-matching-module-authors)
  — RKE2.

## Lifecycle constraints

- **Init.** Exactly one control-plane Machine gets init data, guarded by
  an init-lock ConfigMap. The init node has no `server:` configured — it
  creates the cluster standalone and, notably, needs **no LB/9345
  reachability to itself** during init, unlike the hairpin requirement
  that applies to every later join
  (`rke2/controlplane/internal/controllers/scale.go:51-99`;
  `rke2/pkg/rke2/config.go:650-676`). Don't read this as weakening the
  general endpoint-reachability requirement in [networking and load
  balancer](#networking-and-load-balancer): it applies to every Machine
  that joins, i.e. every control-plane Machine after the first, and to
  every worker.
- **Join (control-plane and worker), in order.** Requires the Cluster's
  `ControlPlaneInitialized` condition; the `<cluster>-token` Secret; and
  `RCP.status.availableServerIPs` non-empty, which itself needs at least
  one **Ready** control-plane Machine and a reachable workload API server
  via the `<cluster>-kubeconfig` Secret
  (`rke2/bootstrap/internal/controllers/rke2config_controller.go:230,699-703,852-856`;
  `rke2/controlplane/internal/controllers/status.go:114-146,152`). Both
  CP joins and worker joins use `availableServerIPs[0]`
  (`rke2/bootstrap/internal/controllers/rke2config_controller.go:717,867`).
- **Rollout.** `maxSurge` 0 or 1, default 1; scale-up then scale-down of
  the oldest outdated Machine in the most-populated failure domain
  (`rke2/controlplane/api/v1beta2/rke2controlplane_types.go:548-580`;
  `rke2/controlplane/internal/controllers/scale.go:285-334`).
- **Preflight (scale up/down, in-place).** No Machine deleting; every
  control-plane Machine must have `AgentHealthy` and `EtcdMemberHealthy`
  both `True` (`Unknown` or missing blocks); a missing Node blocks by
  extension
  (`rke2/controlplane/internal/controllers/scale.go:200-266`).
- **Scale-down / deletion.** Etcd leadership is forwarded to the newest
  Machine, then the Machine is deleted; the `rke2-cleanup` pre-terminate
  hook re-forwards leadership, annotates the Node for etcd removal, and
  waits for confirmation before releasing — InfraMachine deletion happens
  only after that
  (`rke2/controlplane/internal/controllers/scale.go:141-197`).
- **Remediation.** RCP remediates control-plane Machines with
  `HealthCheckSucceeded=False` + `OwnerRemediated=False`
  (MHC-driven). Pre-init remediation is allowed directly; post-init
  remediation additionally requires more than one replica, no Machine
  still provisioning without a Node, no Machine deleting, and preserved
  etcd quorum
  (`rke2/controlplane/internal/controllers/remediation.go:97-330,366-420`).
  [Machine.md's health → remediation
  section](../contract/v1alpha1/machine.md#lifecycle) already reflects
  this: remediation happens for Machines whose owner acts on the
  MachineHealthCheck's `MachineOwnerRemediated` condition, and RCP is
  such an owner for its own control-plane Machines, not only
  MachineSet and KubeadmControlPlane.
- **In-place updates.** Behind the CAPI `InPlaceUpdates` feature gate
  (alpha) plus exactly one registered `CanUpdateMachine` extension;
  otherwise falls back to delete/recreate. Not something a CAPTF module
  needs to support, since `TerraformMachine.spec.source` is immutable regardless
  (`rke2/controlplane/main.go:287`).
- **Payload size / air-gap.** Init control-plane user-data embeds four CA
  key pairs plus config and optional manifest/registry/audit files.
  Non-air-gapped installs `curl -sfL https://get.rke2.io` at boot, which
  means **node internet egress**; `airGapped: true` expects pre-baked
  artifacts in the image instead
  (`rke2/bootstrap/internal/cloudinit/controlplane_init.go:34-36`).
  `gzipUserData` exists for size-limited clouds; see [machine.md's
  `bootstrap_data` input](../contract/v1alpha1/machine.md#inputs) for
  how the contract handles the resulting binary payload.

## Networking and load balancer

| Path | Port | Needed when |
| --- | --- | --- |
| LB/VIP → CP nodes | 6443/TCP (endpoint port → node 6443; RKE2 ignores `apiServerPort`) | always |
| LB/VIP → CP nodes | 9345/TCP supervisor, **same host** as the endpoint | `control-plane-endpoint` (default) and `address` registration methods |
| All nodes → CP nodes | 6443, 9345 TCP direct (after registration) | always |
| CP ↔ CP | 2379, 2380, 2381 TCP | embedded etcd (not with `externalDatastoreSecret`) |
| all ↔ all | 10250 TCP; NodePort range (default 30000-32767) | always |
| CNI (default canal) | 8472/UDP VXLAN, 9099/TCP | `cni: canal` or unset |

(`rke2/controlplane/internal/controllers/rke2controlplane_controller.go:757`;
`rke2docs/docs/install/ha.md:42`; `rke2docs/docs/install/requirements.md:128,142-148,158-161`.)

- **No LB listener on 2379 is needed.** The controller reaches etcd only
  by port-forwarding through the API server; an LB entry for 2379 is not
  required by anything in RCP
  (`rke2/pkg/proxy/dial.go:99-106`; `rke2/pkg/etcd/client_generator.go:34`).
- **Health checks.** 9345: TLS `GET /v1-rke2/readyz` expecting **403**
  (unauthenticated) — or plain TCP. 6443: TCP, or HTTPS `/healthz` only
  if anonymous auth is enabled
  (`rke2/examples/templates/docker/cluster-template.yaml:60,176-194`).
- **DNS endpoints are supported.** RKE2 HA supports a DNS name /
  round-robin DNS as the fixed registration address; the endpoint host is
  added to `tls-san` automatically. `registrationAddress` is **not**
  added to `tls-san` automatically — add it via `serverConfig.tlsSan` if
  it differs from the endpoint host
  (`rke2docs/docs/install/ha.md:36-37`; `rke2/pkg/rke2/config.go:350`).
- **Backend membership.** The module owns LB membership — nothing in RCP
  or CAPI registers a backend for you. The instance MUST be added before
  its Machine is Ready (joins happen through the LB during bring-up), and
  the LB MUST tolerate a backend whose supervisor is not yet up (see
  [lifecycle constraints](#lifecycle-constraints), "Join").

## Module checklist

### Cluster module

- MUST output a valid `control_plane_endpoint` (host and port) no later
  than the apply that makes the cluster `provisioned`, unless the user
  sets one — RCP creates no Machine at all until
  `Cluster.spec.controlPlaneEndpoint.IsValid()`
  (`rke2/controlplane/internal/controllers/rke2controlplane_controller.go:421-440`;
  see [what RKE2ControlPlane
  reads](#what-rke2controlplane-reads-from-your-modules)). This matches
  the contract's own endpoint-timing rule in
  [`../contract/v1alpha1/cluster.md`](../contract/v1alpha1/cluster.md)
  `control_plane_endpoint` output.
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
- MUST provision **two** LB listeners on the same host: `endpoint.port`
  → CP nodes `:6443`, and `:9345` → CP nodes `:9345` — not just one, as
  with KCP (`rke2docs/docs/install/ha.md:42`; see [networking and load
  balancer](#networking-and-load-balancer)).
- MUST NOT rely on `cluster_network.api_server_port` or `service_domain`
  to configure RKE2; RKE2 reads neither
  (`rke2/pkg/rke2/config.go:224-225`; see [what RKE2ControlPlane
  reads](#what-rke2controlplane-reads-from-your-modules)).
- Backend membership is the module's job (not CAPI's): a target group by
  tag/label, or an explicit attach resource — see the three patterns in
  [README.md's LB-membership patterns](README.md#lb-membership-patterns).
- SHOULD leave `failure_domains[].control_plane` at its default `true`
  (`rke2/pkg/rke2/control_plane.go:176-190`; see [what RKE2ControlPlane
  reads](#what-rke2controlplane-reads-from-your-modules)), same as under
  KCP.

### Machine module

- MUST accept both `bootstrap_format` values RCP can write,
  `cloud-config` and `ignition`
  (`rke2/bootstrap/internal/controllers/rke2config_controller.go:1040-1061`;
  see [what RCP and RKE2Config write](#what-rcp-and-rke2config-write)).
- MUST register the control-plane instance in both the 6443 and 9345 LB
  target sets, and open/attach the corresponding security rules, before
  the Machine becomes Ready
  (`capi/docs/book/src/developer/providers/contracts/infra-machine.md:633,645`;
  see [networking and load balancer](#networking-and-load-balancer)).
- MUST supply `addresses` of the type(s) the cluster's
  `registrationMethod` needs (the `registrationMethod` table in [what
  RKE2ControlPlane reads](#what-rke2controlplane-reads-from-your-modules))
  when that method is anything other than
  `control-plane-endpoint`/`address`; the controller, not the module, is
  responsible for output ordering
  (`../contract/v1alpha1/machine.md` `addresses`).
- MUST emit `provider_id` matching exactly what the Node's kubelet
  registers — either via a cloud-controller-manager, or via
  `agentConfig.kubelet.extraArgs: [provider-id=<value>]` set from
  instance metadata, since CAPRKE2 sets none of this itself (see [what
  RCP and RKE2Config write](#what-rcp-and-rke2config-write)). Under RKE2
  a mismatch on the **first** control-plane Machine blocks every
  subsequent join, not just that Machine's own readiness, because every
  join needs `availableServerIPs` non-empty, which needs a Ready CP
  Machine (see [what RKE2ControlPlane
  reads](#what-rke2controlplane-reads-from-your-modules) and [lifecycle
  constraints](#lifecycle-constraints)).
- `kubernetes_version` arrives as `vX.Y.Z+rke2rN`; strip the `+rke2rN`
  suffix before using it for an image lookup or a semver comparison (see
  [what RKE2ControlPlane
  reads](#what-rke2controlplane-reads-from-your-modules)).
- Init/CP-join payloads embed four CA key pairs; on size-limited clouds
  both `cloud-config` + `gzipUserData: true` and `ignition` +
  `gzipUserData: true` work for reducing payload size (see [what RCP and
  RKE2Config write](#what-rcp-and-rke2config-write)). Either way the
  module MUST route `bootstrap_data` to a base64-taking argument (e.g.
  `user_data_base64`); it MUST NOT `base64decode()` it, because a
  gzipped payload is not valid UTF-8.

## Differences from KubeadmControlPlane

| Aspect | KubeadmControlPlane | RKE2ControlPlane v0.25.2 |
| --- | --- | --- |
| LB ports | API port only | API (6443) **and** supervisor 9345, same host |
| Join target | CP endpoint, backend port | `availableServerIPs[0]`:9345 — endpoint host, `registrationAddress`, or a CP Machine IP |
| Uses `Machine.status.addresses` | no | yes, for 3 of 5 `registrationMethod` values |
| Join gate | Cluster `ControlPlaneInitialized` | that, **plus** ≥1 Ready CP Machine (needs Node ⇒ providerID match) |
| `Machine.spec.version` | `vX.Y.Z` | `vX.Y.Z+rke2rN` |
| `clusterNetwork.apiServerPort` | not wired to bindPort either, but the field exists as a convention (see [kubeadm.md's what it reads](kubeadm.md#what-kubeadmcontrolplane-reads-from-your-modules)) | ignored entirely; 6443 is fixed |
| `clusterNetwork.serviceDomain` | honored by CABPK | ignored (`serverConfig.clusterDomain`) |
| Bootstrap `format` | always present (`cloud-config` or `ignition`) | always present |
| Secrets | `-ca`, `-etcd`, `-sa`, `-proxy`, `-kubeconfig` | `-ca`, `-cca`, `-etcd`, `-peer-etcd`, `-kubeconfig`, `-token` |
| etcd removal | KCP pre-terminate hook, etcd client | `rke2-cleanup` pre-terminate hook, Node annotation `etcd.rke2.cattle.io/remove` |
| Install | kubeadm/kubelet pre-installed in image | `curl get.rke2.io` at boot unless air-gapped artifacts are baked in |
| Contract | v1beta2, built on CAPI v1.14 | v1beta2, built on CAPI v1.13.5 |

(Individual rows cited in the corresponding sections above and in
`kubeadm.md`.)

## Open questions

- **No `InternalIP` guarantee.** `addresses` may legally be `[]`
  (`../contract/v1alpha1/machine.md` `addresses`). For
  `internal-only-ips`/`external-only-ips`/`internal-first`, a Ready
  Machine without the right address type blocks every subsequent join
  with an RCP status error (see [what RKE2ControlPlane
  reads](#what-rke2controlplane-reads-from-your-modules)). No
  `tfcapi-lint` rule warns when a module never emits an `InternalIP`.
- **CAPI v1.14 compatibility.** CAPRKE2 v0.25.2 is tested only up to
  CAPI core v1.13.5 (see [version and
  compatibility](#version-and-compatibility)). CAPTF runs v1.14.2. Run a
  compatibility smoke test against v1.14.2 before relying on
  RKE2ControlPlane in production; watch for a CAPRKE2 release built on
  v1.14.
- **Nondeterministic join target.** Under IP-based `registrationMethod`
  values, `availableServerIPs` is built by iterating a Go map, so which
  control-plane node a joiner targets is nondeterministic, and a stale
  or just-removed node's address can be chosen until the next status
  refresh (see [what RKE2ControlPlane
  reads](#what-rke2controlplane-reads-from-your-modules);
  `rke2/bootstrap/internal/controllers/rke2config_controller.go:717,867`).
  A module cannot fix this directly; a Machine that leaves `Ready` (for
  example through a MachineHealthCheck) drops out of
  `availableServerIPs` on the next status refresh.

## See also

- [`README.md`](README.md) — the shared creation sequence and the
  LB-membership patterns.
- [`kubeadm.md`](kubeadm.md) — the same requirements under
  KubeadmControlPlane.
- [`checklist.md`](checklist.md) — every requirement from both guides in
  one place.
- [The machine role](../contract/v1alpha1/machine.md) — the normative
  contract this guide builds on.
