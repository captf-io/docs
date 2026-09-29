# Secrets

This page inventories every Secret CAPTF reads or writes: what it is named,
which namespace it lives in, who creates and deletes it, what it contains,
and whether it carries sensitive data. Read it before deciding who may read
Secrets in a tenant namespace, or before writing a NetworkPolicy or
admission policy that assumes only some Secrets matter. For what the
runner's own access to these Secrets means once a Job is running, see
[Security model](../concepts/security-model.md).

## Before you begin

- `get` access to Secrets in the namespaces you administer, to inspect any
  of these.
- Knowing which kind (`TerraformCluster`, `TerraformMachine` or
  `TerraformMachinePool`), object name or identity a Secret belongs to;
  several of the name patterns below embed one of these.

## Every Secret CAPTF reads or writes

| Name pattern | Namespace | Owner | Created / deleted | Contents | Sensitive |
| --- | --- | --- | --- | --- | --- |
| Identity's source Secret (any name, `TerraformClusterIdentity.spec.secretRef`) | `secretRef.namespace`, any namespace | The operator | By the operator; CAPTF never creates, updates or deletes it, and removes any owner reference an older CAPTF version left on it | Cloud credentials (arbitrary keys and values, provider SDK conventions or file contents) | Yes |
| `captf-creds-<identity>` (mirror) | Each namespace `allowedNamespaces` permits and that has resolved the identity | The `Terraform*` object(s) using the identity there, as non-blocking owner references | Created the first time an object in the namespace resolves the identity; rewritten whenever the source Secret's data changes; deleted when the namespace stops being allowed, or when its last owning object is removed | A byte-for-byte copy of the source Secret's data | Yes |
| `captf-inputs-c-<name>`, `captf-inputs-m-<name>`, `captf-inputs-mp-<name>` (durable inputs) | The object's namespace | The `TerraformCluster`, `TerraformMachine` or `TerraformMachinePool` itself | Created before the object's first Job; rewritten on every reconcile that re-renders inputs; deleted once the object's state and infrastructure are gone | The rendered root module and tfvars, plus the pinned image, image digest and identity | Yes |
| `captf-run-<job>` (per-run) | The object's namespace | The Job | Created just before the Job's pod starts, from that reconcile's rendered inputs; deleted once the controller has read the finished Job's result | The same rendered root module and tfvars the Job runs with | Yes |
| `tfstate-default-<suffix>` and its `-part-N` chunks (state) | The object's namespace | Unowned until the first successful apply, then the object, as a non-blocking owner reference | Created by the Terraform/OpenTofu Kubernetes state backend itself, not by CAPTF; deleted by CAPTF after a successful destroy, or immediately on deleting an object that never applied | The compressed Terraform state, plus the backend's own workspace labels | Yes |
| `captf-state-backup-<suffix>-<serial>` and its `-part-N` chunks (state backups) | The object's namespace | The `Terraform*` object, as a non-blocking owner reference (never the state) | Created after a reconcile observes a state serial not backed up yet; pruned to a configured retention on the same pass; never deleted by the destroy cleanup above | A verbatim copy of the state Secrets they were taken from, at that serial | Yes |
| Bootstrap data Secret (any name, `Machine.spec.bootstrap.dataSecretName` or `MachinePool.spec.template.spec.bootstrap.dataSecretName`) | The Machine's or MachinePool's namespace | The bootstrap provider (for example a `KubeadmConfig`), not CAPTF | By the bootstrap provider; CAPTF only reads it, uncached, and never labels, updates or deletes it | The bootstrap data (`value`) and its format (`format`) | Yes |
| `spec.variablesFrom` source (any name, labeled `captf.io/variables=true`) | The object's namespace | The operator | By the operator; CAPTF only reads it, and only while the label is present — an unlabeled Secret counts as missing | Arbitrary keys treated as module variable values | Yes |
| Image pull secret (any name, named in `spec.jobs.imagePullSecrets`) | The object's namespace | The operator | By the operator; for a `TerraformCluster`, `TerraformMachine` or `TerraformMachinePool`, CAPTF only references its name on the Job's pod, never reading or writing its contents. For a `TerraformMachineTemplate`, CAPTF also reads its own pull Secrets' contents to authenticate the image inspection that resolves capacity, but never writes them | A `kubernetes.io/dockerconfigjson` registry credential | Yes |
| `captf-webhook-service-cert` (webhook serving certificate) | The provider's namespace | cert-manager, through its `Certificate` object | By cert-manager, on issuance and renewal; CAPTF never creates, reads or deletes it | A TLS key pair and CA bundle for the admission webhook | Yes |

A name pattern that would exceed the 253-character Secret name limit — the
mirror and the durable inputs Secret, both built from a user-chosen name —
is shortened to its prefix plus a hash, still deterministic and unique.

## What the manager caches

The manager's main cache holds only Secrets labeled `captf.io/managed=true`:
credential mirrors, durable and per-run inputs, state and state backups —
the five Secrets above that carry that label, whether CAPTF or the state
backend created them. A
second, separate cache backs `spec.variablesFrom` watches; it holds Secrets
(and ConfigMaps) labeled `captf.io/variables=true`, with their data stripped
out before they are stored, so no variable value ever sits in memory there.
Everything else — the identity's source Secret, bootstrap data, image pull
secrets, and a `spec.variablesFrom` Secret's actual content when it is
resolved — is read directly from the API server on demand and never
watched.

## What never enters logs or status

The durable and per-run inputs Secrets carry bootstrap data and module
variable values in clear by design, and CAPTF never logs their data. State
and its backups are read the same way: never logged. A `spec.variablesFrom`
value marked sensitive is redacted from the Job's own plan and apply output
and from the controller's trace-level logs, but that redaction does not
reach the Secrets in this table: like every other input, the value is still
written in clear into the durable and per-run inputs Secrets and into the
state.

This is a separate guarantee from what CAPTF keeps out of `status` and
events, which never carry Secret contents at all; see [what CAPTF keeps out
of status, events and
logs](../concepts/security-model.md#what-captf-keeps-out-of-status-events-and-logs).

## See also

- [Security model](../concepts/security-model.md)
- [RBAC](rbac.md)
- [Identities and Credentials](../user-guide/identities.md)
- [Job Inputs](../concepts/inputs.md)
- [Terraform State](../concepts/state.md)
- [Module Variables](../user-guide/variables.md)
