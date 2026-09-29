# tfcapi-lint

`tfcapi-lint` checks a Terraform or OpenTofu module, and the OCI image built
from it, against the CAPTF module contract
([module contract](contract/README.md)) and the
[image contract](image-contract.md), without running `init`, `plan` or
`apply`. It is for module authors, and for CI pipelines that build module
images. It is released alongside the provider, with the same version.

## Install

Every release attaches one binary per platform, plus a checksum file:

| Asset | Platform |
| --- | --- |
| `tfcapi-lint-linux-amd64` | Linux x86-64 |
| `tfcapi-lint-linux-arm64` | Linux ARM64 |
| `tfcapi-lint-darwin-amd64` | macOS Intel |
| `tfcapi-lint-darwin-arm64` | macOS Apple silicon |
| `tfcapi-lint-windows-amd64.exe` | Windows x86-64 |
| `tfcapi-lint-checksums.txt` | SHA-256 of every asset above |

```sh
base="https://github.com/captf-io/cluster-api-provider-terraform/releases/download/<version>"
curl -fsSLO "${base}/tfcapi-lint-<os>-<arch>"
curl -fsSLO "${base}/tfcapi-lint-checksums.txt"
sha256sum --check --ignore-missing tfcapi-lint-checksums.txt
install -m 0755 "tfcapi-lint-<os>-<arch>" /usr/local/bin/tfcapi-lint
tfcapi-lint version
```

- `<version>` is the provider release you deploy, for example `v0.1.0`.
- `<os>` and `<arch>` pick one row of the table above, for example
  `linux` and `amd64`. On macOS, verify the checksum with
  `shasum -a 256 -c --ignore-missing tfcapi-lint-checksums.txt` instead.

Match the `tfcapi-lint` release to the controller you deploy against:
`tfcapi-lint version --json` reports the contract versions it lints
against, `["v1alpha1"]`.

`go install .../cmd/tfcapi-lint@<version>` does not work: the repository is
a Go workspace, and `cmd/tfcapi-lint` depends on the `api` module, which
only the workspace resolves. Build from source instead (below), or use a
release binary.

## Roles

Every module implements exactly one role, and `--role` on `module` and
`image` is required and takes one of `cluster`, `machine` or
`machinepool`, matching the [`TerraformCluster`](../concepts/kinds.md),
[`TerraformMachine`](../concepts/kinds.md) and
[`TerraformMachinePool`](../concepts/kinds.md) contracts. `tfcapi-lint`
checks the module or image against that role's inputs, outputs and checks
only; see [tfcapi-lint CLI](../reference/tfcapi-lint-cli.md#checks) for
which checks apply to which roles.

## Lint a module

```sh
tfcapi-lint module --role machine ./machine
```

This reads the `.tf`, `.tf.json`, `.tofu` and `.tofu.json` files under
`./machine` directly; it needs neither `terraform` nor `tofu` installed,
and never contacts a registry. A clean module prints an empty finding
list and an all-zero summary.

## Lint an image

```sh
tfcapi-lint image --role machine registry.example.com/acme/machine:v1.0.0
```

This pulls the image manifest and its layers, and checks the fixed paths
and labels the [image contract](image-contract.md) requires, without
running the image. `<image-ref>` is a registry reference; `oci:<dir>`
reads a local OCI image layout instead, such as one written by
`podman save --format oci-dir` or `skopeo copy ... oci:<dir>`, with no
registry or daemon involved. By default it checks the `linux/amd64`
platform of a multi-platform image; `--platform os/arch` picks a
different one, and `--all-platforms` checks every platform the image
publishes.

### Registry credentials

`tfcapi-lint image` authenticates the same way `docker` and `podman` do,
through go-containerregistry's default keychain: it reads
`~/.docker/config.json`, or `$DOCKER_CONFIG/config.json` when that
variable is set; if neither exists, it falls back to a Podman-style
config at `$REGISTRY_AUTH_FILE` or
`$XDG_RUNTIME_DIR/containers/auth.json`. With none of those present, the
pull is anonymous. Log in with `docker login` or `podman login` against
the registry before linting a private image; `--insecure` allows a
plain-HTTP registry for a local or air-gapped registry that has none.

## Strict mode and allowed warnings

`--strict` treats a warning the same as an error for the exit code, so a
module or image that is merely clean today does not silently pick up new
warnings later. `--allow-warning <id>` (repeatable, or a comma-separated
list) downgrades one check ID's warnings to informational findings; it
never touches errors. Use it for a deliberate, reviewable exception, for
example a module whose provider cannot tag anything:
`--allow-warning input/tags-unused`. Run with `--strict` by default, and
add `--allow-warning` only for checks you have decided not to act on.

`--json` prints a report with a `findings` array (`id`, `severity`,
`file`, `line`, `message`) and a `summary`, instead of one line of text
per finding. See [tfcapi-lint CLI](../reference/tfcapi-lint-cli.md) for
every flag, and
[tfcapi-lint CLI: checks](../reference/tfcapi-lint-cli.md#checks) for
every check ID, its severity and the roles it applies to.

## Exit codes

`tfcapi-lint` uses its exit code to signal a CI step's pass or fail; see
[tfcapi-lint CLI: exit codes](../reference/tfcapi-lint-cli.md#exit-codes)
for the full list. In short: `0` is clean, `1` is at least one error (or,
under `--strict`, at least one warning), `2` means the module could not
be parsed or the image could not be pulled, and `3` is a usage error.

## In CI

Lint the module before building the image, then lint the built image
before pushing it: the source is checked before the build, and the built
layout after it.

```sh
tfcapi-lint module --role machine --strict ./module
podman build -t "$IMAGE" .
podman save --format oci-dir -o "$RUNNER_TEMP/image" "$IMAGE"
tfcapi-lint image --role machine --strict "oci:$RUNNER_TEMP/image"
podman push "$IMAGE"
```

To check exactly what was pushed, for example a multi-platform index
built and pushed by a separate step, lint the pushed reference instead of
the local layout:

```sh
tfcapi-lint image --role machine --strict --all-platforms "$IMAGE"
```

## Building from source

`make release-lint-snapshot` builds all five release assets and the
checksum file into `dist/` with GoReleaser, stamped with a snapshot
version; `make release-lint` does the same from the current git tag.
See [Releasing](../developer-guide/releasing.md) for how these assets
reach a GitHub release.

## See also

- [tfcapi-lint CLI](../reference/tfcapi-lint-cli.md) for every flag, every
  check ID and the exit codes.
- [Module contract](contract/README.md) and
  [image contract](image-contract.md) for what the checks enforce.
- [Runtime environment](runtime-environment.md) for what a module sees
  once CAPTF actually runs it.
