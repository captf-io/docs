# Machine Pools

This page shows you how to create a `MachinePool` backed by a
`TerraformMachinePool`: a group of nodes CAPTF provisions and scales as one
native cloud scaling group (an autoscaling group, a scale set, an instance
group, or similar), rather than as individual `TerraformMachine`s. It
covers fixed and autoscaled replica counts, the group's reported members,
and deletion. See [The Kinds](../concepts/kinds.md) for how a
`TerraformMachinePool` compares to a `TerraformMachine`, and the
[machinepool contract](../module-author/contract/v1alpha1/machinepool.md)
for everything the module role must implement.

## Before you begin

- The provider installed, and a `TerraformCluster` provisioned or being
  provisioned (see [Installation](../operator-guide/installation.md)).
- A `TerraformClusterIdentity` allowed in your namespace (see
  [Identities and Credentials](identities.md)).
- A machinepool-role module image: one that implements the
  [machinepool contract](../module-author/contract/v1alpha1/machinepool.md),
  managing one scaling group and reporting its provider IDs, desired
  capacity and members.

## Create a MachinePool

A `MachinePool` has a single infrastructure object for its whole group,
not one per member: `MachinePool.spec.template.spec.infrastructureRef`
names one `TerraformMachinePool` directly, by kind and name, the same way
`Cluster.spec.infrastructureRef` names one `TerraformCluster`. There is no
per-replica cloning, so you create the `TerraformMachinePool` yourself
rather than pointing at a `TerraformMachinePoolTemplate`; a
`TerraformMachinePoolTemplate` exists only for a `MachinePool` a
ClusterClass topology manages, covered in
[Templates and ClusterClass](clusterclass.md).

The `TerraformMachinePool` must carry the cluster's
`cluster.x-k8s.io/cluster-name` label: CAPTF looks up the owning `Cluster`
by that label, not by the `MachinePool`'s `spec.clusterName`. Cluster
API's `MachinePool` controller patches this label on from
`spec.clusterName` once the `TerraformMachinePool` exists, but only on
its own next reconcile; setting the label yourself avoids that wait.

For example:

```yaml
apiVersion: cluster.x-k8s.io/v1beta2
kind: MachinePool
metadata:
  name: my-cluster-workers
  namespace: team-a
spec:
  clusterName: my-cluster
  replicas: 3
  template:
    spec:
      clusterName: my-cluster
      version: v1.31.4
      bootstrap:
        configRef:
          apiGroup: bootstrap.cluster.x-k8s.io
          kind: KubeadmConfig
          name: my-cluster-workers
      infrastructureRef:
        apiGroup: infrastructure.cluster.x-k8s.io
        kind: TerraformMachinePool
        name: my-cluster-workers
---
apiVersion: bootstrap.cluster.x-k8s.io/v1beta2
kind: KubeadmConfig
metadata:
  name: my-cluster-workers
  namespace: team-a
spec:
  joinConfiguration: {}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: TerraformMachinePool
metadata:
  name: my-cluster-workers
  namespace: team-a
  labels:
    cluster.x-k8s.io/cluster-name: my-cluster
spec:
  source:
    image: ghcr.io/example/machinepool-module:v0.1.0
  identityRef:
    name: aws-prod
```

The `KubeadmConfig` is the bootstrap provider's own object (one per pool,
for the same reason: a pool has no per-member Machine to hold one each);
its content is the bootstrap provider's concern, not CAPTF's. With
`spec.replicas` unset, Cluster API defaults it to 1; set it to the fixed
size you want, as above. Every field of `TerraformMachinePoolSpec` is
mutable: changing `spec.source`, `spec.identityRef`, `spec.variables` or
any other field re-applies the module on the next reconcile, and there is
no `spec.applyPolicy` and no delete guard (see [The
Kinds](../concepts/kinds.md)). Pass module-specific configuration through
`spec.variables` or `spec.variablesFrom` as for any other kind (see
[Module Variables](variables.md)); `spec.jobs` tunes the Job the same way
it does for a `TerraformMachine` (see [Tuning Jobs](job-tuning.md)). A
pool with none of its own inherits `spec.identityRef`, `spec.jobs` and
`spec.drift.intervalSeconds` from the owning `TerraformCluster`'s
`spec.defaults`.

