# Summary

[Introduction](introduction.md)

# Getting Started

- [Quick Start](getting-started/quick-start.md)
- [Your First Module](getting-started/first-module.md)

# Concepts

- [Architecture](concepts/architecture.md)
- [The Kinds](concepts/kinds.md)
- [The Reconcile Lifecycle](concepts/lifecycle.md)
- [Job Inputs](concepts/inputs.md)
- [Terraform State](concepts/state.md)
- [Drift and Health](concepts/drift-and-health.md)
- [Security Model](concepts/security-model.md)

# User Guide

- [Identities and Credentials](user-guide/identities.md)
- [Module Variables](user-guide/variables.md)
- [Templates and ClusterClass](user-guide/clusterclass.md)
- [Machine Pools](user-guide/machine-pools.md)
- [Plan Approval](user-guide/plan-approval.md)
- [Drift](user-guide/drift.md)
- [Machine Remediation](user-guide/remediation.md)
- [Tuning Jobs](user-guide/job-tuning.md)

# Module Authors

- [Module Contract](module-author/contract/README.md)
  - [v1alpha1](module-author/contract/v1alpha1/README.md)
    - [Common](module-author/contract/v1alpha1/common.md)
    - [Cluster Role](module-author/contract/v1alpha1/cluster.md)
    - [Machine Role](module-author/contract/v1alpha1/machine.md)
    - [MachinePool Role](module-author/contract/v1alpha1/machinepool.md)
    - [Changelog](module-author/contract/v1alpha1/CHANGELOG.md)
- [Image Contract](module-author/image-contract.md)
- [Runtime Environment](module-author/runtime-environment.md)
- [tfcapi-lint](module-author/tfcapi-lint.md)
- [Control-Plane Integration](module-author/control-planes/README.md)
  - [KubeadmControlPlane](module-author/control-planes/kubeadm.md)
  - [RKE2ControlPlane](module-author/control-planes/rke2.md)
  - [Requirements Checklist](module-author/control-planes/checklist.md)

# Operator Guide

- [Installation](operator-guide/installation.md)
- [Configuration](operator-guide/configuration.md)
- [RBAC](operator-guide/rbac.md)
- [Secrets](operator-guide/secrets.md)
- [Observability](operator-guide/observability.md)
- [Upgrades](operator-guide/upgrades.md)
- [Runbooks](operator-guide/runbooks/README.md)
  - [Failing Jobs](operator-guide/runbooks/job-failures.md)
  - [Stuck Destroy](operator-guide/runbooks/stuck-destroy.md)
  - [Unreadable State](operator-guide/runbooks/state-unreadable.md)
  - [State Restore](operator-guide/runbooks/state-restore.md)
  - [Stale State Lock](operator-guide/runbooks/stale-lock.md)
  - [Size Limits](operator-guide/runbooks/size-limits.md)
  - [Slow Jobs](operator-guide/runbooks/slow-jobs.md)
  - [Reconcile Errors](operator-guide/runbooks/reconcile-errors.md)
  - [Identities and Credentials](operator-guide/runbooks/identity-and-credentials.md)
  - [Webhook Unavailable](operator-guide/runbooks/webhook-unavailable.md)
  - [clusterctl move](operator-guide/runbooks/move.md)

# Reference

- [API Reference](reference/api.md)
- [Conditions](reference/conditions.md)
- [Events](reference/events.md)
- [Alerts](reference/alerts.md)
- [Metrics](reference/metrics.md)
- [Manager Flags](reference/manager-flags.md)
- [Runner CLI](reference/runner-cli.md)
- [tfcapi-lint CLI](reference/tfcapi-lint-cli.md)
- [Job Environment](reference/environment.md)
- [Annotations, Labels and Finalizers](reference/annotations-labels.md)
- [clusterctl Variables](reference/clusterctl-variables.md)
- [Make Targets](reference/make-targets.md)
- [Glossary](reference/glossary.md)
- [Third-Party Licenses](reference/third-party-licenses.md)

# Developer Guide

- [Contributing](developer-guide/contributing.md)
- [Testing](developer-guide/testing.md)
- [Writing Documentation](developer-guide/documentation.md)
- [Releasing](developer-guide/releasing.md)
- [libvirt Development Host](developer-guide/libvirt-host.md)
