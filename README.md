# smartthings-edge-namron

[![Test](https://github.com/pjsamuel3/smartthings-edge-namron/actions/workflows/test.yml/badge.svg)](https://github.com/pjsamuel3/smartthings-edge-namron/actions/workflows/test.yml)

Community SmartThings Edge drivers for Namron Zigbee devices.

The drivers run locally on your SmartThings hub. They need no cloud services or third-party servers, and they use only the standard SmartThings Edge libraries.

## Supported devices

| Driver | Devices | What you get |
|---|---|---|
| [Namron Edge Thermostat](drivers/namron-edge-thermostat/) | Namron Zigbee Edge Termostat 4512783, 4512784, 4566702, 4566703 | Temperature, heating setpoint, modes (off/heat/eco/schedule/frost guard), heating/idle, power, energy, humidity, and device settings (sensor mode, child lock, window detection…) |

Is your Namron device missing? See [Contributing](CONTRIBUTING.md). Most devices only need a fingerprint and a test.

## Install

### Option A – from a driver channel (no tools needed)

1. Open the channel invite link: **_(link will be added here once the channel is published)_**
2. Sign in with your Samsung account, **Enroll** your hub, then **Available Drivers → Install** the driver.
3. In the SmartThings app, open the device, then tap **⋮ → Driver → Select a different driver** and choose **Namron Edge Thermostat**.
   New devices you pair after installing the driver will use it automatically.
4. Open the device's **⋮ → Settings** and set **Sensor mode** to match your installation (for example *Floor sensor* for floor heating).

### Option B – build and install it yourself with the SmartThings CLI

Requires the [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli). On macOS: `brew install smartthingscommunity/smartthings/smartthings`. The first command opens a browser to sign in.

```bash
git clone https://github.com/pjsamuel3/smartthings-edge-namron.git
cd smartthings-edge-namron

smartthings edge:drivers:package drivers/namron-edge-thermostat   # build + upload, prints the driver ID
smartthings edge:channels:create                                  # once: create your own channel
smartthings edge:channels:assign                                  # publish the driver to the channel
smartthings edge:channels:enroll                                  # once: enrol your hub in the channel
smartthings edge:drivers:install                                  # install the driver on the hub
smartthings edge:drivers:switch                                   # move an existing device to this driver
```

To update later, pull the latest code and run `package` and `assign` again. The hub picks up the new version within about 12 hours. To get it immediately, run `edge:drivers:install` again.

## Testing on real hardware

1. Switch **one** device to the driver first.
2. Watch the live logs while you change the setpoint, the mode and the settings in the app:
   ```bash
   smartthings edge:drivers:logcat --hub-address <hub-ip>
   ```
3. Check that the thermostat's own display follows each change, and that temperature, power and energy update in the app. The driver also checks the device every 15 minutes.
4. If something is wrong, [open an issue](https://github.com/pjsamuel3/smartthings-edge-namron/issues) and include the logcat output. To go back, switch the device back to its previous driver (for example *Zigbee Switch*).

## Running the automated tests

The tests use SmartThings' own integration test framework. It simulates the hub and the Zigbee device, so no hardware is needed. The same script runs on every push and pull request in GitHub Actions.

Requirements: Lua 5.3, plus `luacheck` for linting (optional locally).

```bash
# Ubuntu/Debian
sudo apt-get install lua5.3 lua-check
# macOS
brew install lua@5.3 luarocks && luarocks --lua-version=5.3 install luacheck

./scripts/test.sh
```

On first run, the script downloads a pinned release of the SmartThings Lua libraries and verifies it against a SHA-256 checksum. It then runs `luacheck` and every `drivers/*/src/test/test_*.lua` file. It exits non-zero if anything fails.

If `lua5.3` has a different name on your system, run for example `LUA=lua ./scripts/test.sh`.

## Repository layout

```
drivers/<driver-name>/     one folder per Edge driver (same layout as SmartThings' official repo)
  config.yml               driver name and permissions
  fingerprints.yml         which devices the driver claims
  profiles/                capabilities and settings shown in the app
  src/init.lua             driver code
  src/test/                integration tests
scripts/test.sh            lint + tests (used locally and in CI)
```

## Credits and licence

- Device attribute map and firmware quirks: the [Zigbee2MQTT](https://www.zigbee2mqtt.io/) / zigbee-herdsman-converters contributors.
- Licensed under [Apache-2.0](LICENSE), the same licence as SmartThings' own drivers, so the code can be contributed upstream.
- Not affiliated with Namron or Samsung SmartThings.
