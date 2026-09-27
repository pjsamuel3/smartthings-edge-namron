# Notes for AI coding agents

This repository is meant to be maintained mostly by AI agents and community contributors. Before opening a PR:

- Read `CONTRIBUTING.md` and follow its ground rules. The most important one is that `./scripts/test.sh` must pass.
- Each driver in `drivers/<name>/` is self-contained. Don't share code between drivers unless it is duplicated in three or more places.
- Handlers take `(driver, device, value, zb_rx)`. Build all Zigbee messages with `st.zigbee` helpers (`cluster_base`, `clusters.*`). Don't hand-craft bytes except for device-specific commands, and document those in the driver README.
- Device quirks live in the driver's `README.md` under "Device notes". Update it whenever you learn one.
- Don't add capabilities, permissions or dependencies that the device doesn't need. Keep diffs minimal and focused.
- Tests use the SmartThings integration test framework. See the existing tests for message and coroutine test patterns, and for how `test.mock_time` is used.
