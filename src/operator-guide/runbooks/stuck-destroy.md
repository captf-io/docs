# Stuck Destroy

CAPTF has no skip-destroy annotation: if a `destroy` Job keeps failing, the
object stays with `ApplyJobSucceeded=False`/`DestroyFailed` (so `Ready=False`)
and the controller retries with backoff forever. This applies the same way
to a `TerraformCluster`, a `TerraformMachine` and a `TerraformMachinePool`.
This page walks through recovering: back up what the destroy would remove,
clean up the cloud resources another way, then remove the object's
finalizer by hand.

Removing the finalizer garbage-collects the state Secrets, the state
backups and the durable inputs Secret through their owner references —
**the only record of the live cloud resources** — so back them up, or
un-own them, before you do that.

A stuck destroy on a control-plane machine also blocks
KubeadmControlPlane/RKE2ControlPlane remediation, scale and upgrade until
it is resolved.

## Before you begin

- `get`, `patch` and `delete` access to Secrets and to the stuck object, in
  its namespace, on the management cluster.
- Replace `<ns>`, `<name>` and `<kind>` below with the object's namespace,
  name and Kind (`terraformcluster`, `terraformmachine` or
  `terraformmachinepool`; the lowercase singular works with `kubectl`).
  Run every command against the management cluster.

## 1. Find the state suffix

State Secret and backup Secret names are keyed by a suffix the controller
derives from the object's namespace, kind and name. Read it back from the
object's own status rather than recomputing it:

```sh
kubectl get <kind> -n <ns> <name> -o jsonpath='{.status.stateSecretSuffix}'
```

Save the output as `<suffix>` for the commands below.

## 2. Back up the state and inputs Secrets

```sh
kubectl get secret -n <ns> -l tfstate=true,tfstateSecretSuffix=<suffix> -o yaml > backup-state.yaml
kubectl get secret -n <ns> -l captf.io/state-backup=true,captf.io/state-backup-suffix=<suffix> -o yaml > backup-state-backups.yaml
kubectl get secret -n <ns> captf-inputs-<kindshort>-<name> -o yaml > backup-inputs.yaml
```

`<kindshort>` is `c` for a TerraformCluster, `m` for a TerraformMachine, `mp`
for a TerraformMachinePool. The first selector matches the base state
Secret and every `-part-N` chunk of a large Terraform state in one call;
the second matches every backup Secret (and its chunks) taken of this
object — see [Terraform State](../../concepts/state.md#state-backups) and
the [state restore runbook](state-restore.md). Both kinds of Secret are
owned by the object and are garbage-collected along with it once its
finalizer is removed.

`backup-inputs.yaml`'s `captf.io/image-digest` annotation (see
[Annotations, labels and finalizers](../../reference/annotations-labels.md))
names the exact image that ran the last successful apply — you will need it
in step 4.

## 3. Un-own the Secrets, if you want them to survive finalizer removal

`kubectl patch` takes names, not a label selector, so patch each Secret by
name:

```sh
for s in $(kubectl get secret -n <ns> -l tfstate=true,tfstateSecretSuffix=<suffix> -o name); do
  kubectl patch -n <ns> "$s" --type=json -p '[{"op":"remove","path":"/metadata/ownerReferences"}]'
done
for s in $(kubectl get secret -n <ns> -l captf.io/state-backup=true,captf.io/state-backup-suffix=<suffix> -o name); do
  kubectl patch -n <ns> "$s" --type=json -p '[{"op":"remove","path":"/metadata/ownerReferences"}]'
done
kubectl patch secret -n <ns> captf-inputs-<kindshort>-<name> \
  --type=json -p '[{"op":"remove","path":"/metadata/ownerReferences"}]'
```

Skip this if you would rather rely on step 2's `backup-*.yaml` files: with
those in hand you don't need the live Secrets to survive finalizer removal.

## 4. Clean up the cloud resources

