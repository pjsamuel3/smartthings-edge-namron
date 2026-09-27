-- Namron Zigbee Edge Thermostat (4512783 / 4512784 / 4566702 / 4566703)
--
-- SmartThings Edge driver. The thermostat is an HZC-platform device that uses
-- the standard ZCL Thermostat cluster (0x0201) plus a block of
-- non-manufacturer-specific custom attributes (0x8000+) on the same cluster.
-- Attribute IDs and firmware quirks are taken from the Zigbee2MQTT converter
-- (zigbee-herdsman-converters, src/devices/namron.ts, PR #13145).
--
-- Firmware quirks handled here:
--   * writes must request a default response (the ST library does by default)
--   * several custom attributes only accept a write after a read in the same
--     session, so every custom write is preceded by a read
--   * returning from eco/schedule to manual needs the custom cluster commands
--     setEco (0x08) / setProgram (0x07); writing the bitmap is ignored

local capabilities      = require "st.capabilities"
local ZigbeeDriver      = require "st.zigbee"
local defaults          = require "st.zigbee.defaults"
local clusters          = require "st.zigbee.zcl.clusters"
local data_types        = require "st.zigbee.data_types"
local cluster_base      = require "st.zigbee.cluster_base"
local device_management = require "st.zigbee.device_management"
local zcl_messages      = require "st.zigbee.zcl"
local messages          = require "st.zigbee.messages"
local zb_const          = require "st.zigbee.constants"
local generic_body      = require "st.zigbee.generic_body"
local FrameCtrl         = require "st.zigbee.zcl.frame_ctrl"
local utils             = require "st.utils"
local log               = require "log"
local zb_defaults_const = require "st.zigbee.constants"
local default_energy_handler = require "st.zigbee.defaults.energyMeter_defaults.energy_meter_handler"
local default_power_handler  = require "st.zigbee.defaults.powerMeter_defaults.active_power_meter_handler"

local Thermostat            = clusters.Thermostat
local ThermostatUI          = clusters.ThermostatUserInterfaceConfiguration
local RelativeHumidity      = clusters.RelativeHumidity
local SimpleMetering        = clusters.SimpleMetering
local ElectricalMeasurement = clusters.ElectricalMeasurement

local ThermostatMode   = capabilities.thermostatMode
local OperatingState   = capabilities.thermostatOperatingState
local HeatingSetpoint  = capabilities.thermostatHeatingSetpoint

-- ---------------------------------------------------------------------------
-- Custom attributes on the Thermostat cluster (no manufacturer code)
-- ---------------------------------------------------------------------------
local ATTR = {
  WINDOW_CHECK      = 0x8000, -- Boolean
  FROST             = 0x8001, -- Boolean
  WINDOW_STATE      = 0x8002, -- Boolean (read-only)
  SENSOR_MODE       = 0x8004, -- Enum8 0..6
  PANEL_BRIGHTNESS  = 0x8005, -- Uint8 1..100
  FAULT             = 0x8006, -- Bitmap (read-only)
  REGULATOR_CYCLE   = 0x8007, -- Uint8
  TIME_SYNC_REQUEST = 0x800A, -- Boolean, device sets 1 when it wants the time
  TIME              = 0x800B, -- Uint32, seconds since 2000-01-01 UTC
  REGULATOR_PERCENT = 0x801D, -- Int16 0..100
  AUTO_TIME         = 0x8022, -- Boolean
  MAX_HEAT_TEMP     = 0x8025, -- Int16, 0.1 °C
  SCREEN_ON_TIME    = 0x8029, -- Enum8 0..3
}

local CMD_SET_PROGRAM = 0x07 -- payload Boolean: true = follow weekly schedule
local CMD_SET_ECO     = 0x08 -- payload Boolean: true = eco

local EPOCH_2000 = 946684800
local SYSTEM_MODE_OFF  = 0x00
local SYSTEM_MODE_HEAT = 0x04

local SUPPORTED_MODES = {
  ThermostatMode.thermostatMode.off.NAME,
  ThermostatMode.thermostatMode.heat.NAME,
  ThermostatMode.thermostatMode.eco.NAME,
  ThermostatMode.thermostatMode.schedule.NAME,
  ThermostatMode.thermostatMode.frostguard.NAME,
}

local SENSOR_MODE_NAMES = {
  [0] = "air", [1] = "floor", [2] = "air_floor", [3] = "external",
  [4] = "external_floor", [5] = "floor_percent", [6] = "regulator",
}

local FIELD_SYSTEM_MODE = "namron_system_mode"
local FIELD_PROG_MODE   = "namron_prog_mode"
local FIELD_FROST       = "namron_frost"
-- Last max heat temp (°C) the driver validated and wrote to the thermostat. Setpoints are
-- limited to this, never to the raw preference, which may hold a rejected value.
local FIELD_MAX_HEAT_TEMP = "namron_max_heat_temp"
local DEFAULT_MAX_HEAT_TEMP = 35

local POLL_INTERVAL_S = 15 * 60
-- Minimum time between clock syncs triggered by the device's own sync requests.
-- Stops a device that keeps re-raising the flag from flooding the Zigbee mesh.
local CLOCK_SYNC_MIN_INTERVAL_S = 5 * 60
local FIELD_LAST_CLOCK_SYNC = "namron_last_clock_sync"

-- Plausible range for temperatures reported by the device (°C). Anything outside is
-- treated as invalid (e.g. 0x8000 = "not available") and not shown to the user.
local REPORTED_TEMP_MIN_C = -40
local REPORTED_TEMP_MAX_C = 80

-- ---------------------------------------------------------------------------
-- Low-level helpers
-- ---------------------------------------------------------------------------
--- Convert v to an integer within [min, max]. Returns nil for nil, NaN, fractions
--- that cannot be rounded meaningfully, or out-of-range values.
local function to_int_in_range(v, min, max)
  local n = tonumber(v)
  if n == nil or n ~= n then return nil end
  n = utils.round(n)
  if n < min or n > max then return nil end
  return n
end

local function thermostat_cluster_id()
  return data_types.ClusterId(Thermostat.ID)
end

local function read_custom(device, attr_id)
  device:send(cluster_base.read_attribute(device, thermostat_cluster_id(), data_types.AttributeId(attr_id)))
end

--- Read-then-write a custom Thermostat attribute (firmware requires the read first).
local function write_custom(device, attr_id, data_type, value)
  read_custom(device, attr_id)
  device:send(cluster_base.write_attribute(device, thermostat_cluster_id(),
    data_types.AttributeId(attr_id), data_type(value)))
end

--- Send one of the device's cluster-specific Thermostat commands (0x07 / 0x08).
local function send_thermostat_command(device, cmd_id, flag)
  local frame_ctrl = FrameCtrl(0x00)
  frame_ctrl:set_cluster_specific()
  local zclh = zcl_messages.ZclHeader({
    cmd = data_types.ZCLCommandId(cmd_id),
    frame_ctrl = frame_ctrl,
  })
  local addrh = messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(Thermostat.ID),
    zb_const.HA_PROFILE_ID,
    Thermostat.ID
  )
  device:send(messages.ZigbeeMessageTx({
    address_header = addrh,
    body = zcl_messages.ZclMessageBody({
      zcl_header = zclh,
      zcl_body = generic_body.GenericBody(string.char(flag and 1 or 0)),
    }),
  }))
