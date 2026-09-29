# clusterctl move

`clusterctl move` refuses to run against a Cluster that is already paused
— it stops with an error naming the paused Clusters — and it pauses the
Cluster itself for the duration of the move and unpauses it afterwards. So
**do not** leave the source Cluster paused when you run it. This page walks
through moving a Cluster's `Terraform*` objects safely, what does and does
not come along, and cleaning up what a move leaves behind.

## Before you begin

- `clusterctl` configured with both the source and target management
  cluster's kubeconfigs.
- The target cluster running the same or a newer CAPTF version.
- Replace `<ns>` and `<name>` with the Cluster's namespace and name below.

## Procedure

The documented sequence pauses first only to drain in-flight Jobs, then
unpauses before invoking `clusterctl move` (which pauses and unpauses it
again on its own):

1. **Pause the Cluster** so the controller starts no new Job on any
   `Terraform*` object of it:

   ```sh
   kubectl patch cluster -n <ns> <name> --type=merge -p '{"spec":{"paused":true}}'
   ```

   A Job already running is left to finish, unless it never started at
   all — its per-run inputs Secret is missing and every pod it created is
   still `Pending` a minute after the Job was created — in which case the
   paused reconcile deletes it so the next reconcile starts it again. The
   paused reconcile still does Job bookkeeping and clears
   `clusterctl.cluster.x-k8s.io/block-move` once no Job is active, even
   while paused ([the clusterctl move
   block](../../concepts/lifecycle.md#the-clusterctl-move-block)).

2. **Wait until no `Terraform*` object of the Cluster carries
   `block-move`:**

   ```sh
   kubectl get terraformclusters,terraformmachines,terraformmachinepools -n <ns> \
     -l cluster.x-k8s.io/cluster-name=<name> \
     -o custom-columns='KIND:.kind,NAME:.metadata.name,BLOCK-MOVE:.metadata.annotations.clusterctl\.cluster\.x-k8s\.io/block-move'
   ```

   Repeat until every row's `BLOCK-MOVE` column is `<none>`. The annotation
   is set before a Job is created and removed once no Job is active, so a
   cleared annotation means the object has no Job in flight.

3. **Unpause the Cluster** — required, or step 4 fails immediately:

   ```sh
   kubectl patch cluster -n <ns> <name> --type=merge -p '{"spec":{"paused":null}}'
   ```

4. **Run `clusterctl move`** to the target management cluster:

   ```sh
   clusterctl move --namespace <ns> --to-kubeconfig <target-kubeconfig>
   ```

`clusterctl move`'s own backoff does not wait for long Jobs (about two
minutes, while `jobs.activeDeadlineSeconds` defaults to one hour), which is
why step 2 waits explicitly before the move itself starts.

## Moving every namespace

`clusterctl move` always moves one namespace: an unset `--namespace` falls
back to your kubeconfig context's current namespace, not to every
namespace on the cluster, and there is no flag that moves all of them in
one invocation. Moving every namespace means repeating the procedure above
once per namespace.

A `TerraformClusterIdentity` is cluster-scoped and several namespaces can
reference the same one. This is safe to move namespace by namespace:
`clusterctl move` never deletes a cluster-scoped object from the source,
only namespaced ones, so the first namespace's move copies the identity to
the target and leaves it in place on the source; each later namespace's
move finds it already on the target and skips re-creating it rather than
erroring. You do not need to move the namespaces that share an identity in
any particular order, and you still copy its credentials Secret to the
target only once (see [below](#the-identitys-credentials-secret-does-not-move)),
however many namespaces that use it you move.

## What moves and what doesn't

`clusterctl move` discovers CRD-kind objects, ConfigMaps and Secrets in a
Cluster's owner reference chain, copies them to the target, then strips
finalizers and deletes them from the source. The controller's own delete
path therefore never runs on the source.

| Moves | Doesn't move |
| --- | --- |
| State Secrets (`tfstate-default-<suffix>` and its chunks) — owned by the object | The state lock Lease (`lock-tfstate-default-<suffix>`) — not a discovered kind. **Recreated by the backend at the target's next `init`.** |
| State backups (`captf-state-backup-<suffix>-<serial>` and their chunks) — owned by the object | The runner ServiceAccount (`captf-runner`) and its RoleBinding — not discovered kinds. **Recreated by the controller before the target's first Job.** |
| The durable inputs Secret (`captf-inputs-<kindshort>-<name>`) — owned by the object | The run lease and, for a TerraformCluster, the cluster write lease — not discovered kinds. A lease whose Job was active during the move is left on the source; see [run leases](../../concepts/lifecycle.md#run-leases-and-the-cluster-operation-gate). |
| The mirrored credentials Secret (`captf-creds-<identity>`) | The identity's own credentials Secret — deliberately not owned and not labeled for move. **Copy it to the target yourself; see below.** |
| | Every `variablesFrom` ConfigMap or Secret — deliberately not owned. **Recreate it on the target, or label it for move yourself** (see [Module Variables](../../user-guide/variables.md#what-a-change-does-per-kind)). |

The Secrets in the "Moves" column carry the `clusterctl.cluster.x-k8s.io/move`
label themselves, which is what makes `clusterctl move` discover and carry
them alongside the `Terraform*` object that owns them, on top of the
owner-reference chain it always follows; see
[Annotations and labels](../../reference/annotations-labels.md) for that
label and every other one this page's objects carry.

`status` is never restored by move: it is rebuilt from state on the
target's first reconcile.

A `TerraformCluster` or `TerraformMachinePool` (both mutable) re-reads its
`variablesFrom` sources on every reconcile, so it waits at
`DependenciesReady=False`/`VariablesSourceNotFound` on the target until the
source exists there, whether or not it was already provisioned. A
`TerraformMachine` (immutable) stops needing its sources once provisioned,
so only one moved before its first apply waits.

### The identity's credentials Secret does not move

The `TerraformClusterIdentity` object itself is cluster-scoped and carries
a move-hierarchy label, so `clusterctl` moves it as part of the global
hierarchy every namespace's move includes. Its credentials Secret is
different: it is namespace-scoped and used by every namespace the identity
allows, so CAPTF deliberately removes any owner reference it might have
added and never labels it for `clusterctl move`. Labeling it for move
yourself would make `clusterctl` delete it from the source once the move
of the namespace it lives in finished — deleting credentials that other
allowed namespaces on the source still use, and `clusterctl move` never
moves more than one namespace per invocation regardless (see [Moving every
namespace](#moving-every-namespace) above), so there is no invocation that
"finishes last" to safely hang the deletion off. Copy it yourself every
time, on every namespace's move; it is a duplicate, not a move.

Because the identity object moves but its Secret does not, the identity
reports `Ready=False`/`SecretNotFound` on the target until you copy the
Secret there yourself, keeping its name and the keys the identity names;
every `TerraformCluster`, `TerraformMachine` and `TerraformMachinePool` that
uses it reports `IdentityAllowed=False`/`SecretNotFound` for the same
reason. `kubectl get -o yaml | kubectl apply -f -` carries the source
Secret's `resourceVersion` and `uid` along, which `apply` rejects against a
target that has no existing object with that `resourceVersion`; strip the
identifying metadata first:

```sh
kubectl --kubeconfig <source-kubeconfig> get secret -n <ns> <secret-name> -o json \
  | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences)' \
  | kubectl --kubeconfig <target-kubeconfig> apply -f -
```

See [Identities and Credentials](../../user-guide/identities.md) for
creating, rotating and revoking that Secret.

### TerraformMachine deletion during a move

`clusterctl` annotates each object with
`clusterctl.cluster.x-k8s.io/delete-for-move` before deleting it on the
source. The `TerraformMachine` delete webhook honors that annotation only
while the machine's Cluster (its `cluster.x-k8s.io/cluster-name` label) has
`spec.paused: true`, which `clusterctl move` sets before it deletes
anything. On an unpaused Cluster the annotation changes nothing: deleting a
`TerraformMachine` whose Machine is live is refused, because it would skip
drain and the lifecycle hooks. This check exists only on `TerraformMachine`:
a `TerraformMachinePool` is never delete-guarded, moved or not.

## Confirm it worked

```sh
kubectl --kubeconfig <target-kubeconfig> get terraformclusters,terraformmachines,terraformmachinepools -n <ns>
kubectl --kubeconfig <target-kubeconfig> get cluster -n <ns> <name> -o jsonpath='{.spec.paused}'
```

The first command lists the `Terraform*` objects on the target with the
same names they had on the source; the second prints nothing (or `false`),
confirming `clusterctl move` unpaused the Cluster once it finished. Expect
`Ready=False` until you complete the [manual steps
above](#the-identitys-credentials-secret-does-not-move) and any
`variablesFrom` source the objects need, then a Job starts on the target
and the object reaches the same `Ready` state it had on the source. See the
[other runbooks](README.md) for any condition that does not clear on its
own.

## Orphaned objects left on the source

After a successful move, the source namespace still holds the runner
ServiceAccount and RoleBinding (`captf-runner`), and any run or cluster
write lease whose Job was active during the move or had not been bookkept
yet (`captf-run-<suffix>`, `captf-cluster-<hash>`) — all labeled
`captf.io/managed=true`. Jobs and their per-run Secrets are not left
behind: they have owner references to the deleted source objects, so the
garbage collector removes them.

The manager sweeps these automatically: on start, and then every
`--sync-period` (default 10 minutes), it removes the `captf.io/managed=true`
ServiceAccounts, RoleBindings and Leases of every namespace that holds no
`TerraformCluster`, `TerraformMachine` or `TerraformMachinePool` — exactly
what a completed move leaves behind. See [RBAC](../rbac.md) for the full
mechanism, including how it treats a namespace an administrator still
manages by hand.

To clean up without waiting for the next sync, once the namespace holds no
`Terraform*` object:

```sh
kubectl delete lease,serviceaccount,rolebinding -l captf.io/managed=true -n <ns>
```

Run it only once the namespace holds no `TerraformCluster`,
`TerraformMachine` or `TerraformMachinePool`: while any remain, their
runner and lock are still in use.

## See also

- [The Reconcile Lifecycle](../../concepts/lifecycle.md) — the
  `block-move` annotation and run leases in full.
- [Identities and Credentials](../../user-guide/identities.md) — creating
  and rotating the credentials Secret this page tells you to copy.
- [RBAC](../rbac.md) — the runner ServiceAccount and RoleBinding the sweep
  manages.
- [Module Variables](../../user-guide/variables.md) — `variablesFrom`
  sources and why they don't move either.
