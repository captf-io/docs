# Identities and Credentials

A `TerraformClusterIdentity` is a cluster-scoped object that names a Secret
of cloud credentials and the namespaces allowed to use it. Every
`TerraformCluster`, `TerraformMachine` and `TerraformMachinePool` needs one,
directly or by inheriting its cluster's, before it can run a Job. This page
covers creating an identity, choosing which namespaces it allows,
referencing it from each kind, rotating and revoking its credentials, and
deleting it. For the trust an identity's credentials carry once mounted
into a Job, see [Security model](../concepts/security-model.md).

## Before you begin

- Cluster-scoped access to create `TerraformClusterIdentity` objects, and
  namespace access to create the Secret it names.
- `get` access to that Secret: creating an identity, or pointing an
  existing one at a different Secret, checks it.
- A `TerraformCluster`, `TerraformMachine` or `TerraformMachinePool` to
  reference the identity from, or a namespace to create one in.

## How credentials reach a Job

An identity's credentials never reach a Job directly. Into each allowed
namespace where an object uses the identity, the controller mirrors the
source Secret as `captf-creds-<identity>` and keeps it in sync. Each Job
that resolves to this identity gets that mirror both ways:

- `envFrom`, so every key becomes an environment variable — the
  convention most provider SDKs (`AWS_*`, `ARM_*`, `GOOGLE_*`, …) read.
  A key starting with `TF_` or `KUBE_` never reaches the module's
  environment, except `TF_IN_AUTOMATION`, `TF_INPUT` and `KUBE_NAMESPACE`,
  which the Job sets itself and which a Secret key cannot override; see
  [Runtime environment](../module-author/runtime-environment.md) for why.
- A read-only file mount at `/var/run/captf/credentials/<key>`, one file
  per key, for file-based authentication
  (`GOOGLE_APPLICATION_CREDENTIALS`, a kubeconfig, a PEM key). The `TF_`
  and `KUBE_` filtering above applies only to the environment: a
  matching key still appears as a file.

The runner ServiceAccount that a Job runs as can itself read every Secret
in its namespace; the identity mechanism controls which credentials a Job
carries, not what its ServiceAccount could otherwise reach — see
[RBAC](../operator-guide/rbac.md). The mirror Secret itself, its
lifecycle and its sensitivity are cataloged in
[Secrets](../operator-guide/secrets.md); its labels and annotations are
listed in [Annotations and labels](../reference/annotations-labels.md),
and the `MirrorCreated`/`MirrorRemoved` events in
[Events](../reference/events.md).

## Create the credentials Secret

Create a plain `Opaque` Secret with one key per credential your module's
providers read:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <identity-name>
  namespace: <credentials-namespace>
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: <value>
  AWS_SECRET_ACCESS_KEY: <value>
```

- `<identity-name>` — reused below as the identity's own name; the two do
  not have to match, but it keeps the pair easy to find.
- `<credentials-namespace>` — any namespace the identity's creator can
  read Secrets in. It is commonly a provider or platform namespace,
  separate from the tenant namespaces that use the identity.

The keys are exactly what reaches every Job that resolves to this
identity: name them for what your module's providers expect, not for
CAPTF.

## Create the identity

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: TerraformClusterIdentity
metadata:
  name: <identity-name>
spec:
  secretRef:
    name: <identity-name>
    namespace: <credentials-namespace>
  allowedNamespaces:
    list:
      - <tenant-namespace>
```

`allowedNamespaces` decides which namespaces may use the identity:

| Value | Meaning |
| --- | --- |
| unset | No namespace may use it |
| `list` | Exactly the named namespaces |
| `selector` | Namespaces whose labels match |
| `selector: {}` (empty selector) | Every namespace, including one that does not exist yet |
| `list` and `selector` both set | The union of the two |
| `{}` (empty object) | Rejected: write `selector: {}` for every namespace instead |

