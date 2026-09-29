# Stale State Lock

Both Terraform and OpenTofu lock the `kubernetes` backend for the duration
of a run and release the lock on a clean exit
([Terraform State](../../concepts/state.md#locks)). Only a `SIGKILL` or a
node loss leaves the lock held with nothing left to release it — a stale
lock. This page covers finding a held lock, telling a stale one from a live
one, and clearing it. It applies the same way to a `TerraformCluster`, a
`TerraformMachine` and a `TerraformMachinePool`: all three use the same
backend and the same lock mechanics.

## Before you begin

- `get` access to Leases and Pods, and `patch` access to the object, in its
  namespace, on the management cluster.
- Docker or Podman, and pull access to the object's pinned runtime image,
  if the automatic force-unlock in [Diagnosis](#diagnosis) does not apply
  and you need [Fix](#fix)'s manual run.
- Replace `<ns>`, `<name>` and `<kind>` below with the object's namespace,
  name and Kind (`terraformcluster`, `terraformmachine` or
  `terraformmachinepool`; the lowercase singular works with `kubectl`).
  Run every command against the management cluster.

## Symptoms

- The object reports `StateReadable=False`/`StateLocked`, naming the
  holder, its operation and when it took the lock.
- A Job runs longer than usual, then fails: it waited out
  `lockTimeoutSeconds` (`spec.jobs.lockTimeoutSeconds`, default 300 s;
  see [Tuning Jobs](../../user-guide/job-tuning.md)) for a lock that never
  cleared.
- The [`CAPTFForceUnlocks`](../../reference/alerts.md#captfforceunlocks)
  alert fired: the controller already force-unlocked a stale lock and moved
  on: not itself a problem, but worth checking why the previous Job died.

## Cause

The lock is a `coordination.k8s.io/v1` Lease named
`lock-tfstate-default-<suffix>` in the object's namespace
(`<suffix>` is `status.stateSecretSuffix`). `spec.holderIdentity` carries
the lock ID; the `app.terraform.io/lock-info` annotation carries the JSON
lock info (`ID`, `Operation`, `Who`, `Version`, `Created`). `Who` is
`<user>@<hostname>`; in a Job pod the hostname is the pod name.

Job pods get a 600-second termination grace period, and on `SIGTERM` (a
drain, an eviction, or the Job's `activeDeadlineSeconds`) the runner gives
the runtime up to 570 s to finish in-flight provider calls, write state and
release the lock before it is killed. So an ordinary deletion or drain does
not leave a stale lock; only a hard kill or a lost node does.

## Diagnosis

Before creating a Job, the controller already checks the lock and acts on
what it finds:

- No holder: proceeds; nothing to do.
- Holder present, and its pod is one of the object's own runner Job pods
  and still exists (not finished): the lock is live; the next Job waits out
  `lockTimeoutSeconds` for it.
- Holder present, and its pod is one of the object's own runner Job pods
  but no longer exists: stale. The controller passes `--force-unlock` to
  the next Job, which force-unlocks it after `init`, emits an event, and
  continues.
- Holder present, but it is not recognizable as one of the object's own
  runner pods — the `Who` field has no `@`, or its hostname is not a pod
  of this object's Jobs, for example a workstation running `terraform
  state rm`: **never force-unlocked automatically**, whatever else is
  true. The object reports `StateReadable=False`/`StateLocked` naming the
  holder, its operation and when it took the lock.

In most cases waiting for the object's next reconcile (it retries with
backoff) resolves a stale lock without any manual step. Manual inspection
and force-unlock below are for the last case, where the controller will
never act on its own.

To inspect the lock by hand:

```sh
kubectl get lease -n <ns> lock-tfstate-default-<suffix> -o yaml
```

Read `spec.holderIdentity` (the lock ID) and the `app.terraform.io/lock-info`
annotation. The part of `Who` after the last `@` is the pod name; confirm
whether it still exists and has finished:

```sh
kubectl get pod -n <ns> <pod-name-from-who>
```

- **Pod exists and has not finished:** the lock is live. Do not force
  unlock; a concurrent run against the same state would be unsafe. Let the
  holder finish, or find out why it is still running.
- **Pod is gone, or finished (`Succeeded`/`Failed`):** if it is one of this
  object's own runner pods, the controller force-unlocks it automatically
  the next time it creates a Job (trigger a reconcile, for example by
  waiting for the next requeue, or by editing an annotation). If it is not
  one of this object's own runner pods, force-unlock by hand below.
- **`Who` has no `@` (holder unknown):** the controller never
  force-unlocks this automatically. Confirm independently that no process
  still holds the lock, then force-unlock by hand.

## Fix

Run the pinned image's own `terraform`/`tofu` binary against the backend,
the same pattern as the [stuck-destroy runbook](stuck-destroy.md)'s manual
recovery:

```sh
docker run --rm --entrypoint /captf/runtime \
  -v "$PWD/root:/captf/work/root" -w /captf/work/root \
  <image>@<digest> init -input=false -no-color \
  -backend-config=secret_suffix=<suffix> -backend-config=namespace=<ns> \
  -backend-config=in_cluster_config=true -backend-config=labels=<labels>

docker run --rm --entrypoint /captf/runtime \
  -v "$PWD/root:/captf/work/root" -w /captf/work/root \
  <image>@<digest> force-unlock -force <lock-id>
```

`<image>@<digest>` comes from the object's durable inputs Secret
(`captf.io/image`/`captf.io/image-digest`; drop any `:tag` from `image`,
append `@` and the digest). `<labels>` must be the same HCL object the Job
itself would pass, or `init` reads an empty state: read it off the state
Secret's own `.metadata.labels` the same way as the [stuck-destroy
runbook](stuck-destroy.md#4-clean-up-the-cloud-resources). `force-unlock`
touches no resources, so `./root/main.tf.json` needs only a backend
declaration, not the full rendered module:

```json
{
  "terraform": {
    "backend": {
      "kubernetes": {}
    }
  }
}
```

(an empty `./root/terraform.tfvars.json`, `{}`, avoids a missing-file
warning, though force-unlock never reads it). `force-unlock` needs an
initialized backend first, unlike `apply` or `destroy`, so `init` runs
first with the same `-backend-config` flags the Job itself would pass —
see [Job Environment](../../reference/environment.md#runner-command-and-args)
for the exact set, and note that `in_cluster_config=true` needs this run
from inside the cluster. This clears the holder and the `lock-info`
annotation; it does not delete the Lease object itself — only a workspace
delete removes it, and the `default` workspace (the only one CAPTF ever
uses) cannot be deleted.

## Confirm

```sh
kubectl get lease -n <ns> lock-tfstate-default-<suffix> \
  -o jsonpath='{.spec.holderIdentity}'
```

Empty output means the lock is clear. The object's next reconcile starts a
Job normally; `StateReadable` clears to `True`/`StateRead` once the
reconcile after that Job finishes reads the state.

## See also

- [Terraform State](../../concepts/state.md) — the backend, its Secret
  naming and how the lock fits in.
- [Stuck destroy runbook](stuck-destroy.md) — the same manual-run pattern,
  for a destroy that cannot succeed.
- [Conditions reference](../../reference/conditions.md#statereadable) —
  every `StateReadable` reason.
