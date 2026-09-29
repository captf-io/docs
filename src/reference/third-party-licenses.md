# Third-party licenses

CAPTF is Apache-2.0. The modules below are linked into `tfcapi-lint`, and
this file lists those whose license is not Apache-2.0. The full dependency
set is in `go.mod`; a license check over the full set is not yet
automated.

| Module | Version | License | Used for |
| --- | --- | --- | --- |
| `github.com/hashicorp/terraform-config-inspect` | `v0.0.0-20260904064934-75d64de68c31` | MPL-2.0 | `tfcapi-lint` reads a module's variables and outputs without running Terraform |
| `github.com/hashicorp/hcl/v2` | `v2.20.1` | MPL-2.0 | the second lint pass: `backend`/`cloud` blocks, provider attributes, `.tofu` files, expressions |
| `github.com/hashicorp/hcl` | `v0.0.0-20170504190234-a4b07c25de5f` | MPL-2.0 | legacy HCL parser required by terraform-config-inspect |
| `github.com/zclconf/go-cty` | `v1.14.4` | MIT | HCL's type and value system (the lint pass reads literal values with it) |
| `github.com/mitchellh/go-wordwrap` | `v1.0.0` | MIT | diagnostic formatting in HCL |

## MPL-2.0

MPL-2.0 is file-level copyleft. An Apache-2.0 binary may link unmodified
MPL-2.0 code (MPL-2.0 section 3.3, "Distribution of a Larger Work"),
provided the MPL-covered source stays available: these modules are
published, and CAPTF does not modify them.

The combination would not be permitted for a file carrying Exhibit B, the
"Incompatible With Secondary Licenses" notice. `hack/check-licenses.sh`
(part of `make verify`) checks the three MPL modules at their pinned
versions: the phrase must appear only in their `LICENSE` files, as the
license's own definitions (sections 1.5, 3.3 and 10.4), and in no source
file. It last passed on 2026-09-26. This remains subject to license review
before a release.
