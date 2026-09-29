# Contributing

This page is for anyone changing CAPTF itself: the repository layout, the
prerequisites, the build/lint/test/verify loop, the conventions the checks
enforce, and running the manager under Tilt.

## Repository layout

| Path | Holds |
| --- | --- |
| `api/` | The `v1alpha1` Go types: its own module in `go.work`, so the CRD types carry no dependency on controller-runtime or the manager. |
| `cmd/manager`, `cmd/runner`, `cmd/tfcapi-lint` | The three binaries. Each has an `app` package with its wiring and an `app/options` or equivalent for flags, so `main.go` stays a thin entry point. |
| `internal/` | Everything the binaries share, one package per concern: `controllers` (one subpackage per reconciled kind — `TerraformClusterTemplate` and `TerraformMachinePoolTemplate` have no controller of their own — plus `shared` for the common reconcile flow and `sweep` for the orphan RBAC sweep), `jobs`, `runner`, `state`, `identity`, `rbac`, `runlease`, `inputs`, `render`, `outputs`, `locks`, `conditions`, `contract`, `hash`, `ownership`, `webhooks`, `lint`, `docsgen`, `feature`, `imageinspect`, `manager`, `metrics`. |
| `config/` | Kustomize bases: `crd`, `rbac`, `webhook`, `manager`, `certmanager`, assembled by `default`; `network-policy` and `prometheus` are separate optional overlays, and `samples` holds example custom resources. |
| `templates/` | The `clusterctl generate` templates and flavors. |
| `modules/` | Reference Terraform/OpenTofu modules: `noop` (with its variants) and `libvirt`. |
| `hack/` | Build and verify tooling: pinned tool installers under `hack/tools`, the `verify-*.sh`/`check-*.sh` scripts `make verify` runs, `hack/godoccheck`, and the `vale` house style under `hack/vale`. |
| `test/fixtures` | Frozen fixtures unit tests read, such as real captured Terraform/OpenTofu state. |

