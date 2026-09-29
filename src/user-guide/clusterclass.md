# Templates and ClusterClass

This page covers the clusterctl templates CAPTF ships, how to generate a
cluster from them, and the `noop` `ClusterClass`: what it creates, its
topology variables, and how to patch a module variable onto it. It is for
anyone creating clusters with CAPTF, especially with `ClusterClass`.

## Before you begin

- The provider is installed and registered with `clusterctl`
  ([Installation](../operator-guide/installation.md)).
- A `TerraformClusterIdentity` is applied for the namespace you are
  generating into ([Identities and credentials](identities.md)).
- Your cluster and machine module images are built, linted and pushed
  ([tfcapi-lint](../module-author/tfcapi-lint.md),
  [image contract](../module-author/image-contract.md)).
- You know the values for the `clusterctl` variables you need
  ([clusterctl variables](../reference/clusterctl-variables.md)).

## The shipped flavors

CAPTF ships three flavors as `templates/cluster-template*.yaml` files;
once the provider is registered, `clusterctl generate cluster
--infrastructure terraform` renders one of them from the registered
repository ([Installation](../operator-guide/installation.md)):

| Flavor | Template file | What it creates |
| --- | --- | --- |
| Default (no `--flavor`) | `cluster-template.yaml` | A `Cluster`, `TerraformCluster`, `KubeadmControlPlane`, two `TerraformMachineTemplate`s (control plane and workers), a `MachineDeployment` with its `KubeadmConfigTemplate`, and a `MachineHealthCheck` for each of the control plane and the workers |
| `clusterclass` | `cluster-template-clusterclass.yaml` | A `Cluster` with `spec.topology.classRef.name: noop`, referencing the `noop` `ClusterClass` |
| `libvirt` | `cluster-template-libvirt.yaml` | The same shape as the default flavor, sized for the development host's libvirt modules: kube-vip on the control plane, and nodes that install containerd and Kubernetes at boot from the version in the machine's cloud-init metadata rather than a version clusterctl baked in |

Every flavor's `KubeadmControlPlane` sets `spec.remediation.maxRetry: 3`
and `retryPeriodSeconds: 300`, so a module that fails deterministically
stops being retried instead of churning cloud resources, and its
`localAPIEndpoint.bindPort` (init and join) equals
`Cluster.spec.clusterNetwork.apiServerPort` (6443); kubeadm never reads
the Cluster field, so keep the two equal if you change one.

