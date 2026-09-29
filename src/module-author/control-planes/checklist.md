# Requirements Checklist

Every port, health check and ordering rule a KubeadmControlPlane (KCP) or
RKE2ControlPlane (RCP) cluster needs from a CAPTF cluster or machine
module, grouped by topic. Details and citations are in
[`kubeadm.md`](kubeadm.md) and [`rke2.md`](rke2.md); the shared creation
sequence and LB-membership patterns are in [`README.md`](README.md).
`n/a` means the row does not apply to that provider or module role.

"Verified by" is one of:

- `lint`: `tfcapi-lint` can check it today.
- `e2e`: only an end-to-end run with a real control-plane provider
  catches a violation.
- `operator`: checked by whoever reviews or writes the module; no
  automated check exists.
- `none`: not checked anywhere today.

Some `lint`-worthy rules have no check today; those are called out in
[kubeadm.md's open questions](kubeadm.md#open-questions) and
[rke2.md's open questions](rke2.md#open-questions). The project has no
end-to-end suite today, so no `e2e` row below has been verified against
a real control plane.

## Endpoint and load balancer

| Requirement | KubeadmControlPlane | RKE2ControlPlane | Cluster module | Machine module | Verified by |
| --- | --- | --- | --- | --- | --- |
| Endpoint valid before any Machine | KCP creates no Machine until `Cluster.spec.controlPlaneEndpoint.IsValid()` (host and port both set) | RCP returns before creating any Machine, including the first, while `!IsValid()` | MUST output a valid `control_plane_endpoint` no later than the apply that makes the cluster `provisioned`, unless the user sets one | n/a | e2e |
| LB frontend → CP backend port | `endpoint.port` → CP `:bindPort` (default `6443`); one frontend | `endpoint.port` → CP `:6443` (`apiServerPort` ignored); one of two frontends | MUST create a frontend on `endpoint.port` and a backend on `api_server_port ?? 6443`, kept equal to the module's `bindPort`/RKE2's fixed 6443 | n/a | operator |
| Second LB listener on 9345 | not applicable | `:9345` → CP `:9345`, **same host** as the endpoint; required for `control-plane-endpoint` (default) and `address` registration methods | MUST create this second listener for RKE2 clusters | MUST register the instance in the 9345 target set alongside 6443 | operator |
| Hairpin reachability | The endpoint MUST be reachable from the first CP node itself — `admin.conf`/`super-admin.conf`/`kubelet.conf` all point at the endpoint, not the node's local address | Same MUST applies to every RKE2 join. The init node itself has no `server:` configured and so needs no LB/9345 reachability at init time ([rke2.md's lifecycle constraints](rke2.md#lifecycle-constraints)) — this does not weaken the MUST for every later join | MUST make the LB/VIP allow a backend to reach its own frontend | n/a | none |
| Endpoint stability | Once emitted, `control_plane_endpoint` MUST be stable for the life of the object — CAPI never updates `Cluster.spec.controlPlaneEndpoint` after the first valid copy | Same rule; RCP also builds `tls-san` and the kubeconfig Secret from the first copy | MUST NOT replace the LB behind an already-emitted endpoint (new DNS name or IP); consider `lifecycle { prevent_destroy = true }` on that resource | n/a | none |

## Health checks and backend membership

| Requirement | KubeadmControlPlane | RKE2ControlPlane | Cluster module | Machine module | Verified by |
| --- | --- | --- | --- | --- | --- |
| Health check — API port | TCP, or HTTPS `/readyz`/`/healthz` without certificate verification; MUST go green with a single backend during init | TCP, or HTTPS `/healthz` only if anonymous auth is enabled | MUST configure a check matching one of these | n/a | operator |
| Health check — RKE2 supervisor (9345) | not applicable | TLS `GET /v1-rke2/readyz` expecting **403** (unauthenticated), or plain TCP | MUST configure this check for RKE2 clusters | n/a | operator |
| Backend membership timing | Instance MUST be in the LB backend before `kubeadm init`/`kubeadm join` finishes on it, or `controlPlaneInitialized` never latches | Instance MUST be added before its Machine becomes Ready; the LB MUST tolerate a backend whose supervisor is not yet up | n/a (registration is the machine module's job) | MUST register/deregister the instance in its own Terraform state, in the same apply as instance creation | e2e |
| SG / firewall — control plane | Backend port (`bindPort`) from LB, nodes and management; TCP 2379-2380 and 10250 between CP nodes; 10250 from CP to workers | CP↔CP TCP 2379-2381; all→CP TCP 6443 and 9345; all↔all TCP 10250 and the NodePort range (default 30000-32767); CNI ports for the chosen CNI (default canal: 8472/udp, 9099/tcp); egress to `get.rke2.io`/GitHub releases unless air-gapped | MUST create these security groups/firewall rules | MUST attach the instance to them | operator |

## Node identity and addresses

| Requirement | KubeadmControlPlane | RKE2ControlPlane | Cluster module | Machine module | Verified by |
| --- | --- | --- | --- | --- | --- |
| `provider_id` == Node `providerID` | MUST match exactly — the Machine controller links Node to Machine only on an exact match; KCP gates join preflight, etcd matching and remediation on the resulting `nodeRef` | MUST match exactly; a mismatch on the first CP Machine blocks every later join (no Ready CP Machine ⇒ `availableServerIPs` stays empty) | n/a | MUST emit the same value the Node's kubelet/CCM will register (CCM sets it, or `kubeletExtraArgs`/`agentConfig.kubelet.extraArgs: [provider-id=...]`) | e2e |
| `addresses` types and order | Not read by KCP or CABPK at all | Required address types by `registrationMethod`: `control-plane-endpoint`/`address` — none; `internal-first` — `InternalIP` and/or `ExternalIP`; `internal-only-ips` — `InternalIP`; `external-only-ips` — `ExternalIP`. Order is fixed by the controller (`InternalIP, InternalDNS, ExternalIP, ExternalDNS, Hostname`), not the module | n/a | MUST emit the required type(s) for the cluster's `registrationMethod`; MUST NOT rely on emission order | none |
| `kubernetes_version` suffix | Arrives as plain `vX.Y.Z` | Arrives as `vX.Y.Z+rke2rN`, copied verbatim from `RKE2ControlPlane.spec.version` | n/a | Under RKE2, MUST strip `+rke2rN` before using the value for an image lookup or a semver comparison | none |

## Bootstrap payload

| Requirement | KubeadmControlPlane | RKE2ControlPlane | Cluster module | Machine module | Verified by |
| --- | --- | --- | --- | --- | --- |
| `bootstrap_format` always set | Always written by CABPK (`cloud-config` default, `ignition` behind the alpha feature gate) | Always written by CAPRKE2 (`cloud-config` default, `ignition` fully supported) | n/a | MUST accept both `cloud-config` and `ignition` | e2e |
| `bootstrap_data` is base64, including the gzip case | Payload is always UTF-8 text (`cloud-config`/`ignition`), base64-encoded by the CAPTF controller like every other bootstrap provider | With `gzipUserData: true`, the decoded payload is raw (non-UTF-8) gzip bytes — still base64-encoded by the CAPTF controller, same as any other payload | n/a | MUST pass `bootstrap_data` to a base64-taking argument, or `base64decode()` it only when the content is known to be UTF-8 (never for a gzipped payload) | none |
| CP bootstrap payload size and secrecy | Init/join payload embeds cluster CA, etcd CA, service-account and front-proxy key material, uncompressed | Init payload embeds four CA key pairs, uncompressed unless `gzipUserData: true` | n/a | MUST gzip the payload or stage it in a secret store with a small stub, and MUST keep key material out of readable instance metadata | none |

## Templates, timing and compatibility

| Requirement | KubeadmControlPlane | RKE2ControlPlane | Cluster module | Machine module | Verified by |
| --- | --- | --- | --- | --- | --- |
| `failure_domains[].control_plane` default | Only entries with `controlPlane == true` are visible to KCP; nil counts as `false` | Same rule for RCP | SHOULD leave the field at its default `true` | n/a | none |
| Control-plane bring-up timing | N replicas ≈ N × (apply + boot + join); joins strictly serialized on the previous Machine's `nodeRef` | Same shape; a join additionally requires ≥1 already-Ready CP Machine (Node with matching `providerID`) | n/a | n/a (informs MHC timeout sizing) | none |
| Control-plane template defaults | Templates SHOULD set `remediation.maxRetry` (e.g. `3`) and a non-zero `retryPeriodSeconds` (defaults are unlimited retries, immediate retry); the control-plane MachineHealthCheck's `InfrastructureReady=False` timeout MUST exceed apply time plus one drift interval (no fixed number specified here) | RCP has its own `remediationStrategy{maxRetry, retryPeriod, minHealthyPeriod}`; no CAPTF-recommended value is given | n/a | n/a | operator |
| Control-plane provider / CAPI compatibility | Built for and tested against CAPI v1.14.2 (this provider's target) | CAPRKE2 v0.25.2 is tested by its own e2e suite only against CAPI core v1.12.11 and v1.13.5; CAPTF runs v1.14.2. Run a compatibility smoke test before relying on RKE2ControlPlane in production | n/a | n/a | none |

## See also

- [`README.md`](README.md) — the shared creation sequence and the
  LB-membership patterns.
- [`kubeadm.md`](kubeadm.md) and [`rke2.md`](rke2.md) — the full
  guidance and citations behind each row above.
- [The module contract](../contract/v1alpha1/README.md) — the
  normative cluster and machine roles both guides build on.