end

-- The thermostat has no time zone: it shows 0x800B as local *standard* time and adds
-- the summer hour itself ("Auto Daylight Saving" in its menu). Confirmed on a 4512783:
-- sending UTC showed UTC+1 in summer. The offset comes from the utcOffset preference.
local DEFAULT_UTC_OFFSET_MIN = 60 -- CET (Norway, Sweden, Denmark)

--- utcOffset preference (hours) as minutes, rounded to 15 minutes, or nil if invalid.
local function valid_utc_offset_min(v)
  local quarters = to_int_in_range((tonumber(v) or 0/0) * 4, -48, 56)
  return quarters and quarters * 15
end

local function utc_offset_min(device)
  return valid_utc_offset_min(device.preferences.utcOffset) or DEFAULT_UTC_OFFSET_MIN
end

--- Push the hub's time to the thermostat, as local standard time.
--- @param force boolean bypass the rate limit (used for explicit user/configure actions)
local function sync_clock(device, force)
  local now_epoch = os.time()
  local now = now_epoch - EPOCH_2000 + utc_offset_min(device) * 60
  if now <= 0 then
    log.warn(string.format("[%s] hub clock not set, skipping thermostat clock sync", device.label))
    return
  end
  local last = device:get_field(FIELD_LAST_CLOCK_SYNC)
  -- (a hub clock that jumped backwards also counts as "due", so syncing never stalls)
  if not force and last ~= nil and now_epoch >= last and (now_epoch - last) < CLOCK_SYNC_MIN_INTERVAL_S then
    log.debug(string.format("[%s] clock sync requested again within %ds, ignoring", device.label,
      CLOCK_SYNC_MIN_INTERVAL_S))
    return
  end
  device:set_field(FIELD_LAST_CLOCK_SYNC, now_epoch)
  write_custom(device, ATTR.TIME, data_types.Uint32, now)
  write_custom(device, ATTR.TIME_SYNC_REQUEST, data_types.Boolean, false)
