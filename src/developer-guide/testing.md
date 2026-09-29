# Testing

This page describes CAPTF's test suite: what `make test` runs, what its
tiers mean here, golden files, and running less than the whole suite.

## Running the tests

`make test` runs `go test -race -count=1 ./...` in every module (`.` and
`api`). That is the entire suite, and it is all unit tests: nothing it runs
creates a Kubernetes cluster, calls a real cloud API, or invokes `terraform`
or `tofu`.

- Controllers and webhooks run against the controller-runtime fake client,
  never a real API server; there is no [envtest](https://book.kubebuilder.io/reference/envtest)
  in this repository.
- Job execution is faked the same way: a reconciler test asserts on the
  `batch/v1.Job` CAPTF would create, and a runner test drives the runner's
  own logic directly, without a pod ever starting.
- `internal/state`, `internal/outputs` and `internal/locks` instead read
  real `kubernetes`-backend state: [`test/fixtures/state`](https://github.com/captf-io/cluster-api-provider-terraform/blob/main/test/fixtures/state/README.md)
  holds state Secrets and lock Leases captured once from real Terraform and
  OpenTofu runs, checked in as frozen data. Regenerating them needs a
  capture setup that does not exist in this repository; treat the files
  under `test/fixtures/state` as read-only.
- `go test ./templates/` decodes every shipped `templates/*.yaml` object
  strictly into its API type and checks the values `hack/verify-templates.sh`
  renders; it also runs CAPI's own `ClusterClass` admission webhook and
  topology generator, applying the class patches, against
  `clusterclass-noop.yaml`.

## Test tiers, and what does not exist yet

CAPTF does not have a separate "integration" build tag or `make` target.
Everything that would fall under that name — a reconciler driven through
several packages at once, still against the fake client — runs as an
ordinary unit test under `make test`, alongside the narrower ones; for
example, `internal/controllers/shared`'s `TestBringUpJobCount` reconciles a
whole cluster bring-up against the fake client and asserts the resulting
Job count.

**End-to-end** — provisioning a real cluster on real infrastructure — does
not exist yet. The closest things to it are checks that run outside `go
test`, still without a real cloud:

- `make test-libvirt-modules` runs each `modules/libvirt/*` module's own
  `tofu test` against a mocked provider.
- `make verify-noop-modules` stages every no-op module and variant, runs
  `terraform`/`tofu init` and `validate` against it, and lints it with
  `tfcapi-lint module --strict`; it needs those binaries on `PATH` and is
  not part of `make verify`.
- `make verify-local-repository` (part of `make verify`) runs `clusterctl
  generate provider` and `generate cluster` against a local repository of
  the release assets, offline.

A release's smoke test against a real management cluster is done by hand;
see [Releasing](releasing.md).

Two shell scripts, `hack/docs-check_test.sh` and `hack/check-metadata_test.sh`,
test the `hack/docs-check.sh` and `hack/check-metadata.sh` checks themselves
against fixtures under `hack/testdata`. They are not part of `make test`;
`make docs-check` and `make verify-metadata` run them automatically, before
the check itself, as part of `make verify`.

## Golden files

Several packages pin an exact rendered output as a checked-in file and
compare against it on every run, rather than asserting field by field:

| Package | What it pins |
| --- | --- |
| `internal/contract` | The rendered JSON of fully populated contract inputs. |
| `internal/jobs` | The `batch/v1.Job` of every operation, as YAML. |
| `internal/outputs` | Rendered output fixtures. |
| `internal/render` | The generated root module. |
| `internal/docsgen`, `internal/metrics` | The generated reference pages in a `captf-io/docs` checkout (see [Writing Documentation](documentation.md#generated-pages)). |
| `cmd/tfcapi-lint` | Its `--json` output. |

Run the affected test with `UPDATE_SNAPSHOTS=1` to rewrite its golden files,
then read the diff before committing it — a passing rewrite is not the same
as a correct one. `internal/docsgen`'s and `internal/metrics`'s golden
tests need `DOCS_DIR` (an absolute path to a `captf-io/docs` checkout) and
skip without it; `make docs-gen DOCS_DIR=<path>` does exactly this for the
generated reference pages: `DOCS_DIR=<path> UPDATE_SNAPSHOTS=1 go test
./internal/docsgen/... ./internal/metrics/... -run 'Docs|Golden'`.

## Running one package, or one test

```sh
go test -race ./internal/jobs/...
go test -race -run TestGoldenJobs ./internal/jobs/...
UPDATE_SNAPSHOTS=1 go test ./internal/jobs/... -run TestGoldenJobs
```

`go.work` makes the `api` module's tests reachable from the repository
root too: `go test ./api/...` needs no `cd`.

## Coverage

There is no `make` target for it and no enforced threshold. Build a profile
and view it with the standard toolchain:

```sh
mkdir -p bin
go test -race -coverprofile=bin/cover.out ./...
go tool cover -html=bin/cover.out -o bin/cover.html
```

## See also

- [Contributing](contributing.md)
- [Writing Documentation](documentation.md)
- [Releasing](releasing.md)
