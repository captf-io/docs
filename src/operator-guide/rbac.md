# RBAC

CAPTF ships a fixed set of ClusterRoles, one Role and the objects that bind
them, and creates one more RoleBinding per tenant namespace as it goes. This
page covers every one of them: what the manager itself can do, what the
runner can do inside a tenant namespace, how a namespace gets its runner
identity, and how CAPTF cleans that identity up again. For what a Terraform
or OpenTofu module can do with the runner's access once it has it, see
[Security model](../concepts/security-model.md).

## Before you begin

- Cluster-admin access to the management cluster, and `kubectl`.
- The manager's own ClusterRole and ClusterRoleBinding are named
  `captf-manager-role` and `captf-manager-rolebinding` after `clusterctl init`
  (see [Installation](installation.md)); the runner ClusterRole is
  `captf-runner` regardless of which cluster or namespace it runs in.

## The manager's ClusterRole

The manager's ServiceAccount, `captf-controller-manager` in the provider's
namespace, is bound to one ClusterRole scoped to exactly what reconciling
`Terraform*` objects needs:

| Resource | Verbs | Why |
| --- | --- | --- |
| `terraformclusters`, `terraformmachines`, `terraformmachinepools`, `terraformclusteridentities`, their `*Template` kinds | get, list, watch, create, update, patch, delete | Reconciles and owns every kind it serves |
| The `/status` subresources of every kind above except `terraformmachinepooltemplates` (which has none) | get, update, patch | Writes status separately from the spec |
| The `/finalizers` subresources of `terraformclusters`, `terraformmachines`, `terraformmachinepools` and `terraformclusteridentities` (never a `*Template` kind) | update | Adds and removes its own finalizers |
| `clusters`, `clusters/status`, `machines/status`, `machinepools/status` | get, list, watch | Reads the Cluster API objects a `Terraform*` object belongs to |
| `machines` | get, list, watch, patch | Reads Machines and patches the `cluster.x-k8s.io/remediate-machine` annotation it sets to request remediation |
| `machinepools` | get, list, watch, patch | Reads MachinePools and writes back an autoscaled pool's observed replicas |
| `secrets` | get, list, watch, create, update, patch, delete | Reads and writes every Secret in [Secrets](secrets.md) |
| `namespaces` | get, list, watch | Evaluates a `TerraformClusterIdentity`'s `allowedNamespaces` selector |
| `configmaps` | get, list, watch | Reads `spec.variablesFrom` ConfigMap sources labeled `captf.io/variables=true` |
| `serviceaccounts` | get, list, watch, create, delete | Creates the default runner ServiceAccount, reads any override, and the [orphan sweep](#the-orphan-sweep) deletes unused ones |
| `rolebindings` | get, list, watch, create, update, delete | Manages the per-namespace runner RoleBinding below |
| `clusterroles`, resource name `captf-runner` | bind | Lets the manager bind that ClusterRole without holding its permissions itself |
| `leases` | get, list, watch, create, update, delete | Its own run and cluster-operation-gate leases, and cleaning up the backend's state lock lease on delete |
| `jobs` | get, list, watch, create, patch, delete | Creates, watches and prunes the runner Jobs |
| `jobs/finalizers` | update | Granted alongside `jobs`; the controller itself never sets a finalizer on a Job |
| `pods` | get, list, watch | Reads a Job's pod status for its outcome and the image digest it ran |
| `pods/log` | get, list, watch | Granted alongside `pods`; the controller itself never reads a pod's logs |
| `events`, `events.k8s.io/events` | create, patch | Records reconcile events on `Terraform*` objects |
| `authentication.k8s.io/tokenreviews` | create | Backs the authenticated diagnostics endpoint |
| `authorization.k8s.io/subjectaccessreviews` | create | Backs the authenticated diagnostics endpoint and the identity webhook's Secret-read check |

The manager is never labeled to aggregate into a broader ClusterRole, and it
holds no permission on any resource outside this table.

## The leader-election Role

`captf-leader-election-role` is a namespaced Role, scoped to the provider's
namespace, bound to the manager's ServiceAccount by
`captf-leader-election-rolebinding`. It grants `leases` (get, list, watch,
create, update, patch, delete) and `events` (create, patch):
controller-runtime's leader election uses a Lease, one per manager, and only
matters when `--leader-elect` is on (see
[Leader election](configuration.md#leader-election)).

## The runner ClusterRole

`captf-runner` is the one ClusterRole every tenant namespace's runner
ServiceAccount is bound to. It is cluster-scoped and static: the manager
never edits its rules, only binds it per namespace
([below](#the-per-namespace-runner-serviceaccount-and-rolebinding)).

| Resource | Verbs | Why |
| --- | --- | --- |
| `secrets` | get, list, create, update, delete | The Terraform/OpenTofu Kubernetes state backend's own requirements |
| `leases` | get, create, update | Takes, releases and force-unlocks the state lock |
| `events.k8s.io/events` | create | Reports run progress on the object that owns the Job |

The Secret verbs are exactly what the state backend uses, no more: `get`,
`create` and `update` read and write the state; `list` is needed because the
backend lists its state chunks by label on every read and write, and lists
workspaces during `init`; `delete` trims chunks when the state shrinks. None
of those verbs can be scoped by name or label, so they apply to every Secret
in the namespace — this is the basis of the trust boundary described in
[Security model](../concepts/security-model.md). `leases` omits `delete`:
the backend deletes its lock Lease only when a workspace is deleted, which
the runner never does, and the manager deletes it itself once an object's
state is gone. `events.k8s.io/events` grants `create` only, never `patch` or
`get`: the runner emits a series of one-shot events
([Reading events](observability.md#reading-events)) and never reads or
updates one; with `--runner-events=false` the Jobs pass no event target and
nothing calls this permission.

No Role is ever created for the runner. The manager binds this ClusterRole
through the `bind` verb, restricted to its name, so the manager does not
need to hold the ClusterRole's own permissions itself.

## The per-namespace runner ServiceAccount and RoleBinding

The first time a namespace needs a Job, the manager makes sure it has both:

- a ServiceAccount, `captf-runner` by default, labeled
  `captf.io/managed=true`. An operator who pre-creates it themselves keeps
  whatever else they put on it.
- a RoleBinding, always named `captf-runner`, whose `roleRef` is fixed to
  the `captf-runner` ClusterRole and whose subjects are recomputed on every
  reconcile: the union of every ServiceAccount some `Terraform*` object in
  the namespace runs its Job as.

A RoleBinding named `captf-runner` that already exists without
`captf.io/managed=true` is left alone and never modified: the manager
reports an error rather than take over a hand-written binding of the same
name. One it does manage is re-created, not patched, if something changes
its `roleRef` — `roleRef` is immutable in Kubernetes — and otherwise only
has its subject list updated.

## Custom ServiceAccounts and the runner opt-in

`spec.jobs.serviceAccountName` (or the same field under a
`TerraformCluster`'s `spec.defaults.jobs`) can name a ServiceAccount other
than `captf-runner` for a Job to run as. Naming `captf-runner` itself is not
an override and needs nothing further. Naming anything else needs that
ServiceAccount to already exist **and** carry the label
`captf.io/runner=true`; without both, the condition
`RunnerRBACReady=False/ServiceAccountNotOptedIn` is set and no Job runs.
Once it opts in, the manager adds it to the `captf-runner` RoleBinding's
subjects alongside every other ServiceAccount the namespace's objects use;
removing the label removes it from the binding again on the next reconcile.

The label is consent, not authorization: whoever can label a ServiceAccount
opts it in, whether or not they administer the namespace. It grants little
by itself, because anyone who can already create Pods running as that
ServiceAccount can read the namespace's Secrets through a volume mount
anyway; what it prevents is a ServiceAccount gaining the runner's Secret
*write* access merely by being named in `spec.jobs.serviceAccountName`.

## The orphan sweep

At manager start, and then every `--sync-period` while this manager leads
(see [Sync period and the orphan
sweep](configuration.md#sync-period-and-the-orphan-sweep)), the manager
deletes the `captf.io/managed=true` ServiceAccounts, RoleBindings and Leases
of every namespace holding no `TerraformCluster`, `TerraformMachine` and
`TerraformMachinePool` — what a [`clusterctl move`](runbooks/move.md) leaves
behind in the source namespace, since `clusterctl` strips finalizers before
deleting the source objects and the controller's own delete-time cleanup
never runs there. The decision is made through the manager's uncached reader
with no `--watch-filter` applied, so another manager instance's objects,
even ones this manager does not watch, still keep a namespace from being
swept. Nothing is deleted for a single object here, so the sweep logs what
it removed rather than recording an event.

A namespace that still holds objects keeps its runner ServiceAccount and
RoleBinding, but the RoleBinding's subjects are pruned to the
ServiceAccounts still in use: a `Terraform*` object's own
`spec.jobs.serviceAccountName`, else, for a machine or pool, its cluster's
`spec.defaults.jobs.serviceAccountName`, else `captf-runner`. This is how
switching `spec.jobs.serviceAccountName` from one opted-in ServiceAccount to
another eventually drops the old one's Secret access, rather than leaving it
bound until the whole namespace empties out. When a machine or pool's
cluster cannot be resolved yet, every cluster default in the namespace is
kept rather than pruned, so a resolution delay never flaps the binding.

## The metrics-reader ClusterRole

`captf-metrics-reader` lets a Prometheus instance read the manager's
authenticated `/metrics` endpoint; it ships only with the opt-in Prometheus
component, not with the base install. See [Enabling the Prometheus
component](observability.md#enabling-the-prometheus-component) for what it
binds to and how to point it at your own Prometheus.

## See also

- [Security model](../concepts/security-model.md)
- [Secrets](secrets.md)
- [Identities and Credentials](../user-guide/identities.md)
- [Configuration](configuration.md)
- [`clusterctl move`](runbooks/move.md)
