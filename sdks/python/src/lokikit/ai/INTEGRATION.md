# Install, wire, verify, remove

For candidate validation, build from a reviewed immutable repository revision:

```sh
python -m build sdks/python
python -m pip install <exact-local-wheel-file>
```

Use a fresh virtual environment and record the revision, wheel SHA-256 and
resolved dependencies. The version string alone cannot distinguish unpublished
0.1.0 candidates. Publication to PyPI is not part of these commands.

Discover `ai/README.md` with `importlib.resources` as described in the entry.
The [synthetic example](EXAMPLES.md) demonstrates actual public import, client
batching, Bearer wiring and exact payload readback from a loopback test receiver.
It does not contact Loki, Grafana or any production endpoint.

For real integration, inject the approved endpoint/token, allow-list product
event fields before calling `push`, choose batching with the documented
blocking behavior, and close the client during product shutdown. A logging
handler requires the same filtering; do not attach it broadly to an unfiltered
root logger. Verify consent and product-specific data policy separately.

To remove, detach/close handlers, close clients and remove the dependency. The
SDK has no durable queue. Code rollback cannot retract records already sent;
storage/retention changes require separate approval. Test the consumer's own
shutdown, auth rejection and rollback before enabling live transmission.