An empty selector reads as "every namespace" rather than "no namespace",
so `allowedNamespaces: {}` is rejected outright rather than treated as one
or the other. `list` accepts up to 100 namespace names; `selector` follows
the usual label selector rules. Full field details, including size limits,
are in the
[API reference](../reference/api.md#terraformclusteridentityspec).

Creating the identity, and any later change to `spec.secretRef`, runs a
`SubjectAccessReview` for the requesting user to `get` the named Secret,
and the request is rejected if they may not. This stops a role that may
manage identities but not read Secrets from pointing one at a Secret it
cannot read and having the controller mirror it somewhere that role can.
Other updates, including `allowedNamespaces`, are not re-checked.

## Reference it

An identity is used through `identityRef`, which names it by `name`:

- **`TerraformCluster`**: `spec.identityRef` is required and mutable —
  changing it re-resolves the cluster's credentials on its next reconcile.
- **`TerraformCluster` defaults for machines and pools**:
  `spec.defaults.identityRef`, mutable, is the identity a machine or pool
  without its own `identityRef` uses; unset, they fall back further to
  the cluster's own `spec.identityRef`. See
  [Kinds](../concepts/kinds.md) for how `spec.defaults` inheritance works,
  and [Templates and ClusterClass](clusterclass.md) for a
  `TerraformClusterTemplate` that leaves `identityRef` for a ClusterClass
  patch.
- **`TerraformMachine`**: `spec.identityRef` is optional, and immutable
  once the object is created — including from unset to a value. Change it
  by replacing the machine (a `MachineDeployment` or control-plane
  rollout), not by editing it in place. A machine created with no
  `identityRef` keeps falling back to its cluster's current default or
  `spec.identityRef`, so changing those still changes which credentials
  such a machine uses.
- **`TerraformMachinePool`**: `spec.identityRef` is optional and mutable,
  with the same fallback as a machine.

`identityRef.name` must resolve to an identity that exists and allows the
object's namespace; the [Conditions](../reference/conditions.md#identityallowed)
reference has every reason `IdentityAllowed` and `CredentialsMirrored` can
carry.

## Confirm it worked

```sh
kubectl get terraformclusteridentity <identity-name>
kubectl describe terraformcluster <cluster-name> -n <tenant-namespace>
```

The identity's own `Ready` condition is `True`/`SecretFound` once its
Secret exists, `False`/`SecretNotFound` otherwise, and `status.namespaces`
lists every namespace currently holding a mirror of it. On the object
that references it, `IdentityAllowed` and `CredentialsMirrored` turn
`True` once the namespace is allowed and the mirror is in place; until
then no Job for that object starts.

## Rotate credentials

- **Edit the credentials Secret's data in place**, keeping its name and
  namespace. The controller cannot watch that Secret, so this is not
  picked up at once: the mirror in each allowed namespace is rewritten
  the next time an object that uses the identity reconciles for any
  reason, and at the latest within one
  [`--sync-period`](../reference/manager-flags.md) (10 minutes by
  default). A Job created after that reconcile gets the new values
  through its `envFrom`. A Job already running gets them too, but only in
  its file mount: the kubelet resyncs that volume from the mirror on its
  own schedule, even for a pod that started before the rotation; whether
  a long-running provider process re-reads a changed file is up to the
  provider. Only the environment is fixed for the life of the pod.

  A Job already running when you rotate keeps the old credentials in its
  environment for its whole run: the old credential must stay valid until
  every mirror has picked up the rotation and the longest
  `activeDeadlineSeconds` any in-flight Job could still run for has
  passed (default 3600 seconds; see [Deadlines and lock
  waits](job-tuning.md#deadlines-and-lock-waits)), not just until you
  edited the Secret.

  Every mirror carries a `captf.io/source-hash` annotation of the source
  Secret's data at the time it was last written; it changes whenever the
  mirror is rewritten, so watching it move off the value it held before
  the edit confirms that namespace's mirror has picked up the rotation,
  without comparing credential values directly:

  ```sh
  kubectl get secret captf-creds-<identity-name> -n <tenant-namespace> \
    -o jsonpath='{.metadata.annotations.captf\.io/source-hash}'
  ```

  Repeat for every namespace `status.namespaces` lists, or diff the
  mirror's `data` against the source Secret's `data` directly if you want
  to confirm the values themselves rather than only that a rewrite
  happened. Only once every mirror has moved past its pre-rotation hash is
  the old credential safe to revoke.
- **Point the identity at a different Secret**, by editing
  `spec.secretRef`. This is a change to the identity object itself, so it
  is watched: every object that uses the identity reconciles at once and
  refreshes its mirror. It also re-runs the `SubjectAccessReview`, so the
  user making the change needs `get` access to the new Secret.

## Revoke access

Editing `spec.allowedNamespaces` to drop a namespace is a change to the
identity object, so every object of that namespace using the identity
reconciles at once: the controller starts no new Job for it, leaves any
infrastructure it already created alone, and deletes the mirror Secret in
that namespace, whatever objects still reference it. This also blocks a
destroy: deleting such an object waits, reporting that the destroy is
waiting for the identity to allow the namespace again, until access is
restored.

## Delete an identity

Deletion is refused while:

- a `TerraformCluster`, `TerraformMachine` or `TerraformMachinePool`, in
  any namespace, currently resolves to this identity through its own
  `identityRef` or a cluster's fallback — an object being deleted still
  counts, since its destroy still needs the credentials; or
- `status.namespaces` still lists a namespace holding a mirror of it.

The rejection names one object still using it, or every namespace still
holding a mirror. Switching an object's `identityRef` away from this
identity does not by itself release its mirror in that namespace: the
mirror keeps that object as an owner until the object is deleted, so
`status.namespaces` keeps listing the namespace, and the identity cannot
be deleted, until it is. If nothing resolves to the identity there
anymore, deleting the mirror Secret directly also releases the
namespace: it is only a copy, so this does not touch the source Secret,
and the identity's status catches up as soon as the deletion is seen.
Deleting an identity never deletes the Secret it names: that Secret
belongs to you, and stays behind for you to remove or reuse.

## Move considerations

`TerraformClusterIdentity` moves with `clusterctl move`, but its
credentials Secret deliberately does not: see the
[move runbook](../operator-guide/runbooks/move.md) for why, and the
procedure for copying it to the target cluster yourself.

## See also

- [Security model](../concepts/security-model.md) — the trust boundary a
  mounted identity's credentials sit inside.
- [Secrets](../operator-guide/secrets.md) — every Secret CAPTF reads or
  writes, including the credential mirror.
- [RBAC](../operator-guide/rbac.md) — the runner ServiceAccount that Jobs
  run as.
- [Kinds](../concepts/kinds.md) — how `spec.defaults` inheritance works.
- [Conditions](../reference/conditions.md) — every `IdentityAllowed` and
  `CredentialsMirrored` reason.
- [Module Variables](variables.md) — a `variablesFrom` Secret is a
  different mechanism: it supplies module-specific values (sizes, CIDRs,
  passwords), never cloud credentials, and CAPTF only ever reads it,
  in place, rather than mirroring it like an identity's Secret.
