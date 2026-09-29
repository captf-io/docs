# Runbook: identity, credentials or RBAC not ready

Before a `TerraformCluster`, `TerraformMachine` or `TerraformMachinePool`
can run a Job, the controller must resolve its
[identity](../../user-guide/identities.md), mirror that identity's
credentials into the object's namespace, and make sure a runner
`ServiceAccount` exists and is bound to the runner `ClusterRole`. Three
conditions cover those steps: `IdentityAllowed`, `CredentialsMirrored` and
`RunnerRBACReady`. While any of them is not `True`, no Job starts. This
runbook covers every `False` and `Unknown` reason they carry, and how to
fix each.

Replace `<ns>`, `<kind>` and `<name>` below with the object's namespace,
kind (`terraformcluster`, `terraformmachine` or `terraformmachinepool`) and
name.

## Find the reason

```sh
kubectl get <kind> -n <ns> <name> -o jsonpath='{range .status.conditions[?(@.type=="IdentityAllowed" || @.type=="CredentialsMirrored" || @.type=="RunnerRBACReady")]}{.type}={.status}/{.reason}: {.message}{"\n"}{end}'
```

## IdentityAllowed

### IdentityNotFound

`False`. Either the object (and, for a machine or pool, its
`TerraformCluster`'s `spec.defaults.identityRef`) sets no `identityRef` at
all, or `identityRef.name` names a `TerraformClusterIdentity` that does
not exist. Fix: set `identityRef.name` (on the object, or on the
cluster's `spec.defaults` for a machine or pool that should inherit it) to
an existing `TerraformClusterIdentity`, or create the one it already
names. See [Reference it](../../user-guide/identities.md#reference-it).

### NamespaceNotAllowed

`False`. The named identity exists, but its `spec.allowedNamespaces`
does not include this object's namespace. Fix: add the namespace to the
identity's `allowedNamespaces` (its `list`, or a `selector` matching one
of the namespace's labels). See
[Create the identity](../../user-guide/identities.md#create-the-identity)
for the field's exact semantics, including the empty-list-versus-empty-
selector distinction.

### SecretNotFound

`False`. The identity exists and allows this namespace, but its
`spec.secretRef` Secret does not exist (or was deleted after the identity
was created and admission's `SubjectAccessReview` check passed). Fix:
create the credentials Secret at the namespace and name `spec.secretRef`
names, or point `spec.secretRef` at one that exists. See
[Create the credentials Secret](../../user-guide/identities.md#create-the-credentials-secret).

### IdentityCheckFailed

`Unknown`. A transient error while checking the identity or its Secret —
reading the `TerraformClusterIdentity`, evaluating a `selector` against
the namespace's labels, or reading the credentials Secret all failed for
a reason other than not-found (an API server error, for example). Unlike
the three `False` reasons above, this is not a configuration problem: the
reconcile itself returns an error and retries with backoff, so it usually
clears on its own. If it persists, read the manager's logs for the
underlying error.

## CredentialsMirrored

### MirrorPending

`Unknown`. Set whenever `IdentityAllowed` is `False` — no identity
resolved yet, the namespace is not (or no longer) allowed, or the
credentials Secret is missing — and before the first mirror is ever
written. Not an error condition in itself: fix the `IdentityAllowed`
reason above, and `CredentialsMirrored` follows it.

### MirrorFailed

`False`. Either the mirror Secret `captf-creds-<identity>` could not be
created or updated (an API error, named in the message), or a Secret with
that exact name already exists in the namespace but is not a mirror of
this identity: it lacks the `captf.io/mirrored` label, or its
`captf.io/identity` annotation names a different identity. The controller
never overwrites a Secret it does not recognize as its own mirror, so this
does not clear on its own.

Fix the conflict case by renaming or removing whatever created the
conflicting Secret — most often a Secret created by hand or by another
tool using the same name CAPTF would mirror to. See
[How credentials reach a Job](../../user-guide/identities.md#how-credentials-reach-a-job)
for the exact mirror name (`captf-creds-<identity>`, or a truncated hash
form for a very long identity name) and what the mirror carries. For any
other `MirrorFailed` message, it names the underlying API error; retry
after fixing that (for example, a namespace quota or a webhook rejecting
the write).

## RunnerRBACReady

### RBACFailed

`False`. Creating or updating the runner `ServiceAccount` or the
`captf-runner` `RoleBinding` failed. The message names the error. One
specific cause: a `RoleBinding` named `captf-runner` already exists in the
namespace without `captf.io/managed=true` — the controller never modifies
a `RoleBinding` it does not own, since a binding it did not create could
carry subjects or a `RoleRef` from something else. Fix that case by
renaming or removing the conflicting `RoleBinding`; CAPTF then creates its
own. For any other message, it is an API error (permissions, quota, a
webhook); the manager's own RBAC to manage these objects is set up as part
of [installation](../installation.md). See
[RBAC](../rbac.md) for what the controller creates and why.

### ServiceAccountNotOptedIn

`False`. The object's effective `spec.jobs.serviceAccountName` names a
`ServiceAccount` other than the default `captf-runner`, and that
`ServiceAccount` either does not exist or does not carry
`captf.io/runner=true`. CAPTF treats that label as the namespace's consent
to bind the `ServiceAccount` to the runner `ClusterRole`; it is never
inferred. Fix: label the `ServiceAccount` (`kubectl label serviceaccount
-n <ns> <name> captf.io/runner=true`), create it if it does not exist, or
remove the override from `spec.jobs.serviceAccountName` (and the
cluster's `spec.defaults.jobs.serviceAccountName`, if that is where it
came from) to use the default `captf-runner` instead. See
[Job tuning](../../user-guide/job-tuning.md) for
`spec.jobs.serviceAccountName` and its default inheritance.

## Confirm it worked

```sh
kubectl get <kind> -n <ns> <name> -o jsonpath='{range .status.conditions[?(@.type=="IdentityAllowed" || @.type=="CredentialsMirrored" || @.type=="RunnerRBACReady")]}{.type}={.status}/{.reason}{"\n"}{end}'
```

Expect `IdentityAllowed=True/IdentityAllowed`,
`CredentialsMirrored=True/Mirrored` and
`RunnerRBACReady=True/RBACReady`. The next reconcile after all three are
`True` starts a Job if one is otherwise due.

## See also

- [Identities and Credentials](../../user-guide/identities.md)
- [RBAC](../rbac.md)
- [Job tuning](../../user-guide/job-tuning.md)
- [Conditions reference](../../reference/conditions.md#identityallowed)
- [Events reference](../../reference/events.md)
