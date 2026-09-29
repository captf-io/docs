# Configuration

The CAPTF manager takes every setting as a command-line flag; there is no
config file. This page explains what each group of flags changes and when
to change it. For the full flag list, types and defaults, see
[Manager Flags](../reference/manager-flags.md); this page does not repeat
that table.

## Before you begin

- Cluster-admin access to the management cluster, and `kubectl`.
- The shipped Deployment is named `captf-controller-manager` in the
  provider's namespace (`captf-system` after `clusterctl init`; see
  [Installation](installation.md)).

## Changing a flag

The manager's arguments live on the `manager` container of the
`captf-controller-manager` Deployment. Because `args` is a plain list with no
merge key, a strategic-merge patch that only adds one flag replaces the
whole list and silently drops the others (including `--leader-elect` and
the diagnostics flags the shipped manifest sets). Add a flag with a JSON
patch instead, which appends to the existing list:

```sh
kubectl patch deployment captf-controller-manager -n captf-system --type=json \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--<flag>=<value>"}]'
```

To manage the arguments as a whole (for example with a kustomize overlay
over the released manifest), patch the full `args` list so no existing flag
is lost:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: captf-controller-manager
  namespace: captf-system
spec:
  template:
    spec:
      containers:
      - name: manager
        args:
        - --leader-elect
        - --diagnostics-address=:8443
        - --insecure-diagnostics=false
        - --webhook-port=9443
        - --<flag>=<value>
```

Confirm the change with:

```sh
kubectl rollout status deployment/captf-controller-manager -n captf-system
kubectl get deployment captf-controller-manager -n captf-system \
  -o jsonpath='{.spec.template.spec.containers[0].args}'