The `libvirt` flavor is for the project's development host; see
[the libvirt host guide](../developer-guide/libvirt-host.md) and
[the libvirt module](https://github.com/scrothers/cluster-api-provider-terraform/blob/main/modules/libvirt/README.md).
Its identity template is `templates/identity-libvirt.yaml`, applied instead
of the default `templates/identity.yaml`.

## Generate a cluster

Set the identity, image and sizing variables, then generate and apply.
Default flavor:

```sh
export TERRAFORM_IDENTITY_NAME=<identity-name> \
  TERRAFORM_CLUSTER_IMAGE=<cluster-module-image> \
  TERRAFORM_MACHINE_IMAGE=<machine-module-image>
clusterctl generate cluster <cluster-name> --infrastructure terraform \
  --target-namespace <namespace> \
  --kubernetes-version <version> \
  --control-plane-machine-count <count> --worker-machine-count <count> \
  | kubectl apply -f -
```

`ClusterClass` flavor: enable the `ClusterTopology` feature gate when you
register the provider ([Installation](../operator-guide/installation.md));
it is alpha and off by default. Apply the class to the namespace once, then
generate with `--flavor clusterclass`:

```sh
kubectl apply -n <namespace> -f templates/clusterclass-noop.yaml
clusterctl generate cluster <cluster-name> --infrastructure terraform \
  --flavor clusterclass --target-namespace <namespace> \
  --kubernetes-version <version> \
  --control-plane-machine-count <count> --worker-machine-count <count> \
  | kubectl apply -f -
```

`clusterclass-noop.yaml` carries no `clusterctl` variables of its own and no
namespace, so apply it once to every namespace that generates clusters from
it. Neither flavor defaults `CLUSTER_NAME`, `KUBERNETES_VERSION`,
`CONTROL_PLANE_MACHINE_COUNT`, `WORKER_MACHINE_COUNT`, the two image
variables or the identity name: a missing one fails `clusterctl generate`
instead of deploying something unintended. See
[clusterctl variables](../reference/clusterctl-variables.md) for the full
list, including the `libvirt` flavor's defaults.

## The noop ClusterClass

`templates/clusterclass-noop.yaml` defines `ClusterClass noop` and the
templates it references:

- `TerraformClusterTemplate/noop`, the infrastructure template.
- `KubeadmControlPlaneTemplate/noop-control-plane` and
  `TerraformMachineTemplate/noop-control-plane`, the control plane and its
  infrastructure.
- `TerraformMachineTemplate/noop-worker` and
  `KubeadmConfigTemplate/noop-worker`, the infrastructure and bootstrap for
  the `default-worker` machine deployment class.

Each of the three Terraform templates carries the placeholder image
`example.invalid/captf/set-by-clusterclass:unset`: a Cluster that fails to
patch a real image gets a failed image pull instead of running an
unintended module. The class also carries default `MachineHealthCheck`
timeouts for the control plane and the workers; the `clusterclass` flavor
overrides them through `Cluster.spec.topology` with the same variables as
`cluster-template.yaml` (see
[clusterctl variables](../reference/clusterctl-variables.md)).

The class declares three required string topology variables —
`identityName`, `clusterImage` and `machineImage` — described in
[the ClusterClass topology variables table](../reference/clusterctl-variables.md#clusterclass-topology-variables).
Three patches apply them to the templates above:

- `identity` sets `spec.template.spec.identityRef` on
  `TerraformClusterTemplate/noop` to `identityName`, and also sets
  `spec.template.spec.defaults.identityRef` to the same value, so machines
  without their own `identityRef` inherit it.
- `clusterImage` replaces `spec.template.spec.source.image` on
  `TerraformClusterTemplate/noop` with `clusterImage`.
- `machineImage` replaces `spec.template.spec.source.image` on both
  `TerraformMachineTemplate/noop-control-plane` and
  `TerraformMachineTemplate/noop-worker` with `machineImage`, matched by
  `matchResources.controlPlane` and
  `matchResources.machineDeploymentClass.names: [default-worker]`.

`cluster-template-clusterclass.yaml` sets the three variables from
`TERRAFORM_IDENTITY_NAME`, `TERRAFORM_CLUSTER_IMAGE` and
`TERRAFORM_MACHINE_IMAGE`.

## Patch a module variable through ClusterClass

A `ClusterClass` patch can also turn a topology variable into a module
variable (`spec.template.spec.variables`;
[module variables](variables.md)). Declare the topology variable, then add a
patch whose `jsonPatches` write `/spec/template/spec/variables` (or one key
under it, if the template already sets others):

```yaml
spec:
  variables:
  - name: workerInstanceType
    required: true
    schema:
      openAPIV3Schema:
        type: string
  patches:
  - name: workerInstanceType
    definitions:
    - selector:
        apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
        kind: TerraformMachineTemplate
        matchResources:
          machineDeploymentClass:
            names: [default-worker]
      jsonPatches:
      - op: add
        path: /spec/template/spec/variables
        valueFrom:
          template: |
            instance_type: {{ .workerInstanceType }}
```

The same patch on `TerraformClusterTemplate` reaches the `TerraformCluster`
instead, whose `spec.variables` is mutable: changing the variable
re-applies the cluster module, and a destructive plan still waits for
approval ([plan approval](plan-approval.md)). A `ConfigMap` or `Secret`
named in `variablesFrom` is not part of the `ClusterClass`: create it,
labeled `captf.io/variables=true`, in each namespace that uses the class
([module variables](variables.md)).

## Template immutability and rolling out a change

A `*Template` kind's `spec.template.spec` cannot be edited in place once
created; only its metadata can change (see
[mutability per kind](../concepts/kinds.md)). `ClusterClass` topology
reconciliation is exempt from that rule for its own dry-runs, which is how
patching works at all, but a direct edit to a `*Template` object is
rejected.

Two situations follow from this:

- **A field the class exposes as a topology variable.** Changing the
  variable's value on a Cluster's `spec.topology.variables` is enough:
  since the resulting `TerraformMachineTemplate` would differ from the one
  already referenced, and templates are immutable, the topology controller
  creates a new `TerraformMachineTemplate` with the patched spec and rolls
  the affected `MachineDeployment` or control plane onto it. Changing
  `machineImage` on a `clusterclass`-flavor Cluster works this way.
- **A field the class does not expose as a variable**, such as a
  `KubeadmControlPlaneTemplate` field or a new patch. Create a new template
  object under a new name with the desired `spec.template.spec`, then
  update the `ClusterClass`'s reference to it — `spec.infrastructure.templateRef`,
  `spec.controlPlane.templateRef`,
  `spec.controlPlane.machineInfrastructure.templateRef`, or the matching
  `workers.machineDeployments[].infrastructure.templateRef` /
  `bootstrap.templateRef` — and apply the class. Topology reconciliation
  then rolls every Cluster on the class onto the new template, subject to
  each machine deployment's or control plane's own rollout strategy (the
  `noop` class's control plane sets `maxSurge: 0`; its `default-worker`
  machine deployment class leaves the rollout strategy unset, so the
  default `maxSurge: 1` applies).

A `TerraformCluster` itself is mostly mutable — only
`spec.controlPlaneEndpoint` is immutable once it has a host — so a
`clusterImage` or `identityName` change re-applies the cluster module in
place rather than creating a new object.

## See also

- [Identities and credentials](identities.md)
- [Module variables](variables.md)
- [Plan approval](plan-approval.md)
- [The kinds](../concepts/kinds.md)
- [clusterctl variables](../reference/clusterctl-variables.md)