`node_labels` (rendered from `spec.template.metadata.labels`, not the
`TerraformMachinePool`'s own metadata) and the other inputs a module sees
are listed in the [machinepool contract](../module-author/contract/v1alpha1/machinepool.md#inputs)
and the [environment reference](../reference/environment.md); this page
does not restate them.

## Choose fixed replicas or autoscaling

With no autoscaler annotations, `MachinePool.spec.replicas` is the sole
source of desired capacity, exactly as in the example above: change it to
resize the group.

To let the module's own native autoscaling policy own the desired count
instead, set both annotations Cluster API's autoscaler contract defines,
on the `MachinePool`:

```yaml
apiVersion: cluster.x-k8s.io/v1beta2
kind: MachinePool
metadata:
  name: my-cluster-workers
  namespace: team-a
  annotations:
    cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size: "3"
    cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size: "10"
spec:
  clusterName: my-cluster
  template:
    spec:
      clusterName: my-cluster
      version: v1.31.4
      bootstrap:
        configRef:
          apiGroup: bootstrap.cluster.x-k8s.io
          kind: KubeadmConfig
          name: my-cluster-workers
      infrastructureRef:
        apiGroup: infrastructure.cluster.x-k8s.io
        kind: TerraformMachinePool
        name: my-cluster-workers
```

Both annotations must be present, parse as non-negative integers, and
satisfy min ≤ max, or the pool reports
[`AutoscalingActive=False/AutoscalingAnnotationsInvalid`](../reference/conditions.md#autoscalingactive)
and applies without autoscaling. Valid, the pool reports
`AutoscalingActive=True/ReplicasManagedByModule`: the module owns the
group's desired count and its own scaling policy (target tracking,
scheduled, or whatever it implements), and the controller claims the
`cluster.x-k8s.io/replicas-managed-by` annotation on the `MachinePool` so
Cluster API stops treating `spec.replicas` as authoritative. On every
reconcile the controller then writes the group's observed desired
capacity back to `MachinePool.spec.replicas`, emitting a
[`ReplicasWrittenBack`](../reference/events.md) event when it changes; see
[Annotations, Labels and
Finalizers](../reference/annotations-labels.md#cluster-api-and-clusterctl-keys)
for both keys. Leave `spec.replicas` unset in this mode: Cluster API
defaults and clamps it from the annotations for the first apply, and the
write-back takes over from there. Removing both annotations returns
`spec.replicas` to being authoritative and releases
`replicas-managed-by`.

The Kubernetes Cluster Autoscaler itself does not drive these pools: its
`clusterapi` cloud provider requires MachinePool Machines, which CAPTF
does not implement. Running it against a CAPTF pool is unsupported, since
its `spec.replicas` patches would be overwritten by the write-back above.

## Add an autoscaled pool to a generated cluster

This walks through adding an autoscaled `MachinePool` to a cluster
generated from the default flavor ([Templates and
ClusterClass](clusterclass.md)), since none of the shipped flavors creates
one on their own.

Generate the default flavor with no workers; a `MachineDeployment` is
still created, with `spec.replicas: 0`, rather than omitted:

```sh
clusterctl generate cluster my-cluster --infrastructure terraform \
  --target-namespace team-a \
  --kubernetes-version v1.31.4 \
  --control-plane-machine-count 1 --worker-machine-count 0 \
  | kubectl apply -f -
```

Add the pool alongside it: a `MachinePool` with the autoscaler
annotations, its `KubeadmConfig` (the flavor's bootstrap provider is
kubeadm), and the `TerraformMachinePool`:

```yaml
apiVersion: cluster.x-k8s.io/v1beta2
kind: MachinePool
metadata:
  name: my-cluster-workers
  namespace: team-a
  annotations:
    cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size: "2"
    cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size: "5"
spec:
  clusterName: my-cluster
  template:
    spec:
      clusterName: my-cluster
      version: v1.31.4
      bootstrap:
        configRef:
          apiGroup: bootstrap.cluster.x-k8s.io
          kind: KubeadmConfig
          name: my-cluster-workers
      infrastructureRef:
        apiGroup: infrastructure.cluster.x-k8s.io
        kind: TerraformMachinePool
        name: my-cluster-workers
---
apiVersion: bootstrap.cluster.x-k8s.io/v1beta2
kind: KubeadmConfig
metadata:
  name: my-cluster-workers
  namespace: team-a
spec:
  joinConfiguration: {}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: TerraformMachinePool
metadata:
  name: my-cluster-workers
  namespace: team-a
  labels:
    cluster.x-k8s.io/cluster-name: my-cluster
spec:
  source:
    image: ghcr.io/example/machinepool-module:v0.1.0
  identityRef:
    name: aws-prod
```

`spec.replicas` is left unset on the `MachinePool`: with both autoscaler
annotations present and valid, Cluster API defaults and clamps it from
`min-size`/`max-size` for the first apply, and the pool's own write-back
takes over from there (see [Choose fixed replicas or
autoscaling](#choose-fixed-replicas-or-autoscaling) above). Apply the
three objects, then confirm as in [Confirm it worked](#confirm-it-worked)
below.

## Set the membership refresh interval

Between applies, the controller runs a refresh to pick up members joining
or leaving the group, on `spec.membershipRefreshIntervalSeconds` (15–86400
seconds; unset or 0 means 60):

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: TerraformMachinePool
spec:
  membershipRefreshIntervalSeconds: 30
```

A new member is unschedulable until its provider ID reaches
`spec.providerIDList`, so a shorter interval gets new nodes ready for
workloads sooner, at the cost of more frequent Jobs. The controller also
refreshes right after every apply and, while the group has not converged
(`spec.providerIDList`'s length differs from `status.replicas`), every 30
seconds, or the configured interval instead when it is shorter.

## Check the group's members

```sh
kubectl get terraformmachinepool <name> -n <namespace>
```

shows the owning cluster, `MachinePool`, desired replicas and the `Ready`
condition. `spec.providerIDList` is every non-terminated member, sorted
and deduplicated; `status.replicas` is the desired capacity as of the
last refresh; `status.instances` is the module's own per-member detail
(provider ID, an optional instance ID, addresses, failure domain and
health state), capped at 1000 entries:

```sh
kubectl get terraformmachinepool <name> -n <namespace> \
  -o jsonpath='{.status.instances}'
```

See the [API reference](../reference/api.md#terraformmachinepoolstatus)
for every status field. A pool reports provisioned, and the `Ready`
condition (mirrored onto the `MachinePool`'s `InfrastructureReady`)
true, once its state carries a successful apply and its module reports a
health state other than pending; unlike a fixed-replica machine, that
latch does not depend on `spec.providerIDList` being non-empty, since a
pool may legitimately scale to zero.

## Drift on a pool

A pool's drift check cannot be disabled: `spec.drift.intervalSeconds: 0`
falls back to the manager's default interval rather than turning checks
off, because the drift Job's own refresh is what feeds a plan; without
it, a cloud-side scaling change would never register as drift. With
`spec.drift.action: Remediate`, a detected difference re-applies the
pool's current inputs; with autoscaling enabled the module is responsible
for excluding its own desired-count attribute from that plan, or every
cloud-side scale reports as drift. See [Drift](drift.md) for setting the
interval and action, and [Drift and Health](../concepts/drift-and-health.md)
for how a check runs and feeds health.

## Delete a MachinePool

Deleting the `MachinePool` deletes its `KubeadmConfig` and
`TerraformMachinePool` with it. Nothing blocks a `TerraformMachinePool`'s
deletion: it destroys the group from its durable inputs and removes its
finalizer once the destroy Job succeeds, whether or not the owning
`MachinePool` or `Cluster` still exist. See [the reconcile
lifecycle](../concepts/lifecycle.md) for how deletion and finalizers work
across every kind.

## Confirm it worked

```sh
kubectl get terraformmachinepool <name> -n <namespace>
```

`Ready` reads `True` once the group is provisioned, and `Replicas` shows
the desired capacity. `kubectl get machinepool <name> -n <namespace>`
shows the same replica count and `InfrastructureReady=True` once Cluster
API has copied `spec.providerIDList` and `status.replicas` across, which
happens only once the workload cluster is reachable.

## See also

- [The Kinds](../concepts/kinds.md) for how a `TerraformMachinePool`'s
  mutability differs from a `TerraformMachine`'s.
- [The machinepool contract](../module-author/contract/v1alpha1/machinepool.md)
  for every input and output a module role must implement.
- [Drift](drift.md) and [Drift and Health](../concepts/drift-and-health.md).
- [Templates and ClusterClass](clusterclass.md) for a
  `TerraformMachinePoolTemplate` used through a ClusterClass topology.
- [Module Variables](variables.md) and [Tuning Jobs](job-tuning.md).
- [API Reference](../reference/api.md#terraformmachinepool),
  [Conditions](../reference/conditions.md#autoscalingactive),
  [Events](../reference/events.md) and [Annotations, Labels and
  Finalizers](../reference/annotations-labels.md#cluster-api-and-clusterctl-keys).
