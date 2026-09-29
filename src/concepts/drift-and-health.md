# Drift and Health

This page explains how CAPTF checks a provisioned `TerraformCluster`,
`TerraformMachine` or `TerraformMachinePool` against reality: the drift
schedule, what the module's health output means, and how both feed the
`InfrastructureHealthy` and `Ready` conditions and, for machines, Cluster
API remediation. It is for anyone who wants to understand the behavior
before changing it. To configure drift checking, see
[Drift](../user-guide/drift.md); to configure machine remediation, see
[Machine Remediation](../user-guide/remediation.md); for the full reason
tables, see [Conditions](../reference/conditions.md).

## What runs, and when

Two kinds of Job read an object's infrastructure after it is provisioned:

- A **refresh Job** runs `apply -refresh-only`: it updates the state from
  reality and produces a fresh health reading, but plans nothing and
  finds no drift.
- A **drift Job** does the same refresh, then plans with `-refresh=false`:
  a plan with no changes means no drift, and any add, change or destroy
  in the plan is drift. A cluster or pool plans against its freshly
  rendered current inputs (falling back to the durable inputs Secret only
  when the current ones can't be built); a machine, being immutable,
  always plans against its durable inputs. See [Job inputs](inputs.md).

Both count as one health sample once the object is provisioned, and both
set the `DriftJobSucceeded` condition to report whether the Job
succeeded; only a drift Job sets `DriftDetected`. A failed refresh or
drift Job is retried under the reconciler's normal backoff; see
[Reconcile flow](lifecycle.md) for how retries and requeues work in
general.

A drift check runs on a schedule: `spec.drift.intervalSeconds`, inherited
from the `TerraformCluster`'s `spec.defaults.drift` for a machine or pool
that sets none, else the manager's `--drift-default-interval` (30
minutes by default; see [Manager flags](../reference/manager-flags.md)).
The first check after provisioning is due one interval after the last
successful apply, not immediately; each object's schedule is jittered
deterministically by its UID so that objects created together don't all
check at once. `TerraformCluster` and `TerraformMachine` both let
`spec.drift.intervalSeconds: 0` turn drift checks off entirely, which
normally also stops routine health sampling after provisioning, since no
more refresh or drift Jobs run on a schedule (a reading of
`InstancePending` still gets occasional extra refreshes on its own,
below). A `TerraformMachinePool`'s own interval must be at least 1
second — the CRD rejects `0` outright — and even a cluster's
`spec.defaults.drift.intervalSeconds: 0`, which does disable a machine's
drift, leaves a pool's on the manager's default instead: a pool's
periodic drift Job is what feeds its refreshed instance count into a
plan, so disabling it would stop that count from ever reaching a plan;
see
[Machine pools](../user-guide/machine-pools.md).

Outside the drift schedule, a `TerraformMachine` or `TerraformMachinePool`
also takes a refresh right after each successful apply, to get an
immediate health reading (unless the apply's own outputs already gave a
definite one); a `TerraformMachinePool` refreshes again on its own
`membershipRefreshIntervalSeconds` cadence to keep membership current
regardless of drift (see [Machine pools](../user-guide/machine-pools.md)),
and, with `remediation.annotateMachine` set, a machine refreshes on
`remediation.healthCheckIntervalSeconds` independent of drift too (see
[Machine Remediation](../user-guide/remediation.md)); none of these
apply to a `TerraformCluster`. For a `TerraformCluster` or
`TerraformMachine`, while a reading is `InstancePending`, the next
refresh backs off on its own doubling schedule (30 seconds up to 5
minutes) instead of waiting for the next drift interval, so a newly
launched instance is checked again quickly. A `TerraformMachinePool`'s
pending reading instead refreshes every 30 seconds flat, the same fixed
cadence its membership convergence uses, since the two converge
together; see [Machine pools](../user-guide/machine-pools.md).

## Report or remediate

Drift found by a drift Job is either just recorded or automatically
corrected, per the object's drift action, `Report` or `Remediate`:

- **`Report`** (the default for every kind) only sets `DriftDetected`;
  it records the finding but applies nothing.
- **`Remediate`** additionally re-applies the object's current inputs to
  remove the drift.

Only a `TerraformCluster`'s own `spec.drift.action` and a
`TerraformMachinePool`'s own `spec.drift.action` (never inherited from
the cluster's `spec.defaults.drift`, which has no action field at all)
can select `Remediate`. A `TerraformMachine`'s drift policy has no action
field either, and is always `Report`: a machine's instance is immutable
infrastructure, replaced by a Cluster API rollout, not reconciled in
place by a re-apply.

