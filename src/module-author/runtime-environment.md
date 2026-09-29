# Runtime Environment

This page describes what a module sees once CAPTF actually runs it: the
working directory, the environment, the provider mirror, the commands the
runner runs and in what order, and how a failure is reported. It complements
[Image Contract](image-contract.md), which is the static shape of the image
itself.

For every operation, the runner replaces the image's `ENTRYPOINT`/`CMD`
with its own binary, checks the image's layout (below), prepares a working
directory, then runs `/captf/runtime` (the image's `tofu` or `terraform`)
as a child process, one command at a time, streaming its output to the
Job's log.

## Working directory and the generated root

Before running anything, the runner checks that `/captf/module` holds at
least one `.tf`, `.tf.json`, `.tofu` or `.tofu.json` file at its top level
and that `/captf/runtime` is executable; either failure stops the Job with
`error.kind: image-layout` before any command runs.

It then builds a **generated root** at `/captf/work/root` from the files
mounted read-only at `/captf/config` (the per-run Secret): `main.tf.json`,
which declares a partial `kubernetes` backend (`init`'s `-backend-config=`
flags complete it) and calls the image's module as `module "role" { source
= "../../module" }` (resolving to `/captf/module`, a local path, so `init`
never fetches the module from anywhere), and `terraform.tfvars.json`, the
rendered contract and user variables. A restore's root is the backend block
alone: it calls no module and declares no variable, since `state push` and
`state list` need neither. Every command in this page runs with
`/captf/work/root` as its working directory; the runner never uses
`-chdir`. What the module actually receives through these two files — the
contract inputs, user variables and where each value comes from — is on
[Job Inputs](../concepts/inputs.md).

The runner never invokes a shell: it execs `/captf/runtime` directly. A
module's `local-exec` provisioner needs a shell in the image, or its own
`interpreter`, to run at all: the reference images on
[Image Contract](image-contract.md#building-an-image) ship one, but a
`distroless/static` final stage does not. The image's root filesystem is
read-only by default (`readOnlyRootFilesystem: true`); the only writable
paths are `/captf/work` (this generated root, the plan files and
`TF_DATA_DIR`) and `/tmp`. A provider that writes anywhere else needs the
module or the image to relocate it, typically through an environment
variable such as a cache directory setting.

## Environment set and dropped

The runner starts from the container's own environment (the identity's
`envFrom`, the image's `ENV`, and `spec.jobs.env`) and rewrites it before
running any command: `HOME` is always forced to `/captf/work` and
`TF_DATA_DIR` to `/captf/work/.terraform` (note that the working directory
of every command is `/captf/work/root`, one level below); `TMPDIR` is kept
if already set (the Job sets it to `/tmp`) and otherwise defaults to
`/captf/work/tmp`; and every other
`TF_*` and `KUBE_*` variable is dropped — logged by name, never by value —
except the three the Job itself sets (`TF_IN_AUTOMATION`, `TF_INPUT`,
`KUBE_NAMESPACE`). This stops a leaked `TF_WORKSPACE`, `TF_CLI_ARGS_*`,
`TF_VAR_*`, `TF_LOG` or `KUBE_*` value from moving state, rewriting a step's
flags, overriding a rendered input, or logging provider traffic and
credentials. See [Job Environment](../reference/environment.md) for the
full variable list, a worked example of what is kept and dropped, and the
names `spec.jobs.env` may not set at all.

**There is no way to turn on provider debug logging in a Job.** `TF_LOG`
falls under the dropped `TF_*` names above; `spec.jobs.env` cannot set it
either, since any name starting with `TF_` or `KUBE_` is rejected outright
(with an event) rather than passed through. A module author debugging a
provider needs to reproduce the run outside a Job: pull the pinned image,
and run its `/captf/runtime` binary by hand against a copy of the
rendered root and inputs, with `TF_LOG` set in that shell. [The
stuck-destroy runbook](../operator-guide/runbooks/stuck-destroy.md#4-clean-up-the-cloud-resources)
walks through getting those inputs (the durable inputs Secret's
`main.tf.json`/`terraform.tfvars.json`, the image digest, and the
identity's credentials) and invoking the image's binary directly; the same
recipe works for a debug run, add `-e TF_LOG=DEBUG` (or `TRACE`) to the
`docker run`/`podman run` invocation.

## Provider mirror and CLI configuration

When the image ships `/captf/providers`, the runner writes
`/captf/work/cli.tfrc`:

```hcl
provider_installation {
  filesystem_mirror {
    path    = "/captf/providers"
    include = ["*/*/*"]
  }
  direct {
    exclude = ["*/*/*"]
  }
}
```

and sets `TF_CLI_CONFIG_FILE` to that path, so `init` installs every
provider from the image and never contacts a registry; `init` fails
clearly instead of silently downloading a provider missing from the
mirror. Without `/captf/providers`, the runner sets neither, and `init`
falls back to the runtime's default direct installation, which needs
registry egress. `TF_PLUGIN_CACHE_DIR` is never set: it must not coincide
with a filesystem mirror.

**A network mirror or a private registry cannot be configured at run
time.** `TF_CLI_CONFIG_FILE` is runner-owned, written fresh for every Job
as shown above (or left unset), and `spec.jobs.env` cannot override it or
any other `TF_*` name (see "Environment set and dropped"); there is no
field that lets an object or its defaults point `init` at a `network_mirror`
block or a private registry host's credentials. The supported path is a
filesystem mirror baked into the image at `/captf/providers` (see [Image
Contract](image-contract.md#provider-mirror-layout)): build it from
whatever upstream, mirror or private registry the image's build pipeline
can reach, and ship the result. There is no run-time equivalent.

## Commands, and their order

`version -json` runs first, once per Job, to record the runtime version for
the result document; its outcome is informational and never fails the Job.
`init`, `plan`, `apply` and `destroy` (including `-refresh-only`) carry
`-input=false -no-color -lock-timeout=<n>s` (`init` also carries a
`-backend-config=` flag for each value the generated root's partial
`kubernetes` backend needs); `validate` and `show` carry `-json -no-color`
instead; `state push` carries only `-force -lock-timeout=<n>s`; and
`state list` and `force-unlock` take neither.
Every command runs against the generated root in order, and a non-zero exit
(outside the codes a step accepts, such as `plan`'s 2 for "changes
present") stops the Job at that step. When the Job carries a stale lock ID
to clear, `force-unlock -force <id>` runs immediately after `init`
(force-unlock needs an initialized backend); it accepts an already-unlocked
state as success, since a retried pod or another holder may have cleared it
already.

| Operation | Commands, in order |
| --- | --- |
| Apply (machine and machine-pool roles) | `init` → `validate -json` → `apply -auto-approve -var-file=<tfvars>` |
| Apply (cluster role: always guarded, and re-planned against the approved hash under `applyPolicy: Manual`) | `init` → `validate -json` → `plan -detailed-exitcode -var-file=<tfvars> -out=<file>` → `show -json <file>` (only if plan exited 2) → `apply <file>` |
| Destroy | `init` → `destroy -auto-approve -var-file=<tfvars>` |
| Refresh | `init` → `apply -refresh-only -auto-approve -var-file=<tfvars>` |
| Drift check | `init` → `apply -refresh-only -auto-approve -var-file=<tfvars>` → `plan -detailed-exitcode -refresh=false -var-file=<tfvars> -out=<file>` → `show -json <file>` (only if plan exited 2) |
| Plan preview (cluster role, `applyPolicy: Manual`, before approval) | `init` → `validate -json` → `plan -detailed-exitcode -var-file=<tfvars> -out=<file>` → `show -json <file>` (only if plan exited 2) |
| Restore | `init` → `state push -force <backup>` → `state list` |

`<tfvars>` is `terraform.tfvars.json`, in the generated root. An apply
whose plan exits 0 (no changes at all, not even to outputs) skips its
`apply` step entirely: the Job ends successfully without applying
anything. `show -json`'s output is never written to the Job's log, since a
plan document carries every input value; every other command's output
streams to the log as it runs. `validate`'s JSON diagnostics are the
exception: they are captured for the failure summary below *and* still
written to the log, since they carry no input values. `state list`'s
output (resource addresses only) is logged too. Approving a destructive
plan or a Manual-policy preview is covered in
[Plan Approval](../user-guide/plan-approval.md); the counts, add/change/
destroy resource lists and the drift check itself are covered in
[Drift and Health](../concepts/drift-and-health.md).

## Lock timeout and stop timeout

`init`, `plan`, `apply`, `destroy` and `state push` all carry
`-lock-timeout`, defaulting to 300 seconds and overridable per object with
`spec.jobs.lockTimeoutSeconds` ([Tuning Jobs](../user-guide/job-tuning.md)).
On SIGTERM — a deletion, a drain, or the Job's `activeDeadlineSeconds`
(default 3600 seconds) — the runner sends `/captf/runtime` SIGTERM, never
its provider plugins, and gives it up to 570 seconds (the pod's 600-second
termination grace period, less a margin the runner needs to write the
result) to finish in-flight provider calls, write state and release the
backend lock before SIGKILL. A run stopped this way reports
`error.kind: interrupted`, not a module failure.

## What a failed step reports

A run's `status.lastRun.error` never carries raw process output. Its `kind`
is one of `image-layout`, `step`, `interrupted`, `blocked` (a guarded apply
stopped before a plan that deletes or replaces a resource) or
`plan-changed` (an approved apply whose new plan no longer matches the
approved hash); `step` names the command that failed, when there is one. A
`blocked` or `plan-changed` result changes nothing. A `plan-changed`
result also carries a plan summary in `status.plan`; a `blocked` result's
summary appears in the object's condition message instead. Both are
covered in [Plan Approval](../user-guide/plan-approval.md).

The failure summary itself is built from the failing step's own output,
never a raw stderr dump: for `validate`, from its `-json` diagnostics; for
every other step, from the `Error:` diagnostic header lines in its stderr
(ANSI escape codes stripped first, since a provider or a `local-exec`
child is not bound by `-no-color`). When neither yields a line, it falls
back to `step <name> exited <code>; see the Job's logs`. The summary is
capped at 512 bytes; the process exit code is the failing step's own code,
or `1` when the runner itself could not start or was killed. The full
stderr always reaches the Job's own pod log, uncapped, whether or not it
contributed to the summary.

## Output size limits

| Limit | Value | Applies to |
| --- | --- | --- |
| Failure summary | 512 bytes | `status.lastRun.error.summary`, above |
| Termination message | 4096 bytes | The whole result document; the kubelet truncates a longer one, so the runner drops fields in stages (resource-change counts, then the error tail, then plan and drift resource lists, then step history) to fit, keeping the plan's hash and counts last |
| Plan resources listed | 50 | `status.plan.resources`; a plan with more sets `truncated: true` |
| Drift resources listed | 20 | The drift check's resource address list |
| Stderr kept in memory per step | 64 KiB | The tail a step's failure summary is built from; the log itself is not truncated |

## See also

- [Image Contract](image-contract.md)
- [Job Environment](../reference/environment.md)
- [Job Inputs](../concepts/inputs.md)
- [Plan Approval](../user-guide/plan-approval.md)
- [Tuning Jobs](../user-guide/job-tuning.md)
