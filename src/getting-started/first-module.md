# Your First Module

This tutorial writes a small machine-role module from scratch, lints it,
packages it as the OCI image CAPTF runs, lints that image, and references
it from a `TerraformMachineTemplate`. It ends with a working, lint-clean
module image; it does not provision real infrastructure, since the module
in this tutorial creates no cloud resources. For the full set of rules a
module must follow, see the [module contract](../module-author/contract/v1alpha1/machine.md)
and the [image contract](../module-author/image-contract.md).

## Before you begin

- `tfcapi-lint`, installed as in [tfcapi-lint](../module-author/tfcapi-lint.md#install).
- `podman` or `docker`, to build the image.
- A directory to work in. This tutorial calls it `machine/`.

Terraform or OpenTofu itself is not required on your machine: the reference
Containerfile below downloads it inside the build, and `tfcapi-lint module`
parses the module's files directly.

## 1. Write the module

A machine-role module implements one Terraform/OpenTofu module that CAPTF
calls once per `TerraformMachine`. It receives the [common contract
inputs](../module-author/contract/v1alpha1/common.md) plus the [machine
role's inputs](../module-author/contract/v1alpha1/machine.md#inputs), and
must return the [machine role's outputs](../module-author/contract/v1alpha1/machine.md#outputs)
plus the common `health` output. This tutorial's module returns fixed
values instead of calling a cloud provider, which keeps every input and
output visible and needs no credentials or provider plugins to build or
lint. Swap the fixed values for calls to your cloud's Terraform/OpenTofu
provider once you understand the shape.

Create four files in `machine/`.

### `variables.tf`

The contract inputs. `captf_contract`, `captf_cluster`, `captf_object` and
`captf_tags` apply to every role; `captf_cluster_outputs` applies to the
machine and machinepool roles only (the cluster role produces it, and so
does not receive it); the rest are specific to the machine role.

```hcl
{{#include examples/noop/machine/variables.tf}}
```

### `main.tf`

The module's own logic. This tutorial stands in a `terraform_data`
resource for a real instance, so the module has something to hold its
inputs; a real module replaces this with the resources that create an
instance.

```hcl
{{#include examples/noop/machine/main.tf}}
```

### `outputs.tf`

The contract outputs. `provider_id`, `addresses` and `failure_domain` are
required; `interruptible` must be declared even when it is always `false`;
`health` is the common output every role returns.

```hcl
{{#include examples/noop/machine/outputs.tf}}
```

### `versions.tf`

```hcl
{{#include examples/noop/machine/versions.tf}}
```

This module declares no `required_providers`: `terraform_data` ships with
Terraform/OpenTofu itself, so there is no provider to install or mirror.
A module that calls a cloud provider adds a `required_providers` block
here as usual.

## 2. Lint the module

```sh
tfcapi-lint module ./machine --role machine --strict
```

A clean module prints an empty finding list and an all-zero summary.
`--strict` fails the command on a warning as well
as an error, so a lint-clean module here stays lint-clean once you add
real inputs, outputs and user variables. See
[tfcapi-lint](../module-author/tfcapi-lint.md) for the full command
reference and [tfcapi-lint CLI](../reference/tfcapi-lint-cli.md) for every
check ID.

## 3. Package it as an image

CAPTF runs a module as one OCI image that bundles the module's files and
the Terraform or OpenTofu binary; there is no separate module source and
no separate runtime image. Save the reference Terraform-based Containerfile
into `machine/`:

```Dockerfile
{{#include ../module-author/examples/Containerfile.terraform}}
```

An OpenTofu-based equivalent is also available
([`Containerfile.opentofu`](../module-author/image-contract.md#reference-opentofu-base));
either runtime satisfies the contract. Build from inside `machine/`:

```sh
export IMAGE=registry.example.com/acme/machine:v1.0.0
podman build -f Containerfile.terraform --build-arg ROLE=machine -t "$IMAGE" .
```

`IMAGE` is the registry, repository and tag you push to; `ROLE=machine`
tags the image with the role it implements. See the [image
contract](../module-author/image-contract.md) for the fixed paths, OCI
labels and execution environment every image must satisfy.

## 4. Lint the image

`tfcapi-lint image` reads a pushed registry reference or a local OCI
layout. Without a registry to push to yet, save the image podman just
built to a local OCI directory and lint that:

```sh
podman save --format oci-dir -o /tmp/first-module-image "$IMAGE"
tfcapi-lint image --role machine "oci:/tmp/first-module-image"
```

Once you push `$IMAGE` to a registry, lint the pushed reference the same
way: `tfcapi-lint image --role machine "$IMAGE"`.

## 5. Reference it from a TerraformMachineTemplate

A `TerraformMachineTemplate` is what a `MachineDeployment`, a
`KubeadmControlPlane` or a `MachineSet` points at to create
`TerraformMachine`s; its `spec.template.spec.source.image` names the image
you just built:

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: TerraformMachineTemplate
metadata:
  name: first-module
  namespace: default
spec:
  template:
    spec:
      source:
        image: registry.example.com/acme/machine:v1.0.0
```

Apply it:

```sh
kubectl apply -f first-module-template.yaml
```

`kubectl get terraformmachinetemplate first-module -n default` confirms
the object exists; there is nothing to provision yet, since nothing
references this template as a `MachineDeployment`, `MachineSet` or control
plane's `infrastructureRef` does. A `TerraformMachine` created from it
needs an identity to run under: either its own `spec.identityRef`, or one
inherited from its `TerraformCluster`'s `spec.defaults.identityRef`, as
set up in the [quick start](quick-start.md#2-apply-an-identity).

## Next steps

- Walk through the [quick start](quick-start.md) to wire a machine
  template like this one into a full cluster.
- Read the [module contract](../module-author/contract/v1alpha1/README.md)
  for every rule a production module must follow, and the [cluster
  role](../module-author/contract/v1alpha1/cluster.md) and [machine pool
  role](../module-author/contract/v1alpha1/machinepool.md) for the other
  two roles a full deployment needs.
- Read [Runtime Environment](../module-author/runtime-environment.md) for
  what a module sees when the runner actually executes it.
