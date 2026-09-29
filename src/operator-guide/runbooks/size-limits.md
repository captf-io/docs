# Runbook: state or inputs near a size limit

CAPTF stores an object's state and its rendered module inputs in
Kubernetes Secrets, which cap out well before an unbounded Terraform or
OpenTofu project would. Two alerts warn before that cap:
`CAPTFStateNearSecretLimit` and `CAPTFInputsNearLimit`; a third condition
reason, `InputsTooLarge`, marks the point where the cap is already hit.
This runbook covers all three: what each limit is, how to find the object
tripping it, and how to shrink what it is trying to store.

Replace `<ns>`, `<kind>` and `<name>` below with the object's namespace,
kind (`terraformcluster`, `terraformmachine` or `terraformmachinepool`)
and name.

## CAPTFStateNearSecretLimit: the state is approaching a Secret's size cap

**The limit.** A Kubernetes Secret holds at most 1 MiB. OpenTofu's
`kubernetes` backend writes the whole state into a single Secret and fails
to save a state larger than that; Terraform's splits an oversized state
across additional `-part-N` Secrets instead, up to the reader's own cap of
32 chunks. Either way, `captf_state_bytes` (the compressed size) crossing
900 KiB fires the alert — for OpenTofu that is a warning before a hard
failure, for Terraform a warning about growth. See
[Chunking and size caps](../../concepts/state.md#chunking-and-size-caps)
for the exact numbers and how CAPTF reads a chunked state.

**Find it.**

```sh
kubectl get <kind> -n <ns> <name> -o jsonpath='{.status.stateSecretSuffix}{"\n"}'
kubectl get secret -n <ns> -l tfstate=true,tfstateSecretSuffix=<suffix> -o name
```

One result means an unchunked (or not yet chunked) state; more than one
means Terraform has already split it into `-part-N` Secrets. For the exact
compressed size, read `captf_state_bytes{namespace="<ns>",name="<name>"}`
from Prometheus, or sum the chunks by hand:

```sh
kubectl get secret -n <ns> -l tfstate=true,tfstateSecretSuffix=<suffix> \
  -o jsonpath='{range .items[*]}{.data.tfstate}{"\n"}{end}' | while read -r c; do
  echo "$c" | base64 -d | wc -c
done
```

Compare the total against `captf_state_resources` (also per object) to see
how many managed resources it is spread across.

**Shrink it.** The state holds every managed resource's full attribute
set, not just what you set in configuration:

- Split a large module into more than one `TerraformCluster` or
  `TerraformMachine` (or use a `TerraformMachinePool` for repeated
  instances instead of one resource per machine): each gets its own state.
- Drop attributes you do not need from the state by not managing them:
  large inline blocks such as embedded certificates, rendered
  cloud-init or user-data templates, or full API responses stored in a
  resource's computed attributes are common culprits. Move that content
  to a source the module reads at apply time (a Secret, a bucket object)
  instead of a resource argument Terraform tracks verbatim.
- For a resource with many similar instances (`count` or `for_each`), each
  instance's full attribute set is stored once; reducing the count reduces
  the state proportionally.

## CAPTFInputsNearLimit and InputsTooLarge: the rendered inputs are approaching or over the cap

**The limit.** The rendered `main.tf.json` plus `terraform.tfvars.json`
(what the module actually runs against) is capped at 1,000,000 bytes,
reported per object on `captf_inputs_bytes`. `CAPTFInputsNearLimit` warns
above 900,000 bytes; at or above the cap, no Job starts and
`ApplyJobSucceeded` turns `False` with reason `InputsTooLarge`. See
[Limits](../../concepts/inputs.md#9-limits) for how the size is computed
and what counts toward it.

**Find it.**

```sh
kubectl get <kind> -n <ns> <name> \
  -o jsonpath='{range .status.conditions[?(@.type=="ApplyJobSucceeded")]}{.status}/{.reason}: {.message}{"\n"}{end}'
```

`InputsTooLarge`'s message names the operation that could not render. The
`captf_inputs_bytes` gauge is set to the rendered size even when it was too
large to run, so it is set for this object right up to the cap.

**Shrink it.** The three contributors are bootstrap data, cluster exports
and user variables:

- **`bootstrap_data`** (`TerraformMachine` and `TerraformMachinePool`
  only): the bootstrap provider's cloud-init or ignition content, carried
  base64-encoded (roughly 4/3 its raw size). Trim what the bootstrap
  provider generates — fewer files, less embedded content — through its
  own configuration (KubeadmConfig, RKE2Config, or your bootstrap
  provider's equivalent), not through CAPTF.
- **`captf_cluster_outputs`** (machines and pools): whatever the cluster
  module's `exports` output publishes, handed to every machine and pool of
  the cluster. See
  [What a cluster hands to its machines and pools](../../concepts/inputs.md#5-what-a-cluster-hands-to-its-machines-and-pools).
  Publish only what the machine or pool module actually needs from
  `exports`, not the cluster module's full internal state.
- **User variables** (`spec.variables`, `spec.variablesFrom`): trim large
  inline values, especially ones duplicated across many objects that could
  instead reference a `ConfigMap` or `Secret` your module reads directly
  at run time rather than passing through tfvars. See
  [Module Variables](../../user-guide/variables.md) for how variables are
  set and merged.

## Confirm it worked

```sh
kubectl get <kind> -n <ns> <name> \
  -o jsonpath='{.status.conditions[?(@.type=="ApplyJobSucceeded")].reason}{"\n"}'
```

For `InputsTooLarge`, the next reconcile after the inputs shrink re-renders
and, once it fits, starts the Job; the alerts clear once
`captf_state_bytes` or `captf_inputs_bytes` drops back under 900 KiB / 900,000
bytes for their `for` window.

## See also

- [Terraform State](../../concepts/state.md)
- [Job Inputs](../../concepts/inputs.md)
- [Module Variables](../../user-guide/variables.md)
- [Conditions reference](../../reference/conditions.md#applyjobsucceeded)
- [Observability](../observability.md#captfstatenearsecretlimit)
