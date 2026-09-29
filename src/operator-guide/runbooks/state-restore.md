# State Restore

The `kubernetes` backend keeps only the latest state for each object; there
is no history to roll back to inside the backend itself. CAPTF keeps
**versioned backups** of every object's state instead, and can push one
back into the backend when you ask it to. This applies the same way to a
`TerraformCluster`, a `TerraformMachine` and a `TerraformMachinePool`: all
three keep backups and restore the same way.

## Before you begin

- `get` access to the object and its Secrets, and `patch` access to the
  object (`kubectl annotate` patches it), in its namespace, on the
  management cluster.
- Replace `<ns>`, `<name>` and `<kind>` below with the object's namespace,
  name and Kind (`terraformcluster`, `terraformmachine` or
  `terraformmachinepool`; the lowercase singular works with `kubectl`).
  `<suffix>` is `status.stateSecretSuffix`. Run every command against the
  management cluster.

## When to use it

- `StateReadable=False`/`StateLost`: the state Secret of a provisioned
  object is gone.
- `StateReadable=False`/`StateCorrupt` or `StateInconsistent` that does not
  clear on its own (a chunk deleted or overwritten by something other than
  the runner).
- A state overwritten with the wrong content — someone ran `terraform
  state push` or `state rm` from a workstation against the wrong object.

Restore is for disasters. It rewrites the object's state, so every
resource created **after** the backup's serial is no longer in the state:
Terraform forgets it, and it keeps running unmanaged in the cloud. The
next plan shows the difference (for a machine, the next drift check). Do
not use a restore to undo an ordinary change: change the inputs back
instead.