```

The manager also logs its parsed flags once at start (`FLAG: --name="value"`
lines), and refuses to start on an invalid combination, so a typo or an
out-of-range value shows up in the Pod's logs and status rather than
running with a wrong value. `clusterctl upgrade apply` reinstalls the
provider's manifests, so a hand-patched flag does not survive an upgrade
unless the patch is reapplied; see [Upgrades](upgrades.md).

## Namespace scoping and `--watch-filter`

`--namespace` restricts the manager to one namespace: it only watches and
reconciles namespaced objects (`TerraformCluster`, `TerraformMachine`,
`TerraformMachinePool`, their `*Template` kinds, and the Secrets and
ConfigMaps CAPTF reads) in that namespace. `TerraformClusterIdentity` is
cluster-scoped and is always watched everywhere, regardless of
`--namespace`. Unset (the default, and what `clusterctl init` installs),
the manager watches every namespace. **A single manager instance therefore
watches one namespace or all of them, never a chosen set**: running a
second, differently-namespaced manager instance does not split load or
ownership the way it might look like it should. The leader-election Lease
name (`controller-leader-election-captf`) is a fixed constant, not
namespaced or parameterized by `--namespace`, and the shipped install is a
singleton — one `ValidatingWebhookConfiguration`, one webhook `Service`,
one `Certificate`. Two manager Deployments with `--leader-elect` and
different `--namespace` values both contend for the same Lease in the same
manager namespace, so only one of them ever holds leadership and
reconciles anything; the other sits idle regardless of which namespace it
was pointed at.

To share one management cluster across several provider instances or
tenants, use `--watch-filter` instead: it limits reconciling to objects
labeled `cluster.x-k8s.io/watch-filter: <value>`; unset, the manager
reconciles every object it can see. It is the convention CAPI and its
other providers use for exactly this, and each instance still watches (and
its webhook still admits) every namespace. The filter applies to the
`Terraform*` objects themselves; a Job or Secret one of them owns is still
acted on regardless of its own labels.

The `ValidatingWebhookConfiguration` has no `namespaceSelector`: it admits
a `Terraform*` create or update in any namespace, whether or not any
manager instance watches that namespace or the object's
`watch-filter` label matches one. A `Terraform*` object created in a
namespace no running manager watches (outside `--namespace`'s one
namespace, or not labeled for any instance's `--watch-filter`) is admitted
normally and then never reconciled: no Job ever starts for it, and its
conditions never move past whatever they were set to (or left unset) at
admission.

Both flags apply to the [orphan sweep](rbac.md) too: `--namespace` limits
which namespaces it sweeps, and it always ignores `--watch-filter` when it
decides whether a namespace still holds a `Terraform*` object, so another
instance's objects (including one this manager does not watch) keep a
namespace from being swept.

## Per-kind concurrency

`--terraformcluster-concurrency`, `--terraformmachine-concurrency`,
`--terraformmachinepool-concurrency` and
`--terraformmachinetemplate-concurrency` each cap how many objects of that
kind the manager reconciles at once (default 10). Raise one when that
kind's objects queue behind each other under load — reconciles are
lightweight (a handful of API reads and a status patch, unless a Job needs
starting) and mostly wait on Job completion, so a higher number rarely
costs much CPU. Lower one to reduce the manager's burst of API calls
against a small or rate-limited API server.

## Leader election

`--leader-elect` (default `false`) turns on leader election so that only
one of several manager replicas reconciles at a time; enable it whenever
you run more than one replica, so a rolling update or a crash never leaves
two managers reconciling the same objects together. The shipped Deployment
runs one replica but sets `--leader-elect` anyway, ready for a scale-up.
`--leader-elect-lease-duration`, `--leader-elect-renew-deadline` and
`--leader-elect-retry-period` tune how fast a crashed leader is detected
and replaced; the defaults (15s/10s/2s) match `kube-controller-manager` and
rarely need changing.

## Sync period and the orphan sweep

`--sync-period` (default 10 minutes) is the minimum interval at which the
manager's informers re-enqueue every cached object for reconciliation, on
top of the normal event-driven reconciles; it reads only the local cache,
never the API server, so it does not set the cadence of drift or health
checks, which run on their own schedule
(see [Drift and Health](../concepts/drift-and-health.md)), and it does not
recover a watch event that never reached the cache. Lowering it corrects a
missed requeue sooner at the cost of more reconciles; raising it does the
opposite.

The same interval drives the orphan sweep, so lowering `--sync-period` also
cleans up an orphaned namespace's runner objects sooner. See
[The orphan sweep](rbac.md#the-orphan-sweep) for what it removes and how it
decides.

## `--cluster-operation-gate`

Keeps a `TerraformCluster`'s apply, destroy or restore from running at the
same time as its machines' and machine pools' applies, destroys or
restores, through a per-Cluster write Lease; the per-object run Lease that
keeps two Jobs from starting for the same object is always on and cannot be
turned off. Default `true`. Turn it off only if you accept a cluster's own
operation and its machines' operations running concurrently — see
[Run leases and the cluster operation gate](../concepts/lifecycle.md#run-leases-and-the-cluster-operation-gate)
for what the gate does and how the two sides wait for each other.

## `--runner-image`

The image of the init container that copies the runner binary into every
Job; it must be an image that contains a `/runner` binary, which in practice
means a CAPTF manager or runner image, not a module image. Unset, it
defaults to `$CAPTF_MANAGER_IMAGE`, the manager's own image, which the
shipped Deployment sets to whatever image it runs — so most installs never
need to set the flag or the environment variable by hand. Set it to pin
the init container to a specific published image independently of the
manager's own, for example while testing a new manager build against the
current runner. The manager refuses to start when neither the flag nor the
environment variable resolves to a valid image reference. See
[Job Environment](../reference/environment.md) for where the copied binary
ends up and [Security Model](../concepts/security-model.md) for why images
are pinned by digest once a Job has run.

## `--runner-events`

Default `true`. Have each Job's runner post its own progress (`RunStarted`,
`Step*`, `PlanSummary`, `ResourcesChanged`, `RunFinished`) as Events on the
`Terraform*` object the Job is for, related to the Job itself; emission is
best effort and never fails or slows the run. Turn it off to reduce Event
volume on a cluster with many objects, or if the runner ClusterRole in your
installation does not grant `events` `create` (see [RBAC](rbac.md)). See
[Events](../reference/events.md) for the full list.

## `--state-backups`

How many state backups to keep per object (default 5); every new state
serial the manager observes is copied into a `captf-state-backup-*` Secret,
and older copies beyond the count are pruned in the same pass.
`--state-backups=0` takes no new backups but leaves existing ones in place
and restorable. Lower it to reduce the Secret count and storage in a large
installation; raise it for a longer recovery window. See
[Terraform State](../concepts/state.md#state-backups) for the backup
naming and what is skipped, and
[State Restore](runbooks/state-restore.md) for the restore procedure.

## `--drift-default-interval`

The drift check interval (default 30 minutes) an object falls back to when
neither it nor, for a machine or pool, its `TerraformCluster`'s
`spec.defaults.drift` sets one. For a `TerraformCluster` or
`TerraformMachine`, it has no effect once `spec.drift.intervalSeconds` (own
or inherited) is set, including to `0`, which disables drift. A
`TerraformMachinePool`'s drift can never be disabled: a `0`, its own or
inherited, falls back to this default instead. Change the default to shift
the fleet-wide drift cadence without touching every object; see
[Drift](../user-guide/drift.md) for setting an interval per object and
[Drift and Health](../concepts/drift-and-health.md) for how the schedule
and its jitter work.

## Diagnostics address, authentication and TLS

`--diagnostics-address` (default `:8443`) is where the manager serves
Prometheus metrics, authenticated and authorized against the API server by
default. `--insecure-diagnostics` (default `false`) turns that off and
serves plain HTTP with no authentication instead; use it for local
development only, never for a manager reachable from anything but your own
workstation. `--tls-min-version`, `--tls-cipher-suites` and
`--tls-curve-preferences` constrain the TLS the metrics and webhook servers
negotiate, the same flags and defaults as the CAPI core providers. See
[Observability](observability.md) for what the endpoint serves and how a
scraper authenticates to it.

`--webhook-port` (default `9443`) is where the manager serves admission
webhooks; `--webhook-cert-dir`, `--webhook-cert-name` and
`--webhook-key-name` say where it finds the serving certificate that
cert-manager issues. The shipped manifests wire all of this together; see
[Installation](installation.md).

## Logging

`--logging-format` (default `text`) also accepts `json`. `-v` sets the log
verbosity (default `2`); raise it while diagnosing a problem and lower it
back afterward, since higher verbosities log more of each reconcile.
`--vmodule` overrides the verbosity for individual source files, and only
works with the text format. `--feature-gates` takes a comma-separated
`key=value` list of the logging feature gates (`ContextualLogging`,
`LoggingBetaOptions`, `LoggingAlphaOptions`); CAPTF itself registers no
feature of its own. See [Manager Flags](../reference/manager-flags.md#logging)
for the full flag and feature gate list.

## See also

- [Manager Flags](../reference/manager-flags.md) — every flag, its type
  and its default.
- [Installation](installation.md) — installing the provider and its
  webhook certificate.
- [Upgrades](upgrades.md) — what a provider upgrade changes.
- [RBAC](rbac.md) — the orphan sweep and the runner's permissions.
- [Observability](observability.md) — metrics, alerts and events.
