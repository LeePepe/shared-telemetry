# Integration

Build a reviewed immutable source revision, then run `npm pack` in `sdks/web`.
Install that exact tarball in a separate consumer and retain the lockfile
integrity plus source SHA. Do not treat the shared `0.1.0` candidate version
string as sufficient to distinguish different unpublished tarballs. This
package stays `private: true`; no npm-registry publication is authorized.

The [executable fixture](EXAMPLES.md) imports the installed ESM API and type
checks its public declarations. A separate smoke check covers CommonJS exports.
For product wiring, inject an approved endpoint/token, filter fields before
calling `track/log`, and await an explicit flush attempt before calling
`shutdown` when lifecycle permits. Bearer authentication requires receiver-
specific integration tests; neither Beacon nor fetch completion proves storage.

Prefer `storage: "memory"` in tests. `auto` may mutate origin localStorage and
restore old events; do not test against real browser profiles. There is no
per-client storage namespace configuration in this version.

To remove, stop producers, call shutdown, remove the dependency and dispose of
any remaining persisted queue only under consumer-approved data policy. Do not
delete origin storage broadly. Consumer pin rollback cannot retract sent data.
