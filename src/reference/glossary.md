# Glossary

Short definitions of CAPTF terms used across this book, and the Cluster
API and Terraform or OpenTofu terms CAPTF's own docs assume. Each entry
links to the page that covers the term in full; this page never repeats
what that page already says.

- **apply** — The Job operation that renders an object's current inputs,
  records them as its durable inputs, then plans and applies them. The
  destructive-plan guard stops it after the plan step; see
  [choosing the next operation](../concepts/lifecycle.md#choosing-the-next-operation).
- **applyPolicy** — A `TerraformCluster` field, `Automatic` (the default)
  or `Manual`, that decides whether every apply first waits for a
  reviewed plan. See [Plan Approval](../user-guide/plan-approval.md).
- **bookkeeping** — The reconcile step that reads an object's finished
  Jobs, records each one's result in `status.lastRun`, pins a succeeded
  apply's image digest, and releases the Job's leases. See
  [the reconcile lifecycle](../concepts/lifecycle.md#bookkeeping).
- **ClusterClass** — Cluster API's reusable cluster template mechanism.
  CAPTF ships a `noop` `ClusterClass`, which expands a
  `TerraformClusterTemplate` and two `TerraformMachineTemplate`s. See
  [Templates and ClusterClass](../user-guide/clusterclass.md).
- **cluster operation gate** — The manager's `--cluster-operation-gate`
  flag (`true` by default), which keeps a `TerraformCluster`'s own apply
  or destroy from running at the same time as its machines' and machine
  pools', through a per-cluster write lease. See
  [run leases and the cluster operation gate](../concepts/lifecycle.md#run-leases-and-the-cluster-operation-gate).
- **contract** — The normative interface between the controller and a
  module: which inputs each role receives and which outputs it must
  produce. See [Module contract](../module-author/contract/README.md).
- **destroy** — The Job operation that runs the module's `destroy` step
  against an object's durable inputs, run only on deletion. See
  [deletion order](../concepts/lifecycle.md#deletion-order).
- **destructive plan** — A plan that deletes or replaces at least one
  resource. A `TerraformCluster` stops before applying one until the
  exact inputs hash it belongs to is approved. See
  [Plan Approval](../user-guide/plan-approval.md#the-destructive-plan-guard).
- **drift** — A difference between a provisioned object's Terraform or
  OpenTofu state and reality, found by a drift Job's plan. See
  [Drift and Health](../concepts/drift-and-health.md).
- **durable inputs (Secret)** — `captf-inputs-<kindshort>-<name>`, the
  record of what the controller rendered when it last started an apply
  Job for an object. An immutable machine's destroy, drift and refresh
  always use it; a mutable cluster or pool's destroy prefers it and falls
  back to current inputs, while its drift and refresh prefer current
  inputs and fall back to it. See [Job Inputs](../concepts/inputs.md).
- **identity** — A `TerraformClusterIdentity`: names the Secret of cloud
  credentials a `TerraformCluster`, `TerraformMachine` or
  `TerraformMachinePool` uses, and the namespaces allowed to use it. See
  [Identities and Credentials](../user-guide/identities.md).
- **InfraCluster / InfraMachine / InfraMachinePool** — Cluster API's
  generic roles for an infrastructure provider's objects. CAPTF's are
  `TerraformCluster`, `TerraformMachine` and `TerraformMachinePool`. See
  [The Kinds](../concepts/kinds.md).
- **inputs hash** — `captf.io/inputs-hash`: covers the contract version,
  the role, `spec.source.image` as written, the rendered inputs, and any
  user variables. A change to it re-applies a mutable object. See
  [Job Inputs](../concepts/inputs.md).
- **kindshort** — The short kind code in a Secret, Lease or Job name:
  `c` for `TerraformCluster`, `m` for `TerraformMachine`, `mp` for
  `TerraformMachinePool`. See
  [Secret names and the suffix](../concepts/state.md#secret-names-and-the-suffix).
- **mirror Secret** — `captf-creds-<identity>`, the copy of an identity's
  credentials Secret the controller mirrors into each allowed namespace
  where an object uses the identity, and keeps in sync, so a Job never
  reads the source Secret directly. See
  [Identities and Credentials](../user-guide/identities.md#how-credentials-reach-a-job).
- **module** — The Terraform or OpenTofu code that implements one
  contract role, shipped in an OCI image together with the runtime that
  runs it. See [Image Contract](../module-author/image-contract.md).
- **per-run Secret** — `captf-run-<job>`, a private copy of a Job's
  inputs, owned by the Job, mounted at `/captf/config`, and deleted when
  the Job finishes. See [Job Inputs](../concepts/inputs.md).
- **plan hash** — Under `applyPolicy: Manual`, the hash over a plan's
  sorted, non-no-op changes that a `captf.io/approve-plan` annotation
  names to approve it. See [Plan Approval](../user-guide/plan-approval.md).
- **provider mirror** — The optional `/captf/providers` filesystem
  mirror an image can ship, so `init` needs no registry egress at run
  time. See [Runtime Environment](../module-author/runtime-environment.md).
- **refresh** — The Job operation that runs `apply -refresh-only`: it
  updates state from reality and produces a health reading, without
  planning or finding drift. See
  [Drift and Health](../concepts/drift-and-health.md).
- **restore** — The Job operation, requested by the
  `captf.io/restore-state` annotation, that pushes a listed state backup
  back into the backend with `state push -force`. See
  [Restore](../concepts/state.md#restore).
- **role** — Which of `cluster`, `machine` or `machinepool` a module
  implements, and which of `TerraformCluster`, `TerraformMachine` or
  `TerraformMachinePool` runs it. See
  [Module contract](../module-author/contract/README.md).
- **run lease** — A `coordination.k8s.io/v1` Lease the controller takes
  on an object before starting a Job, so two reconciles never start two
  Jobs for the same object at once. See
  [run leases and the cluster operation gate](../concepts/lifecycle.md#run-leases-and-the-cluster-operation-gate).
- **runner** — The binary that is a Job's entrypoint: it drives init and
  the requested operation (plan, apply, destroy, refresh, drift or
  restore), enforces the destructive-plan guard and, under `Manual`, a
  plan's approval, and emits step events on the object. See
  [Runner CLI](runner-cli.md).
- **source image** — `spec.source.image`, the OCI image naming a
  `Terraform*` object's module and runtime. It is CAPTF's trust
  boundary: whoever may set it controls what the Job's Pod does. See
  [Security Model](../concepts/security-model.md).
- **state backup** — `captf-state-backup-<suffix>-<serial>`, a versioned
  copy of an object's state Secrets, taken whenever the controller
  observes a state serial it has not backed up before. See
  [Terraform State](../concepts/state.md).
- **workload kinds** — `TerraformCluster`, `TerraformMachine` and
  `TerraformMachinePool`: the three kinds that each run one Job-backed
  Terraform or OpenTofu module role and share a common spec and status
  shape. See [The Kinds](../concepts/kinds.md).

## See also

- [API Reference](api.md) for every field these terms name.
- [Conditions](conditions.md) for the reasons the kinds above report.
- [Module contract](../module-author/contract/README.md) for the
  normative meaning of a role and its inputs and outputs.
