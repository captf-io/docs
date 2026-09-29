# Reconcile Errors

This page helps you diagnose the `CAPTFReconcileErrors` alert: one of the
manager's own controllers is repeatedly failing to reconcile, as opposed
to an object's Job failing (see [Failing Jobs](job-failures.md)). A
reconcile error means the controller could not even finish deciding what
to do — it is not a statement about any one object's infrastructure.

## Before you begin

- `kubectl` access to the manager's Deployment and its logs, in the
  `captf-system` namespace (or wherever it is installed), on the
  management cluster.

## 1. Read the manager's logs

```sh
kubectl logs -n captf-system deploy/captf-controller-manager --tail=200
```

Each reconcile that returns an error logs a line carrying `controller`
(one of `terraformcluster`, `terraformmachine`, `terraformmachinepool`,
`terraformmachinetemplate` or `terraformclusteridentity` — the alert's
`controller=~"terraform.*"` matches all five), the object's `namespace`
and `name`, and the error itself. Reconciles for a `TerraformMachine`,
`TerraformCluster` or `TerraformMachinePool` also carry that object's own
key (`TerraformMachine`, `TerraformCluster`, `TerraformMachinePool`) plus
its owning `Cluster`, `Machine` or `MachinePool` where one exists, so you
can filter by any of those instead of grepping free text.

The default log level (`-v=2`) already includes the manager's own flow
logging in addition to errors, so raising `-v` is rarely needed just to
see that a reconcile failed; it helps to see *why* a decision was made
before the error, not to see the error itself. `--diagnostics-address`'s
endpoint can change the running level without a restart when
`--insecure-diagnostics` is not set; see
[Manager Flags](../../reference/manager-flags.md).

## 2. Narrow down which object, and how often

```text
sum by (controller) (rate(controller_runtime_reconcile_errors_total{controller=~"terraform.*"}[10m]))
```

matches the alert's own query. If it is one object erroring repeatedly,
its logs name it on every line; if it is spread across many objects of
one kind, look for a cause common to the whole namespace or cluster
(quota, RBAC, an API server problem) rather than the object's own spec.

## Common causes

- **The Kubernetes API server is unavailable or throttling requests**: a
  `Get`, `Create`, `Update` or `Patch` failed with a server-side error
  (`500`, `503`, or a `429` from client-side rate limiting). Transient —
  the error clears once the API server does; if it does not, check the
  API server's own health.
- **The manager's own patch was rejected by the validating webhook**: the
  manager itself writes a `Terraform*` object's finalizer and a handful
  of spec fields (for example a `TerraformMachine`'s `providerID`, a
  `TerraformCluster`'s `controlPlaneEndpoint`) through the same admission
  path a user's `kubectl apply` goes through. If the webhook cannot be
  reached, that patch fails and shows up here. See
  [Webhook Unavailable](webhook-unavailable.md).
- **The manager's own RBAC is missing a permission**: the `ClusterRole`
  it runs as (`captf-manager-role`) was edited by hand, or an upgrade
  changed what it needs and the installed `ClusterRole` was not updated
  to match. The error names the verb, resource and group a `403`
  `Forbidden` response refused. See [RBAC](../rbac.md) for what the
  manager needs and creates.
- **A namespace `ResourceQuota` blocks a create**: the manager creates
  Jobs, Secrets, Leases, and a per-namespace runner `ServiceAccount` and
  `RoleBinding` on an object's behalf. A quota on any of those object
  counts in the tenant namespace surfaces as a `Forbidden` create error
  here rather than anywhere on the `Terraform*` object's own status.
- **A conflicting concurrent write**: two updates to the same object
  raced (for example, the manager and an operator editing it at the same
  moment). The condition-patching helper already retries a conflicting
  status write itself; a `Conflict` that still reaches the log usually
  clears on the next reconcile, which controller-runtime's own per-item
  backoff already schedules — distinct from a Job's retry backoff (see
  [Failing Jobs](job-failures.md#retry-backoff)), and not something to
  act on unless it repeats for the same object.

None of these are the same as an object's Job failing: a Job failure is
recorded on the object's own `status` and conditions and never increments
`controller_runtime_reconcile_errors_total` — only an error the
reconciler itself returns does. See [Failing Jobs](job-failures.md) if
what you are chasing is instead a failing apply, destroy, drift check or
refresh.

## Confirm it worked

```sh
kubectl logs -n captf-system deploy/captf-controller-manager --tail=50 --follow
```

No further `Reconciler error` lines appear for the affected controller,
and `sum by (controller) (rate(controller_runtime_reconcile_errors_total{controller=~"terraform.*"}[10m]))`
returns to 0.

## See also

- [Failing Jobs](job-failures.md) — a Job or an object's status, as
  opposed to the controller itself.
- [Webhook Unavailable](webhook-unavailable.md) — a specific, common
  cause of reconcile errors.
- [RBAC](../rbac.md) — what the manager's own `ClusterRole` grants.
