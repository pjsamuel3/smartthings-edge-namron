# Contributing

Contributions are welcome, from people and from AI coding agents. The rules are simple so that the project can run with very little maintainer time.

## Ground rules

1. **Every change needs a green `./scripts/test.sh`.** CI runs it on every pull request, and a PR can only be merged when it passes.
2. **Behaviour changes need a test.** Add or extend a test in `drivers/<driver>/src/test/`.
3. **Use only the standard SmartThings Edge libraries.** No third-party Lua modules, no network access from drivers, and no new driver permissions beyond `zigbee`.
4. **Keep it small.** Prefer the SmartThings default handlers (`st.zigbee.defaults`) over custom code. Change only what the device actually needs.
5. **Cite your source** for device attributes and quirks, for example Zigbee2MQTT, a zigbee-herdsman-converters PR, the Namron manual, or your own logcat output.

## Adding a device that behaves like an existing one

1. Add an entry to that driver's `fingerprints.yml`, using the manufacturer and model shown on the device's page at my.smartthings.com → Advanced.
2. Update the table in the README.
3. Run `./scripts/test.sh` and open a PR.

## Adding a new kind of device

Create `drivers/<new-driver>/` with the same layout as `drivers/namron-edge-thermostat/`. Start from the closest driver in [SmartThingsEdgeDrivers](https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers/tree/main/drivers/SmartThings) rather than writing from scratch.

## Upgrading the SmartThings Lua libraries

Update `LUA_LIBS_TAG`, `LUA_LIBS_ASSET` and `LUA_LIBS_SHA256` at the top of `scripts/test.sh`. Take the values from the new [SmartThingsEdgeDrivers release](https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers/releases), run the tests, and open a PR.

## Reporting a problem

Open an issue with:

- your device model and firmware,
- the driver version,
- what you did and what happened,
- and ideally `smartthings edge:drivers:logcat` output.
