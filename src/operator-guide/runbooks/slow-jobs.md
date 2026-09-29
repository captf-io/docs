# Slow Jobs

This page helps you find out why a `TerraformCluster`, `TerraformMachine`
or `TerraformMachinePool`'s Jobs are taking a long time — either to run,
or to start. It covers the `CAPTFJobSlow` and `CAPTFJobQueueSlow` alerts.
The two measure different things and point at different causes, so start
by working out which one fired.

## Before you begin

- `kubectl` access to the object's namespace and to Leases and pods there,
  on the management cluster.
- Both alerts carry `kind` and `op`, not an object name; find the specific
  object through `status.activeJob` or the Jobs of that kind and op.

## 1. Tell the two alerts apart

- `CAPTFJobSlow` measures the wall time of a **completed** Job, start to
  finish. Go to [A Job that runs long](#a-job-that-runs-long).
- `CAPTFJobQueueSlow` measures the time from a Job's **creation** to its
  module container actually starting. Go to
  [A Job slow to start](#a-job-slow-to-start).

Neither counts time spent waiting *before* a Job is even created — that
wait shows up as a condition stuck in an `Unknown` state instead. If
`status.activeJob` names no Job yet the object is not idle either, go to
[Waiting for a lease](#waiting-for-a-lease) first.

## Waiting for a lease

Before creating a Job, the controller takes the object's own run lease
(`captf-run-<suffix>`), and, for an apply, destroy or restore that names a
cluster, the Cluster's write lease (`captf-cluster-<hash>`) as well. See
[Run leases and the cluster operation
gate](../../concepts/lifecycle.md#run-leases-and-the-cluster-operation-gate)
for how the two work together, and [Configuration](../configuration.md)
for the `--cluster-operation-gate` flag. While either is held by someone
else, `ApplyJobSucceeded` (or `DriftJobSucceeded` for a refresh or drift,
`RestoreJobSucceeded` for a restore — see
[Restoring State](state-restore.md)) stays `Unknown`, with one of these
reasons, and no Job exists yet:

- `WaitingForRunLease`: another live Job — usually another manager
  instance's — already holds this object's run lease.
- `WaitingForClusterOperation`: a `TerraformMachine`'s or
  `TerraformMachinePool`'s operation is waiting for its
  `TerraformCluster`'s to finish first.
- `WaitingForMachineOperations`: a `TerraformCluster`'s operation is
  waiting for its machines' and machine pools' applies and destroys,
  already in flight, to finish first; any new one of theirs waits for the
  cluster in turn.

The condition's message names the Lease and the Job (or manager) holding
it, and the controller checks again every 30 seconds — this is normal and
usually resolves on its own once the holder finishes.

```sh
kubectl get lease -n <ns> -l captf.io/lease=run,captf.infrastructure.cluster.x-k8s.io/owner-name=<name>
kubectl get lease -n <ns> -l captf.io/lease=cluster
```

`spec.holderIdentity` is the holder's Job name; the
`captf.io/lease-op` and `captf.io/lease-acquired-at` annotations say what
it is running and since when. A lease is only ever taken over by the
controller itself, once its holder Job has finished, does not exist after
a short grace period, or is older than its own deadline plus a backstop
— **never delete or edit a Lease by hand**: if its holder Job is genuinely
stuck, that is a [failing Job](job-failures.md) or a
[slow one](#a-job-that-runs-long) to chase down instead, not a lease
problem.

A wait that outlasts the holder's `activeDeadlineSeconds` means the
holder cannot finish; look at that Job directly.

## A Job that runs long

`CAPTFJobSlow` fires on the Job's own duration, so the module (or the
cloud it calls) is doing the work, not the controller withholding
anything. Narrow it down:

```text
# p90 duration by step, for this kind and op
histogram_quantile(0.9, sum by (le, step) (rate(captf_job_step_duration_seconds_bucket{kind="<kind>",op="<op>"}[6h])))
```

`status.lastRun.steps` on the object itself shows the same breakdown for
its most recent run, without a Prometheus query. Once you know which step
is slow:

- **`plan`, `apply`, `apply-refresh-only` or `destroy` is slow**: these
  are the steps that lock the state (`init` never does), so a slow but
  *successful* one may have been contending for the lock — every locking
  step waits at most `spec.jobs.lockTimeoutSeconds` (five minutes unless
  set) for it before failing on its own. Check `StateReadable` for reason
  `StateLocked` and see the [stale state lock runbook](stale-lock.md).
  Otherwise it is a large or slow module, or a cloud provider that is
  itself slow — nothing in the controller to tune. Compare against
  `spec.jobs.activeDeadlineSeconds`
  ([Tuning Jobs](../../user-guide/job-tuning.md)) before it starts
  hitting the deadline and turning into a
  [failing Job](job-failures.md) instead of a slow one.
- **every step is proportionally slow**: check the Job pod's own resource
  use against `spec.jobs.resources`
  ([Tuning Jobs](../../user-guide/job-tuning.md)) — a Terraform or
  OpenTofu process with several providers is memory-hungry, and
  throttling or swapping shows up as slowness everywhere, not one step.

## A Job slow to start

`CAPTFJobQueueSlow` covers everything between the Job existing and its
module container running: pod scheduling, both image pulls (the runner
init container's and the module's own), and the runner binary copy.

```sh
kubectl get pods -n <ns> -l captf.infrastructure.cluster.x-k8s.io/op=<op> --field-selector=status.phase=Pending
kubectl describe pod -n <ns> <pod-name>
```

Read the pod's `Events`:

- `FailedScheduling`: exhausted node capacity, a `ResourceQuota`, or a
  scheduling constraint (affinity, taints) the runner's pod cannot
  satisfy. Check `spec.jobs.resources`, `spec.jobs.podSecurityContext`
  overrides and the namespace's quota; see
  [Tuning Jobs](../../user-guide/job-tuning.md).
- `Pulling` / `ErrImagePull` / `ImagePullBackOff`: a slow, rate-limited or
  unreachable registry. A pull that never succeeds eventually hits the
  Job's deadline and becomes a
  [failing Job](job-failures.md#image-pull-failures) instead; a pull that
  succeeds but is merely slow is this alert's whole story.

A controller's own concurrency limit
(`--terraformcluster-concurrency`, `--terraformmachine-concurrency`,
`--terraformmachinepool-concurrency`, ten each unless set; see
[Configuration](../configuration.md)) does not appear here: it bounds how
many objects of a kind reconcile at once, not how fast a Job someone
already created gets scheduled and pulled. A concurrency limit too low
for the fleet shows up as objects going longer between reconciles overall
— check the object's own `status.observedGeneration` and event timestamps
for that, not this alert.

## Confirm it worked

```sh
kubectl get <kind> -n <ns> <name> -o json | jq '.status.lastRun.steps'
```

The next run's step durations (or `captf_job_duration_seconds` and
`captf_job_queue_seconds` for the kind and op) drop back under the
alerts' thresholds — 30 minutes p90 duration, 5 minutes p90 queue time.

## See also

- [Failing Jobs](job-failures.md) — a Job that stops instead of merely
  running long.
- [Stale State Lock](stale-lock.md) — clearing a lock a Job is waiting on.
- [The Reconcile Lifecycle](../../concepts/lifecycle.md) — run leases and
  the cluster operation gate in full.
- [Tuning Jobs](../../user-guide/job-tuning.md) — deadlines, lock
  timeouts and resources.
