# Runbooks

Each runbook below covers one symptom: what it looks like, why it happens,
how to check, how to fix it, and how to confirm the fix worked. Alerts and
condition reasons are cross-references, not a substitute for reading the
page: start from whichever alert fired or condition you see, but read the
whole runbook before you act.

- [Failing Jobs](job-failures.md) — a `TerraformCluster`, `TerraformMachine`
  or `TerraformMachinePool` whose Jobs keep failing.
  [`CAPTFJobFailing`](../../reference/alerts.md#captfjobfailing),
  [`CAPTFNoRecentSuccess`](../../reference/alerts.md#captfnorecentsuccess);
  `ApplyJobSucceeded=False` and `DriftJobSucceeded=False`.
- [Stuck Destroy](stuck-destroy.md) — a `destroy` Job that cannot succeed,
  and how to remove the object's finalizer safely.
  [`CAPTFDestroyStuck`](../../reference/alerts.md#captfdestroystuck);
  `ApplyJobSucceeded=False`/`DestroyFailed`.
- [Unreadable State](state-unreadable.md) — a state Secret CAPTF cannot
  parse.
  [`CAPTFStateUnreadable`](../../reference/alerts.md#captfstateunreadable);
  `StateReadable=False`/`StateCorrupt`, `StateInconsistent` or
  `StateEncrypted`.
- [State Restore](state-restore.md) — restoring a Terraform or OpenTofu
  state from a CAPTF-managed backup.
  `StateReadable=False`/`StateLost`; `RestoreJobSucceeded`.
- [Stale State Lock](stale-lock.md) — clearing a state lock left behind by
  a killed or evicted runner.
  [`CAPTFForceUnlocks`](../../reference/alerts.md#captfforceunlocks);
  `StateReadable=False`/`StateLocked`.
- [Size Limits](size-limits.md) — a state or rendered inputs approaching
  the Secret size limit.
  [`CAPTFStateNearSecretLimit`](../../reference/alerts.md#captfstatenearsecretlimit),
  [`CAPTFInputsNearLimit`](../../reference/alerts.md#captfinputsnearlimit);
  `ApplyJobSucceeded=False`/`InputsTooLarge`.
- [Slow Jobs](slow-jobs.md) — Jobs that take a long time to run, or a long
  time to start.
  [`CAPTFJobSlow`](../../reference/alerts.md#captfjobslow),
  [`CAPTFJobQueueSlow`](../../reference/alerts.md#captfjobqueueslow).
- [Reconcile Errors](reconcile-errors.md) — the controller itself failing
  to reconcile.
  [`CAPTFReconcileErrors`](../../reference/alerts.md#captfreconcileerrors).
- [Identities and Credentials](identity-and-credentials.md) — an object
  that cannot resolve or mirror its `TerraformClusterIdentity`.
  `IdentityAllowed=False`, `CredentialsMirrored=False`.
- [Webhook Unavailable](webhook-unavailable.md) — writes to a `Terraform*`
  object failing because the admission webhook cannot be reached.
- [clusterctl move](move.md) — moving a Cluster's `Terraform*` objects with
  `clusterctl move`: the procedure, what does and does not come along, and
  cleaning up what a move leaves behind.

Every runbook above applies to `TerraformCluster`, `TerraformMachine` and
`TerraformMachinePool` alike unless it says otherwise.

## See also

- [Observability](../observability.md) — the metrics and alerts these
  runbooks are reached from.
- [Conditions reference](../../reference/conditions.md) — every condition
  type and reason named above.
