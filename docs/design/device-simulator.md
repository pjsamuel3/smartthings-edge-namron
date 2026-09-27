# Design: simulated Namron thermostat and randomised invariant tests

**Issue:** #12 · **Status:** proposed, awaiting maintainer review · **Date:** 27 Sep 2026

## Why

The existing tests replay fixed message sequences that the author thought of. The first real-hardware bug (#8, energy reported 100x too high) came from an *ordering* the tests never tried: a report arriving before the divisor was read. A stateful simulator driven by random but reproducible sequences finds this class of bug. It also checks the safety rules in `AGENTS.md` on every step, not only in the one test written for each rule.

## Goals and non-goals

Goals:

- Run the real driver (`src/init.lua`) against a simulated device that behaves like the firmware, quirks included.
- Generate random sequences of user commands, preference edits, device events and time passing, reproducible from a seed.
- Check a fixed set of invariants after every step.
- Run inside the existing `./scripts/test.sh` and CI, with no change to either and no new dependencies.

Non-goals:

- Changing driver behaviour. Bugs found get their own issue and PR.
- Modelling the Zigbee radio (routing, retries, join). The simulator works at ZCL level.
- Replaying real captures. That's T6, which will reuse the simulator's message decoding.

## How it fits the test framework

The SmartThings integration test framework replaces the Zigbee and capability sockets with mock channels (`integration_test/mock_generic_channel.lua` in the pinned `apiv21_62` libs). Normally every message the driver sends must match a queued `__expect_send`.

For simulator tests, the test file replaces `send` on the mock channel objects:

- `test.socket.zigbee.send` → decodes the outgoing `ZigbeeMessageTx`, records it, passes it to the simulator, and queues the simulator's replies with `test.socket.zigbee:__queue_receive`.
- `test.socket.capability.send` → records emitted capability events, for the invariant checks.
- The global `report_error` (a no-op in the framework, called when a handler raises) → records the error, so "no handler errors" can be asserted. *Today a handler error does not fail a test at all.*

The overrides are installed in the simulator test's init function and live only in that test file. The framework itself isn't modified. The trade-off is that the tests rely on mock internals. The libs are pinned by checksum, so this only matters when upgrading them. If an upgrade breaks it, the simulator test fails loudly rather than passing silently.

Time uses `test.mock_time.advance_time`, as the existing tests do, so the poll timer, the 2 s read-backs and the clock-sync rate limit all run.

## Files

```
drivers/namron-edge-thermostat/src/test/
  namron_sim.lua                   -- simulator (state, quirks, message decode/encode)
  test_simulated_device.lua        -- randomised runs + invariants (picked up by test.sh)
```

`namron_sim.lua` has no `test_` prefix, so `scripts/test.sh` won't run it as a test on its own. Estimated size: about 300 lines for the simulator and 200 for the tests.

## Simulator

### State

System mode, programming-operation-mode bitmap, frost flag, heating setpoint, local temperature, humidity, running state, the custom configuration attributes (0x8000–0x8029), the clock, cumulative energy (raw), active power, and the scaling attributes (Metering multiplier/divisor and Electrical Measurement multiplier/divisor, each of which a scenario can mark *unsupported*).

### Quirks modelled

Each quirk comes from the Zigbee2MQTT converter or was confirmed on hardware, as noted in the driver README.

| Quirk | Simulator behaviour |
|---|---|
| Custom attributes accept a write only after a read | A write to 0x8000+ without an earlier read of the same attribute returns a failure status and doesn't change state. |
| Writes need a default response | A write whose frame control disables the default response is ignored. |
| Eco/schedule change only via commands 0x07/0x08 | Writes to ProgrammingOperationMode are acknowledged but ignored; commands 0x07/0x08 set or clear bits 2 and 0. |
| Reports follow changes | Every state change queues an attribute report for the changed attribute. |
| Metering divisor 100 | Default scenario: multiplier 1, divisor 100. Energy reports can arrive before the divisor has been read. |
| Clock sync | The device raises 0x800A at random, and clears it once 0x800B is written. |

### Fault injection (per scenario, random)

- Reports duplicated or delayed past later events.
- A read answered with *unsupported attribute* (for example, no Electrical Measurement divisor).
- Invalid values: temperature 0x8000, temperatures outside −40…80 °C, and out-of-range enums.
- A device that keeps re-raising the clock-sync flag.

## Randomised runs

Each run: seed → scenario (fault settings) → driver switch or added → N random steps → invariants checked after every step.

Step types, with rough weights:

- **User (30 %):** `setHeatingSetpoint`, including invalid, NaN, Fahrenheit and out-of-range values; `setThermostatMode`, including `auto` and unsupported modes; `refresh`.
- **Preferences (10 %):** change one preference to a valid or invalid value. The test records which preference the user edited.
- **Device (45 %):** temperature or humidity change, heating on/off, energy increment, power change, a clock-sync request, or a local mode change made on the thermostat's own buttons.
- **Time (15 %):** advance 1 s to 20 min, which fires the poll and the delayed read-backs.

Each failure prints the seed and the step list, so it can be replayed with `SIM_SEED=<n> ./scripts/test.sh`.

**Seeds in CI:** a fixed list of seeds (proposed: 20 seeds × 200 steps, well under 30 s), so CI is deterministic and never flaky. `SIM_SEED` and `SIM_RUNS` environment variables allow longer local soak runs. New seeds that find bugs are added to the fixed list.

## Invariants

Checked after every step:

1. **No handler errors:** nothing reached `report_error`.
2. **No unrequested configuration writes:** a write to a configuration attribute (0x8000, 0x8004, 0x8005, 0x8007, 0x801D, 0x8022, 0x8025, 0x8029, LocalTemperatureCalibration, KeypadLockout) is only allowed in the step where the user changed the matching preference to a valid value. That includes the driver switch step (SR-1).
3. **Setpoint writes are in range:** every OccupiedHeatingSetpoint write is between 500 and `maxHeatTemp × 100` (≤ 3500).
4. **Bounded message rate:**
   - a single device event causes at most *K* outgoing messages;
   - over any 5-minute window with no user action, at most *M* messages go out.
   - *K* and *M* are set from the current driver's worst case plus margin, and recorded in the test.
5. **Energy correctness:**
   - no `energyMeter` event before the simulator has answered the divisor read;
   - every emitted value equals simulator raw ÷ divisor;
   - emitted energy never decreases.
6. **Displayed state matches the device:** after the device's reports have been processed, the last emitted mode, setpoint and temperature match the simulator's state (mode as derived in the README).
7. **Temperatures are plausible:** no emitted temperature or setpoint outside −40…80 °C.

## Already visible from reading the code

The rate invariant is expected to flag one case straight away. If the Metering divisor is **unsupported**, `energy_handler` sends two reads on every energy report, with no limit. Reporting is configured at a minimum of 5 s, so that's up to 24 reads a minute for as long as the device runs. Power already has a fallback after 3 attempts; energy has none. This will be raised as its own issue when the simulator confirms it. The likely fix is to limit the retries without ever guessing the divisor.

## Security and safety

- The simulator is test code only: it adds no driver permissions, dependencies or network access, and nothing in `src/init.lua` changes.
- `scripts/test.sh` and CI are unchanged. The new test file is picked up by the existing `test_*.lua` glob.
- Invariants 2, 3 and 4 turn the `AGENTS.md` safety rules into checks that run on every step, so a future change (human or AI) that breaks them fails CI even if nobody wrote a specific test.

## Decisions for the maintainer

1. **Seeds:** fixed seed list in CI, plus environment variables for local soak runs (proposed). Or a fresh random seed on each CI run: more coverage, but CI can then fail on an unrelated PR.
2. **Mock overrides:** OK to replace `send` on the mock channels and the global `report_error` in this one test file (proposed)? The alternative is proposing a relaxed "record" mode upstream to SmartThingsEdgeDrivers, which is slower and outside our control.
3. **Scope of phase 1:** the `4512783` profile only (proposed), since that's the only model confirmed on hardware.

## Plan after approval

1. PR 1: `namron_sim.lua` plus `test_simulated_device.lua`, with invariants 1–3 and 5–7, and 4 using measured limits.
2. Any invariant failures found become separate issues and fix PRs (starting with the energy-retry case above).
3. Document the simulator in the driver README under "Tests".
