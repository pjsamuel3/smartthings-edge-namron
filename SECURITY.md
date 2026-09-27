# Security

Please report security issues privately through GitHub's **[Report a vulnerability](https://github.com/pjsamuel3/smartthings-edge-namron/security/advisories/new)**, not in a public issue.

Past reviews and their fixes are documented in [docs/security/](docs/security/).

Design principles that PRs are expected to keep:

- Drivers run only on the hub, request only the `zigbee` permission, and make no network calls.
- No credentials, tokens or personal data are stored or logged.
- CI runs with read-only repository permissions. Third-party actions are pinned to a commit SHA, and Dependabot keeps them updated.
- The SmartThings Lua libraries used for testing are pinned to a release and verified by SHA-256 checksum.
- Configuration is only written to a device when the user changes it. Device-triggered actions are rate-limited.
- All changes are reviewed by the code owner, and releases follow [RELEASING.md](RELEASING.md).
