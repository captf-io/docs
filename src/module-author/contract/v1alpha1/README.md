# v1alpha1

cluster-api-provider-terraform is a Cluster API infrastructure provider
that runs Terraform/OpenTofu **child modules written to its contract**,
packaged as OCI images together with the runtime. Existing root modules do
not drop in: the provider owns the root module, the state backend and the
provider installation.

> **Read this first.** A module written to this contract is a *child
> module*. It must not declare a `backend`: the controller generates the
> root module, configures the state backend and supplies the provider
> installation (the image's mirror or the registry), passes exactly the
> contract inputs and reads the contract outputs back from state.

**Status:** Provisional: frozen for implementation, and may still change
until the first real module has provisioned a cluster (see
[`CHANGELOG.md`](CHANGELOG.md)). This contract's text was checked against
the OpenTofu v1.11.5 docs; that is a documentation-verification snapshot,
not a runtime requirement — the reference images
([`image-contract.md`](../../image-contract.md)) ship a newer OpenTofu.

A *module* is a Terraform/OpenTofu module that implements one **role**
(`cluster`, `machine`, `machinepool`). It is delivered as an **OCI image
that bundles the module code and the runtime binary**
([`image-contract.md`](../../image-contract.md)): the image is the artifact,
the version and the runnable object; there is no separate module source
and no separate runtime image. The controller never calls a module
directly: it generates a root module inside the Job that (a) configures
the `kubernetes` backend, (b) calls the module at `/captf/module` with
exactly the contract inputs, and (c) re-exports the contract outputs at
the root so they land in state. Everything the controller learns about
infrastructure comes from those root outputs.

Files:

| File | Contents |
| --- | --- |
| [Image Contract](../../image-contract.md) | Fixed paths, optional provider mirror, labels, execution environment, pinning, reference Containerfiles |
| [Common](common.md) | Inputs injected into every role; the `health` output every role must produce |
| [Cluster Role](cluster.md) | Cluster role (InfraCluster) |
| [Machine Role](machine.md) | Machine role (InfraMachine) |
| [MachinePool Role](machinepool.md) | MachinePool role (InfraMachinePool) |
| `schemas/` | JSON Schemas (draft 2020-12) for the cluster, machine and machinepool inputs and outputs, shared definitions, and valid/invalid examples; checked by `hack/verify-schemas.sh` |
| [Job Inputs](../../../concepts/inputs.md) | Where every `terraform.tfvars.json` value comes from in the running controller: field-by-field sources, the durable and per-run Secrets, the inputs hash, and how to inspect a live object's inputs safely |

## Versioning

- The contract version is a string: `v1alpha1`. It is independent of the
  CRD API version and of the provider release.
- **The image tag is the module version.** `spec.source.image`
  (`registry/repo:tag` or `@sha256:…`) is the only version a CR carries; a
  new module version is a new image, referenced by a new
  Terraform*Template. The controller pins the digest after the first run
  (see [`image-contract.md`](../../image-contract.md#versioning-and-pinning)
  "Versioning and pinning").
- A module does not declare its contract version or role in a way the
  controller acts on; there is no manifest file. The role is implied by
  which CRD references the image, and the contract version is the one the
  controller release generates against (injected as `captf_contract`,
  recorded in object status). The OCI labels `io.captf.contract` and
  `io.captf.role` are informational (see
  [`image-contract.md`](../../image-contract.md#oci-labels)). `tfcapi-lint`
  takes `--role` and `--contract` on the command line and checks the
  labels against them.
- **Compat policy:**
  - Within one version: only **additive, optional** changes (new optional
    inputs with defaults; new optional outputs). Never rename or retype.
  - Making an input required, removing an output, or changing a type
    means a new contract version.
  - The controller supports N and N-1 contract versions concurrently; the
    generated root differs per version.
  - `v1alpha*` versions carry no compat guarantee between alphas; this
    policy starts at `v1beta1`.

## Naming rules

- **Reserved prefix `captf_`.** Every controller-injected input and every
  contract-defined local starts with `captf_`. A module MUST NOT declare a
  variable or output with this prefix except those defined by the
  contract.
- **Contract outputs** are *not* prefixed (`provider_id`, `addresses`, and
  so on) because they are part of the module's public interface. Their
  names are reserved per role; a module MUST declare every required
  output of its role.
- **Module inputs are the contract inputs plus user variables.** Anything
  module-specific (instance type, machine image, region) is either fixed
  inside the module or a user variable: an ordinary module variable the
  object sets through `spec.variables`/`spec.variablesFrom` (see
  [`common.md`](common.md#user-variables) "User variables"). A module
  SHOULD give every non-contract variable a default, so it plans when no
  user variable is set.
- Extra, non-contract outputs are allowed on any role but are never read
  by the controller. The only cluster-to-machine/pool handoff is the
  cluster role's `exports` output (see [`cluster.md`](cluster.md#outputs)
  and `captf_cluster_outputs` in [`common.md`](common.md#inputs)).
- **Tagging is mandatory.** Every role receives `captf_tags` (see
  [`common.md`](common.md#captf_tags)) and MUST apply it to the cloud
  resources it creates; the CAPI provider best practices require a
  mechanism for identifying a provider's cloud objects.

## Trust boundary

`spec.source.image` is executed, unpoliced, as a Job under the runner
ServiceAccount, which can read every Secret in the object's namespace and
runs with the identity's cloud credentials mounted: referencing an image is
equivalent to granting its publisher that access. See [Security
Model](../../../concepts/security-model.md) for the full threat model; this
contract only requires that module authors and operators treat an image
reference accordingly.

## Null semantics

- Required outputs must be **declared**; their value may be `null` until
  known. `null` means "not yet known", never "empty".
- The controller treats `null` for a required output as "keep waiting"
  (the object stays unprovisioned, condition
  `OutputsValid=Unknown/OutputsPending`), unless the role spec says
  otherwise (for example `control_plane_endpoint` on cluster may stay null
  forever when CAPI supplies the endpoint).
- An **absent** output (not declared in the module) is a hard error:
  `OutputsValid=False/OutputsMissing`, with no retry until the module
  changes.
- Empty collections are meaningful and distinct from null (`addresses = []`
  means provisioned with no addresses).

## Type conventions

- Types are Terraform type constraints. Object attributes listed as
  optional use `optional(type)` / `optional(type, default)` (Terraform
  ≥1.3 / OpenTofu; both in scope; see the [Terraform v1.3.0
  changelog](https://github.com/hashicorp/terraform/blob/v1.3.0/CHANGELOG.md)
  and
  [OpenTofu docs: type constraints](https://opentofu.org/docs/language/expressions/type-constraints/)).
  - `output` blocks take no type constraint: their arguments are `value`,
    `description`, `sensitive`, `ephemeral`, `depends_on`, `deprecated`,
    plus `precondition` blocks (see
    [OpenTofu docs: outputs](https://opentofu.org/docs/language/values/outputs/)).
    Output "types" in this contract are the shape the controller decodes,
    and any `optional(..., default)` on an output is applied by the
    controller, not by Terraform.
- All outputs are read from state JSON; the controller decodes by the
  contract's expected shape, not by the `type` recorded in state. Extra
  attributes on objects are ignored; missing required attributes are an
  error.
- Strings that map to Kubernetes fields must satisfy the target field's
  validation: `provider_id` 1–512 chars (see
  [`infra-machine.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machine.md)
  "InfraMachine: provider ID"); failure-domain names 1–256 chars, no
  pattern (see
  [`cluster_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/cluster_types.go)
  `FailureDomain.Name`); address types from the CAPI `MachineAddressType`
  enum (see
  [`common_types.go`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/api/core/v1beta2/common_types.go)).
  The controller rejects invalid values with `OutputsInvalid` rather than
  writing them.
- `sensitive = true` on a module output marks the value sensitive, and
  sensitivity propagates to anything derived from a sensitive value (for
  example `bootstrap_data`). A root `output "x" { value = module.role.x }`
  referencing a sensitive value fails `plan` with "Output refers to
  sensitive values" unless the root output itself sets
  `sensitive = true` (reproduced with OpenTofu v1.11.5; see
  [OpenTofu docs: outputs](https://opentofu.org/docs/language/values/outputs/)
  "sensitive"). Sensitive values are still stored in state in cleartext
  (same page). The generated root marks every re-exported output
  `"sensitive": true`, so a module may mark any contract output sensitive
  without failing `plan`. This has no effect on the controller: the state
  Secret still stores the value in cleartext, and `sensitive` only
  changes CLI display.

## Injection mechanics (for spec readers)

- The generated root lives at `/captf/work/root` inside the Job and calls
  the module as `module "role" { source = "../../module" }`, that is,
  `/captf/module` inside the image. Terraform/OpenTofu local paths must
  begin with `./` or `../`, so the absolute form `/captf/module` is not
  used. It is a local path, so `init` fetches no module from anywhere (see
  [`image-contract.md`](../../image-contract.md#fixed-paths) "Fixed paths").
  Providers come from `/captf/providers` when the image ships a mirror,
  else from the registry.
- Contract inputs are supplied via `terraform.tfvars.json` in the
  generated root (auto-loaded; see
  [OpenTofu docs: variables](https://opentofu.org/docs/language/values/variables/))
  and forwarded to the module call by name. Bootstrap data is marked
  `sensitive = true` on the root variable.
- Every contract input is a root variable named identically to the module
  input; the root forwards `x = var.x`. Nothing else is passed to the
  module call.
- Contract outputs are re-exported at root as
  `output "x" { value = module.role.x, sensitive = true }`: every
  re-export is marked sensitive, so a module marking any contract output
  sensitive never fails `plan` (see Type conventions above).
- The rendered `terraform.tfvars.json` of the newest apply is kept in a
  Secret, written when that apply Job starts (a failed apply may already
  have created resources from those inputs, so destroy must use them),
  owned by the Terraform* object (`captf-inputs-<kindshort>-<name>`),
  together with the resolved image digest (`captf.io/image-digest`) and
  the identity. **Drift and destroy render from that Secret**, never from
  the live CAPI objects: destroy must work after the bootstrap Secret, the
  owning Machine/MachinePool, or the Cluster are gone, and drift on an
  immutable machine must see exactly the inputs it was applied with. The
  per-run Secret handed to a Job is deleted when the Job completes. The
  state Secret stores every value (including `bootstrap_data`, sensitivity
  notwithstanding) in cleartext for as long as the object exists; modules
  that can avoid keeping bootstrap data in state (for example by hashing
  it into a trigger) SHOULD.
- State lives in the `kubernetes` backend, in the `default` workspace (the
  only one CAPTF ever uses), locked with a Lease (see
  [OpenTofu docs: kubernetes backend](https://opentofu.org/docs/language/settings/backends/kubernetes/)
  and [Terraform State](../../../concepts/state.md) for Secret naming,
  locks and backups).
- **What triggers a re-apply** (mutable roles): a change in the hash of a
  canonical struct of the *spec-derived* inputs. Rendered inputs are
  hashed inputs: object metadata (`uid`, labels, annotations, generation)
  and fields the controller itself writes back (`spec.providerID`,
  `spec.providerIDList`, `spec.controlPlaneEndpoint`) are neither rendered
  nor hashed, so a `clusterctl move`, a label edit or the controller's own
  status-driven writes never re-apply anything, and a drift `Remediate`
  (which renders the current hashed set) cannot apply them either (see
  [`common.md`](common.md#what-is-hashed) "What is hashed").

## Roles and CAPI mapping (summary)

| Role | CAPI kind | Immutable spec | Drift | Refresh | Destroy on delete |
| --- | --- | --- | --- | --- | --- |
| cluster | TerraformCluster | no (re-apply on change) | Report (default) / Remediate | with drift; while `pending` 30s, backing off to 5m | yes, after all machines/pools of the Cluster are gone (`DeletionBlocked/DependentsExist` otherwise) |
| machine | TerraformMachine | yes (provider choice; the InfraMachine contract only recommends classifying fields as immutable/mutable, [`infra-machine.md`](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.2/docs/book/src/developer/providers/contracts/infra-machine.md) "support for in-place changes") | Report only; unhealthy → `InfrastructureHealthy=False` → `Ready=False` → MHC | with drift; while `pending` 30s, backing off to 5m | yes; direct deletes refused while the owner Machine is not deleting |
| machinepool | TerraformMachinePool | no (re-apply on change) | Report (default) / Remediate; `apply -refresh-only` then plan, same as every kind — relies on the module's `ignore_changes` when `autoscaling.enabled`, see [`machinepool.md`](machinepool.md#lifecycle) | with drift; membership refresh every `spec.membershipRefreshIntervalSeconds` (default 60), and every 30s while `pending` or not yet converged | yes; destroy from the durable inputs Secret, not the bootstrap Secret |

Delivery pipeline for a module author: `tfcapi-lint module <dir> --role
<role>`, then build the image (see
[`image-contract.md`](../../image-contract.md) for the reference
Containerfiles), then push, then `tfcapi-lint image <ref> --role <role>`,
then reference the tag from a Terraform*Template. Lint runs on the source
directory *before* the build; the image check confirms the layout after
it.

Conditions: `health` feeds `InfrastructureHealthy`, which is an explicit
input to the `Ready` summary. `Deleting` is also in `Ready`'s
`ForConditionTypes` for every kind, declared in
`NegativePolarityConditionTypes{Deleting}`, so `Ready=False` while a
destroy runs (the CAPI v1beta2 convention). Drift results
(`DriftDetected`), drift-Job outcomes, `Paused` and `DeletionBlocked` are
not, so `Ready` — mirrored by CAPI into the Cluster's/Machine's
`InfrastructureReady` — reflects infrastructure only. `Ready` is `Unknown`
while an object waits on dependencies, `False/Provisioning` from apply
start, and `True` when provisioned (see
[`machine.md`](machine.md#ready-timeline) "Ready timeline").

A destroy that fails permanently is resolved by cleaning up out of band
and removing the finalizer by hand, after backing up or un-owning the
`tfstate-*` Secrets (they are garbage-collected with the object). There is
no skip-destroy annotation.