The book itself lives in a separate repository,
[captf-io/docs](https://github.com/captf-io/docs), published at
[https://captf.io/docs/](https://captf.io/docs/); see
[Writing Documentation](documentation.md).

Each Go module (`.` and `api`) is listed in `go.work`. `hack/verify-modules.sh`
(`make verify`) checks that neither carries a `replace` directive and that
both agree on the Kubernetes and controller-runtime versions they share.
Because `api` only exists inside the workspace, `go mod tidy` run from the
repository root does not update its `go.mod`; add or bump one of its
dependencies by editing `api/go.mod`'s `require` block directly, then run
`go mod tidy` inside `api/` with `GOWORK=off`.

## Before you begin

- Go, matching the version `go.work` declares, `make`, `git`, `jq` and `curl`.
- `podman` (the default `CONTAINER_TOOL`) or `docker`, to build images.
- Node.js 22 or later with `npm`, for `make lint-docs-md` and so for
  `make verify`: it installs `markdownlint-cli2` from the lockfile under
  `hack/tools/markdownlint`.
- `python3`, with the `jsonschema` and `PyYAML` packages, for
  `make verify-schemas`, `make verify-metadata`, `make promtool-check`,
  `make promtool-test` and `make release-assets`.

Everything else — `controller-gen`, `kustomize`, `golangci-lint` (plus its
kube-api-linter build), `clusterctl`, `promtool`, `goreleaser`, `goimports`,
`crd-ref-docs`, `mdbook`, `mdbook-mermaid`, `lychee` and `vale` — is a pinned
binary `make` downloads for you.

## The build, lint, test and verify loop

1. Install the pinned tools once: `make tools`. Each lands in
   `hack/tools/bin` as `<name>-<version>`, plus an unversioned symlink;
   bumping a version in the `Makefile` re-downloads it.
2. After changing `api/v1alpha1` or a controller's markers, regenerate the
   deepcopy code and the CRD/RBAC/webhook manifests: `make generate
   manifests`. `make verify-gen` (part of `make verify`) fails if either is
   stale.
3. Format and lint: `make fmt lint`. `fmt` runs `gofmt -s` and `goimports
   -local github.com/captf-io/cluster-api-provider-terraform`; `lint` runs
   `golangci-lint` (`.golangci.yml`) in every module, then kube-api-linter
   (`.golangci-kal.yml`) on `api/` and `tfcapi-lint module --strict` on the
   reference modules under `modules/`. `make lint-fix` reruns both linters
   with their auto-fixers.
4. Run the unit tests: `make test`. See
   [Testing](testing.md) for what it covers and how to run less than
   everything.
5. Before sending a change, run `make verify`: every check listed in
   [Make Targets](../reference/make-targets.md#verify), including that
   generated code and the API reference are current and that
   `make lint-docs-md` and `make lint-docs-prose` are clean. A change that
   touches a generated page needs a `captf-io/docs` checkout too: see
   [Writing Documentation](documentation.md#generated-pages).
6. `make build` compiles every `cmd/*` binary to `bin/`; never to the
   repository root. `make run` builds and runs the
   manager out of cluster against your current `kubeconfig`, for a quick
   check against a real API server.

The full target list, grouped the same way, is in
[Make Targets](../reference/make-targets.md).

## Conventions

- **Commits**: an imperative subject in `<subsystem>: <summary>` form, such
  as `docsgen: render event reasons as prose` or `runner: name the exit
  codes` — check `git log` for the subsystem names already in use.
- **License header**: every hand-written Go file starts with the Apache 2.0
  header the other files in its package carry; `hack/boilerplate.go.txt` is
  the header `controller-gen` writes on `api/v1alpha1/zz_generated.deepcopy.go`.
- **Documentation comments**: `hack/godoccheck` (`make verify-godoc`, part of
  `make verify`) enforces one rule per declaration and one per package,
  everywhere except generated files and `hack/tools`:
  - Every function, method and type has a doc comment starting with its
    name; every interface method and top-level `const` or `var` group
    needs only a doc comment, not one starting with its name.
  - Every named parameter is mentioned by name in that comment. Receivers,
    parameters named `_`, and a `Test`/`Benchmark`/`Fuzz` function's
    conventional `*testing.T`/`*testing.B`/`*testing.F` parameter are exempt.
  - A function or method that returns anything says what it returns, using
    "return", "returns", "returned" or "reports".
  - Every non-generated, non-external-test package has a `doc.go` whose
    package comment is a real overview of at least 400 characters.
- **Generated code**: `zz_generated.deepcopy.go` and the CRD/RBAC/webhook
  manifests come from `make generate manifests`; the book's reference pages
  come from `make docs-gen DOCS_DIR=<path to a captf-io/docs checkout>`
  (see [Writing Documentation](documentation.md#generated-pages)). Never
  hand-edit a generated file: `make verify-gen` fails when the deepcopy
  code or the manifests no longer match their source, and `make verify-docs
  DOCS_DIR=<path>` fails when a generated reference page does.

## Common changes

Each `make docs-gen` below needs `DOCS_DIR=<path to a captf-io/docs
checkout>` (see [Writing Documentation](documentation.md#generated-pages)).

- **Adding a manager flag**: also add it to the `managerFlagGroups` map in
  `internal/docsgen/manager.go`, naming the reference-page heading it
  belongs under. `TestManagerFlagGroups` fails when a flag the manager
  registers has no entry, or an entry names a flag that no longer exists.
  Run `make docs-gen` to regenerate `reference/manager-flags.md`.
- **Adding a condition reason**: condition types, their reasons and each
  reason's doc comment live in `api/v1alpha1/conditions_consts.go`;
  `ConditionReasons` returns the full type-to-reason table, and a reason's
  doc comment becomes its Meaning in the generated reference page. A
  reason is set from `internal/conditions` when it applies across
  controllers, or from `internal/controllers/shared` when it belongs to
  one reconcile flow. Afterward, run `make generate manifests docs-gen` to
  regenerate the CRD schema, the deepcopy code and
  `reference/conditions.md`. Until you do, `internal/docsgen`'s
  `TestConditionKindsComplete`, `TestConditionTypeOrderComplete`,
  `TestReasonMeaning` and `TestGoldenConditions`, plus `make verify-gen`
  and `make test`, fail.

  An event reason follows the same shape: it lives in
  `internal/controllers/shared/events.go`, or `internal/runner`'s
  equivalent for a runner event, with a doc comment that becomes its
  Meaning; `TestManagerEventsComplete` or `TestRunnerEventsComplete`, and
  `TestGoldenEvents`, fail until `make docs-gen` regenerates
  `reference/events.md`. A `tfcapi-lint` check ID in `internal/lint` is the
  same again: its doc comment becomes its description, and
  `TestCheckDescriptionsComplete` fails until `make docs-gen` regenerates
  `reference/tfcapi-lint-cli.md`.

## Tilt

`tilt-provider.yaml` wires this repository into a
[Cluster API](https://cluster-api.sigs.k8s.io/) checkout's Tilt setup: add
`../cluster-api-provider-terraform` to that checkout's `tilt-settings.yaml`
`provider_repos`, and `terraform` to `enable_providers`. Tilt then builds and
live-reloads only the manager binary (from `cmd`, `api`, `internal`,
`go.mod` and `go.sum`) and substitutes its image for
`ghcr.io/captf-io/cluster-api-provider-terraform` in `config/default`.

**Tilt never rebuilds the runner image.** A Job always takes its runner from
`CAPTF_MANAGER_IMAGE`, which Tilt does not rewrite, so it stays whatever
`:dev` image is already loaded in the Tilt cluster. After a change under
`internal/runner` or `cmd/runner`, run `make docker-build` yourself and load
the result into the cluster before a Job needs it. `make verify-tilt-provider`
checks `tilt-provider.yaml` against the tree and `config/default`.

## See also

- [Testing](testing.md)
- [Releasing](releasing.md)
- [Writing Documentation](documentation.md)
- [libvirt Development Host](libvirt-host.md)
