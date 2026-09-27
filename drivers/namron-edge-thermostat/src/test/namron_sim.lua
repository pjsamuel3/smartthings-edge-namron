-- Simulated Namron Edge thermostat (test-only).
--
-- Holds device state, answers the driver's Zigbee messages the way the firmware does
-- (quirks included) and produces the attribute reports a real thermostat would send.
-- Used by test_simulated_device.lua. See docs/design/device-simulator.md.
--
-- Quirks modelled (sources: Zigbee2MQTT namron.ts and the driver README):
--   * custom attributes (0x8000+) accept a write only after a read of the same attribute
--   * writes that disable the default response are ignored
--   * writes to ProgrammingOperationMode are ignored; eco/schedule change via commands 0x08/0x07
--   * every state change is followed by an attribute report
--   * Metering multiplier 1 / divisor 100
local clusters          = require "st.zigbee.zcl.clusters"
local data_types        = require "st.zigbee.data_types"
local zb_const          = require "st.zigbee.constants"
local zigbee_test_utils = require "integration_test.zigbee_test_utils"

local Thermostat            = clusters.Thermostat
local ThermostatUI          = clusters.ThermostatUserInterfaceConfiguration
local RelativeHumidity      = clusters.RelativeHumidity
local SimpleMetering        = clusters.SimpleMetering
local ElectricalMeasurement = clusters.ElectricalMeasurement

local CMD_SET_PROGRAM = 0x07
local CMD_SET_ECO     = 0x08

local sim = {}

-- ---------------------------------------------------------------------------
-- Deterministic PRNG (math.random differs between platforms, seeds must replay in CI)
-- ---------------------------------------------------------------------------
local Rng = {}
Rng.__index = Rng

function sim.rng(seed)
  return setmetatable({ state = seed * 2654435761 + 1 }, Rng)
end

--- Integer in [lo, hi].
function Rng:int(lo, hi)
  self.state = self.state * 6364136223846793005 + 1442695040888963407
  return lo + ((self.state >> 33) % (hi - lo + 1))
end

function Rng:chance(p)
  return self:int(1, 10000) <= p * 10000
end

