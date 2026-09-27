# Security review – September 2026

**Scope:** `drivers/namron-edge-thermostat` (driver code, profile, fingerprints), `scripts/test.sh`, the GitHub Actions workflow, the repository setup, and the process for publishing to the SmartThings driver channel.
**Reviewed version:** commit `7e48468` (before the first release to any hub).
**Status:** all findings fixed in the pull request that closes issues #1–#6. The repository settings listed under SR-5 have to be changed by the maintainer in GitHub.

## Threat model (short)

| Asset | What could go wrong |
|---|---|
| Heating control in a home | The driver writes the wrong configuration, the heating stops or overheats, or the user sees wrong state |
| Zigbee mesh on the hub | The driver or a misbehaving device floods the network, so other devices stop responding |
| Users' hubs (via the driver channel) | Malicious or broken code is published to every enrolled hub |
| Repository | Unreviewed changes, including ones made by AI agents following instructions hidden in issues or PRs, reach `main` or a release |

Trust boundaries: SmartThings cloud → hub (capability commands, preferences); Zigbee device → hub (attribute reports); GitHub (issues/PRs from anyone) → maintainer or agent → channel.

The Edge sandbox limits what a driver can do. This driver asks only for the `zigbee` permission: no LAN, no internet, and no access to other drivers' devices.

## Findings

| ID | Severity | Title | Issue |
|---|---|---|---|
| SR-1 | **Medium** (safety) | Switching a device to the driver overwrites its configuration with preference defaults, including sensor mode | #1 |
| SR-2 | **Medium** (availability) | Clock-sync requests from the device are answered without limit, which can amplify Zigbee traffic | #2 |
| SR-3 | Low | Values from commands, preferences and the device are not validated | #3 |
| SR-4 | Low | Fingerprints claim an unverified manufacturer string (least privilege) | #4 |
| SR-5 | Low | Repository governance is not ready for AI/community maintenance | #5 |
| SR-6 | Low | Publishing to the driver channel has no defined, traceable release process | #6 |

### SR-1 – Driver switch overwrites the thermostat configuration (Medium)

**What:** `infoChanged` wrote every preference whose value differed from the previous one. On a driver switch, the device moves from the *Zigbee Switch* profile, which has none of these preferences, to this driver's profile. Every preference therefore looked changed, and the driver wrote all the **defaults** to the thermostat. That includes **sensor mode = floor sensor**, as well as the max setpoint, window detection and child lock.

**Impact:** a thermostat regulating on its air sensor would switch to a floor sensor that may not be connected. Depending on the firmware, heating then stops (sensor fault) or regulates on the wrong temperature. This happens silently, on exactly the first step every user takes.

**Fix:** `infoChanged` ignores events where the profile changed, and acts only on real edits by the user.

**Trade-off:** after a switch, the settings page shows defaults that the thermostat isn't necessarily using. Choosing the value that is already shown sends nothing, because SmartThings only reports changes. The READMEs explain how to apply such a value: pick another value, then the one you want.

**Test:** `SR-1: preference defaults are NOT written when the profile changes`. It fails on the old code, which writes attribute 0x8004.

### SR-2 – Unbounded clock-sync writes (Medium)

**What:** every report of attribute 0x800A = true made the driver send 4 Zigbee messages (read + write, twice). The Zigbee2MQTT notes say some firmware rejects writes unless they are done in a particular way. A device that keeps raising the flag, whether faulty, rejecting the write, or spoofed on the mesh, would cause a sustained message storm.

**Fix:** clock syncs triggered by the device are limited to one every 5 minutes. Explicit syncs (configure, or turning the preference on) are still sent immediately. A hub clock that jumps backwards resets the limit, so syncing can't stall.

**Test:** `SR-2: repeated clock sync requests from the device are rate limited`.

### SR-3 – Missing input validation (Low)

