# Runbook: state that will not read

`StateReadable` reports whether the controller could read a
`TerraformCluster`, `TerraformMachine` or `TerraformMachinePool`'s state
this reconcile. While it is `False` or `Unknown`, no plan, apply, drift
check or refresh Job runs for the object, and `Ready` follows it down.
This runbook covers every reason `StateReadable` (and its True
counterpart) can carry, what each means, and what to do. For the
`CAPTFStateUnreadable` alert itself, see
[Observability](../observability.md#captfstateunreadable).

Replace `<ns>`, `<kind>` and `<name>` below with the object's namespace,
kind (`terraformcluster`, `terraformmachine` or `terraformmachinepool`) and
name.

## Find the reason

```sh
kubectl get <kind> -n <ns> <name> \
  -o jsonpath='{range .status.conditions[?(@.type=="StateReadable")]}{.status}/{.reason}: {.message}{"\n"}{end}'
```

Also check for a `Warning` event: a reason that turns `False` emits one,
named either `StateLost`, `StateLocked` or, for the three read errors
below, `StateUnreadable`.

```sh
kubectl events --for <kind>/<name> -n <ns>
```

## StateRead

The healthy, `True` reason: the state was read this reconcile. Nothing to
do.

## StateNotFound

`Unknown`. No state Secret exists yet, because the object has never
completed an apply, or (for a mutable kind) it was deleted along with the
state on a previous destroy. This is not an error: a new object reports it
until its first successful apply, and it never fires
`CAPTFStateUnreadable`. If an object that used to be provisioned reports
this instead of `StateRead`, its state Secret is gone; see **StateLost**
below, which is the reason a *provisioned* object with a missing state
Secret carries instead.

## StateLost

`False`. Either the state Secret of a provisioned object is missing, or
its state has no recorded inputs hash although the object is provisioned
(only possible for `TerraformMachine`, which is immutable and so never
rebuilds inputs to re-apply from). Either way, applying again is not safe:
for the missing-Secret case, a second apply would create a second set of
resources next to the live ones instead of managing the ones the lost
state recorded; for the missing-inputs-hash case, there is nothing to
re-apply. No Job runs, and the condition does not clear on its own.

Fix: restore the object's newest usable state backup with the
`captf.io/restore-state` annotation. See the
[state restore runbook](state-restore.md), including how to list the
backups in `status.stateBackups`. If no backup exists, `StateLost` never
clears; the object's resources still exist in the cloud but nothing in
Kubernetes can manage them until a state is restored, or reconstructed out
of band with [manual recovery](state-restore.md#manual-recovery-with-no-backup).

## StateLocked

`False`. The state's lock `Lease` is held by something other than this
object's own runner — for example a workstation running `terraform state
rm`, or a Job that died without releasing it. The condition's message
names the holder, its operation and when it took the lock; every Job for
the object waits `lockTimeoutSeconds` (`spec.jobs.lockTimeoutSeconds`,
defaulting to 300 seconds — see [Job tuning](../../user-guide/job-tuning.md))
for it and then fails.

The controller already force-unlocks a lock whose holder pod is gone, the
next time it starts a Job for the object; most `StateLocked` conditions
clear on their own. See the [stale-lock runbook](stale-lock.md) for how
that detection works, how to tell a live holder from a stale one by hand,
and manual force-unlock.

## StateEncrypted

`False`. The state Secret carries OpenTofu's client-side state encryption
envelope. CAPTF v1 cannot read an encrypted state at all — not the
outputs, not the resource count, nothing — so this condition never clears
on its own and the object gets no drift checks, health checks or further
applies. Because an encrypted state fails the reader before it is ever
parsed, the manager never took a backup of it either: there is no
CAPTF-side backup to restore.

Fix: disable client-side state encryption for this object's module (drop
the encryption configuration so future writes are plain state), and use a
workstation that holds the decryption key to decrypt the current state
and push the plaintext back with `terraform state push` (or `tofu state
push`) against the same `kubernetes` backend configuration — the backend
config, not the state format, is what CAPTF's reader needs to match; see
[manual recovery](state-restore.md#manual-recovery-with-no-backup) for the
exact `secret_suffix`, `namespace` and `labels` the object's backend uses.
Once the pushed state is unencrypted, the next reconcile reads it normally.

## StateCorrupt

`False`. The reader could not treat the Secret's payload as
gzip-compressed Terraform state JSON: the gzip or JSON decoding failed, the
decompressed size exceeded the reader's cap, or (for a multi-Secret
chunked state) there were more chunks than the reader accepts. An
unsupported state file version is reported the same way. The condition's
message names which of these it was. See
[Chunking and size caps](../../concepts/state.md#chunking-and-size-caps)
for the reader's exact limits.

A corrupt state is never backed up by the manager (backups copy only a
state the reader could parse), so a backup taken before the corruption is
your most recent recoverable copy. Fix: restore the newest backup from
before the corruption with the [state restore runbook](state-restore.md).
If nothing wrote a backup before the state became corrupt, there is no
CAPTF-side recovery: rebuild the state out of band with [manual
recovery](state-restore.md#manual-recovery-with-no-backup), using the
resource list from the last known-good backup or the cloud provider's own
inventory as your guide.

## StateInconsistent

`False`. The set of state Secrets for the object's suffix does not add up
to one complete, contiguous state: a chunk is missing or duplicated, a
Secret in the set has an unexpected name, or the base Secret has no
`tfstate` data key. The condition's message names which of these it was.

This can be transient: a runner Job writes a multi-chunk state one Secret
at a time, so a reconcile that reads mid-write sees an incomplete set and
the next reconcile, after the Job finishes, usually reads a complete one.
If it persists past the Job finishing, something outside CAPTF edited or
deleted one of the chunk Secrets by hand. As with `StateCorrupt`, an
inconsistent state is never backed up, so restore the newest backup from
before the inconsistency appeared with the
[state restore runbook](state-restore.md); the reader's own limits are at
[Chunking and size caps](../../concepts/state.md#chunking-and-size-caps).

## Confirm it worked

```sh
kubectl get <kind> -n <ns> <name> \
  -o jsonpath='{range .status.conditions[?(@.type=="StateReadable")]}{.status}/{.reason}{"\n"}{end}'
```

Expect `True/StateRead`. `status.observedStateSerial` moves to the
restored or rebuilt state's serial, and the object's next drift check or
apply proceeds from it.

## See also

- [State restore](state-restore.md)
- [Stale state lock](stale-lock.md)
- [Terraform State](../../concepts/state.md)
- [Conditions reference](../../reference/conditions.md#statereadable)
- [Observability](../observability.md#captfstateunreadable)