For how backups are taken, how many are kept, and what is never backed up,
see [Terraform State](../../concepts/state.md#state-backups).

## List the backups

`status.stateBackups` lists up to 16 complete backups, newest first
(serial, time taken, compressed bytes — see
[`reference/api.md`](../../reference/api.md) for its fields). It is
refreshed when a backup is taken or pruned and when a restore is
requested.

```sh
kubectl get <kind> <name> -n <ns> -o jsonpath='{.status.stateBackups}'
kubectl get secrets -n <ns> -l captf.io/state-backup=true,captf.io/state-backup-suffix=<suffix> \
  -o custom-columns=NAME:.metadata.name,SERIAL:.metadata.annotations.captf\.io/state-backup-serial,TAKEN:.metadata.annotations.captf\.io/state-backup-taken-at
```

`<kind>` is `terraformcluster`, `terraformmachine` or
`terraformmachinepool`; `<suffix>` is `status.stateSecretSuffix`.

## Restore

Pick the serial and annotate the object:

```sh
kubectl annotate <kind> <name> -n <ns> captf.io/restore-state=<serial> --overwrite
```

What happens:

1. The controller finds the newest complete backup of that serial. None,
   or a value that is not a serial:
   `RestoreJobSucceeded=False`/`RestoreBackupNotFound`, no Job.
2. A restore takes precedence over apply, drift and refresh, not over
   deletion: a deleting object never restores. It waits for a running Job
   to finish, then takes the object's run lease (and, for a
   `TerraformCluster` under the cluster operation gate, the cluster write
   lease; a machine's or pool's restore waits for its `TerraformCluster`'s
   apply or destroy) like an apply — see [run leases and the cluster
   operation
   gate](../../concepts/lifecycle.md#run-leases-and-the-cluster-operation-gate).
   A wait shows as `RestoreJobSucceeded=Unknown`/`WaitingForRunLease` (or
   the cluster-gate reasons).
3. A restore Job starts. Its root module declares only the `kubernetes`
   backend, so it needs neither the durable inputs nor any provider. It
   runs `init` (backend config as usual), `state push -force` (holding the
   state lock; `-force` because the backup's serial is older, or the
   lineage differs, or there is no state at all), and `state list`. The
   Job fails if the listed state has no managed resource although the
   backup had some.
4. On success: `RestoreJobSucceeded=True`/`StateRestored`, one
   `StateRestored` event, the annotation is removed, `status.lastRun`
   names the restore Job, and the next reconcile reads the restored state
   as usual, adopting the inputs hash the backup carried (`StateAdopted`
   — see [Events](../../reference/events.md)). The push writes back
   exactly the backup's serial rather than advancing it, and that serial
   is already backed up with this same content, so nothing new is written
   to `status.stateBackups`.
5. On failure: `RestoreJobSucceeded=False`/`RestoreFailed`, one
   `StateRestoreFailed` warning event. The restore is **not retried** for
   the same serial: set another serial, or delete the failed restore Job to
   try the same one again.

## Confirm

```sh
kubectl get <kind> <name> -n <ns> \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}/{.reason}{"\n"}{end}'
kubectl logs job/<restore-job-name> -n <ns> -c source      # state list output
kubectl events --for <kind>/<name> -n <ns>
```

Expect `StateReadable=True`/`StateRead`, `status.observedStateSerial` at
exactly the restored serial (the push writes it back unchanged, it does
not advance it), and `RestoreJobSucceeded=True`/`StateRestored`.

Then look at the difference between the restored state and reality
**before** anything applies it:

- A `TerraformCluster` or `TerraformMachinePool` (both mutable) whose
  current inputs differ from the restored state's inputs hash applies
  them right after the restore (`InputsChanged`). Only the
  `TerraformCluster`'s apply is guarded: a plan that deletes or replaces
  anything stops for approval (see [The destructive-plan
  guard](../../user-guide/plan-approval.md#the-destructive-plan-guard)),
  so read the blocked Job's plan before approving it; a
  `TerraformMachinePool` applies unguarded. Do not pause the object to
  prevent this: a paused object starts no Job, the restore included.
- Run a drift check to list what the restored state no longer matches;
  with drift action `Report` nothing is changed. See
  [Drift](../../user-guide/drift.md).
- Resources created after the backup are not in the state. Import them
  (`terraform import` from a workstation against the object's backend) or
  delete them in the cloud.

## Manual recovery with no backup

If `StateLost`, `StateCorrupt` or `StateInconsistent` never clears because
no backup was taken before the loss (see the
[state-unreadable runbook](state-unreadable.md)), there is no CAPTF-side
restore: reconstruct the state from a workstation against the object's own
backend, then let the next reconcile read it back.

The object's backend is the `kubernetes` backend, configured exactly:

```hcl
terraform {
  backend "kubernetes" {
    secret_suffix     = "<suffix>"       # status.stateSecretSuffix
    namespace         = "<ns>"           # the object's own namespace
    in_cluster_config = false            # true only from inside the cluster
    config_path       = "~/.kube/config" # a kubeconfig for the management cluster
    labels = {
      "captf.infrastructure.cluster.x-k8s.io/owner-kind" = "<kind>"
      "captf.infrastructure.cluster.x-k8s.io/owner-name" = "<owner-name>"
      "cluster.x-k8s.io/cluster-name"                    = "<cluster-name>"
      "captf.io/managed"                                 = "true"
      "clusterctl.cluster.x-k8s.io/move"                 = ""
    }
  }
}
```

- `<kind>` is exactly `TerraformCluster`, `TerraformMachine` or
  `TerraformMachinePool`.
- `<owner-name>` and `<cluster-name>` are the object's own name and its
  Cluster's name, each verbatim if 63 characters or fewer, or the first 16
  hex characters of its sha256 otherwise (the Kubernetes label value
  limit) — the same rule `status.stateSecretSuffix`'s own derivation
  follows; see [Terraform State](../../concepts/state.md#secret-names-and-the-suffix).
- Getting the `labels` map wrong does not fail loudly: the backend uses it,
  together with the suffix and workspace, to find the object's existing
  state Secrets, so a mismatched value makes it list none and behave as if
  the object had no state at all, rather than erroring. Match it exactly,
  including the empty string on the last key.

Run `terraform init` with this backend block, then either `terraform
import` each resource the cloud provider's own inventory shows is missing,
or `terraform state push <file>` a state file reconstructed another way.
Once it is pushed, the next reconcile reads it back the same as a restored
backup (`StateReadable` turns `True`/`StateRead`): run a drift check before
anything applies again, since the object's own record of its last-applied
inputs was lost along with the state, and the first reconcile after the
push may see the current inputs as changed.

## Caveats

- Restoring an older state makes Terraform forget every resource created
  after that serial: those resources become unmanaged and are neither
  updated nor destroyed with the object.
- A backup is taken of what the backend stored. A state that was already
  wrong when it was written (a bad apply) is backed up just as faithfully.
- A backup older than the object's current inputs makes a `TerraformCluster`
  or `TerraformMachinePool` re-apply its current inputs after the restore.
- A paused object (or Cluster) starts no restore until it is resumed.
- Backups share the namespace's Secret quota with everything else.

## See also

- [Terraform State](../../concepts/state.md) — the backend, Secret naming
  and how backups are taken and pruned.
- [Stuck destroy runbook](stuck-destroy.md) — recovering when the object
  cannot be destroyed at all.
- [Conditions reference](../../reference/conditions.md#restorejobsucceeded)
  — every `RestoreJobSucceeded` reason.