**What:**
- Preference writers passed `tonumber(v)` straight to the Zigbee data types. Non-numeric or fractional values raised errors in the handler. Out-of-range values were sent to the device as they were. A boolean arriving as the string `"false"` would have *enabled* child lock.
- Heating setpoint reports were not checked. The ZCL "invalid" value 0x8000 would have shown as −327.68 °C.
- The setpoint command didn't reject non-numbers or NaN.
- `setThermostatMode("auto")`, which generic clients and automations send, was silently ignored.

**Fix:**
- Numeric and enumeration preferences are range-checked (`to_int_in_range`), and switch preferences are type-checked (they must be real booleans). Invalid values are logged and skipped.
- Reported temperatures outside −40…80 °C, and 0x8000, are dropped.
- The setpoint command rejects non-numeric values.
- `auto` maps to the device's schedule mode.

**Tests:** `SR-3: …` (4 tests).

### SR-4 – Unverified fingerprints (Low)

**What:** `fingerprints.yml` also claimed the manufacturer string `NAMRON AS` for all four models. No device with that exact string and these models has been observed; the older Sunricher-based Namron thermostats use it with different models. Claiming devices you haven't verified risks taking over a different device with incompatible attributes.

**Fix:** only `Namron AS` is claimed, which is confirmed on real hardware and in Zigbee2MQTT. New variants are added through the new-device issue template, with evidence.

### SR-5 – Repository governance for AI/community maintenance (Low)

**What:** the repository is meant to be maintained mainly by AI agents and contributors, but:
- nothing required review before merge, and there was no CODEOWNERS file;
- `AGENTS.md` didn't warn agents that issue and PR text is untrusted and may contain prompt injection;
- `SECURITY.md` pointed to private vulnerability reporting, which isn't enabled by default.

**Fix (in repo):**
- Added `CODEOWNERS` (maintainer reviews everything).
- Added an *Untrusted input* section and hard limits to `AGENTS.md`: no new permissions, network access, CI changes or secrets.
- Updated `CONTRIBUTING.md`.

**Fix (maintainer, in GitHub settings):**
1. *Settings → Code security* → enable **Private vulnerability reporting**, **Dependabot alerts** and **Secret scanning**.
2. *Settings → Rules → Rulesets* → new branch ruleset for `main`:
   - require a pull request with 1 approval and **Require review from Code Owners**;
   - require the **test** status check;
   - block force pushes and deletions;
   - add **Repository admin** to the bypass list, set to *For pull requests only*. As the only maintainer you can't approve your own PRs, so this lets you merge your own green PRs. Everyone else, including AI agents working under other accounts, still needs your review.
3. *Settings → Actions → General* → **Workflow permissions: Read repository contents**, and do **not** allow GitHub Actions to approve pull requests.

### SR-6 – Release process for the driver channel (Low)

**What:** anyone who controls the channel owner's Samsung account can publish code to every enrolled hub. Nothing recorded which commit a published driver version came from.

**Fix:** added `RELEASING.md`. It covers two-step verification on the Samsung account, publishing only from a clean, CI-green, tagged `main`, a GitHub release recording the driver version, rolling out to your own hub first, and rollback. Publishing is deliberately **not** automated in CI. Doing so would require storing a SmartThings token as a repository secret, which adds more risk than it removes for a project this size.

## Reviewed and found OK

- **Driver permissions and logging:** the driver has `zigbee` permission only. There are no network calls, no `os.execute`/`io` use, and no secrets in the code. Logs contain only the device label and attribute values.
- **Zigbee message construction:** messages use the SmartThings `cluster_base`/`clusters` helpers. The only hand-built payload is a 1-byte Boolean for commands 0x07/0x08.
- **Polling:** one 15-minute timer per device, created in `init`. It doesn't grow on driver switch or reconfigure.
- **CI workflow:**
  - `permissions: contents: read`;
  - `actions/checkout` pinned to a commit SHA with `persist-credentials: false`;
  - no secrets;
  - pull requests from forks run with a read-only token;
  - Dependabot updates the pinned action.
- **Test harness:**
  - the SmartThings Lua libraries are pinned to one release and verified by SHA-256 before extraction;
  - GNU tar refuses `..` paths;
  - only `*.lua` files are extracted.