end

local function read_mode_state(device)
  device:send(Thermostat.attributes.SystemMode:read(device))
  device:send(Thermostat.attributes.ThermostatProgrammingOperationMode:read(device))
  read_custom(device, ATTR.FROST)
end

-- ---------------------------------------------------------------------------
-- Mode derivation: SystemMode + ProgrammingOperationMode + frost flag
-- ---------------------------------------------------------------------------
local function emit_mode(device)
  local sys   = device:get_field(FIELD_SYSTEM_MODE)
  local prog  = device:get_field(FIELD_PROG_MODE) or 0
  local frost = device:get_field(FIELD_FROST)
  if sys == nil then return end

  local mode
  if sys == SYSTEM_MODE_OFF then
    mode = ThermostatMode.thermostatMode.off
  elseif frost then
    mode = ThermostatMode.thermostatMode.frostguard
  elseif (prog & 0x04) ~= 0 then
    mode = ThermostatMode.thermostatMode.eco
  elseif (prog & 0x01) ~= 0 then
    mode = ThermostatMode.thermostatMode.schedule
  else
    mode = ThermostatMode.thermostatMode.heat
  end
  device:emit_event(mode({ data = { supportedThermostatModes = SUPPORTED_MODES } }))
end

-- ---------------------------------------------------------------------------
-- Zigbee attribute handlers
-- ---------------------------------------------------------------------------
--- Convert a ZCL temperature (0.01 °C, Int16) to °C, or nil if invalid/implausible.
local function zcl_temperature_to_c(raw)
  if type(raw) ~= "number" or raw == -32768 then return nil end
  local c = raw / 100.0
  if c < REPORTED_TEMP_MIN_C or c > REPORTED_TEMP_MAX_C then return nil end
  return c
end

local function local_temperature_handler(driver, device, value, zb_rx)
  local c = zcl_temperature_to_c(value.value)
  if c == nil then return end
  device:emit_event(capabilities.temperatureMeasurement.temperature({
    value = utils.round(c * 10) / 10.0, unit = "C"
  }))
end

local function heating_setpoint_handler(driver, device, value, zb_rx)
  local c = zcl_temperature_to_c(value.value)
  if c == nil then return end
  device:emit_event(HeatingSetpoint.heatingSetpoint({ value = c, unit = "C" }))
end

local function system_mode_handler(driver, device, value, zb_rx)
  device:set_field(FIELD_SYSTEM_MODE, value.value)
  emit_mode(device)
end

local function programming_mode_handler(driver, device, value, zb_rx)
  device:set_field(FIELD_PROG_MODE, value.value)
  emit_mode(device)
end

local function running_state_handler(driver, device, value, zb_rx)
  if (value.value & 0x0001) ~= 0 or (value.value & 0x0008) ~= 0 then
    device:emit_event(OperatingState.thermostatOperatingState.heating())
  else
    device:emit_event(OperatingState.thermostatOperatingState.idle())
  end
