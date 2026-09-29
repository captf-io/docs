# Observability

This page is for operators running the manager: what its metrics endpoint
serves and who may read it, how to wire up Prometheus, what each alert
means and where to look first, and how to read conditions, events and logs
once you are looking at a specific object or Job.

## The diagnostics endpoint

The manager serves Prometheus metrics over HTTPS, authenticated and
authorized against the API server by default:

1. The bearer token in the request is checked with a `TokenReview`.
2. The token's access is checked with a `SubjectAccessReview` for `get` on
   the non-resource URL `/metrics`.

`--insecure-diagnostics` turns both checks off and serves plain HTTP
instead; use it only for local development.
[Configuration](configuration.md#diagnostics-address-authentication-and-tls)
covers that flag and the address, TLS version and cipher flags, and
[Manager Flags](../reference/manager-flags.md#diagnostics-and-tls-capi)
lists them with their defaults.

| Request | Result |
| --- | --- |
| `GET /metrics` without a token | `401 Unauthorized` |
| `GET /metrics` with a token authorized for `get` on `/metrics` | `200`, serving `captf_build_info` and the rest of the series |

There is no flag for the metrics server's own certificate: mount a Secret
with `tls.crt` and `tls.key` at `/tmp/k8s-metrics-server/serving-certs/` to
serve your own, or leave it unmounted and the manager generates a
self-signed certificate at startup.

The same authenticated endpoint also serves a profiler
(`GET /debug/pprof/*`) and an endpoint to change the log level at runtime
(`PUT /debug/flags/v`; see [Logs and verbosity](#logs-and-verbosity)) once
`--insecure-diagnostics` is off. Each request is authorized the same way,
against its own non-resource URL and the HTTP method lowercased as the
verb (`get` for the profiler, `put` for the log level). Nothing in the
shipped manifests grants either, only `/metrics`, so bind your own
ClusterRole to reach them.

The series themselves are listed in [Metrics](../reference/metrics.md).

## Enabling the Prometheus component

`config/prometheus` is an opt-in kustomize component: a metrics `Service`,
a `ServiceMonitor` and a `PrometheusRule` with the eleven alerts below,
plus a `ClusterRole` that lets a Prometheus instance read the diagnostics
endpoint. It is not part of `infrastructure-components.yaml` and is not a
release asset, so `clusterctl init` never installs it and `clusterctl
upgrade` never touches it: get `config/prometheus` from a checkout of the
tag you installed, build it, and apply it yourself, and repeat that after
every upgrade to pick up any change to the alert rules. See
[RBAC](rbac.md#the-metrics-reader-clusterrole) for what the `ClusterRole`
grants.

Before you begin:

- the Prometheus Operator CRDs (`ServiceMonitor`, `PrometheusRule`) are
  installed in the cluster;
- you know the namespace and name of the ServiceAccount your Prometheus
  scrapes with, if it is not kube-prometheus's default
  (`monitoring/prometheus-k8s`).

1. Build the component on its own — it needs no other resources, and its
   objects already carry the `captf-` names and the `captf-system`
   namespace that `config/default` produces:

   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   components:
   - <path-to-checkout>/config/prometheus
   ```

   ```sh
   kustomize build <path-to-this-kustomization> >captf-prometheus.yaml
   ```

2. If your Prometheus does not run as `monitoring/prometheus-k8s`, patch
   the `captf-metrics-reader` `ClusterRoleBinding`'s subject to your
   ServiceAccount instead, before applying.
3. Apply the built manifest with `kubectl apply -f captf-prometheus.yaml`.
   If your provider install itself uses renamed objects (a non-default
   `namePrefix` or namespace), patch the `ServiceMonitor`'s and
   `PrometheusRule`'s selectors and the `Service` reference to match, since
   a component does not inherit an overlay's name or namespace
   transformers.

The `ServiceMonitor` scrapes over HTTPS with `insecureSkipVerify` set,
since the metrics server's certificate is self-signed by default; once you
mount a CA-signed certificate, set `tlsConfig.ca` instead and drop
`insecureSkipVerify`.

To confirm it works without waiting on Prometheus, read the endpoint
yourself with the same kind of token Prometheus uses:

```sh
kubectl port-forward -n captf-system svc/captf-controller-manager-metrics 8443:8443 &
curl -sk -H "Authorization: Bearer $(kubectl create token <serviceaccount> -n <namespace> --duration=5m)" \
  https://localhost:8443/metrics | grep captf_build_info
```

`<serviceaccount>` and `<namespace>` name a ServiceAccount already bound
to `captf-metrics-reader` (or your own equivalent grant). A `captf_build_info`
line back confirms both the endpoint and the token's authorization; `401`
or `403` means the token or the binding, not the manager.

`make promtool-check` and `make promtool-test` validate the alert rules
before you ship a change to them; see
[Make Targets](../reference/make-targets.md).

## Useful queries

```promql
# p95 Job duration by op, over the last day, for Jobs that ran their course
histogram_quantile(0.95, sum by (le, op) (rate(captf_job_duration_seconds_bucket{result=~"succeeded|failed"}[1d])))

# Slowest runner steps (p90) by kind, op and step
histogram_quantile(0.9, sum by (le, kind, op, step) (rate(captf_job_step_duration_seconds_bucket[6h])))

# Failures by error kind and step
sum by (op, error_kind, step) (increase(captf_job_errors_total[1d]))

# p90 queue time (creation to the source container's start) by op
histogram_quantile(0.9, sum by (le, op) (rate(captf_job_queue_seconds_bucket[1h])))

# The ten largest states, and how close each is to one Secret's 1 MiB
topk(10, captf_state_bytes)
captf_state_bytes / (1024 * 1024)

# Objects whose drift check or health refresh is overdue
time() - captf_last_success_timestamp_seconds{op=~"drift|refresh"} > 3600
```

No Grafana dashboard ships with the component; the queries above are the
panels one would build. The full series list, with every label, is in
[Metrics](../reference/metrics.md).

## Alerts

`config/prometheus` ships eleven alerts on the series above. Two things
help in reading them:

- The failure counters count transitions, not reconciles: they go up once
  when an object or Job newly enters the bad state, so `increase(...) > 0`
  means something newly broke, not that it is still broken.
- `CAPTFClusterDrift`, `CAPTFStateNearSecretLimit`, `CAPTFInputsNearLimit`
  and `CAPTFNoRecentSuccess` name the object directly, with `namespace`
  and `name` labels. The rest aggregate by `kind` (with `op` or `reason`),
  except `CAPTFReconcileErrors`, which aggregates by `controller` alone;
  find the affected object through its conditions, as each section below
  says.

Every rule's expression, `for` and severity are in
[Alerts](../reference/alerts.md); each heading below links there.

### CAPTFJobFailing

Jobs of a kind and op failed or hit their deadline more than twice in 30
minutes. Find the objects with `ApplyJobSucceeded=False` or
`DriftJobSucceeded=False` and read `status.lastRun` and the Job's logs:

```sh
kubectl get terraformclusters,terraformmachines,terraformmachinepools -A -o json \
  | jq -r '.items[] | select(.status.conditions[]? | .type == ("ApplyJobSucceeded", "DriftJobSucceeded") and .status == "False") | "\(.kind)\t\(.metadata.namespace)/\(.metadata.name)"'
```

See [Failing Jobs](runbooks/job-failures.md) and
[the rule](../reference/alerts.md#captfjobfailing).

### CAPTFDestroyStuck

An object's destroy keeps failing while it deletes; its finalizer and
state stay in place, so nothing is orphaned. See
[Stuck Destroy](runbooks/stuck-destroy.md) and
[the rule](../reference/alerts.md#captfdestroystuck).

### CAPTFClusterDrift

A `TerraformCluster`'s last drift check found changes and it has stayed
that way for an hour. With `drift.action: Report` an operator decides
next; with `Remediate` the remediation apply is failing, check
`ApplyJobSucceeded`. See [Drift](../user-guide/drift.md) and
[the rule](../reference/alerts.md#captfclusterdrift).

### CAPTFStateUnreadable

A state Secret turned unreadable. Find the object with
`StateReadable=False` and read that condition's reason and message:

```sh
kubectl get terraformclusters,terraformmachines,terraformmachinepools -A -o json \
  | jq -r '.items[] | select(.status.conditions[]? | .type == "StateReadable" and .status == "False") | "\(.kind)\t\(.metadata.namespace)/\(.metadata.name)"'
```

See [Unreadable State](runbooks/state-unreadable.md) and
[the rule](../reference/alerts.md#captfstateunreadable).

### CAPTFForceUnlocks

A Job force-unlocked a state lock whose holder pod no longer existed.
Find out why the previous Job died before it happens again. See
[Stale State Lock](runbooks/stale-lock.md) and
[the rule](../reference/alerts.md#captfforceunlocks).

### CAPTFReconcileErrors

A controller keeps returning errors from its reconcile loop. Read the
manager's logs for the failing kind. See
[Reconcile Errors](runbooks/reconcile-errors.md) and
[the rule](../reference/alerts.md#captfreconcileerrors).

### CAPTFJobSlow

Jobs of a kind and op are taking longer than expected at the 90th
percentile. Compare it with the Jobs' `activeDeadlineSeconds` and find the
slow step with `captf_job_step_duration_seconds`. See
[Slow Jobs](runbooks/slow-jobs.md) and
[the rule](../reference/alerts.md#captfjobslow).

### CAPTFJobQueueSlow

Jobs are waiting too long between creation and the source container
starting: scheduling, image pulls or the runner's own init copy. Look for
Pending runner pods and their events. See
[Slow Jobs](runbooks/slow-jobs.md) and
[the rule](../reference/alerts.md#captfjobqueueslow).

### CAPTFStateNearSecretLimit

An object's compressed state is approaching the 1 MiB a Secret can hold.
`captf_state_resources` shows how many resources it manages. See
[Size Limits](runbooks/size-limits.md) and
[the rule](../reference/alerts.md#captfstatenearsecretlimit).

### CAPTFInputsNearLimit

An object's rendered inputs are approaching the size no Job will start
past. See [Size Limits](runbooks/size-limits.md) and
[the rule](../reference/alerts.md#captfinputsnearlimit).

### CAPTFNoRecentSuccess

An object's scheduled drift check or health refresh has not succeeded in
six hours. Read `DriftJobSucceeded` and `status.lastRun`, the same as for
a failing Job. See [Failing Jobs](runbooks/job-failures.md) and
[the rule](../reference/alerts.md#captfnorecentsuccess).

## Reading conditions

`kubectl describe` on any `TerraformCluster`, `TerraformMachine`,
`TerraformMachinePool` or `TerraformClusterIdentity` shows its conditions:
a type, a status of `True`, `False` or `Unknown`, a reason and a message.
Most conditions are normal polarity (`True` is healthy); a few are
inverted, such as `Deleting`. `Unknown` most often means the object is
waiting on something else to finish, not that anything failed: it does
not fail `Ready`. See [retry backoff](../concepts/lifecycle.md#retry-backoff)
for how a wait like this is treated.

Every condition type CAPTF sets, its polarity, and every reason and
message it can carry are in [Conditions](../reference/conditions.md).

## Reading events

Every stage of an object's life emits a Kubernetes Event on it: the
manager once per transition, and a Job's runner in real time while it
runs. Read them in order with:

```sh
kubectl events --for terraformcluster/<name> -n <namespace>
kubectl events --for terraformmachine/<name> -n <namespace>
kubectl events --for terraformmachinepool/<name> -n <namespace>
kubectl events --for terraformclusteridentity/<name> -n default
```

`TerraformClusterIdentity` is cluster-scoped, but its events still land
in the `default` namespace.

Add `-o wide` for a `SOURCE` column that distinguishes the manager's
events from a runner's. Notes never carry credentials, tfvars, output,
plan values or raw stderr: a step failure's note is the runner's curated
summary, not its log output. Every reason, its type and what it means are
in [Events](../reference/events.md).

### Runner events

A Job's runner posts its own progress (`RunStarted`, `StepStarted`,
`StepSucceeded`, `StepFailed`, `PlanSummary`, `ResourcesChanged`,
`RunFinished`) as Events on the object the Job is for, related to the Job
itself. Emission is best effort: each request has its own short timeout,
and after a few consecutive failures the runner stops emitting for the
rest of that run without failing or slowing it. Turning `--runner-events`
off (see [Configuration](configuration.md#--runner-events)) skips them
entirely, which is worth doing on a large fleet since a single scheduled
drift check alone produces several of them. The runner's own `events`
`create` grant is in [RBAC](rbac.md).

## Logs and verbosity

The manager logs at a default verbosity where the usual reconcile flow is
visible; raising it shows more detail down to per-request tracing, and
lowering it keeps only errors and irreversible actions such as force
unlocks. Credentials, bootstrap data, tfvars content and output values are
never logged, whatever the level.

Change the level without restarting the manager through the same
authenticated diagnostics endpoint:

```sh
curl -sk -X PUT -H "Authorization: Bearer <token>" --data '<level>' \
  https://<address>/debug/flags/v
```

The token needs its own authorization for `put` on `/debug/flags/v`; the
shipped manifests do not grant it. `--v`, `--vmodule` and
`--logging-format` set the level, per-file overrides and the output
format at startup instead; see
[Configuration](configuration.md#logging) and
[Manager Flags](../reference/manager-flags.md#logging).

Read the manager's own logs, and a Job's, with:

```sh
kubectl logs -n captf-system deploy/captf-controller-manager -c manager
kubectl logs -n <namespace> job/<name> -c source
```

## See also

- [Metrics](../reference/metrics.md) — every series, its type, labels and
  meaning.
- [Alerts](../reference/alerts.md) — every rule's expression, `for` and
  severity.
- [Conditions](../reference/conditions.md) — every condition, reason and
  message.
- [Events](../reference/events.md) — every event reason, type and meaning.
- [Configuration](configuration.md) — the flags behind the diagnostics
  endpoint, runner events and logging.
- [RBAC](rbac.md) — the manager's and Prometheus's RBAC.
- [Runbooks](runbooks/README.md) — the recovery procedures the alerts
  above link to.