function Rng:pick(list)
  return list[self:int(1, #list)]
end

--- Pick a key from { key = weight, ... } in a stable order.
function Rng:weighted(weights)
  local keys, total = {}, 0
  for k, w in pairs(weights) do keys[#keys + 1] = k; total = total + w end
  table.sort(keys)
  local n = self:int(1, total)
  for _, k in ipairs(keys) do
    n = n - weights[k]
    if n <= 0 then return k end
  end
end

-- ---------------------------------------------------------------------------
-- Attribute table: name -> how it is addressed and reported
-- ---------------------------------------------------------------------------
local function std(cluster, attr_name)
  local attr = cluster.attributes[attr_name]
  return { cluster = cluster.ID, id = attr.ID,
           build = function(device, v) return attr:build_test_attr_report(device, v) end }
end

local function custom(id, dt)
  return { cluster = Thermostat.ID, id = id, custom = true,
           build = function(device, v)
             return zigbee_test_utils.build_attribute_report(device, Thermostat.ID, { { id, dt.ID, v } })
           end }
end

local ATTRS = {
  local_temperature  = std(Thermostat, "LocalTemperature"),
  heating_setpoint   = std(Thermostat, "OccupiedHeatingSetpoint"),
  system_mode        = std(Thermostat, "SystemMode"),
  prog_mode          = std(Thermostat, "ThermostatProgrammingOperationMode"),
  running_state      = std(Thermostat, "ThermostatRunningState"),
  temp_calibration   = std(Thermostat, "LocalTemperatureCalibration"),
  keypad_lockout     = std(ThermostatUI, "KeypadLockout"),
  humidity           = std(RelativeHumidity, "MeasuredValue"),
  energy             = std(SimpleMetering, "CurrentSummationDelivered"),
  metering_mult      = std(SimpleMetering, "Multiplier"),
  metering_div       = std(SimpleMetering, "Divisor"),
  power              = std(ElectricalMeasurement, "ActivePower"),
  power_mult         = std(ElectricalMeasurement, "ACPowerMultiplier"),
  power_div          = std(ElectricalMeasurement, "ACPowerDivisor"),
  window_check       = custom(0x8000, data_types.Boolean),
  frost              = custom(0x8001, data_types.Boolean),
  window_state       = custom(0x8002, data_types.Boolean),
  sensor_mode        = custom(0x8004, data_types.Enum8),
  panel_brightness   = custom(0x8005, data_types.Uint8),
  time_sync_request  = custom(0x800A, data_types.Boolean),
  time               = custom(0x800B, data_types.Uint32),
  regulator_percent  = custom(0x801D, data_types.Int16),
  auto_time          = custom(0x8022, data_types.Boolean),
  max_heat_temp      = custom(0x8025, data_types.Int16),
  screen_on_time     = custom(0x8029, data_types.Enum8),
}
sim.ATTRS = ATTRS

local BY_ADDRESS = {}
for name, a in pairs(ATTRS) do
  a.name = name
  BY_ADDRESS[a.cluster .. ":" .. a.id] = a
end

function sim.attr_at(cluster, id)
  return BY_ADDRESS[cluster .. ":" .. id]
end

-- ---------------------------------------------------------------------------
-- Decoding what the driver sends
-- ---------------------------------------------------------------------------
--- Decode a ZigbeeMessageTx into a plain table:
--- { kind = "zdo"|"read"|"write"|"command"|"configure_reporting"|"other", cluster, cmd, ... }
function sim.decode(msg)
  local ah = msg.address_header
  local d = { cluster = ah.cluster.value }
  if ah.profile.value ~= zb_const.HA_PROFILE_ID then
    d.kind = "zdo"
    return d
  end
  local zh = msg.body.zcl_header
  local body = msg.body.zcl_body
  d.cmd = zh.cmd.value
  d.no_default_response = zh.frame_ctrl:is_disable_default_response_set()
  if zh.frame_ctrl:is_cluster_specific_set() then
    d.kind = "command"
    d.payload = body:_serialize()
  elseif d.cmd == 0x00 then
    d.kind = "read"
    d.attrs = {}
    for _, a in ipairs(body.attr_ids) do d.attrs[#d.attrs + 1] = a.value end
  elseif d.cmd == 0x02 then
    d.kind = "write"
    d.writes = {}
    for _, r in ipairs(body.attr_records) do
      d.writes[#d.writes + 1] = { id = r.attr_id.value, value = r.data.value }
    end
  elseif d.cmd == 0x06 then
    d.kind = "configure_reporting"
  else
    d.kind = "other"
  end
  return d
end

-- ---------------------------------------------------------------------------
-- The simulated device
-- ---------------------------------------------------------------------------
local Device = {}
Device.__index = Device

--- @param device table the mock device
--- @param rng table from sim.rng
--- @param scenario table { metering_div_unsupported, power_div_unsupported, p_duplicate, p_delay, p_invalid }
--- @param deliver function(rx) queues a message from the device to the driver
function sim.new(device, rng, scenario, deliver)
  local self = setmetatable({
    device = device, rng = rng, scenario = scenario, deliver = deliver,
    read_seen = {},      -- custom attr id -> read since last write (write-after-read quirk)
    rejected = {},       -- writes the firmware would reject; the driver must never cause these
    delayed = {},        -- reports held back (fault injection)
    energy_reports = {}, -- raw values reported, for checking scaling
    divisor_answered = false,
    last_report = nil,
  }, Device)
  self.state = {
    local_temperature = 2150, heating_setpoint = 2100, system_mode = 0x04, prog_mode = 0x00,
    running_state = 0x0000, temp_calibration = 0, keypad_lockout = 0, humidity = 4500,
    energy = 15668, metering_mult = 1, metering_div = 100,
    power = 0, power_mult = 1, power_div = 1,
    window_check = false, frost = false, window_state = false, sensor_mode = 0,
    panel_brightness = 50, time_sync_request = false, time = 0, regulator_percent = 50,
    auto_time = true, max_heat_temp = 350, screen_on_time = 1,
  }
  self.unsupported = {
    metering_div = scenario.metering_div_unsupported or nil,
    metering_mult = scenario.metering_div_unsupported or nil,
    power_div = scenario.power_div_unsupported or nil,
    power_mult = scenario.power_div_unsupported or nil,
  }
  return self
end

--- Send a report for attribute `name` (current state unless `value` is given).
--- `answer` = true for read responses, which are never delayed or duplicated.
function Device:report(name, value, answer)
  if value == nil then value = self.state[name] end
  local rx = ATTRS[name].build(self.device, value)
  if name == "energy" then self.energy_reports[value] = true end
  if not answer and name ~= "energy" and self.rng:chance(self.scenario.p_delay or 0) then
    -- Energy is cumulative; a stale energy report would legitimately go backwards, so
    -- only instantaneous values are delayed.
    self.delayed[#self.delayed + 1] = rx
    return
  end
  self.deliver(rx)
  self.last_report = rx
  if not answer and self.rng:chance(self.scenario.p_duplicate or 0) then
    self.deliver(rx)
  end
end

function Device:flush_delayed()
  local n = #self.delayed
  for _, rx in ipairs(self.delayed) do self.deliver(rx) end
  self.delayed = {}
  return n
end

function Device:reject(reason, d)
  self.rejected[#self.rejected + 1] = string.format("%s (cluster 0x%04X)", reason, d.cluster)
end

--- Handle one message from the driver.
function Device:receive(d)
  if d.kind == "read" then
    for _, id in ipairs(d.attrs) do
      local a = sim.attr_at(d.cluster, id)
      if a ~= nil then
        if a.custom then self.read_seen[id] = true end
        if not self.unsupported[a.name] then
          if a.name == "metering_div" then self.divisor_answered = true end
          self:report(a.name, nil, true)
        end
      end
    end
  elseif d.kind == "write" then
    if d.no_default_response then
      self:reject("write without default response", d)
      return
    end
    for _, w in ipairs(d.writes) do
      local a = sim.attr_at(d.cluster, w.id)
      if a == nil then
        self:reject(string.format("write to unknown attribute 0x%04X", w.id), d)
      elseif a.name == "prog_mode" then
        self:reject("write to ProgrammingOperationMode (firmware ignores it)", d)
      elseif a.custom and not self.read_seen[w.id] then
        self:reject(string.format("write to 0x%04X without a preceding read", w.id), d)
      else
        if a.custom then self.read_seen[w.id] = nil end
        self.state[a.name] = w.value
        if a.name == "time" and w.value > 0 then self.clock_set = true end
        self:report(a.name)
      end
    end
  elseif d.kind == "command" and d.cluster == Thermostat.ID then
    local flag = d.payload:byte(1) == 1
    local bit = (d.cmd == CMD_SET_ECO and 0x04) or (d.cmd == CMD_SET_PROGRAM and 0x01) or nil
    if bit == nil then
      self:reject(string.format("unknown thermostat command 0x%02X", d.cmd), d)
      return
    end
    self.state.prog_mode = flag and (self.state.prog_mode | bit) or (self.state.prog_mode & ~bit)
    self:report("prog_mode")
  end
  -- ZDO (bind) and configure reporting are accepted silently.
end

--- The mode the thermostat is in, derived like the driver README describes.
function Device:mode()
  local s = self.state
  if s.system_mode == 0x00 then return "off" end
  if s.frost then return "frostguard" end
  if (s.prog_mode & 0x04) ~= 0 then return "eco" end
  if (s.prog_mode & 0x01) ~= 0 then return "schedule" end
  return "heat"
end

-- ---------------------------------------------------------------------------
-- Things that happen on the device by themselves
-- ---------------------------------------------------------------------------
local EVENTS = {
  temperature = function(self)
    self.state.local_temperature = self.rng:int(1500, 2800)
    self:report("local_temperature")
  end,
  humidity = function(self)
    self.state.humidity = self.rng:int(3000, 7000)
    self:report("humidity")
  end,
  heating = function(self)
    local on = self.state.running_state == 0
    self.state.running_state = on and 0x0001 or 0x0000
    self.state.power = on and self.rng:int(1600, 1700) or 0
    self:report("running_state")
    self:report("power")
  end,
  energy = function(self)
    self.state.energy = self.state.energy + self.rng:int(1, 40)
    self:report("energy")
  end,
  clock_request = function(self)
    self.state.time_sync_request = true
    self:report("time_sync_request")
  end,
  local_setpoint = function(self)
    self.state.heating_setpoint = self.rng:int(10, 70) * 50
    self:report("heating_setpoint")
  end,
  local_mode = function(self)
    local r = self.rng:int(1, 4)
    if r == 1 then
      self.state.system_mode = self.state.system_mode == 0 and 0x04 or 0x00
      self:report("system_mode")
    elseif r == 2 then
      self.state.frost = not self.state.frost
      self:report("frost")
    else
      self.state.prog_mode = self.state.prog_mode ~ (r == 3 and 0x04 or 0x01)
      self:report("prog_mode")
    end
  end,
  window = function(self)
    self.state.window_state = not self.state.window_state
    self:report("window_state")
  end,
  invalid_temperature = function(self)
    -- 0x8000 ("not available") or an implausible value; state is unchanged
    self:report("local_temperature", self.rng:pick({ -32768, 12000, -5000 }))
  end,
  duplicate = function(self)
    if self.last_report ~= nil then self.deliver(self.last_report) end
  end,
  flush_delayed = function(self)
    self:flush_delayed()
  end,
}

local EVENT_WEIGHTS = {
  temperature = 20, humidity = 8, heating = 12, energy = 20, clock_request = 6,
  local_setpoint = 6, local_mode = 6, window = 3, invalid_temperature = 3, duplicate = 3, flush_delayed = 4,
}

--- Run one random device event; returns its name.
function Device:random_event()
  local name = self.rng:weighted(EVENT_WEIGHTS)
  if name == "clock_request" and self.scenario.clock_spam then
    -- a faulty device re-raising the flag many times in a row
    for _ = 1, 10 do EVENTS.clock_request(self) end
  else
    EVENTS[name](self)
  end
  return name
end

return sim
