# Releasing

This page is for whoever cuts a CAPTF release: what a release consists of,
the checklist, and installing the assets before or instead of publishing
them.

A release is a tag `vX.Y.Z` (or `vX.Y.Z-rc.N`) on a clean `main`, the
manager image `ghcr.io/scrothers/cluster-api-provider-terraform:vX.Y.Z`, the
noop example images, and a GitHub release with the clusterctl assets and the
`tfcapi-lint` binaries. Tags never move and nothing is force-pushed: a bad
release candidate gets a new `-rc.N`.

## Before you begin

- Write access to push a signed tag and create a GitHub release.
- Registry push access for `ghcr.io/scrothers/cluster-api-provider-terraform`.
- `gh` authenticated against this repository, for `make release-github`.
- `skopeo`, for `make release` to read the pushed image's registry digest.

## Assets

| Asset | Built by |
| --- | --- |
| `infrastructure-components.yaml` | `make manifests-release`: `config/default` with the release image, and `CAPTF_MANAGER_IMAGE` set to the same image. |
| `metadata.yaml` | The repository root file; `hack/check-metadata.sh` enforces an append-only `releaseSeries`. |
| `cluster-template.yaml`, `cluster-template-clusterclass.yaml`, `clusterclass-noop.yaml`, `cluster-template-libvirt.yaml`, `identity.yaml`, `identity-libvirt.yaml` | [`templates/`](https://github.com/scrothers/cluster-api-provider-terraform/blob/main/templates/README.md). |
| `tfcapi-lint-<os>-<arch>`, `tfcapi-lint-checksums.txt` | GoReleaser; see [tfcapi-lint](../module-author/tfcapi-lint.md). |

The libvirt flavor's own module images (below) are not a release asset: they
are a development-host target, never published as part of `make release`.

## libvirt module images

The libvirt flavor (`templates/cluster-template-libvirt.yaml`) defaults
`TERRAFORM_CLUSTER_IMAGE` and `TERRAFORM_MACHINE_IMAGE` to
`ghcr.io/scrothers/cluster-api-provider-terraform/libvirt-{cluster,machine}`,
tagged `v0.1.0-opentofu`. Those images are built with `make libvirt-images`
and pushed with `make libvirt-images-push VERSION=v0.1.0` (tags and pushes
`$(NOOP_REGISTRY)/libvirt-<role>:$(VERSION)-opentofu` for each module under
`modules/libvirt`, mirroring `noop-images-push`). This is a manual step, run
from the development host with registry access. It is not part of `make
release` and has no fixed cadence tied to a provider release: repeat it
whenever `modules/libvirt/*` changes, using a `VERSION` that matches the tag
the template defaults reference (or override
`TERRAFORM_CLUSTER_IMAGE`/`TERRAFORM_MACHINE_IMAGE` at `clusterctl generate`
time to point at a different tag).

## Checklist

1. If this release starts a new minor series, append it to `metadata.yaml`
   `releaseSeries`. Never remove or change an existing series.
2. Update the
   [contract changelog](../module-author/contract/v1alpha1/CHANGELOG.md) for
   anything that changes what a module sees or must implement, and
   [Upgrades](../operator-guide/upgrades.md) for anything an operator needs
   to do when moving to this release. Run `make docs-gen DOCS_DIR=<path to
   a captf-io/docs checkout>` so the generated reference pages ([Writing
   Documentation](documentation.md#generated-pages)) match the code going
   into the release, then commit and push the result in that checkout too.
3. `make lint test verify` is green. `verify` includes
   `verify-local-repository`, which generates the provider and the default,
   clusterclass and libvirt flavors from a clusterctl local repository of
   the release assets, offline.
4. Tag and push the tag: `git tag -s vX.Y.Z && git push origin vX.Y.Z`.
5. Build and push the images and build the assets:

   ```sh
   make release VERSION=vX.Y.Z
   ```

   `release-preflight` refuses a dirty tree, an untagged HEAD, a malformed
   version, or a metadata change that is not append-only. The assets land
   in `out/release/`.
6. Smoke-test from a local repository against a real cluster. There is no
   automated end-to-end test; do this step by hand.
7. Publish: `make release-github VERSION=vX.Y.Z` writes
   `out/release/notes.md` from the commits since the previous tag and runs
   `gh release create` with every asset.

## Installing from a local repository

To try the assets before publishing, or offline, copy `out/release/*` to
`~/local-repository/infrastructure-terraform/vX.Y.Z/`: the directory name
is the provider label `infrastructure-terraform`. Point a `clusterctl`
config's `url` at the local path instead of a release URL (see
[Register the provider](../operator-guide/installation.md#register-the-provider)
for the rest of the config entry):

```yaml
url: file:///home/<you>/local-repository/infrastructure-terraform/vX.Y.Z/infrastructure-components.yaml
```

`<you>` is your username on this machine; a `file://` URL needs the
absolute path, so `~` does not work here. Pin the version at install time:

```sh
clusterctl init --config clusterctl.yaml --infrastructure terraform:vX.Y.Z
```

`hack/verify-local-repository.sh` does the same layout in a temp directory
and runs `clusterctl generate provider` and `generate cluster` (the
default, clusterclass and libvirt flavors) against it.

## See also

- [Writing Documentation](documentation.md#checks) for the book's own build
  and verification commands.
- [Contributing](contributing.md) for the general build/lint/test/verify
  loop.
- [libvirt Development Host](libvirt-host.md) for building and pushing the
  libvirt module images from the development host.
