# Plan Approval

`TerraformCluster` guards two things before it changes infrastructure: a
plan that deletes or replaces a resource always waits for an approval, and
with `spec.applyPolicy: Manual` every plan waits for one. This page covers
both guards, how they interact, and what they do not cover.

## Before you begin

- A `TerraformCluster` whose apply you want to guard or preview.
- `kubectl` access to annotate it and to read the source container's logs
  of its Jobs.

## The destructive-plan guard

A `TerraformCluster` is mutable: a new image tag, an edited field, or drift
`Remediate` re-applies its module. A module release that renames a
resource, or a different module pointed at the same state, can plan to
destroy infrastructure nobody asked to destroy. So every `TerraformCluster`
apply, including a drift remediation, runs its plan first and stops before
applying if any resource's planned actions include a delete: a removal, or
a replacement in either order. Nothing changes and the state is untouched.
`status.lastRun.error.kind` is `blocked`, `ApplyJobSucceeded` turns
`False`/`DestructivePlanBlocked` naming the affected addresses and
actions, and a `DestructivePlanBlocked` event is emitted once per blocked
Job. See [Conditions](../reference/conditions.md#applyjobsucceeded) and
[Events](../reference/events.md) for the exact reasons.

While the newest apply of the current inputs hash is blocked, no apply of
that hash starts; the controller re-checks at least every ten minutes. A
blocked drift remediation keeps drift and health checks running; a blocked
input change pauses them, since they would render the unapplied inputs.
Changing the inputs, which produces a new hash, starts a new guarded apply
at once, and so does approving the blocked hash. A blocked Job counts
toward neither the retry backoff nor the remediation failure cap.

### Approving a destructive plan

Read the plan first: `kubectl logs job/<name> -c source` has its
human-readable output, and the condition message lists what it deletes or
replaces. If the change is intended, approve the inputs hash named in the
condition:

```sh
kubectl annotate terraformcluster <name> -n <namespace> \
  captf.io/approve-destructive-plan=<inputs-hash> --overwrite
```

`<name>` and `<namespace>` are the `TerraformCluster`'s; `<inputs-hash>` is
the hash from the condition message.

The approval is by **inputs hash**: the hash of everything the apply
renders, the image reference and every module input (see [Job
Inputs](../concepts/inputs.md)). It approves exactly those inputs, not the
object. Any later change produces a new hash, which the annotation does
not name, so the next destructive plan is blocked again without anyone
removing the approval.

The approval is consumed once: when an apply of the approved hash
succeeds, the controller removes the annotation. A drift remediation
re-applies the inputs the state already records, so without this, an
approval of an input change would also cover a later destructive
remediation of the same inputs; instead, that remediation is blocked again
and needs its own approval.

The approval covers the plan computed when the approved apply runs, not
the plan you read: something that changed since is covered too. `lifecycle
{ prevent_destroy = true }` in the module remains the stronger control for
a resource that must never be replaced: it fails even an approved plan.
Anyone who can annotate the `TerraformCluster` can approve; that is the
same set of people who can change `spec.source.image`, which already
decides what the module does (see [Security
Model](../concepts/security-model.md)). See
[`captf.io/approve-destructive-plan`](../reference/annotations-labels.md)
for the annotation's full definition.

A guarded apply whose plan has no changes is never blocked: it stops
after the plan step, and the Job succeeds without an apply step, adopting
the rendered inputs hash and pinning the image digest as a full apply
would; see [Reconcile Lifecycle](../concepts/lifecycle.md).

## Plan preview: applyPolicy Manual

The destructive-plan guard only stops deletes and replacements; an
in-place change to a load balancer, a network or a security group still
applies on the next edit. Teams that review every infrastructure change
set `spec.applyPolicy: Manual` on the `TerraformCluster` or its
`TerraformClusterTemplate`. The default, `Automatic`, keeps the behavior
above unchanged. `applyPolicy` is mutable: switching back to `Automatic`
applies whatever was waiting, and clears `status.plan`.

1. **Plan.** When the controller would apply new inputs, it starts a plan
   Job instead (`status.activeJob.operation: plan`): init, validate, plan
   and read the plan back, with no apply step.
2. **Review.** The runner reports the plan's counts, the address and
   action of each changed resource (at most 50, never a value), and a
   **plan hash** over the sorted, non-no-op changes. The controller writes
   this to `status.plan` (`inputsHash`, `job`, `planHash`, `add`,
   `change`, `destroy`, `resources`, `truncated`, `createdAt`), sets
   `ApplyJobSucceeded` to `Unknown`/`PlanAwaitingApproval` with the exact
   approve command, and emits one `PlanReady` event with the counts. The
   Job's log has the human-readable plan.
3. **Wait.** Nothing applies and no further Job starts. The controller
   re-checks at least every ten minutes; a changed annotation or new
   inputs re-trigger it at once. The condition is `Unknown`, not `False`:
   waiting never turns `Ready` false.
4. **Approve.** Set the annotation from the condition message to the plan
   hash in `status.plan.planHash`:

   ```sh
   kubectl annotate terraformcluster <name> -n <namespace> \
     captf.io/approve-plan=<plan-hash> --overwrite
   ```

   `<name>` and `<namespace>` are the `TerraformCluster`'s; `<plan-hash>`
   is `status.plan.planHash`.

5. **Apply.** The apply Job starts (`PlanApproved` event), plans again, and
   applies only if the new plan's hash is the approved one. If anything
   changed since the plan was reviewed, it stops before applying:
   `status.lastRun.error.kind` is
   `plan-changed`, the new plan replaces `status.plan`,
   `ApplyJobSucceeded` turns `Unknown`/`PlanChanged` with a new approve
   command, and a `PlanChanged` event is emitted. The apply then waits for
   the approval of the new hash. A changed plan counts toward neither the
   retry backoff nor the remediation failure cap.
6. **Done.** When the approved apply succeeds, the controller removes
   `captf.io/approve-plan`, clears `status.plan`, and emits `PlanApplied`.

`captf_plan_approvals_total{result="approved"|"changed"}` counts applied
approvals and changed plans; see [Metrics](../reference/metrics.md).

Gated: every apply but the first, which covers an input change (image,
spec field, module variable, a Cluster input), a drift remediation, and
the retry of a failed apply. Not gated: the first apply of a new cluster
(there is no state yet, so nothing to break), deletion, refresh, and
drift checks. A plan without changes needs no approval: its hash is that
of the empty change list, and the apply proceeds at once, though it plans
again first and stops if the plan is no longer empty.

### With the destructive-plan guard

Approving a plan also approves its deletes and replacements: they are
listed in `status.plan.resources`, which the reviewer saw, and the apply
runs only that exact plan. So under `Manual`, the
`captf.io/approve-destructive-plan` annotation is never needed; the
destructive-plan guard is still armed for an apply that has no plan
approval, for example right after switching back to `Automatic`.
`lifecycle { prevent_destroy = true }` still fails an approved plan.

### Caveats

- An approval names a **plan hash**, not an inputs hash: it approves a set
  of changed addresses and actions, not the values that change. Two plans
  that touch the same resources hash the same, whatever the new values
  are. Review the plan's log, not only its hash.
- An approval is consumed only when the approved apply succeeds. One left
  behind, because the plan changed or the inputs changed before the apply
  ran, approves any later plan with the same hash, for example a
  recurring drift on the same resource. Remove a stale approval with
  `kubectl annotate terraformcluster <name> -n <namespace>
  captf.io/approve-plan-`.
- `status.plan` is status, not durable state: after `clusterctl move`,
  which does not restore status, the controller plans again, and an
  approval still on the annotation applies if the new plan hashes the
  same.
- In a GitOps setup, the annotation is set by a person, or by a pipeline
  after its own review of `status.plan` and the plan Job's log. It is not
  part of the desired state in Git: a controller that syncs annotations
  from Git would re-add a consumed approval.

## What is not guarded

Neither guard applies to a `TerraformMachine` or a `TerraformMachinePool`.
A machine is immutable: Cluster API replaces it with a new object instead
of changing it in place, so there is nothing for the destructive-plan
guard to catch, and `applyPolicy` does not exist outside
`TerraformCluster`. A machine pool is mutable and its `spec.variables` and
`spec.variablesFrom` change over its whole life, like a `TerraformCluster`
does, but its applies are never guarded: it has no `applyPolicy` field,
and the destructive-plan guard only watches `TerraformCluster` applies.
See [Machine Pools](machine-pools.md) and the
[reconcile lifecycle](../concepts/lifecycle.md).

## Confirm it worked

- After approving a destructive plan, `kubectl describe terraformcluster
  <name> -n <namespace>` shows `ApplyJobSucceeded` back to `True` and the
  `captf.io/approve-destructive-plan` annotation gone.
- After approving a plan under `Manual`, `status.plan` is empty and
  `ApplyJobSucceeded` is `True`/`ApplySucceeded`.

## See also

- [Drift](drift.md) for `drift.action: Remediate`, which the
  destructive-plan guard also covers.
- [Reconcile Lifecycle](../concepts/lifecycle.md) for where these guards
  sit in the reconcile flow.
- [Annotations, Labels and Finalizers](../reference/annotations-labels.md)
  for every annotation this page uses.
- [Conditions](../reference/conditions.md#applyjobsucceeded) and
  [Events](../reference/events.md) for the exact reasons.
