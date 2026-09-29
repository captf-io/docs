# Terraform State

CAPTF stores every object's Terraform or OpenTofu state in Kubernetes
Secrets, alongside the object, and reads it back for outputs, drift and
health. This page explains where that state lives, how CAPTF backs it up,
and what happens to it when an object is deleted. For an inventory of every
Secret CAPTF reads or writes, including state, see
[Secrets](../operator-guide/secrets.md).

## The backend

Every `TerraformCluster`, `TerraformMachine` and `TerraformMachinePool`
gets its own Terraform or OpenTofu run, backed by the `kubernetes` backend
configured to write into the object's own namespace, in the `default`
workspace (the only one CAPTF ever uses). The backend's `secret_suffix`
is derived from the object's namespace, kind and name, which survive a
`clusterctl move`, and never from its UID, so state follows the object
across a move instead of being orphaned.

## Secret names and the suffix

The suffix is the first 16 hex characters of
`hex(sha256(<namespace>/<kind>/<name>))`, a hyphen, and a short kind
code: `c` for `TerraformCluster`, `m` for `TerraformMachine`, `mp` for
`TerraformMachinePool`. It never ends in `-<digits>`, which the backend
would otherwise try to parse as a chunk index.

The base state Secret is named `tfstate-default-<suffix>`.
`status.stateSecretSuffix` records the suffix; it is informational only,
since the controller derives it deterministically and never reads it back.

The state lock is a `coordination.k8s.io/v1` Lease named
`lock-tfstate-default-<suffix>` in the same namespace. See
[Locks](#locks) below.

## Chunking and size caps

A Kubernetes Secret holds at most 1 MiB, and a large Terraform state can
exceed that once compressed. Terraform splits an oversized state across
additional Secrets named `tfstate-default-<suffix>-part-1`,
`-part-2` and so on; OpenTofu does not chunk state at all and always
writes a single Secret. CAPTF reads whichever shape is present: it lists
every Secret carrying the backend's own labels for the suffix, orders them
by chunk index, and concatenates their payloads before decompressing.

CAPTF caps what it is willing to read: at most 32 chunks and 64 MiB of
decompressed state. Real state compresses 10-20x, so these limits are far
beyond any plausible cluster or machine state; a state that exceeds them,
or whose chunk set is incomplete, duplicated or names an unexpected
Secret, is reported corrupt or inconsistent rather than partially read.
[`CAPTFStateNearSecretLimit`](../operator-guide/observability.md#captfstatenearsecretlimit)
warns before a state's compressed size approaches the 1 MiB Secret limit.

## Locks

Both runtimes hold the lock for the duration of a run and release it on a
clean exit. A runner Job waits up to `lockTimeoutSeconds` (see
[Job tuning](../user-guide/job-tuning.md) for the field and its default)
for a held lock before failing. Before starting a Job, the controller
checks the lock Lease and reads its holder from the backend's own lock
info: a lock whose holder is one of the object's own runner pods, and
that pod either no longer exists or has already exited (a finished Job
keeps its pod object until it is pruned), is stale, and the controller
has the next Job force-unlock it automatically. A lock whose holder is
unknown, or is not one of the object's own runner pods, is left alone
and reported as `StateReadable=False/StateLocked`. See the
[stale state lock runbook](../operator-guide/runbooks/stale-lock.md) to
force-unlock one by hand.

## What CAPTF reads from state

CAPTF parses only the fields it needs from the Terraform state v4 file:
the serial, lineage, Terraform/OpenTofu version, the root module's
outputs, and a count of managed resources (a resource with `count` or
`for_each` counts once). It also tracks the compressed size of the
concatenated chunks and, from an annotation on the base Secret, the inputs
hash of the last successful apply. Resource instance attributes are never
parsed. Outputs may be sensitive and are never logged.

After a successful apply or restore, the controller sets an owner
reference to the object on every chunk Secret (so state moves with a
`clusterctl move` and is garbage collected with the object) and records
the applied inputs hash on the base Secret, since Terraform's own chunk
writes carry only the backend's labels.

## State backups

The manager keeps versioned copies of an object's state so a lost,
corrupted or wrongly overwritten state Secret can be recovered. Whenever
the controller reads a state serial it has not observed before for the
object, it copies the state Secrets' data verbatim into a backup set named
`captf-state-backup-<suffix>-<serial>` (with the same `-part-N` chunking
as the source), owned by the Terraform* object itself rather than by the
state, so a backup survives the state Secret being deleted by hand and is
garbage collected only when the object is. An unchanged serial is not
backed up again.

`--state-backups` (default 5; see [manager
flags](../reference/manager-flags.md)) sets how many backups per object
the manager keeps; it prunes older ones in the same pass. `--state-backups=0`
takes no new backups but leaves existing ones in place and restorable.
`status.stateBackups` lists the newest backups (see
[`reference/api.md`](../reference/api.md) for its fields).

A state that cannot be parsed with the reader's own limits is never backed
up: encrypted, corrupt, inconsistent, or beyond the chunk and size caps
above; nor is one the manager failed to copy, for example on a transient
API error. Either way the manager logs why and counts it in
[`captf_state_backups_total`](../reference/metrics.md) with
`result="skipped"`. A state that cannot be parsed is left that way and the
reconcile continues; a failed copy instead retries on the next reconcile,
since that serial is not recorded as observed. No backups are taken while
an object is being deleted.

## Restore

An annotation asks the controller to push a listed backup's content back
into the backend as a new state, through a restore Job that runs `state
push -force`. See the [state restore
runbook](../operator-guide/runbooks/state-restore.md) for the procedure,
what a restore does and does not undo, and how to verify one.

## OpenTofu state encryption

OpenTofu's client-side state encryption wraps the state file in an
envelope with no `version` field of its own. CAPTF detects that envelope
and reports the state as encrypted (`StateReadable=False/StateEncrypted`)
rather than misreading it as corrupt: reading an encrypted state's outputs
is not supported.

## State on deletion

Neither backend deletes its own state: a `destroy` only empties the
managed resources it recorded, and the `default` workspace cannot be
deleted. The controller removes the state Secrets and the lock Lease
itself, once it is safe to do so: after a destroy Job succeeds, or
immediately on deletion of an object that was never applied and so has no
state. That same cleanup also deletes the durable inputs Secret, the
object's run lease and, for a `TerraformCluster`, its cluster write
lease. State backups are not deleted by
this cleanup; they are owned by the object and are garbage collected when
Kubernetes removes it after its finalizer is gone. If the finalizer is
removed by hand before the state is cleaned up, see the [stuck destroy
runbook](../operator-guide/runbooks/stuck-destroy.md).

## See also

- [Secrets](../operator-guide/secrets.md) for the full Secret inventory,
  including state and its backups.
- [State restore runbook](../operator-guide/runbooks/state-restore.md).
- [Stale state lock runbook](../operator-guide/runbooks/stale-lock.md).
- [Stuck destroy runbook](../operator-guide/runbooks/stuck-destroy.md).
- [Unreadable state runbook](../operator-guide/runbooks/state-unreadable.md).