end

local function frost_handler(driver, device, value, zb_rx)
  device:set_field(FIELD_FROST, value.value == true or value.value == 1)
  emit_mode(device)
end

local function sensor_mode_handler(driver, device, value, zb_rx)
  log.info(string.format("[%s] sensor mode is %s", device.label, SENSOR_MODE_NAMES[value.value] or tostring(value.value)))
end

local function window_state_handler(driver, device, value, zb_rx)
  log.info(string.format("[%s] open window detected: %s", device.label, tostring(value.value)))
end

local function time_sync_request_handler(driver, device, value, zb_rx)
  if (value.value == true or value.value == 1) and device.preferences.autoTimeSync ~= false then
    sync_clock(device, false)
  end
end

-- ---------------------------------------------------------------------------
-- Power / energy: only emit once the device's scaling factors are known.
-- Without the Metering divisor (100 on this device) the first energy report after
-- a driver switch was emitted 100x too high (15668 kWh instead of 156.68 kWh),
-- which corrupts energy history and statistics in SmartThings and Home Assistant.
-- ---------------------------------------------------------------------------
local POWER_FALLBACK_AFTER_SKIPS = 3
local FIELD_POWER_SKIPS = "namron_power_scale_skips"
-- Minimum time between energy scale requests, so firmware that never answers the
-- divisor doesn't get two reads on every energy report.
local ENERGY_SCALE_RETRY_S = 5 * 60
local FIELD_LAST_ENERGY_SCALE_REQUEST = "namron_last_energy_scale_request"

local function request_metering_scale(device)
  local now = os.time()
  local last = device:get_field(FIELD_LAST_ENERGY_SCALE_REQUEST)
  -- (a hub clock that jumped backwards also counts as "due", like the clock sync limit)
  if last ~= nil and now >= last and (now - last) < ENERGY_SCALE_RETRY_S then return end
  device:set_field(FIELD_LAST_ENERGY_SCALE_REQUEST, now)
  device:send(SimpleMetering.attributes.Multiplier:read(device))
  device:send(SimpleMetering.attributes.Divisor:read(device))
end

local function request_power_scale(device)
  device:send(ElectricalMeasurement.attributes.ACPowerMultiplier:read(device))
  device:send(ElectricalMeasurement.attributes.ACPowerDivisor:read(device))
end

local function energy_handler(driver, device, value, zb_rx)
  if device:get_field(zb_defaults_const.SIMPLE_METERING_DIVISOR_KEY) == nil then
    -- Never guess for a cumulative meter: a wrong value can't be taken back.
    log.info(string.format("[%s] energy scale unknown, requesting it before reporting energy", device.label))
    request_metering_scale(device)
    return
  end
  default_energy_handler(driver, device, value, zb_rx)
end

local function power_handler(driver, device, value, zb_rx)
  if device:get_field(zb_defaults_const.ELECTRICAL_MEASUREMENT_DIVISOR_KEY) == nil then
    local skips = (device:get_field(FIELD_POWER_SKIPS) or 0) + 1
    device:set_field(FIELD_POWER_SKIPS, skips)
    if skips <= POWER_FALLBACK_AFTER_SKIPS then
      request_power_scale(device)
      return
    end
    -- Instantaneous value: after a few attempts, fall back to the raw value rather
    -- than never showing power on firmware that doesn't expose the divisor.
    log.warn(string.format("[%s] power divisor not available, reporting raw watts", device.label))
  end
  default_power_handler(driver, device, value, zb_rx)
end

-- ---------------------------------------------------------------------------
-- Capability command handlers
-- ---------------------------------------------------------------------------
local function max_heat_temp(device)
  return device:get_field(FIELD_MAX_HEAT_TEMP) or DEFAULT_MAX_HEAT_TEMP
end