When a pool or cluster remediates, a finding sets `DriftDetected`
True/`DriftPending` rather than True/`DriftReported`, and the reconciler
starts an apply of the current inputs. While that apply runs,
`DriftDetected` reads True/`DriftRemediating`; if the apply succeeds
after the drift check that found the drift, `DriftDetected` clears to
False/`NoDrift` at once, without waiting for the next drift check. If the
apply instead fails, is blocked, or stops because its approved plan
changed, `DriftDetected` falls back to True/`DriftPending` with a note of
what happened, and the reconciler keeps retrying the remediation apply
(under the normal backoff) until as many attempts have failed since the
last successful drift check as the object's failed-Job history keeps
(see [Job tuning](../user-guide/job-tuning.md)); past that, the drift
stays pending until the next successful check re-evaluates it.

A remediation apply is still an apply of that kind, with the same guard
as any other:

- A **`TerraformCluster`**'s remediation apply goes through the same
  destructive-plan guard as any other cluster apply — a plan that would
  delete or replace a resource blocks (`ApplyJobSucceeded=False`/
  `DestructivePlanBlocked`) until it is approved — or, under
  `spec.applyPolicy: Manual`, the plan-approval flow instead of the
  guard. See [Plan preview and approval](../user-guide/plan-approval.md).
- A **`TerraformMachinePool`**'s remediation apply is not guarded: a pool
  has no `applyPolicy` and no destructive-plan guard, so it just runs.

## DriftDetected

`DriftDetected` is negative polarity: True means drift was found, and it
is never an input to `Ready`, so drift alone never makes an object
un-Ready. Before the first drift check it reads Unknown/`DriftNotChecked`.
Its full reason table, including the messages each reason carries, is in
[Conditions](../reference/conditions.md#driftdetected).

## From module health to `InfrastructureHealthy`

Every module role (`cluster`, `machine`, `machinepool`) declares a
`health` output with a `state` (`pending`, `running`, `degraded`,
`stopped`, `terminated` or `unknown`) and a `healthy` boolean, plus
optional `message` and `reasons`. Each refresh or drift Job's outcome —
and, for a machine or pool, the reading an apply itself provides — maps
to `InfrastructureHealthy`:

| Module `health.state` | `healthy` | `InfrastructureHealthy` |
| --- | --- | --- |
| (no apply has started yet) | — | Unknown/`WaitingForProvisioning` |
| (before provisioned, since the first apply started) | — | False/`Provisioning` |
| `pending` | any | False/`InstancePending` |
| `running` | `true` | True/`Healthy` |
| `running` | `false` | False/`InstanceUnhealthy` |
| `degraded` | any | False/`InstanceDegraded` |
| `stopped` | any | False/`InstanceStopped` |
| `terminated` | any | False/`InstanceTerminated` |
| `unknown`, or no health output at all | — | Unknown/`HealthUnknown` |

`message` and `reasons`, when the module sets them, are joined into the
condition's message. The full reason table is in
[Conditions](../reference/conditions.md#infrastructurehealthy).

For a `TerraformMachine` specifically, a `provider_id` output that turns
null after provisioning is read as `terminated` even though the module
reported no such health state: the instance is gone, whatever the health
output says, and `spec.providerID` is kept rather than cleared.

## `InfrastructureHealthy` and `Ready`

`InfrastructureHealthy` is not itself mirrored to Cluster API, but once
an object is provisioned it becomes, with `Deleting` (and for a pool also
`ApplyJobSucceeded`), the entire set of conditions that `Ready`
summarizes — down from the full set of dependency, credential, RBAC,
apply, state and output conditions `Ready` watches beforehand. See
[Reconcile flow](lifecycle.md) for how `status.initialization.provisioned`
latches, and
[Conditions](../reference/conditions.md#ready-summarization) for exactly
which conditions feed `Ready`, per kind and per phase.

## Unhealthy samples

A `TerraformMachine` counts consecutive unhealthy samples in
`status.unhealthySamples`: each successful refresh or drift Job after
provisioning is one sample (an apply's own reading counts too, when it
already gives a definite reading and stands in for the post-apply
refresh). An `InfrastructureHealthy` reading of `Healthy` resets the
count to zero; `InstanceUnhealthy`, `InstanceDegraded` or
`InstanceStopped` adds one; `InstancePending`, `HealthUnknown` or
`InstanceTerminated` leaves it as it is.

This count is what drives Cluster API machine remediation: see
[Machine Remediation](../user-guide/remediation.md) for the threshold,
the terminated-instance shortcut, the `cluster.x-k8s.io/remediate-machine`
annotation and its withdrawal.

## See also

- [Drift](../user-guide/drift.md)
- [Machine Remediation](../user-guide/remediation.md)
- [Plan preview and approval](../user-guide/plan-approval.md)
- [Reconcile flow](lifecycle.md)
- [Conditions](../reference/conditions.md)
