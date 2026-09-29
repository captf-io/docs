# Machine Remediation

A `TerraformMachine` reports its instance's health on the
`InfrastructureHealthy` condition. By itself that only ever turns the
owning Machine's `InfrastructureReady` condition `False`; nothing acts on
it unless something is watching. `spec.remediation` optionally asks
Cluster API to replace an unhealthy instance, through a
`MachineHealthCheck` and the Machine's owner. This page covers
configuring it, how it reaches a replacement, and what it does to the
Machine along the way. See [Drift and
Health](../concepts/drift-and-health.md) for how health itself is
computed.

## Before you begin

- A provisioned `TerraformMachine` whose owning Machine is selected by a
  `MachineHealthCheck` with an `unhealthyMachineConditions` check on
  `InfrastructureReady`.
- `kubectl` access to edit the `TerraformMachine` and read its owning
  Machine.

## Enable remediation

`spec.remediation.annotateMachine` defaults to `false`, meaning CAPTF
never touches the Machine. Set it to `true` to have CAPTF request
remediation once an instance has been unhealthy for long enough:

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: TerraformMachine
spec:
  remediation:
    annotateMachine: true
```

`spec.remediation` is operational policy: it stays mutable for the
machine's whole life, unlike `spec.source` and `spec.identityRef`, which
are fixed at creation.

## Tune the threshold and sampling interval

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: TerraformMachine
spec:
  remediation:
    annotateMachine: true
    unhealthyThreshold: 5
    healthCheckIntervalSeconds: 120
```

- `unhealthyThreshold` (1-100, default 3) is how many consecutive
  unhealthy health samples are needed before CAPTF signals remediation. A
  sample is one completed refresh or drift Job; a single transient
  reading is never enough on its own, since once a `MachineHealthCheck`
  acts on the signal, the Machine is replaced. A terminated instance
  skips the threshold; see [Terminated instances](#terminated-instances)
  below.
- `healthCheckIntervalSeconds` (60-86400, default 300) is how often a
  provisioned instance is refreshed to resample its health while
  `annotateMachine` is `true`, independent of `spec.drift.intervalSeconds`.
  With `annotateMachine` set to `false` it has no effect, and health is
  then re-read only at the drift (or refresh) cadence set by
  `spec.drift.intervalSeconds`; see [Drift](drift.md) for that setting,
  including how `intervalSeconds: 0` stops health sampling entirely once
  `annotateMachine` is `false`.

## How it works with a MachineHealthCheck

1. Health outside `running`/`healthy`, read after provisioning, turns
   `InfrastructureHealthy` `False`, which turns `Ready` `False`, which
   Cluster API mirrors into the owning Machine's `InfrastructureReady`
   condition.
2. A `MachineHealthCheck` with `spec.checks.unhealthyMachineConditions:
   [{type: InfrastructureReady, status: "False", timeoutSeconds: <N>}]`
   selecting the Machine starts its own timeout once `InfrastructureReady`
   turns `False`.
3. When the timeout (or, with `annotateMachine`, the annotation below)
   marks the Machine unhealthy, `MachineHealthCheck` sets the Machine's
   `OwnerRemediated` condition. Only the Machine's **owner** acts on
   that condition: a `MachineDeployment`'s `MachineSet`, or a
   control-plane provider that implements remediation, such as
   `KubeadmControlPlane` or `RKE2ControlPlane`. A single-replica control
   plane refuses to remediate itself.
4. The owner that acts replaces the Machine (and, through its deletion,
   the `TerraformMachine`) with a new one rather than repairing it in
   place: `spec.source` is immutable, so there is nothing for CAPTF to
   patch.

`annotateMachine` does not replace this flow; it feeds it a faster, more
specific signal than the timeout alone (see the next section).

## The remediate-machine annotation

With `annotateMachine: true`, once `unhealthyThreshold` consecutive
samples are unhealthy, degraded or stopped (or the instance is
terminated), CAPTF sets `cluster.x-k8s.io/remediate-machine` on the
owning Machine. This asks the `MachineHealthCheck` reconciler to treat
the Machine as unhealthy at once, bypassing `unhealthyMachineConditions`'
timeout; remediation still goes through the owner as described above.
CAPTF marks the annotation as its own with a second annotation,
`captf.io/remediation-requested`, whose value is why it was set, for
example `InstanceUnhealthy for 5 consecutive samples` or `the instance is
terminated`.

CAPTF removes both annotations once the instance reads `Healthy` again
and the Machine is not being deleted, withdrawing a request that has not
yet been acted on. It never removes `cluster.x-k8s.io/remediate-machine`
when `captf.io/remediation-requested` is absent: an annotation set by
someone else is left alone.

See [Annotations, Labels and
Finalizers](../reference/annotations-labels.md) for both annotations'
full definitions.

## Terminated instances

A terminated instance skips `unhealthyThreshold` entirely: CAPTF sets the
annotations on the very first sample that reads the instance terminated,
since there is nothing to wait for and no risk of a transient reading.

## Confirm it worked

- `kubectl get machine <name> -n <namespace> -o
  jsonpath='{.metadata.annotations}'` shows
  `cluster.x-k8s.io/remediate-machine` and `captf.io/remediation-requested`
  once a request is made, and neither once the instance recovers or is
  replaced.
- A `RemediationRequested` event on the `TerraformMachine` marks a new
  request, and `RemediationWithdrawn` marks a withdrawal; see
  [Events](../reference/events.md).
- `captf_remediation_requests_total{action="requested"|"withdrawn"}`
  counts both; see [Metrics](../reference/metrics.md).

## See also

- [Drift and Health](../concepts/drift-and-health.md) for how health
  samples are produced.
- [Drift](drift.md) for `spec.drift.intervalSeconds`, which paces health
  sampling when `annotateMachine` is `false`.
- [API Reference](../reference/api.md#machineremediation) for
  `MachineRemediation`'s full field list.
- [Conditions](../reference/conditions.md#infrastructurehealthy) for
  `InfrastructureHealthy`'s reasons.
