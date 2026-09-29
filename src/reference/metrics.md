# CAPTF metrics

<!-- markdownlint-disable MD013 -->
<!-- Generated from internal/metrics.Specs in cluster-api-provider-terraform; do not edit. Regenerate there with `make docs-gen DOCS_DIR=<this checkout>`. -->

Declared with k8s.io/component-base/metrics (as Kubernetes components declare their own), all at StabilityLevel ALPHA; component-base prefixes every HELP string below with `[ALPHA]` and a space on the wire. Served on the diagnostics endpoint (`--diagnostics-address`) on controller-runtime's registry, merged by internal/metrics.Bridge with controller-runtime's own defaults (`controller_runtime_*`, `workqueue_*`, `rest_client_*`) and component-base's legacyregistry (`kubernetes_feature_enabled` and any other component-base series; its `go_*` and `process_*` families are dropped, already served by controller-runtime's own registry). Labels are bounded enums (`kind`, `op`, `result`, `reason`, `step`, `action`, `error_kind`); only the 8 per-object gauges carry `namespace` and `name`, and they are removed with their object.

| Metric | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `captf_jobs_total` | counter | kind, op, result | Jobs completed, by result: succeeded, failed, deadline, interrupted (stopped from outside: a drain, eviction or deletion), blocked (a TerraformCluster apply stopped before a plan that deletes or replaces resources, awaiting approval) or plan_changed (an apply approved for one plan planned other changes and stopped, applyPolicy Manual). Op plan is a plan Job that applies nothing. |
| `captf_job_duration_seconds` | histogram | kind, op, result | Wall time of a completed Job, from start to finish, by the result of captf_jobs_total. |
| `captf_job_step_duration_seconds` | histogram | kind, op, step | Wall time of each runner step of a completed Job (init, force-unlock, validate, plan, show-json, apply, apply-refresh-only, destroy, state-push, state-list, prepare; anything else is other). |
| `captf_job_queue_seconds` | histogram | kind, op | Time from a Job's creation to its source container's start: scheduling, image pulls and the runner copy. Not observed when the pod reports no start. |
| `captf_job_errors_total` | counter | kind, op, error_kind, step | Jobs that did not succeed, by the runner's error kind (step, image-layout, interrupted, blocked, plan-changed; deadline or unknown without a result) and failing step (none when no step failed). |
| `captf_jobs_active` | gauge | kind, op | Jobs currently running, counted from the Job cache at scrape time. |
| `captf_job_attempts` | histogram | kind, op | Retry number of a Job that succeeded: 1 plus the failed Jobs of its op since that op last succeeded (interrupted Jobs do not count). |
| `captf_resources_changed_total` | counter | kind, op, action | Resources an apply or destroy Job changed, by action (add, change, destroy, import), from the runtime's final summary line. |
| `captf_drift_resources_total` | counter | kind, action | Resources a drift Job that detected drift found to add, change or destroy. |
| `captf_reconcile_op_decisions_total` | counter | kind, op, reason | What the reconcile decided to run (op none: nothing) and why. |
| `captf_state_read_errors_total` | counter | kind, reason | State reads that turned unreadable: inconsistent, encrypted or corrupt (an unsupported state version counts as corrupt), lost (a provisioned object's state is gone) or locked (held by a holder that is not this object's runner). |
| `captf_outputs_invalid_total` | counter | kind, reason | Outputs that turned invalid against the module contract. |
| `captf_drift_detected` | gauge | kind, namespace, name | 1 while DriftDetected is True, else 0. |
| `captf_ready` | gauge | kind, namespace, name | 1, 0 or -1 for a True, False or Unknown Ready condition. |
| `captf_infrastructure_healthy` | gauge | kind, namespace, name | 1, 0 or -1 for a True, False or Unknown InfrastructureHealthy condition. |
| `captf_state_resources` | gauge | kind, namespace, name | Managed resources (not data sources) in the object's state, as last read. |
| `captf_state_bytes` | gauge | kind, namespace, name | Compressed size of the object's state summed over its Secrets, as last read; the kubernetes backend holds at most 1 MiB per Secret. |
| `captf_inputs_bytes` | gauge | kind, namespace, name | Size of the object's rendered main.tf.json and terraform.tfvars.json (the durable inputs, or the last render); no Job starts above 1000000. |
| `captf_last_success_timestamp_seconds` | gauge | kind, namespace, name, op | Unix time the newest successful Job of an op finished. Drift and refresh are exported only while that op is scheduled (not deleting or paused, with a drift interval or health checks). |
| `captf_unhealthy_samples` | gauge | namespace, name | A TerraformMachine's consecutive unhealthy health samples (status.unhealthySamples). |
| `captf_lock_force_unlocks_total` | counter | kind | Stale state locks force-unlocked. |
| `captf_identity_denied_total` | counter | reason | Identity refusals: notfound or namespace. |
| `captf_image_inspect_errors_total` | counter | reason | Registry or image-label failures while resolving template capacity. |
| `captf_inputs_hash_changes_total` | counter | kind | Applies started because the inputs of a mutable kind changed. |
| `captf_remediation_requests_total` | counter | action | cluster.x-k8s.io/remediate-machine annotations set on (requested) or removed from (withdrawn) a Machine. |
| `captf_destructive_plan_approvals_consumed_total` | counter | kind | Destructive-plan approvals removed after the approved apply succeeded. |
| `captf_lease_waits_total` | counter | kind, reason | Operations that started waiting for a run lease, once per wait: run_lease (another live Job of the object holds it), cluster_operation (a machine's apply or destroy waits for its TerraformCluster's) or machine_operations (a TerraformCluster's apply or destroy waits for its machines'). |
| `captf_state_backups_total` | counter | kind, result | State backups: taken (a new state serial copied into captf-state-backup-* Secrets), pruned (a backup beyond --state-backups deleted) or skipped (a new serial not backed up: encrypted, unreadable or oversized state, or a failed copy). |
| `captf_state_restores_total` | counter | kind, result | State restores requested with captf.io/restore-state: succeeded or failed (a restore Job finished), or not_found (the annotation names no backup). |
| `captf_plan_approvals_total` | counter | kind, result | Plans approved with captf.io/approve-plan (applyPolicy Manual): approved (the apply of the approved plan succeeded and the annotation was removed) or changed (the approved apply planned other changes and stopped; the new plan waits for approval). |
| `captf_build_info` | gauge | version, commit, contract | A metric with a constant '1' value labeled by the version, commit and module contract of the manager. |