local function set_heating_setpoint(driver, device, command)
  local value = tonumber(command.args.setpoint)
  if value == nil or value ~= value then
    log.warn(string.format("[%s] ignoring invalid setpoint %s", device.label, tostring(command.args.setpoint)))
    return
  end
  if value >= 40 then value = utils.f_to_c(value) end -- assume Fahrenheit
  value = utils.clamp_value(value, 5, max_heat_temp(device))
  device:send(Thermostat.attributes.OccupiedHeatingSetpoint:write(device, utils.round(value * 100)))
  device.thread:call_with_delay(2, function()
    device:send(Thermostat.attributes.OccupiedHeatingSetpoint:read(device))
  end)
end

local function ensure_heating(device)
  if device:get_field(FIELD_SYSTEM_MODE) ~= SYSTEM_MODE_HEAT then
    device:send(Thermostat.attributes.SystemMode:write(device, SYSTEM_MODE_HEAT))
  end
end

local function clear_frost(device)
  if device:get_field(FIELD_FROST) then
    write_custom(device, ATTR.FROST, data_types.Boolean, false)
  end
end

local MODE_ACTIONS = {
  off = function(device)
    device:send(Thermostat.attributes.SystemMode:write(device, SYSTEM_MODE_OFF))
  end,
  heat = function(device)
    ensure_heating(device)
    clear_frost(device)
    send_thermostat_command(device, CMD_SET_ECO, false)
    send_thermostat_command(device, CMD_SET_PROGRAM, false)
  end,
  eco = function(device)
    ensure_heating(device)
    clear_frost(device)
    send_thermostat_command(device, CMD_SET_ECO, true)
  end,
  schedule = function(device)
    ensure_heating(device)
    clear_frost(device)
    send_thermostat_command(device, CMD_SET_ECO, false)
    send_thermostat_command(device, CMD_SET_PROGRAM, true)
  end,
  frostguard = function(device)
    ensure_heating(device)
    write_custom(device, ATTR.FROST, data_types.Boolean, true)
  end,
}

