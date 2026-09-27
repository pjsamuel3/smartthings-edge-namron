# Namron Edge Thermostat

A driver for the Namron Zigbee Edge Termostat (models 4512783, 4512784, 4566702 and 4566703; manufacturer `Namron AS`).

Without this driver, SmartThings pairs these thermostats as *Zigbee Switch*, which offers on/off and power only. That happens because SmartThings' generic thermostat driver requires the Temperature Measurement cluster (0x0402), and the Namron reports temperature in the Thermostat cluster (0x0201) instead.

## In the app

| Shown | Zigbee source |
|---|---|
| Temperature | Thermostat › LocalTemperature |
| Heating setpoint (5–35 °C, 0.5 steps; the upper limit follows the *Maximum setpoint* setting) | Thermostat › OccupiedHeatingSetpoint |
| Mode: off / heat / eco / schedule / frostguard | SystemMode + ProgrammingOperationMode + custom 0x8001 |
| Heating / idle | Thermostat › RunningState |
| Humidity | Relative Humidity cluster |
| Power (W), energy (kWh) | Electrical Measurement, Metering |

**Settings:** sensor mode, temperature calibration, child lock, open-window detection, display brightness, display timeout, regulator %, maximum setpoint, clock sync from the hub, and time zone.

A setting is only sent to the thermostat when you change it. The settings page can't show what the thermostat is set to right now. When you switch an existing device to this driver, **no settings are sent**, so the thermostat keeps its current configuration until you change something. To apply a value the page already shows (for example *Floor sensor*), select a different value, then the one you want.

## Device notes

These come from the Zigbee2MQTT converter (`zigbee-herdsman-converters/src/devices/namron.ts`, PR #13145):

- The custom attributes are 0x8000–0x8029 on the Thermostat cluster, with no manufacturer code.
- Every custom write is sent after a read, because the firmware rejects the write otherwise.
- Writes ask for a default response, because the firmware returns NOT_AUTHORIZED without one.
- Eco and schedule use the thermostat's own commands 0x08 (setEco) and 0x07 (setProgram). Writing the ProgrammingOperationMode value directly is ignored.
- Clock: attribute 0x800B is seconds since 2000-01-01 in **local standard time**. The thermostat has no time zone of its own, and adds the summer hour itself when *Auto Daylight Saving* is on in its Time menu. Confirmed on a 4512783: sending UTC showed UTC+1 in summer (#19). The driver sends UTC plus the *Time zone* setting (standard time, default +1 for Norway, Sweden and Denmark). Leave *Auto Daylight Saving* on; if you turn it off, include summer time in the setting. The driver answers the device's sync request (0x800A) at most once every 5 minutes, and syncs straight away when the setting changes.
- The value read back from 0x800B is the last sync time, not a running clock.
- Temperatures reported outside −40…80 °C, and the ZCL "invalid" value 0x8000, are ignored.
- The generic `auto` thermostat mode maps to the thermostat's weekly schedule.
- Energy uses the Metering divisor (100 on firmware seen so far: raw 15668 = 156.68 kWh). The driver doesn't report energy until the divisor is known, because a wrong cumulative value can't be taken back. While it's unknown, the driver asks for it at most once every 5 minutes. Power waits for the Electrical Measurement divisor the same way, but falls back to raw watts after 3 reports.
- The temperature always comes from whichever sensor is active. The thermostat doesn't report separate readings per sensor.

## Tests

`./scripts/test.sh` runs two test files:

- `src/test/test_namron_edge_thermostat.lua`: fixed message sequences, one per behaviour or regression.
- `src/test/test_simulated_device.lua`: randomised runs against a simulated thermostat (`src/test/namron_sim.lua`) that models the firmware quirks above. After every step it checks safety invariants: no unrequested writes, setpoint range, message rate, energy scaling, and displayed state matching the device. CI runs 20 fixed seeds of 200 steps each.
  - A failure prints the seed and the last steps. Replay it with `SIM_SEED=<seed> ./scripts/test.sh`.
  - Longer local soak runs: `SIM_RUNS=250 SIM_SEED_BASE=5000 ./scripts/test.sh`, and `SIM_STEPS` changes the run length.
  - When a new seed finds a bug, fix it in its own PR with a regular regression test.
  - Design: [docs/design/device-simulator.md](../../docs/design/device-simulator.md).

## Not implemented yet

Vacation mode, the countdown timer, and showing open-window status in the app. These would need custom capabilities.