Either clean up out of band (the cloud console, or the module's own
tooling), or run the pinned image's `terraform`/`tofu` binary by hand
against the backed-up state and inputs. The image's own binary lives at
`/captf/runtime`
([Image Contract](../../module-author/image-contract.md#fixed-paths)); the
Job's own use of it, including its exact `-backend-config` flags, is in
[Job Environment](../../reference/environment.md#runner-command-and-args).

```sh
docker run --rm --entrypoint /captf/runtime \
  -v "$PWD/root:/captf/work/root" -w /captf/work/root \
  <image>@<digest> init -input=false -no-color \
  -backend-config=secret_suffix=<suffix> -backend-config=namespace=<ns> \
  -backend-config=in_cluster_config=true -backend-config=labels=<labels>

docker run --rm --entrypoint /captf/runtime \
  -v "$PWD/root:/captf/work/root" -w /captf/work/root \
  <image>@<digest> destroy -auto-approve -input=false -no-color \
  -var-file=terraform.tfvars.json
```

- `<image>@<digest>` is the repository from `backup-inputs.yaml`'s
  `captf.io/image` annotation (drop any `:tag`) plus `@` and the digest
  from its `captf.io/image-digest` annotation.
- `<labels>` must be the same HCL object the Job itself would pass, or
  `init` reads an empty state: the backend selects state by this whole
  map. Copy it from `backup-state.yaml`'s base Secret `.metadata.labels`,
  dropping `tfstate`, `tfstateSecretSuffix` and `tfstateWorkspace` (the
  backend sets those itself), as `{"key"="value",...}`; see [Annotations,
  labels and finalizers](../../reference/annotations-labels.md) for what
  each remaining key means.
- `./root` needs `main.tf.json` and `terraform.tfvars.json` from
  `backup-inputs.yaml`'s data (the durable inputs Secret's rendered root
  module and tfvars), and the identity's credentials as environment
  variables (`-e <KEY>=<value>` for each key of the mirrored credentials
  Secret, or a file for a file-based one — see [Identities and
  credentials](../../user-guide/identities.md#how-credentials-reach-a-job)).
- `-backend-config=in_cluster_config=true` reads the pod's own
  ServiceAccount token, so this only works run from inside the cluster (for
  example, a debug pod using the `captf-runner` ServiceAccount). Running it
  from a workstation needs a kubeconfig-based backend configuration
  instead.
- Restoring `backup-state.yaml` first (recreate the Secrets it holds) and
  letting the `kubernetes` backend read that live state also works, and
  skips reconstructing the backend configuration by hand.

## 5. Remove the finalizer

```sh
kubectl patch <kind> -n <ns> <name> --type=json \
  -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```

Use the lowercase, plural CRD resource name (for example,
`terraformmachines`) if your `kubectl` version needs it instead of the
Kind. This removes the whole `metadata.finalizers` array: safe for a
`Terraform*` object, which carries only CAPTF's own finalizer, but check
`.metadata.finalizers` first if something else may have added one, and
remove that entry by index instead.

## Confirm it worked

```sh
kubectl get <kind> -n <ns> <name>
kubectl get secret -n <ns> -l tfstate=true,tfstateSecretSuffix=<suffix>
```

The first command reports `NotFound` once the object is gone. The second
shows nothing unless you un-owned the Secrets in step 3, in which case they
are exactly what you chose to keep.

## The durable inputs Secret is missing

If the object reports `ApplyJobSucceeded=False`/`DestroyFailed` with the
message "The durable inputs Secret is missing, so destroy cannot be
rendered; see
<https://captf.io/docs/operator-guide/runbooks/stuck-destroy.html>", the
durable inputs Secret (`captf-inputs-<kindshort>-<name>`: the rendered root
module, tfvars and pinned image from the last successful apply — see [Job
Inputs](../../concepts/inputs.md)) was deleted or never written.

`TerraformMachine` is the persistent case: it is immutable and never falls
back to re-rendering current inputs for a destroy, since the Machine and
its bootstrap Secret a rebuild would need are usually already gone by the
time destroy runs, so once its durable Secret is gone the condition never
clears on its own. `TerraformCluster` and `TerraformMachinePool` (both
mutable) fall back to building current inputs instead; they show the same
message only while that build is gated (for example, waiting on a
dependency that is itself being deleted), and it usually clears once the
gate does. The controller retries forever either way; it never invents
inputs to destroy with.

To recover:

- **If you have a backup** (`backup-inputs.yaml` from a previous run of
  step 2 above, or any earlier copy of the durable inputs Secret), recreate
  it with `kubectl apply -f backup-inputs.yaml` after removing
  `metadata.uid` and `metadata.resourceVersion` from the YAML: reapplying
  the exact object restores its owner reference, labels and annotations,
  including the pinned `captf.io/image` and `captf.io/image-digest`. The
  next reconcile reads it and starts the destroy Job.
- **If you have no backup**, the controller cannot destroy the object's
  resources. Back up the state (step 2), then clean up out of band (step
  4): without the rendered `main.tf.json` and `terraform.tfvars.json`,
  running the module by hand needs reconstructing them, but the state
  lists every resource the module created. `status.source.image` and
  `status.source.imageDigest` still name the image the last Job ran. Then
  remove the finalizer (step 5). **Removing the finalizer without cleaning
  up the cloud resources first abandons them**: they stay in the cloud,
  unmanaged, with nothing in Kubernetes recording that they ever existed.

## See also

- [Terraform State](../../concepts/state.md) — how state, its backups and
  their owner references work.
- [State restore runbook](state-restore.md) — restoring a state instead of
  destroying it.
- [Job Inputs](../../concepts/inputs.md) — the durable inputs Secret.
