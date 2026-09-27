-- Randomised tests against a simulated thermostat (see docs/design/device-simulator.md).
--
-- Each run drives the real driver with a reproducible random sequence of user commands,
-- preference edits, device events and time passing, against namron_sim.lua, and checks
-- the invariants below after every step. A failure prints the seed and the steps so far;
-- replay it with SIM_SEED=<seed> ./scripts/test.sh. SIM_RUNS (seeds from SIM_SEED_BASE,
-- default 1000) and SIM_STEPS allow longer local soak runs.
--
-- Invariants:
--   1. no handler errors (the framework runs drivers with _fail_on_error)
--   2. no writes without a user action: preference attributes only in the step where the
--      user changed that preference to a valid value; mode/setpoint only in user steps;
--      device events and time only ever cause reads and clock syncs
--   3. setpoint writes within 5 °C and the device's max heat temp (<= 35 °C)
--   4. bounded message rate for device events and time passing
--   5. energy only after the divisor was read, scaled correctly, never decreasing
--   6. displayed mode, setpoint, temperature and operating state match the device
--   7. no displayed temperature or setpoint outside -40..80 °C
--   8. the driver never sends a write the firmware would reject (quirks)
--   9. every clock write is local standard time from the utcOffset preference (#19)
local test              = require "integration_test"
local t_utils           = require "integration_test.utils"
local zigbee_test_utils = require "integration_test.zigbee_test_utils"
local json              = require "st.json"
local sim               = require "test.namron_sim"

local CI_SEEDS = {}
for s = 1, 20 do CI_SEEDS[s] = s end
local STEPS = tonumber(os.getenv("SIM_STEPS") or "") or 200

-- Invariant 4 limits (see the design note). A device event causes at most one clock sync
-- (read + write, twice = 4 messages). Over any 5 minutes of device events and time passing:
-- one poll (9 reads), one clock sync (4), one energy scale request (2) and up to three
-- power scale requests (6).
local MAX_TX_PER_DEVICE_EVENT = 4
local RATE_WINDOW_S = 5 * 60
local MAX_TX_PER_WINDOW = 9 + 4 + 2 + 6

local START_TIME = 1790000000 -- 2026; the driver skips clock syncs while the hub clock is unset

local profile = t_utils.get_profile_definition("namron-edge-thermostat.yml")

-- ---------------------------------------------------------------------------
-- Preferences: candidate values and the driver's documented valid ranges
-- ---------------------------------------------------------------------------
local PREFS = {
  sensorMode       = { attr = "sensor_mode",       values = { "0", "1", "2", "3", "4", "5", "6", "7", "9", "-1" },
                       valid = function(v) local n = tonumber(v); return n ~= nil and n >= 0 and n <= 6 end },
  panelBrightness  = { attr = "panel_brightness",  values = { 1, 20, 50, 80, 100, 0, 101, 500 },
                       valid = function(v) return v >= 1 and v <= 100 end },
  screenOnTime     = { attr = "screen_on_time",    values = { "0", "1", "2", "3", "4", "7" },
                       valid = function(v) local n = tonumber(v); return n ~= nil and n >= 0 and n <= 3 end },
  regulatorPercent = { attr = "regulator_percent", values = { 0, 25, 50, 100, -1, 101 },
                       valid = function(v) return v >= 0 and v <= 100 end },
  tempCalibration  = { attr = "temp_calibration",  values = { -3, -1.5, 0, 0.5, 3, 3.5, -4, 12 },
                       valid = function(v) return v >= -3 and v <= 3 end },
  maxHeatTemp      = { attr = "max_heat_temp",     values = { 15, 20, 25, 30, 35, 10, 36, 99 },
                       valid = function(v) return v >= 15 and v <= 35 end },
  childLock        = { attr = "keypad_lockout",    values = { true, false, "true" },
                       valid = function(v) return type(v) == "boolean" end },
  windowDetection  = { attr = "window_check",      values = { true, false, "false" },
                       valid = function(v) return type(v) == "boolean" end },
  autoTimeSync     = { attr = "auto_time",         values = { true, false, "true" },
                       valid = function(v) return type(v) == "boolean" end },
  -- no attribute of its own: changes the value of clock syncs (#19)
  utcOffset        = { values = { 0, 1, 2, 5.5, -5, 14, -12, 15, -13 },
                       valid = function(v) return v >= -12 and v <= 14 end },
}
local PREF_NAMES = {}
for name in pairs(PREFS) do PREF_NAMES[#PREF_NAMES + 1] = name end
table.sort(PREF_NAMES)

local function attr_key(name)
  local a = sim.ATTRS[name]
  return a.cluster .. ":" .. a.id
end

-- attribute key -> preference that may write it
local PREF_BY_ATTR = {}
for name, p in pairs(PREFS) do
  if p.attr then PREF_BY_ATTR[attr_key(p.attr)] = name end
end
local TIME_KEY = attr_key("time")

--- What 0x800B must be: local standard time from the utcOffset preference (#19),
--- rounded to 15 minutes, 1 h (CET) if the preference is invalid.
local function expected_thermostat_time(utc_offset)
  local quarters = type(utc_offset) == "number" and math.floor(utc_offset * 4 + 0.5) or nil
  if quarters == nil or quarters < -48 or quarters > 56 then quarters = 4 end
  return os.time() - 946684800 + quarters * 15 * 60
end
local CLOCK_ATTRS = { [attr_key("time")] = true, [attr_key("time_sync_request")] = true }
local CONTROL_ATTRS = { [attr_key("system_mode")] = true, [attr_key("heating_setpoint")] = true,
                        [attr_key("frost")] = true }


-- ---------------------------------------------------------------------------
-- One randomised run
-- ---------------------------------------------------------------------------
local function run(seed, device)
  local rng = sim.rng(seed)
  local scenario = {
    metering_div_unsupported = rng:chance(0.2),
    power_div_unsupported = rng:chance(0.2),
    clock_spam = rng:chance(0.2),
    p_duplicate = rng:chance(0.5) and 0.1 or 0,
    p_delay = rng:chance(0.5) and 0.1 or 0,
  }
  local history = {}
  local ctx -- the current step
  local shown = {}  -- capability.attribute -> last displayed value
  local last_energy = nil
  local dirty = false -- a stale (delayed) report may be displayed until the next full refresh
  local window = {}   -- { time, count } of device and time steps, for invariant 4

  local function fail(fmt, ...)
    local lines = { string.format("SIMULATION INVARIANT FAILED (seed %d, step %d): " .. fmt, seed, ctx.step, ...),
                    "scenario: " .. json.encode(scenario), "steps:" }
    for i = math.max(1, #history - 25), #history do lines[#lines + 1] = string.format("  %d %s", i, history[i]) end
    lines[#lines + 1] = string.format("replay with: SIM_SEED=%d ./scripts/test.sh", seed)
    error(table.concat(lines, "\n"), 0)
  end

  -- The test framework's profile loader drops the preferences section, so the device starts
  -- with none set and the driver uses its built-in defaults, like a thermostat whose settings
  -- were never changed.
  local prefs = {}

  local s = sim.new(device, rng, scenario, function(rx)
    test.socket.zigbee:__queue_receive({ device.id, rx })
  end)

  -- Everything the driver sends to the device goes to the simulator.
  test.socket.zigbee.send = function(_, ...)
    local args = { ... }
    local d = sim.decode(args[#args])
    ctx.tx[#ctx.tx + 1] = d
    if d.kind == "write" then
      for _, w in ipairs(d.writes) do
        local key = d.cluster .. ":" .. w.id
        local pref = PREF_BY_ATTR[key]
        if pref ~= nil then
          if not ctx.allowed[key] then fail("unrequested write of preference %s (0x%04X)", pref, w.id) end
        elseif CONTROL_ATTRS[key] then
          if ctx.kind ~= "user" then fail("write of 0x%04X without a user command", w.id) end
          if key == attr_key("heating_setpoint") then
            local max = math.min(s.state.max_heat_temp * 10, 3500)
            if w.value < 500 or w.value > max then
              fail("setpoint write %d outside 500..%d", w.value, max)
            end
          end
        elseif key == TIME_KEY then
          local want = expected_thermostat_time(prefs.utcOffset)
          if w.value ~= want then
            fail("clock write %d is %+d s off local standard time (utcOffset %s)", w.value, w.value - want,
              tostring(prefs.utcOffset))
          end
        elseif not CLOCK_ATTRS[key] then
          fail("unexpected write to cluster 0x%04X attribute 0x%04X", d.cluster, w.id)
        end
      end
    elseif d.kind == "command" and ctx.kind ~= "user" then
      fail("thermostat command 0x%02X without a user command", d.cmd)
    end
    s:receive(d)
  end

  -- Everything the driver displays is recorded and checked.
  test.socket.capability.send = function(_, _, payload)
    local ev = json.decode(payload)
    local key = ev.capability_id .. "." .. ev.attribute_id
    local value = ev.state and ev.state.value
    shown[key] = value
    if key == "energyMeter.energy" then
      if not s.divisor_answered then fail("energy %s displayed before the divisor was known", tostring(value)) end
      local raw = math.floor(value * 100 + 0.5)
      if not s.energy_reports[raw] then fail("energy %s doesn't match any reported raw value / 100", tostring(value)) end
      if last_energy ~= nil and value < last_energy then fail("energy went down: %s -> %s", last_energy, value) end
      last_energy = value
    elseif key == "temperatureMeasurement.temperature" or key == "thermostatHeatingSetpoint.heatingSetpoint" then
      if value < -40 or value > 80 then fail("implausible %s %s displayed", key, tostring(value)) end
    end
  end

  local function check_after_step()
    if #s.rejected > 0 then fail("device rejected: %s", s.rejected[1]) end
    if ctx.kind ~= "user" and ctx.kind ~= "prefs" and ctx.kind ~= "start" then
      if ctx.kind == "device" and #ctx.tx > MAX_TX_PER_DEVICE_EVENT then
        fail("%d messages sent for one device event", #ctx.tx)
      end
      local now = os.time()
      window[#window + 1] = { time = now, count = #ctx.tx }
      local total = 0
      for _, w in ipairs(window) do
        if now - w.time < RATE_WINDOW_S then total = total + w.count end
      end
      if total > MAX_TX_PER_WINDOW then fail("%d device-triggered messages within 5 minutes", total) end
    end
    -- (traffic caused by user commands, preference edits and the start isn't counted)
    -- a full refresh (user refresh or the poll) re-reads all state
    for _, d in ipairs(ctx.tx) do
      if d.kind == "read" and d.cluster == sim.ATTRS.local_temperature.cluster then
        for _, id in ipairs(d.attrs) do
          if id == sim.ATTRS.local_temperature.id then dirty = false end
        end
      end
    end
    if dirty or #s.delayed > 0 then return end
    local expect = {
      ["thermostatMode.thermostatMode"] = s:mode(),
      ["thermostatHeatingSetpoint.heatingSetpoint"] = s.state.heating_setpoint / 100,
      ["temperatureMeasurement.temperature"] = math.floor(s.state.local_temperature / 10 + 0.5) / 10,
      ["thermostatOperatingState.thermostatOperatingState"] = s.state.running_state ~= 0 and "heating" or "idle",
    }
    for key, want in pairs(expect) do
      if shown[key] ~= want then
        fail("%s shows %s but the device is %s", key, tostring(shown[key]), tostring(want))
      end
    end
  end

  local function step(kind, label, fn)
    ctx = { step = #history + 1, kind = kind, allowed = {}, tx = {} }
    history[#history + 1] = kind .. ": " .. label
    fn()
    test.wait_for_events()
    if kind == "user" then
      -- let the driver's 2 s read-backs fire inside the user step
      test.mock_time.advance_time(3)
      test.wait_for_events()
    end
    check_after_step()
  end

  local function capability_cmd(capability, command, args)
    test.socket.capability:__queue_receive({ device.id,
      { capability = capability, component = "main", command = command, args = args } })
  end

  -- Start: either a fresh join (added + doConfigure) or a switch from another driver.
  test.mock_time.advance_time(START_TIME)
  if rng:chance(0.5) then
    step("start", "added + doConfigure", function()
      device:expect_metadata_update({ provisioning_state = "PROVISIONED" })
      test.socket.device_lifecycle:__queue_receive({ device.id, "added" })
      test.socket.device_lifecycle:__queue_receive({ device.id, "doConfigure" })
    end)
  else
    step("start", "driverSwitched", function()
      device:expect_metadata_update({ profile = "namron-edge-thermostat", provisioning_state = "PROVISIONED" })
      test.socket.device_lifecycle:__queue_receive({ device.id, "driverSwitched" })
    end)
  end
  -- the thermostat's state is only known after a first refresh
  step("user", "refresh", function() capability_cmd("refresh", "refresh", {}) end)

  local USER_ACTIONS = {
    function()
      local v = rng:pick({ 5, 12.5, 18, 20.5, 21, 22.5, 25, 30, 35, 3, 36, 40, 50, 68, 72.5, 100, -5, 0 })
      return "setHeatingSetpoint " .. v, function()
        capability_cmd("thermostatHeatingSetpoint", "setHeatingSetpoint", { v })
      end
    end,
    function()
      local m = rng:pick({ "off", "heat", "eco", "schedule", "frostguard", "auto", "cool" })
      return "setThermostatMode " .. m, function()
        capability_cmd("thermostatMode", "setThermostatMode", { m })
      end
    end,
    function()
      local c = rng:pick({ "off", "heat", "auto" })
      return "thermostatMode." .. c, function() capability_cmd("thermostatMode", c, {}) end
    end,
    function()
      return "refresh", function() capability_cmd("refresh", "refresh", {}) end
    end,
  }

  for _ = 1, STEPS do
    local kind = rng:weighted({ user = 30, prefs = 10, device = 45, time = 15 })
    if kind == "user" then
      local label, fn = rng:pick(USER_ACTIONS)()
      step("user", label, fn)
    elseif kind == "prefs" then
      local name = rng:pick(PREF_NAMES)
      local p = PREFS[name]
      local value = rng:pick(p.values)
      step("prefs", name .. " = " .. tostring(value), function()
        if p.attr and value ~= prefs[name] and p.valid(value) then ctx.allowed[attr_key(p.attr)] = true end
        prefs[name] = value
        local new_prefs = {}
        for k, v in pairs(prefs) do new_prefs[k] = v end
        test.socket.device_lifecycle:__queue_receive(device:generate_info_changed({ preferences = new_prefs }))
      end)
    elseif kind == "device" then
      step("device", "event", function()
        local name = s:random_event()
        history[#history] = "device: " .. name
        if name == "flush_delayed" then dirty = true end
      end)
    else
      local secs = rng:int(1, 1200)
      step("time", "+" .. secs .. " s", function() test.mock_time.advance_time(secs) end)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Test registration
-- ---------------------------------------------------------------------------
-- Timers that fire on mock time, so the poll and the delayed read-backs really run.
local function use_real_timers()
  test.timer.create_oneshot = function(seconds)
    local t = test.timer.__create_test_time_advance_timer(seconds, "oneshot")
    table.insert(test.timer.__returned_oneshot_timers, t)
    return t
  end
  test.timer.create_interval = function(seconds)
    local t = test.timer.__create_test_time_advance_timer(seconds, "interval")
    table.insert(test.timer.__returned_interval_timers, t)
    return t
  end
end

zigbee_test_utils.prepare_zigbee_env_info()

local seeds = CI_SEEDS
if os.getenv("SIM_SEED") then
  seeds = { tonumber(os.getenv("SIM_SEED")) }
elseif os.getenv("SIM_RUNS") then
  seeds = {}
  local base = tonumber(os.getenv("SIM_SEED_BASE") or "") or 1000
  -- the test framework can build at most ~255 mock devices per process
  local runs = tonumber(os.getenv("SIM_RUNS"))
  assert(runs and runs >= 1 and runs <= 250, "SIM_RUNS must be 1..250; use SIM_SEED_BASE for more")
  for i = 1, runs do seeds[i] = base + i end
end

for _, seed in ipairs(seeds) do
  local device
  test.register_coroutine_test(
    string.format("Simulated device, seed %d, %d steps", seed, STEPS),
    function() run(seed, device) end,
    { test_init = function()
        use_real_timers()
        device = test.mock_device.build_test_zigbee_device({
          profile = profile,
          zigbee_endpoints = {
            [1] = { id = 1, manufacturer = "Namron AS", model = "4512783",
                    server_clusters = { 0x0000, 0x0003, 0x0006, 0x0201, 0x0204, 0x0405, 0x0702, 0x0B04 } },
          },
        })
        test.mock_device.add_test_device(device)
      end }
  )
end

test.run_registered_tests()
