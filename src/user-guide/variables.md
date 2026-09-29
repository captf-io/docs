# Module Variables

This page shows you how to pass your own variables to a `TerraformCluster`,
`TerraformMachine` or `TerraformMachinePool`'s module: instance sizes,
CIDRs, SSH keys, database passwords, anything besides the [contract
inputs](../module-author/contract/v1alpha1/README.md) CAPTF sets itself.

## Before you begin

- The module declares each variable you set, with a default so it still
  plans when nobody sets the variable
  ([`contract/v1alpha1/common.md`](../module-author/contract/v1alpha1/common.md#user-variables)).
  A variable the module does not declare fails the apply.
- To pass a variable from a ConfigMap or Secret, you need permission to
  create and label one in the object's namespace.

## Set an inline variable

Add the variable to `spec.variables` (or `spec.template.spec.variables` on a
`*Template` kind), a JSON object:

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: TerraformMachineTemplate
metadata:
  name: workers-large
spec:
  template:
    spec:
      source:
        image: ghcr.io/example/aws-machine:v1.4.0
      variables:
        instance_type: m6i.xlarge
        root_volume_gib: 100
        subnet_ids: [subnet-0a1, subnet-0b2]
```

Each key becomes a named argument of the module: the generated root
declares it without a type and passes it through, so the **module's own
declared type** converts the value (a ConfigMap string `"100"` becomes the
number `100` for a `number` variable).

## Set a variable from a ConfigMap or Secret

1. Create the ConfigMap or Secret in the object's namespace, and label it
   so CAPTF is allowed to read it:

   ```sh
   kubectl create configmap aws-sizing -n <namespace> \
     --from-literal=instance_type=m6i.xlarge
   kubectl label configmap aws-sizing -n <namespace> captf.io/variables=true
   ```

   `<namespace>` is the object's own namespace: `variablesFrom` never reaches
   across namespaces. This Secret is unrelated to the credentials Secret a
   `TerraformClusterIdentity` names: the two are separate mechanisms with
   separate labels and separate readers (see [Identities and
   Credentials](identities.md)).

   The manager watches only labeled ConfigMaps and Secrets, and reads their
   data straight from the API server when it renders a Job; it never caches
   it. The label is an explicit opt-in, part of the [trust
   boundary](../concepts/security-model.md): an object cannot read an
   arbitrary Secret of its namespace just by naming it.

2. Reference it from `spec.variablesFrom`:

   ```yaml
   spec:
     variablesFrom:
     - configMapRef:
         name: aws-sizing
     - secretRef:
         name: db-credentials
       format: JSON
     - configMapRef:
         name: team-overrides
       optional: true
   ```

   Every data key of a labeled source becomes a variable of that name. Set
   `optional: true` on a source that may not exist yet: a missing or
   unlabeled required source blocks the object at
   [`DependenciesReady=False/VariablesSourceNotFound`](../reference/conditions.md#dependenciesready)
   and no Job starts; an optional one just contributes nothing. Every value,
   including a Secret's, must be UTF-8; a ConfigMap's `binaryData` is read
   the same as `data`.

3. Confirm: `DependenciesReady` turns `True` once every required source
   resolves, and the object's next Job carries the variable. Inspect the
   rendered `terraform.tfvars.json` of a live object as described in [Job
   inputs](../concepts/inputs.md).

## Merge order and formats

1. `spec.variablesFrom`, in list order: every source's keys become
   variables, and a later source wins on a key it shares with an earlier
   one.
2. `spec.variables` (inline) wins over every source.

A source's `format` decides how its values are read:

- **`String`** (the default): each value is passed as a string. Use it for
  scalars; the module's declared type converts `"3"`, `"true"` and `"0.5"`.
- **`JSON`**: each value is parsed as JSON, for lists, maps and objects
  (`["a","b"]`, `{"team":"a"}`). A value that is not valid JSON holds the
  object at `DependenciesReady=False/VariablesInvalid`, naming the source
  and the key, never the value.

## Names and limits

A variable name is a Terraform identifier: `^[a-zA-Z_][a-zA-Z0-9_-]*$`.
Rejected, whatever the format:

- a name starting with `captf_`;
- a contract input of the object's role — a machine cannot set
  `machine_name`, but a cluster can, since `machine_name` is not one of its
  inputs ([contract reference](../module-author/contract/v1alpha1/README.md));
- a module meta-argument: `source`, `version`, `providers`, `count`,
  `for_each`, `depends_on`, `lifecycle`, `locals`.

`spec.variables` holds at most 256 keys, and when set, at least one; the
admission webhook rejects a bad inline key or too many of them at once, and
also rejects a `variablesFrom` entry that names both a ConfigMap and a
Secret, or neither. A bad key in a referenced source is caught only when
the controller reads it, as `VariablesInvalid` naming the key.
`spec.variablesFrom` holds at most 16 sources.

Variables count toward the rendered-inputs limit shared with every other
input (1,000,000 bytes): past it the apply is refused with
`ApplyJobSucceeded=False/InputsTooLarge`
([Size limits](../operator-guide/runbooks/size-limits.md)). They are also
part of the [inputs hash](../concepts/inputs.md) that decides whether a
mutable object's next reconcile re-applies.

## Sensitivity

A variable's **winning** value (after the merge above) is declared
`sensitive = true` in the generated root when it came from a Secret, so
Terraform and OpenTofu redact it in plan and apply output. A value that
ends up inline or from a ConfigMap is not sensitive, even if an earlier,
losing source was a Secret, and even if the module's own declaration marks
its variable sensitive. Sensitive or not, every variable is still stored
like any other input: in the object's inputs Secrets and in the state
([Secrets](../operator-guide/secrets.md), [Terraform
state](../concepts/state.md)).

## What a change does per kind

- `TerraformCluster`: the variables are part of the inputs hash. Editing
  `spec.variables`, `spec.variablesFrom` or the data of a referenced source
  re-applies the module, guarded like any other input change ([Plan
  approval](plan-approval.md)). The controller re-reads every referenced
  source on each reconcile, and a change to a labeled source it references
  wakes it.
- `TerraformMachine`: `spec.variables` and `spec.variablesFrom` are
  immutable. The controller reads the sources until the machine is
  provisioned; after that it never reads them again, and the machine's
  destroy, refresh and drift runs use the variables already pinned in its
  durable inputs Secret. Editing a referenced ConfigMap or Secret therefore
  affects only machines created afterward: roll the MachineDeployment, or
  bump the template, to replace existing ones.
- `TerraformMachinePool`: `spec.variables` and `spec.variablesFrom` are
  mutable, and the sources are re-read on every reconcile for the pool's
  whole life, the same as a TerraformCluster; a change to a labeled source
  it references wakes it immediately, the same way. The variables are part
  of the inputs hash, but the resulting re-apply is never guarded: a
  TerraformMachinePool has no `applyPolicy` ([Machine
  pools](machine-pools.md)).
- Templates: `spec.template.spec` of a `*Template` kind, so its `variables`
  and `variablesFrom` too, is immutable like the rest of the template
  ([The Kinds](../concepts/kinds.md#templates)); a ClusterClass topology
  patch on `spec.template.spec.variables` rolls out through a new template
  ([Templates and ClusterClass](clusterclass.md#template-immutability-and-rolling-out-a-change)).
- `spec.defaults` on a `TerraformCluster` does not cover variables: a
  machine or pool without its own `identityRef`, `jobs` or `drift` inherits
  the cluster's, but variables are never inherited, so set them on the
  machine, pool or their templates directly.
- `clusterctl move` never carries a `variablesFrom` source: CAPTF puts no
  owner reference on a ConfigMap or Secret it reads. A `TerraformCluster`
  or `TerraformMachinePool`, or a machine not yet provisioned, waits at
  `VariablesSourceNotFound` on the target until you recreate the source
  there ([clusterctl move](../operator-guide/runbooks/move.md)).

## Troubleshooting

| Symptom | Reason | Fix |
| --- | --- | --- |
| `DependenciesReady=False/VariablesSourceNotFound` | A required `variablesFrom` source is missing, or not labeled `captf.io/variables=true` | Create or label the ConfigMap or Secret, or set `optional: true` |
| `DependenciesReady=False/VariablesInvalid` | A source's key is not a Terraform identifier, is reserved, or (format `JSON`) its value is not valid JSON | Rename or remove the key, or fix the source's `format` |
| Admission rejects `spec.variables` | Not a JSON object, an inline key is reserved or not a Terraform identifier, or there are more than 256 keys | Fix or trim the key named in the error |
| `ApplyJobSucceeded=False/ApplyFailed`, `status.lastRun.error.summary` has `Unsupported argument` or `Extraneous JSON object property` | The module does not declare a variable you set | Add the variable to the module, or stop setting it |

See [`conditions.md`](../reference/conditions.md#dependenciesready) for
every `DependenciesReady` reason.

## See also

- [Identities and Credentials](identities.md) — the separate Secret
  mechanism for cloud credentials.
- [`common.md`](../module-author/contract/v1alpha1/common.md#user-variables) —
  how a module declares a user variable.
- [Job inputs](../concepts/inputs.md) — the full render pipeline and the
  inputs hash.
- [Templates and ClusterClass](clusterclass.md) — patching a variable per
  Cluster.
- [Plan approval](plan-approval.md) — the destructive-plan guard a
  TerraformCluster variable change is subject to.
- [`reference/api.md`](../reference/api.md#variablessource) — the full
  field list for `variables` and `variablesFrom`.
