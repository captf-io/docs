# Webhook Unavailable

CAPTF validates every `TerraformCluster`, `TerraformClusterIdentity`,
`TerraformClusterTemplate`, `TerraformMachine`, `TerraformMachineTemplate`,
`TerraformMachinePool` and `TerraformMachinePoolTemplate` write with an
admission webhook, and every one of those webhook rules has
`failurePolicy: Fail`: if the webhook cannot be reached, the write is
refused rather than let through unchecked. This page covers recognizing
that, and getting the webhook serving again.

There is no dedicated alert for this: it shows up as errors on
`kubectl apply` (or on anything else writing a `Terraform*` object) and,
because the manager's own writes go through the same path, often as
[CAPTFReconcileErrors](../../reference/alerts.md#captfreconcileerrors)
as well.

## Before you begin

- `kubectl` access to the `captf-system` namespace (or wherever CAPTF is
  installed): its Deployment, Service, Endpoints and the `cert-manager`
  `Certificate` and `Secret` it depends on.

## What is blocked while the webhook is down

Every `CREATE` and `UPDATE` of the seven kinds above is blocked: nothing
new can be created, and no existing one can be changed — including by
Cluster API's own controllers. In practice that reaches further than a
person running `kubectl apply`:

- a `MachineDeployment` or `KubeadmControlPlane`/`RKE2ControlPlane`
  scaling up cannot create the `TerraformMachine`s for the new replicas;
- `clusterctl move` fails, since it creates and updates `Terraform*`
  objects on the target cluster;
- the manager's own reconciles that write to a `Terraform*` object's
  metadata or spec — adding the finalizer to a new object, removing it
  once deletion finishes, or writing back a resolved `providerID` or
  `controlPlaneEndpoint` — fail the same way, and surface as
  [CAPTFReconcileErrors](../../reference/alerts.md#captfreconcileerrors).
- deleting a `TerraformClusterIdentity` or most `TerraformMachine`s is
  also blocked: those two kinds validate `DELETE` as well as
  `CREATE`/`UPDATE`. The identity's check normally refuses a delete while
  it is still in use or its credentials are still mirrored somewhere; the
  machine's normally redirects a direct delete through its owner
  `Machine` instead, to go through drain. Either check can also be the
  thing *allowing* a delete that would otherwise be refused (an identity
  no longer in use, a machine whose owner `Machine` is already gone), so
  while the webhook is down those deletes are blocked outright rather
  than falling back to permissive.

What keeps working: everything that only patches an object's `status`
subresource — a Job finishing, `status.lastRun`, conditions, drift and
health sampling — since none of the webhook rules cover the `status`
subresource. Existing, already-running Jobs finish normally; only
changes to an object's metadata or spec are affected.

## 1. Confirm the webhook, not something else, is the cause

`kubectl apply` against a `Terraform*` object returns an error naming the
webhook by name (`captf-validating-webhook-configuration`). Map the error
text to a cause:

| Error text | Likely cause |
| --- | --- |
| `... failed calling webhook ...: no endpoints available for service "captf-webhook-service"` | No manager pod is `Ready`; go to step 2. |
| `... failed calling webhook ...: context deadline exceeded` or `connection refused` | The Service or pod is reachable but not serving on the expected port, or a `NetworkPolicy` blocks it; go to step 3. |
| `... x509: certificate signed by unknown authority` | The webhook's `caBundle` is empty or stale; go to step 4. |

## 2. Check the manager pod is Ready

```sh
kubectl get pods -n captf-system -l control-plane=controller-manager
kubectl get endpoints -n captf-system captf-webhook-service
```

The manager's readiness probe includes its webhook server: a pod that
has not finished starting the webhook server, or whose serving
certificate failed to load, reports `NotReady` and drops out of the
`captf-webhook-service` `Endpoints` — which is exactly why
`kubectl get endpoints` shows nothing while this is the cause. Read the
pod's own logs and events for why it is not ready (a crash, an image
pull failure, or the certificate problem in step 4).

## 3. Check the Service and NetworkPolicy

```sh
kubectl get svc -n captf-system captf-webhook-service -o yaml
kubectl get networkpolicy -n captf-system
```

The `Service` forwards port 443 to the manager container's `:9443`; a
`Ready` pod with a populated `Endpoints` list but a webhook that still
cannot be reached from the API server usually means a `NetworkPolicy`
(none is installed by default; see [Installation](../installation.md))
blocking traffic to that port, or the Service's `selector` no longer
matching the pod's labels after a manual edit.

## 4. Check the certificate

```sh
kubectl get certificate -n captf-system captf-serving-cert
kubectl describe certificate -n captf-system captf-serving-cert
kubectl get secret -n captf-system captf-webhook-service-cert
```

`cert-manager` issues the webhook's serving certificate as the `Secret`
`captf-webhook-service-cert`, mounted into the manager pod, from the
`Certificate` `captf-serving-cert`. The
`ValidatingWebhookConfiguration`'s `caBundle` is kept current by
`cert-manager`'s CA injector, driven by the
`cert-manager.io/inject-ca-from: captf-system/captf-serving-cert`
annotation on `captf-validating-webhook-configuration` itself — check
that annotation is still present (a `kubectl apply` of a stripped-down
copy of the manifest can remove it) and that the `Certificate` reports
`Ready`. `cert-manager` not running at all, or its CRDs missing, leaves
the `Certificate` object present but never issued.

See [Installation](../installation.md) for how these names and the
`cert-manager` dependency fit together, and confirm `cert-manager` itself
is healthy in its own namespace if the `Certificate` never becomes
`Ready`.

## Confirm it worked

```sh
kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: TerraformClusterIdentity
metadata:
  name: webhook-check
spec:
  secretRef:
    name: webhook-check
    namespace: default
EOF
```

A server-side dry run still goes through admission. It succeeding (or
failing with a validation error about the object's own content, not a
webhook connectivity error) confirms the webhook is reachable again; a
blocked create or scale-up elsewhere in the cluster starts progressing on
its own once it does.

## See also

- [Reconcile Errors](reconcile-errors.md) — the manager's own writes
  failing for the same reason.
- [Installation](../installation.md) — what `clusterctl init` installs,
  and the exact resource names used above.
