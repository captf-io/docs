# Changelog

Changes to the module contract, newest first. Within `v1alpha*` there is no
compatibility guarantee (see [`README.md`](README.md#versioning)
"Versioning"); every change is still recorded here.

## Unreleased

### Added

- Machinepool role, including native autoscaling (additive
  within v1alpha1; `machinepool.md`, `README.md` "Roles and CAPI
  mapping"): the v1 controller now reconciles `TerraformMachinePool`.
  New API kinds `TerraformMachinePool` and
  `TerraformMachinePoolTemplate`, and new field
  `TerraformMachinePoolSpec.membershipRefreshIntervalSeconds` (default 60,
  15–86400, rejected below 15 by the CRD schema, not the webhook). New
  `OutputsValid` reason `InstancesTruncated`, set when `status.instances`
  is capped at 1000 entries. Manager flag
  `--terraformmachinepool-concurrency` (default 10). The controller does
  not watch the bootstrap Secret (a rotated token reaches the pool at its
  next reconcile, at the latest one membership-refresh interval later) and
  does not support MachinePool Machines.
- Machinepool autoscaling (additive within v1alpha1; `machinepool.md`
  "Inputs" `autoscaling`/`replicas`, "Lifecycle" "Drift order" and
  "Write-back"): the `autoscaling` input is parsed from the MachinePool's
  `cluster-api-autoscaler-node-group-min-size`/`-max-size` annotations;
  when enabled, `replicas` renders `status.replicas` (falling back to
  `MachinePool.spec.replicas` before the first observation) clamped into
  `[min,max]`, is excluded from the inputs hash, and the controller
  writes the raw observed value back to `MachinePool.spec.replicas` and
  claims `cluster.x-k8s.io/replicas-managed-by: captf` (never a foreign
  truthy value), removing its own claim when autoscaling is disabled
  again. New condition `AutoscalingActive` (informational, pool-only,
  never in `Ready`; reasons `ReplicasManagedByModule`,
  `AutoscalingDisabled`, `AutoscalingAnnotationsInvalid`). New event
  `ReplicasWrittenBack`. New RBAC: `patch` on `cluster.x-k8s.io`
  `machinepools` (write-back needs it; `get`/`list`/`watch` already
  covered reads). Drift for a pool already ran `apply -refresh-only` then
  `plan` like every other kind; nothing changed there — it is the
  module's `lifecycle { ignore_changes }` on the desired-count attribute
  that keeps a cloud-side scale from reporting as drift, and that
  responsibility is now load-bearing rather than theoretical. **Upgrade
  behavior:** a MachinePool that already carries both autoscaler
  annotations before the upgrade starts autoscaled and re-applies once
  right after it — its `autoscaling` input flips from
  `{enabled=false,min=0,max=0}` to the parsed, enabled value, which is
  hashed, so the inputs hash changes and the pool re-applies.
- Plan preview and approval (the module contract is unchanged; see
  [Plan Approval](../../../user-guide/plan-approval.md)):
  TerraformCluster and TerraformClusterTemplate gain
  `spec.applyPolicy` (`Automatic`, the default applied at reconcile, or
  `Manual`; mutable, not hashed). Under `Manual` every apply but the first
  (no state yet), including a drift remediation and a retry, first runs a
  new operation, `plan` (added to the `Operation` enum): a Job that runs
  `init`, `validate`, `plan -out` and `show -json` under the run lease only
  and applies nothing. Its plan (counts, up to 50 `"<address> (<action>)"`
  entries, never values, and a plan hash `p1:<sha256>` of the sorted
  `address|actions` of every change) goes to the new `status.plan`
  (`inputsHash`, `job`, `planHash`, `add`, `change`, `destroy`,
  `resources`, `truncated`, `createdAt`), and the apply waits until the new
  `captf.io/approve-plan` annotation names that hash. The approved apply
  (runner flag `--expect-plan`) plans again and applies only an identical
  plan; otherwise it stops with the new `RunErrorKind` `plan-changed` and
  the new plan waits for its own approval. A plan without changes never
  waits. Approving a plan also approves its deletes; the
  destructive-plan annotation is not needed on top. The annotation is
  removed and `status.plan` cleared once the approved apply succeeds. New
  `ApplyJobSucceeded` Unknown reasons `PlanAwaitingApproval` and
  `PlanChanged`; events `PlanReady`, `PlanApproved`, `PlanApplied`,
  `PlanChanged`; metric `captf_plan_approvals_total{kind,result}`
  (`approved`, `changed`) and `captf_jobs_total` result `plan_changed`;
  Job annotations `captf.io/approved-plan`, `captf.io/plan-changed` and
  `captf.io/plan-unreadable`.
- State backups and restore (the module contract is unchanged; see
  [Terraform State](../../../concepts/state.md) and
  [State Restore](../../../operator-guide/runbooks/state-restore.md)):
  every new state serial the manager
  reads is copied verbatim into `captf-state-backup-<suffix>-<serial>`
  Secrets (plus `-part-N` per chunk), owned by the Terraform* object and
  labeled for `clusterctl move`; the newest `--state-backups` (default 5, 0
  disables) are kept. TerraformCluster and TerraformMachine gain
  `status.stateBackups` (up to 16 `{serial, takenAt, bytes}`). The
  `captf.io/restore-state: "<serial>"` annotation starts a new operation,
  `restore` (added to the `Operation` enum of `status.activeJob` and
  `status.lastRun`): a Job that runs `init`, `state push -force` of the
  backup and `state list`, under the run lease (and the cluster write lease
  for a TerraformCluster). It precedes apply, drift and refresh but not
  deletion; the annotation is removed on success, and a failure is not
  retried for the same serial. New condition `RestoreJobSucceeded` (never
  in `Ready`) with reasons `StateRestored`, `RestoreFailed`,
  `RestoreBackupNotFound` and the three lease waits; events
  `StateBackedUp`, `StateRestored`, `StateRestoreFailed`; metrics
  `captf_state_backups_total{kind,result}` and
  `captf_state_restores_total{kind,result}`; runner steps `state-push` and
  `state-list`. A TerraformCluster's restore takes part in the cluster
  operation gate like its apply.
- User variables (see [`common.md`](common.md#user-variables) "User
  variables" and [Module Variables](../../../user-guide/variables.md)):
  TerraformCluster and TerraformMachine (and both
  templates) gain `spec.variables`, an inline JSON object, and
  `spec.variablesFrom`, up to 16 ConfigMaps or Secrets labeled
  `captf.io/variables=true`, each `optional` and read in `format` `String`
  (default) or `JSON`. Sources merge in list order, a later one winning;
  inline variables win over all. Each variable becomes a named argument of
  `module "role"`, declared in the generated root without a type
  (`sensitive = true` when its value came from a Secret) and valued in
  `terraform.tfvars.json`; a name the module does not declare fails the
  apply. Reserved: `captf_` names, the role's contract inputs and the
  module meta-arguments. The inputs hash covers the variables only when an
  object sets some, so existing objects keep their `h2` hash and do not
  re-apply. On a TerraformCluster a changed variable or source re-applies;
  on a TerraformMachine both fields are immutable and read only until the
  machine is provisioned. New `DependenciesReady` False reasons
  `VariablesSourceNotFound` and `VariablesInvalid`. The manager's
  ClusterRole gains `get`, `list` and `watch` on `configmaps`, and it runs a
  second, label-scoped cache (`captf.io/variables=true`, data stripped) for
  the source watches.
- Run leases (the module contract is unchanged; see
  [The Reconcile Lifecycle](../../../concepts/lifecycle.md)): the manager
  holds a `coordination.k8s.io/v1` Lease
  `captf-run-<suffix>` per object before it creates a Job, so a stale Job
  cache, a leader-election handover or two manager instances with
  overlapping `--watch-filter` values cannot run two Jobs of one object.
  With the new `--cluster-operation-gate` (default true) a TerraformCluster's
  apply or destroy and its machines' applies and destroys never run at once
  (cluster write Lease `captf-cluster-<hash>`); refresh and drift are not
  gated. New `ApplyJobSucceeded` Unknown reasons `WaitingForRunLease`,
  `WaitingForClusterOperation` and `WaitingForMachineOperations`
  (`DriftJobSucceeded` gains `WaitingForRunLease`), the Normal events of
  the same names once per wait, and `captf_lease_waits_total{kind,reason}`.
  The manager's ClusterRole gains `create` and `update` on `leases`.
- Events for every stage (the module contract is unchanged; see
  [Observability](../../../operator-guide/observability.md) "Events"): the
  runner now reports its progress as `events.k8s.io/v1` Events on the
  object that owns the Job
  (`RunStarted`, `StepStarted`, `StepSucceeded`, `StepFailed`,
  `PlanSummary`, `ResourcesChanged`, `RunFinished`; reporting controller
  `captf.io/runner`), best effort and never failing the run. Job pods get
  two new runner flags, `--event-object` and `--job-name`; the manager's
  new `--runner-events` (default true) turns them off. The `captf-runner`
  ClusterRole gains `events.k8s.io` `events` `create`. The manager emits
  new reasons once per transition: `JobSucceeded`, `JobInterrupted`,
  `JobDeadlineExceeded`, `StuckJobDeleted`,
  `DestructivePlanApprovalConsumed`, `DeletionStarted`, `FinalizerRemoved`,
  `Paused`, `Resumed`, `ProviderIDSet`, `ControlPlaneEndpointSet`,
  `FailureDomainsChanged`, `InputsChanged`, `StateAdopted`, `StateLost`,
  `StateLocked` (both formerly `StateUnreadable`), `DriftResolved`,
  `DriftRemediationStarted`, `InstanceHealthy`, `InstanceUnhealthy`,
  `MirrorCreated`, `MirrorRemoved`, `IdentitySecretFound`,
  `IdentitySecretNotFound`, `CapacityResolved`, and `ConditionChanged` for
  any other owned condition's status or reason change. `JobFailed` now also
  covers failed drift and refresh Jobs; `JobCreated` names the attempt,
  the image and why the Job started.
- Destructive-plan guard: a TerraformCluster
  apply, including a drift remediation, runs `plan -out`, `show -json` and
  an apply of the saved plan, and stops before a plan whose actions include
  `delete` (a removal or a replacement) unless the
  `captf.io/approve-destructive-plan` annotation names the inputs hash it
  renders. New `status.lastRun.error.kind: blocked`, reason
  `ApplyJobSucceeded=False/DestructivePlanBlocked`, event
  `DestructivePlanBlocked` and `captf_jobs_total{result="blocked"}`. The
  image's runtime must support `plan -out=<file>` and `show -json
  <planfile>` (see [Image Contract](../../image-contract.md)). Machine
  applies are unchanged.
- Controller remediation additions (the module contract is unchanged):
  - New `remediation.healthCheckIntervalSeconds` (60–86400, default 300):
    with `annotateMachine`, a provisioned machine is refreshed at that
    interval to sample health, independent of drift. A health sample is
    one completed refresh or drift Job, not a new state serial.
  - New condition reasons: `StateReadable=False/StateLost` (a provisioned
    object's state is gone or lost its inputs hash; no Job runs),
    `StateReadable=False/StateLocked` (the state lock is held by something
    other than the object's runner) and `ApplyJobSucceeded=False/InputsTooLarge`.
    `DriftDetected` starts as `Unknown/DriftNotChecked`.
  - `captf_job_attempts` records the retry number of a successful Job
    (failures of that op since its last success, plus one);
    `status.activeJob.attempt` is the Job's sequence number.
- `tfcapi-lint`'s `input/extra` error is replaced by the
  `input/user-variable-default` warning (a non-contract variable without a
  default is legitimate when every object is meant to set it through
  `spec.variables`/`spec.variablesFrom`).

### Changed

- The contract pages (`README.md`, `common.md`, `cluster.md`,
  `machine.md`, `machinepool.md` and this changelog) were reorganized for
  readability: long paragraphs were split into sections, table cells were
  shortened with their detail moved into a section below each table, and
  source citations became links. The contract itself did not change:
  every MUST/SHOULD/MAY requirement, every schema and every skeleton is
  unchanged.
- Fewer Jobs per bring-up and in steady state (the module contract is
  unchanged; see [Machine Remediation](../../../user-guide/remediation.md),
  [Plan Approval](../../../user-guide/plan-approval.md) and
  [The Reconcile Lifecycle](../../../concepts/lifecycle.md)): a
  TerraformMachine no
  longer refreshes after a successful apply whose own outputs are valid
  with a `health.state` other than `pending` or `unknown`; that reading is
  the post-apply health sample (`status.lastRefresh` is the apply's finish,
  and it counts once toward `status.unhealthySamples`). While health is
  `pending` the refresh backs off 30s, 1m, 2m, 4m, then every 5m (plus the
  UID jitter) instead of a fixed 30s; TerraformCluster and TerraformMachine
  gain `status.pendingRefreshes`, the consecutive pending samples since the
  last other reading or apply (status only; it restarts after
  `clusterctl move`). A guarded or approved (`--expect-plan`) apply whose
  plan has no changes skips the apply step and succeeds right after the
  plan, with zero changes and no `ResourcesChanged` event, so its leases go
  as soon as it is bookkept. The example bring-up (one cluster, six
  machines, one no-change re-apply) drops from 14 Jobs to 8.
- Controller remediation behavior (the module contract is unchanged):
  - The `cluster.x-k8s.io/remediate-machine` annotation CAPTF set (marked
    `captf.io/remediation-requested`) is removed once the instance reads
    Healthy and the Machine is not being deleted.
  - The first drift check runs one interval after the last successful apply;
    drift and health deadlines get a per-object jitter of up to 10%.
  - A failed apply is retried even when the inputs equal the state's hash.
    An image change clears the pinned digest in the durable inputs Secret.
- `TerraformMachine.spec.drift` and `spec.defaults.drift` are a
  `MachineDriftPolicy` with `intervalSeconds` only: machine drift is always
  reported. The cluster's `spec.drift.action` defaults to `Report`, not
  `Remediate`.
- Machine jobs and drift policies are merged field by field over the
  cluster's `spec.defaults` (env by name, `imagePullSecrets` as a union),
  instead of replacing them as a whole. `spec.defaults` no longer applies
  to the TerraformCluster itself.
- `TerraformMachine.spec.jobs`, `drift` and `remediation` are mutable;
  `source` and `identityRef` stay immutable.
- `jobs.lockTimeoutSeconds` is optional as a pointer; `jobs.activeDeadlineSeconds`
  (at most 86400) and `remediation.unhealthyThreshold` default when unset
  (0), not through a pointer. A policy that sets both `lockTimeoutSeconds`
  and `activeDeadlineSeconds` must keep the lock timeout below the
  deadline. `jobs.securityContext` may not set
  `privileged`, `allowPrivilegeEscalation` or `capabilities.add`.
- `TerraformCluster.spec.identityRef` is required; machines fall back to
  `spec.defaults.identityRef`, then to `spec.identityRef`.
  `spec.controlPlaneEndpoint` is immutable once it has a host.
- `TerraformClusterIdentity.spec.allowedNamespaces: {}` is rejected; write
  `selector: {}` to allow every namespace. The identity has a status
  (`conditions`, `namespaces`), filled by the manager.
- `status.lastRun.error.tail` is now `summary` (at most 512 bytes): the
  runner's summary of the failure, not raw stderr.
- `captf_cluster_outputs` is not passed to the cluster role.
  Previously the text said it was `null`. The generated cluster root declares
  no such variable, and its tfvars carry no key. A cluster module may leave
  it undeclared or declare it with `default = null`, as the skeletons do. A
  declaration without a default fails `validate`. Updated `common.md`,
  `cluster.md`, and the `cluster-inputs.json` description; the schema still
  accepts `null`.
- Consequence of the inputs hash: the hash accepts only integer numbers. The
  cluster role's `exports` value becomes every machine's
  `captf_cluster_outputs` input, which is hashed. So a fractional or
  exponent number anywhere in `exports` (for example `{"ratio": 0.5}`) makes
  those machines' inputs unhashable, and they cannot apply. Module authors
  should export numbers as integers or strings. The controller reports it as
  `OutputsValid=False/OutputsInvalid` on `exports`. No `tfcapi-lint` check
  catches this today. The alternative, a canonical float
  encoding in the hash, was not chosen, because the design calls for
  integers only and a float that does not round-trip exactly would change
  the hash silently.
- API field names: the drift and job durations are integer seconds,
  following the Cluster API v1beta2 convention and the kube-api-linter
  `nodurations` rule. `spec.drift.interval` is now
  `spec.drift.intervalSeconds`, `spec.drift.refreshInterval` is
  `spec.drift.refreshIntervalSeconds`, and `jobs.lockTimeout` is
  `jobs.lockTimeoutSeconds`. Defaults are unchanged (1800, pool-only 60 with a
  minimum of 15, and 300 seconds). References in these documents were renamed.

### Removed

- `jobs.backoffLimit` (Jobs always get `backoffLimit: 0`) and
  `jobs.ttlSecondsAfterFinished` (Jobs never get a TTL): the controller
  owns retries, and backoff, digest pinning and conditions are derived
  from the Jobs it retains.
- `spec.drift.refreshIntervalSeconds` (it did nothing), `spec.source.imagePullSecrets`
  (use `jobs.imagePullSecrets`, which covers the source and runner images) and
  `spec.source.command` (the image contract fixes `/captf/runtime`; the
  image's `/captf/runtime` is now the only executable the runner starts).
  The durable inputs Secret no longer carries `captf.io/command`, and the
  inputs hash no longer covers a command: the scheme is now `h2`, so every
  provisioned mutable object re-applies once after the upgrade.
- The five no-op mutating webhooks; only validating webhooks remain.
  Unused condition reasons `RBACPending`, `StateReadPending` and
  `CapacityResolving`.

### Fixed

- `machinepool.md`'s "Minimal skeleton" gave `failure_domains` and
  `cluster_failure_domains` a `default = []`; both are always set
  (non-null) by the controller, so `tfcapi-lint`'s `input/default` check
  warned on either one, and `--strict` failed. The defaults are removed;
  the inputs are documented as always set (may be `[]`), matching
  `modules/noop/machinepool`. Every role's "Minimal skeleton" (`cluster.md`,
  `machine.md`, `machinepool.md`) now also references `captf_tags` (an
  empty `terraform_data` stub), since the skeletons are now actually run
  through `tfcapi-lint module --role <role> --strict`, which otherwise
  warns `input/tags-unused` on all three.
- `cluster.md`'s "Minimal skeleton" typed `cluster_network`'s attributes
  with `optional(...)`, while the Inputs table types them as required and
  the controller always renders all four (an unset CIDR list as `[]`, an
  unset scalar as `null`, never omitted). Both forms pass
  `tfcapi-lint`'s `input/type` check, but the skeleton now matches the
  table.
- The `output/provider-id-list-shape` check registers at both `error`
  (the output is missing or not a list) and `warning` (the expression is
  not sorted and deduplicated); `reference/tfcapi-lint-cli.md` listed it
  as two separate rows with the same description and no way to tell them
  apart. It is now one row whose Severity cell names both.
- `machinepool.md` said `provider_id_list`'s order was irrelevant (true
  for the controller's own write, which sorts and de-duplicates) without
  mentioning that `tfcapi-lint` separately checks the output's own
  expression for `sort()`/`distinct()`, and the skeleton's comment pointed
  at `modules/noop/machinepool/outputs.tf` instead of explaining why. Both
  are now explained inline, with the pattern shown directly.
- `machinepool.md`'s `node_labels` said only that the module "MUST render
  these into kubelet registration ... through the bootstrap/agent config
  it controls," without saying how, while `bootstrap_data` is opaque and
  may be gzipped or Ignition. The realistic options (a `multipart/mixed`
  cloud-config extra part, with a worked example; Ignition and gzipped
  payloads needing format-aware handling; or a module declaring only the
  formats it supports) are now spelled out. No new MUST or SHOULD is
  added.
- `runtime-environment.md` did not say that a provider's own debug
  logging (`TF_LOG`) cannot be turned on for a Job: it is dropped like
  every other `TF_*` name, and `spec.jobs.env` rejects it outright. The
  page now says so and points at running the pinned image locally against
  copies of the rendered inputs (the stuck-destroy runbook's recipe) with
  `TF_LOG` set, as the supported way to get provider debug output.
- `runtime-environment.md` did not say that a network provider mirror or
  a private registry cannot be configured at run time: `TF_CLI_CONFIG_FILE`
  is runner-owned and every other `TF_*` name is dropped. The page now
  states this and points at a filesystem mirror baked into the image
  (`/captf/providers`) as the supported path.
- `machinepool.md` and `common.md` described `health`, `instances` and
  their controller-side effects individually, without saying how a pool
  module should combine mixed `instances[*].state` values into one group
  `health` — the controller does not aggregate them itself. `machinepool.md`
  "Per-instance state" now states what the controller does (nothing: both
  outputs are copied independently) and what a module SHOULD do to derive
  `health` from `instances` (a new SHOULD, not a MUST).
- `image-contract.md` recommended the `org.opencontainers.image.*` labels
  but the reference Containerfiles
  (`docs/book/src/module-author/examples/Containerfile.terraform` and
  `.opentofu`) never set them. Both now take `IMAGE_SOURCE`,
  `IMAGE_REVISION` and `IMAGE_VERSION` build args (empty by default) and
  set the three labels from them.

## v1alpha1 (provisional freeze)

Frozen for implementation: Go types and the controller are built against this
version. It may still change until the first real module has provisioned a
cluster (the contract is frozen for good only once one real cloud module has
created a cluster); every such change is recorded here.

### Scope

- `README.md`, `common.md`, `cluster.md`, `machine.md`, `machinepool.md`
  and `schemas/` in this directory.
- [Image Contract](../../image-contract.md) and the reference
  Containerfiles (`docs/book/src/module-author/examples/`, `modules/noop/`).
- The control-plane guides in
  [Control-Plane Integration](../../control-planes/README.md).

### Changed at the freeze

- **Provider mirror wildcard.** The runner writes `include = ["*/*/*"]` and
  `exclude = ["*/*/*"]`, not `*/*`. Verified with the pinned runtimes
  Terraform v1.16.4 and OpenTofu v1.12.6, and separately with OpenTofu
  v1.11.5: `*/*` matches providers on the default registry host only, so a
  provider from any other host fell through to `direct`; `*/*/*` matches
  every host.
- **Remediation wording** (`machine.md` "Health → remediation"). Remediation
  happens for Machines whose owner acts on `MachineOwnerRemediated`: a MachineSet
  or a control-plane provider that implements remediation (KubeadmControlPlane,
  RKE2ControlPlane), not only a MachineSet or KubeadmControlPlane.

### Added at the freeze

- **Reserved paths.** `/captf/bin` (the injected runner) and `/captf/config` (the
  per-run Secret) are mount points; an image MUST NOT ship anything there. Added
  to the image contract's "Fixed paths" table and the `tfcapi-lint image`
  checklist.
- Machine-checkable JSON Schemas (draft 2020-12) in `schemas/`:
  `definitions.json`, `cluster-inputs.json`, `cluster-outputs.json`,
  `machine-inputs.json` and `machine-outputs.json`, with a valid and an invalid
  example for each. The schemas change nothing in the contract; they encode it.
  - Inputs are closed at every object level (module inputs are exactly the
    contract inputs); outputs are open (extra, non-contract outputs are ignored).
  - Outputs are validated after the controller's normalization: `""` for an ID
    such as `provider_id` becomes `null` first, so the schema requires 1–512
    characters for a non-null `provider_id`.
  - Limits come from the CAPI v1.14.2 API markers, including three the role
    documents do not spell out: `service_domain` 1–253 characters, at most 100
    CIDR blocks of 1–43 characters each, `api_server_port` 1–65535.
  - Not expressible in the schemas and enforced by the controller: unique
    failure-domain names, the canonical address order, and a machine's
    `failure_domain` output equal to its input when one was requested.
- The image contract's reference Containerfiles create `/captf/providers`
  before running `providers mirror`. Neither `terraform providers mirror`
  (v1.16.4, in the reference build) nor `tofu providers mirror` (checked with
  OpenTofu v1.11.5 on the build host) creates the target directory when the
  module requires no providers, so the previous
  recipe failed with `lstat /captf/providers: no such file or directory` for a
  provider-less module (found building the reference images).

### Decisions

- **Operator decisions:** native pool autoscaling, runner Secret access
  accepted and documented (see [Security
  Model](../../../concepts/security-model.md)), static credential Secrets
  only in v1.
- Every candidate CAPI mapping considered was decided; the adopted ones
  are in the role documents (e.g. address order, `interruptible`, cluster
  `kubernetes_version`, `control_plane_initialized`, endpoint provenance,
  empty `dataSecretName`, `captf.io/template`).
- The role documents' claims were checked against CAPI source and
  resolved. Resolutions for the items raised in [the RKE2ControlPlane
  guide](../../control-planes/rke2.md):
  - binary bootstrap data: resolved by always-base64 `bootstrap_data`;
  - providerID under RKE2: no contract change; the machine module makes
    the kubelet `provider-id` match (CCM or kubelet extra args), as the
    guide and checklist say;
  - a second listener on 9345: a cluster-module convention, not a
    contract field, since CAPI has nowhere to put it;
  - the `InternalIP` guarantee: no contract change; no `tfcapi-lint` check
    exists for it in `internal/lint`;
  - the version string: stays verbatim; modules strip `+rke2rN` (as
    [`machine.md`](machine.md#kubernetes_version-input) says), because
    normalizing would change the inputs hash;
  - remediation wording: fixed above;
  - CAPRKE2 on CAPI v1.14: needs a compatibility smoke test against CAPI
    v1.14.2 before RKE2ControlPlane is relied on in production;
  - a nondeterministic join target: upstream behavior, documented in the
    guide.
- The contract is authoritative on `captf_contract`: every role receives it
  (`common.md`), and the renderer renders it for every role.
- Proposals considered and **not** adopted for `common.md`, `cluster.md`,
  `machine.md` and `machinepool.md` (extra tags, `captf_identity`,
  `health.observed_at`, a `resources` inventory output, cluster `tags`/`dns_zone`,
  machine `image`/`instance_type`/`disk`/`ssh_authorized_keys`/`machine_uid`,
  `failure_domain_attributes`, `bootstrap_data_hash`, `instance_id`, pool
  `rolling_update` and `ready_replicas`): none loosens the closed input
  schemas (`schemas/`) or is needed by a shipped module; several are fixed
  in the module instead because the CRDs have no free-form per-object
  variables outside `spec.variables`/`spec.variablesFrom`.