-- "auto" is what generic clients (and the capability's auto() command) send;
-- the closest thing this thermostat has is its own weekly schedule.
MODE_ACTIONS.auto = MODE_ACTIONS.schedule

local function set_mode(driver, device, mode)
  local action = MODE_ACTIONS[mode]
  if action == nil then
    log.warn(string.format("[%s] unsupported thermostat mode %s", device.label, tostring(mode)))
    return
  end
  action(device)
  device.thread:call_with_delay(2, function() read_mode_state(device) end)
end

local function set_thermostat_mode(driver, device, command)
  set_mode(driver, device, command.args.mode)
end

local function mode_setter(mode)
  return function(driver, device, command) set_mode(driver, device, mode) end
end

-- ---------------------------------------------------------------------------
-- Refresh / configure / lifecycle
-- ---------------------------------------------------------------------------
local function do_refresh(driver, device)
  device:send(Thermostat.attributes.LocalTemperature:read(device))
  device:send(Thermostat.attributes.OccupiedHeatingSetpoint:read(device))
  device:send(Thermostat.attributes.ThermostatRunningState:read(device))
  read_mode_state(device)
  device:send(RelativeHumidity.attributes.MeasuredValue:read(device))
  device:send(ElectricalMeasurement.attributes.ActivePower:read(device))
  device:send(SimpleMetering.attributes.CurrentSummationDelivered:read(device))
end

local function do_configure(driver, device)
  local hub_eui = driver.environment_info.hub_zigbee_eui
  for _, cluster_id in ipairs({ Thermostat.ID, ThermostatUI.ID, RelativeHumidity.ID,
                                SimpleMetering.ID, ElectricalMeasurement.ID }) do
    device:send(device_management.build_bind_request(device, cluster_id, hub_eui))
  end

  device:send(Thermostat.attributes.LocalTemperature:configure_reporting(device, 10, 300, 10))
  device:send(Thermostat.attributes.OccupiedHeatingSetpoint:configure_reporting(device, 1, 600, 10))
  device:send(Thermostat.attributes.SystemMode:configure_reporting(device, 1, 600))
  device:send(Thermostat.attributes.ThermostatRunningState:configure_reporting(device, 1, 600))
  device:send(Thermostat.attributes.ThermostatProgrammingOperationMode:configure_reporting(device, 1, 600))
  device:send(RelativeHumidity.attributes.MeasuredValue:configure_reporting(device, 10, 600, 100))
  device:send(ElectricalMeasurement.attributes.ActivePower:configure_reporting(device, 5, 600, 5))
  device:send(SimpleMetering.attributes.CurrentSummationDelivered:configure_reporting(device, 5, 3600, 1))

  -- scaling factors used by the default power/energy handlers
  device:send(ElectricalMeasurement.attributes.ACPowerMultiplier:read(device))
  device:send(ElectricalMeasurement.attributes.ACPowerDivisor:read(device))
  device:send(SimpleMetering.attributes.Multiplier:read(device))
  device:send(SimpleMetering.attributes.Divisor:read(device))

  if device.preferences.autoTimeSync ~= false then
    sync_clock(device, true)
  end
  do_refresh(driver, device)
end

local function emit_static_attributes(device)
  device:emit_event(ThermostatMode.supportedThermostatModes(SUPPORTED_MODES, { visibility = { displayed = false } }))
  device:emit_event(HeatingSetpoint.heatingSetpointRange({ value = { minimum = 5, maximum = max_heat_temp(device) }, unit = "C" },
    { visibility = { displayed = false } }))
end

local function device_added(driver, device)
  emit_static_attributes(device)
  do_refresh(driver, device)
end

-- Fired when the user switches an existing device (e.g. from "Zigbee Switch") to this driver.
-- The device keeps its old profile on a switch, so move it to ours first.
local function driver_switched(driver, device)
  device:try_update_metadata({ profile = "namron-edge-thermostat", provisioning_state = "PROVISIONED" })
  emit_static_attributes(device)
  do_configure(driver, device)
end

local function device_init(driver, device)
  -- The device does not always honour reporting configuration; poll as a safety net.
  device.thread:call_on_schedule(POLL_INTERVAL_S, function() do_refresh(driver, device) end, "namron_poll")
end

-- Preference name -> function(device, new_value). Each writer validates its input and
-- returns false (after logging) when the value is unusable, so nothing is sent.
local function int_pref(attr_id, data_type, min, max, scale)
  return function(device, v)
    local n = to_int_in_range(v, min, max)
    if n == nil then return false end
    write_custom(device, attr_id, data_type, n * (scale or 1))
    return true
  end
end

local PREFERENCE_WRITERS = {
  sensorMode       = int_pref(ATTR.SENSOR_MODE, data_types.Enum8, 0, 6),
  panelBrightness  = int_pref(ATTR.PANEL_BRIGHTNESS, data_types.Uint8, 1, 100),
  screenOnTime     = int_pref(ATTR.SCREEN_ON_TIME, data_types.Enum8, 0, 3),
  regulatorPercent = int_pref(ATTR.REGULATOR_PERCENT, data_types.Int16, 0, 100),
  tempCalibration = function(device, v)
    local tenths = to_int_in_range((tonumber(v) or 0/0) * 10, -30, 30)
    if tenths == nil then return false end
    device:send(Thermostat.attributes.LocalTemperatureCalibration:write(device, tenths))
    return true
  end,
  childLock = function(device, v)
    if type(v) ~= "boolean" then return false end
    device:send(ThermostatUI.attributes.KeypadLockout:write(device, v and 1 or 0))
    return true
  end,
  windowDetection = function(device, v)
    if type(v) ~= "boolean" then return false end
    write_custom(device, ATTR.WINDOW_CHECK, data_types.Boolean, v)
    return true
  end,
  maxHeatTemp = function(device, v)
    local n = to_int_in_range(v, 15, 35)
    if n == nil then return false end
    write_custom(device, ATTR.MAX_HEAT_TEMP, data_types.Int16, n * 10)
    device:set_field(FIELD_MAX_HEAT_TEMP, n, { persist = true })
    device:emit_event(HeatingSetpoint.heatingSetpointRange({ value = { minimum = 5, maximum = n }, unit = "C" },
      { visibility = { displayed = false } }))
    return true
  end,
  utcOffset = function(device, v)
    if valid_utc_offset_min(v) == nil then return false end
    if device.preferences.autoTimeSync ~= false then sync_clock(device, true) end
    return true
  end,
  autoTimeSync = function(device, v)
    if type(v) ~= "boolean" then return false end
    write_custom(device, ATTR.AUTO_TIME, data_types.Boolean, v)
    if v then sync_clock(device, true) end
    return true
  end,
}

local function info_changed(driver, device, event, args)
  local old_store = args and args.old_st_store
  if old_store == nil then return end

  -- A profile change (e.g. switching from "Zigbee Switch" to this driver) makes every
  -- preference look "new". Those are defaults, not user choices, so writing them would
  -- silently reconfigure the thermostat (sensor mode, limits...). Only act on real edits.
  local old_profile = old_store.profile and old_store.profile.id
  local new_profile = device.profile and device.profile.id
  if old_profile ~= nil and new_profile ~= nil and old_profile ~= new_profile then
    log.info(string.format("[%s] profile changed, not writing default preferences to the device", device.label))
    return
  end

  local old = old_store.preferences or {}
  for name, writer in pairs(PREFERENCE_WRITERS) do
    local new_value = device.preferences[name]
    if new_value ~= nil and new_value ~= old[name] then
      if not writer(device, new_value) then
        log.warn(string.format("[%s] ignoring invalid value %s for preference %s", device.label,
          tostring(new_value), name))
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Driver template
-- ---------------------------------------------------------------------------
local namron_template = {
  supported_capabilities = {
    capabilities.temperatureMeasurement,
    capabilities.thermostatHeatingSetpoint,
    capabilities.thermostatMode,
    capabilities.thermostatOperatingState,
    capabilities.relativeHumidityMeasurement,
    capabilities.powerMeter,
    capabilities.energyMeter,
    capabilities.refresh,
  },
  zigbee_handlers = {
    attr = {
      [SimpleMetering.ID] = {
        [SimpleMetering.attributes.CurrentSummationDelivered.ID] = energy_handler,
      },
      [ElectricalMeasurement.ID] = {
        [ElectricalMeasurement.attributes.ActivePower.ID] = power_handler,
      },
      [Thermostat.ID] = {
        [Thermostat.attributes.LocalTemperature.ID]                   = local_temperature_handler,
        [Thermostat.attributes.OccupiedHeatingSetpoint.ID]            = heating_setpoint_handler,
        [Thermostat.attributes.SystemMode.ID]                         = system_mode_handler,
        [Thermostat.attributes.ThermostatProgrammingOperationMode.ID] = programming_mode_handler,
        [Thermostat.attributes.ThermostatRunningState.ID]             = running_state_handler,
        [ATTR.FROST]             = frost_handler,
        [ATTR.SENSOR_MODE]       = sensor_mode_handler,
        [ATTR.WINDOW_STATE]      = window_state_handler,
        [ATTR.TIME_SYNC_REQUEST] = time_sync_request_handler,
      },
    },
  },
  capability_handlers = {
    [HeatingSetpoint.ID] = {
      [HeatingSetpoint.commands.setHeatingSetpoint.NAME] = set_heating_setpoint,
    },
    [ThermostatMode.ID] = {
      [ThermostatMode.commands.setThermostatMode.NAME] = set_thermostat_mode,
      [ThermostatMode.commands.off.NAME]  = mode_setter("off"),
      [ThermostatMode.commands.heat.NAME] = mode_setter("heat"),
      [ThermostatMode.commands.auto.NAME] = mode_setter("schedule"),
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh,
    },
  },
  lifecycle_handlers = {
    init        = device_init,
    added       = device_added,
    doConfigure = do_configure,
    driverSwitched = driver_switched,
    infoChanged = info_changed,
  },
  health_check = false,
}

defaults.register_for_default_handlers(namron_template, namron_template.supported_capabilities)
local driver = ZigbeeDriver("namron-edge-thermostat", namron_template)

driver:run()
