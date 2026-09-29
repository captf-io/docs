# Tuning Jobs

Every operation CAPTF runs — apply, destroy, drift, refresh, restore and
plan — is one Kubernetes Job. `spec.jobs` on a `TerraformCluster`,
`TerraformMachine` or `TerraformMachinePool` tunes that Job: its resources,
deadlines, history, environment, pull secrets, ServiceAccount and security
contexts. Every field is optional and has a built-in default, so you only
set the fields you need to change. For the full field list, types and
validation see
[`JobPolicy` in the API reference](../reference/api.md#jobpolicy); for the
Job's exact shape (containers, mounts, args) see
[Job Environment](../reference/environment.md).

## Before you begin

- Know which object's `spec.jobs` you are changing. A `TerraformCluster`
  also has `spec.defaults.jobs`, which its `TerraformMachine`s and
  `TerraformMachinePool`s inherit; see
  [Inheriting from a cluster's defaults](#inheriting-from-a-clusters-defaults)
  below.
- A `TerraformCluster`'s own `spec.jobs` does not inherit
  `spec.defaults.jobs`: defaults are for its machines and pools, never for
  the cluster itself.

## Resources

`spec.jobs.resources` sets the main container's `resources` as a whole;
when unset the controller applies its own default (250m CPU / 512Mi memory
requested, 2Gi memory limit, deliberately no CPU limit — throttling a slow
apply is worse than a slow apply). Raise it when a module pulls large
provider plugins or holds a large plan in memory; the init container that
copies the runner binary is not configurable, since it never varies with
the module. See
[Default resources](../reference/environment.md#default-resources) for the
exact values.

## Deadlines and lock waits

- `activeDeadlineSeconds` bounds the whole Job, at most one day. Defaults
  to 3600 (one hour). Raise it for a module with a slow apply or many
  resources; a Job that hits its deadline is interrupted with SIGTERM, the
  same as a pod eviction or deletion. For an apply, destroy or plan Job,
  `ApplyJobSucceeded` is set False with reason `JobDeadlineExceeded`; for a
  drift or refresh Job, `DriftJobSucceeded` is set False with reason
  `DriftJobDeadlineExceeded`; for a restore Job, `RestoreJobSucceeded` is
  set False with reason `RestoreFailed`. See
  [Conditions](../reference/conditions.md#applyjobsucceeded).
- `lockTimeoutSeconds` is passed to the runtime as `-lock-timeout`.
  Defaults to 300 (five minutes). Raise it when Jobs commonly queue behind
  each other on the same state lock.
- When a policy sets both, `lockTimeoutSeconds` must be less than
  `activeDeadlineSeconds`: the webhook rejects a policy where a lock wait
  alone could fill the whole deadline. This check looks at one policy at a
  time, so it does not see a machine's or pool's field-wise merge with a
  cluster's `spec.defaults.jobs` — setting `lockTimeoutSeconds` on a
  machine while only `spec.defaults.jobs.activeDeadlineSeconds` bounds it
  is not caught at admission.

## History limits

`successfulJobsHistoryLimit` and `failedJobsHistoryLimit` cap how many
finished Jobs of each kind are kept, both defaulting to 3. Each is scoped
per object *and* per operation: apply, destroy, drift, refresh, restore and
plan are pruned independently, so lowering one does not shrink another's
history. The newest Job of an operation is always kept, even at a limit of
0 — for a failed operation, until a newer Job of the same operation
succeeds. `failedJobsHistoryLimit` also bounds retry backoff, since backoff
looks at the same retained failures; see
[The reconcile lifecycle](../concepts/lifecycle.md) for how backoff is
computed.

## Environment variables

`spec.jobs.env` adds environment variables to the main container. Entries
named `TF_*` or `KUBE_*` are reserved for the runner and the Job's own
environment (`TF_IN_AUTOMATION`, `KUBE_NAMESPACE`, and so on): an entry
using one of those names is silently dropped instead of applied. See
[`spec.jobs.env` rejected names](../reference/environment.md#specjobsenv-rejected-names)
for the full list of names the Job already sets.

## Image pull secrets

`spec.jobs.imagePullSecrets` covers both the role image (`spec.source.image`)
and the runner's own init image, so one list is enough even when they come
from different registries.

## ServiceAccount

`spec.jobs.serviceAccountName` overrides the runner ServiceAccount. Left
unset, the controller creates and uses `captf-runner`, bound to the static
`captf-runner` ClusterRole. An override must already exist and carry the
label `captf.io/runner=true`; without it, no Job is created and
`RunnerRBACReady` reports False with reason `ServiceAccountNotOptedIn`
(see [Conditions](../reference/conditions.md#runnerrbacready)). Setting up
and opting in your own ServiceAccount, and the RBAC CAPTF manages around
it, is covered in [RBAC](../operator-guide/rbac.md).

## Security contexts

`spec.jobs.securityContext` sets the main container's `securityContext`.
The container holds cloud credentials, so the webhook rejects
`privileged: true`, `allowPrivilegeEscalation: true` and any
`capabilities.add` on it, whatever else the policy sets. Every other field
you set is applied on top of the controller's defaults (no privilege
escalation, every capability dropped, a read-only root filesystem), except
`capabilities`: setting your own replaces the default `drop: [ALL]`
wholesale, so include `ALL` in your own `drop` list to keep every
capability dropped. `runAsNonRoot` is left to you, since some role images
built from a `hashicorp/terraform` base still run as root.

`spec.jobs.podSecurityContext` sets the Job pod's `securityContext`. The
controller defaults its `seccompProfile` to `RuntimeDefault` and its
`fsGroup` to the runner's UID, so a non-root image user can read the
identity credential files (mode 0440) through that group; set your own
`fsGroup` to override it, or your own `runAsNonRoot`/`runAsUser` to run the
main container as a specific non-root user. For the trust boundary these
defaults protect — why the Job is treated like any other pod that holds
cloud credentials — see [The security model](../concepts/security-model.md).

## Inheriting from a cluster's defaults

A `TerraformMachine`'s or `TerraformMachinePool`'s `spec.jobs` is merged
field by field with its `TerraformCluster`'s `spec.defaults.jobs`: a field
the machine or pool sets wins, an unset one falls back to the cluster's
default, and a field neither sets gets the built-in default above. Two
fields merge instead of falling back as a whole:

- `env` is merged by name — the machine's or pool's entries first, then
  any of the cluster default's entries whose name they do not already use.
- `imagePullSecrets` is the union of both lists, without duplicates, the
  machine's or pool's first.

`resources`, `securityContext` and `podSecurityContext` are each replaced
as a whole: setting any one of them on the machine or pool drops the
cluster default's value for that field entirely, rather than merging
individual keys inside it. See
[What a cluster passes to its machines and pools](../concepts/kinds.md#what-a-cluster-passes-to-its-machines-and-pools)
for how this fits the rest of `spec.defaults`.

Defaults are resolved at reconcile time and never persisted, so raising a
cluster's `spec.defaults.jobs` reaches every existing machine and pool on
their next reconcile.

## Confirm it worked

```sh
kubectl get job -n <namespace> -l captf.infrastructure.cluster.x-k8s.io/owner-name=<object-name>
kubectl get job -n <namespace> <job-name> -o jsonpath='{.spec.activeDeadlineSeconds}{"\n"}{.spec.template.spec.serviceAccountName}{"\n"}'
```

`<namespace>` and `<object-name>` are the namespace and name of the
`TerraformCluster`, `TerraformMachine` or `TerraformMachinePool` you
changed; `<job-name>` is one Job name from the first command's output.
Compare the Job's `spec.template.spec.containers[0].resources`,
`securityContext` and `env` against what you set; a field you expected to
change but that still shows the built-in default usually means it was set
on the wrong object, or dropped by the merge rules above.

## See also

- [API Reference](../reference/api.md#jobpolicy) for every `spec.jobs`
  field, its default and its validation.
- [Job Environment](../reference/environment.md) for the Job's fixed
  fields, mounts, security contexts and runner args.
- [RBAC](../operator-guide/rbac.md) for the runner ServiceAccount, its
  RoleBinding and the opt-in sweep.
- [The security model](../concepts/security-model.md) for the trust
  boundary a Job's security context protects.
- [The reconcile lifecycle](../concepts/lifecycle.md) for retry backoff
  and how a Job's operation is chosen.
