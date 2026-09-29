# CAPTF docs

This repository holds the documentation book for
[cluster-api-provider-terraform][captf], published at
[https://captf.io/docs/][site].

[captf]: https://github.com/captf-io/cluster-api-provider-terraform
[site]: https://captf.io/docs/

## Building

- `make serve` renders the book at <http://localhost:3001> and rebuilds on
  change.
- `make verify` builds the book, checks its links, and lints Markdown and
  prose; it is what CI runs.

## Generated pages

The pages under `src/reference/` and the schemas under
`src/module-author/contract/v1alpha1/schemas/*.json` are generated from the
provider repository and must not be hand-edited. Regenerate them from a
checkout of the provider repository with:

```console
make docs-gen DOCS_DIR=<path to this checkout>
```
