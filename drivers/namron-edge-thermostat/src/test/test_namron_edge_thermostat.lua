-- Integration tests for the Namron Edge Thermostat driver
local test              = require "integration_test"
local t_utils           = require "integration_test.utils"
local zigbee_test_utils = require "integration_test.zigbee_test_utils"
local capabilities      = require "st.capabilities"
local clusters          = require "st.zigbee.zcl.clusters"
local data_types        = require "st.zigbee.data_types"
local cluster_base      = require "st.zigbee.cluster_base"
local zcl_messages      = require "st.zigbee.zcl"
local messages          = require "st.zigbee.messages"
local zb_const          = require "st.zigbee.constants"
local generic_body      = require "st.zigbee.generic_body"
local FrameCtrl         = require "st.zigbee.zcl.frame_ctrl"

local Thermostat   = clusters.Thermostat
local ThermostatUI = clusters.ThermostatUserInterfaceConfiguration

local mock_device = test.mock_device.build_test_zigbee_device({
  profile = t_utils.get_profile_definition("namron-edge-thermostat.yml"),
  zigbee_endpoints = {
    [1] = {
      id = 1,
      manufacturer = "Namron AS",
      model = "4512783",
      server_clusters = { 0x0000, 0x0003, 0x0006, 0x0201, 0x0204, 0x0405, 0x0702, 0x0B04 },
    },
  },
})

zigbee_test_utils.prepare_zigbee_env_info()

local function test_init()
  test.mock_device.add_test_device(mock_device)
end
test.set_test_init_function(test_init)

-- The thermostat takes local *standard* time (#19); utcOffset defaults to 1 h (CET).
local function thermostat_time(offset_hours)
  return os.time() - 946684800 + math.floor((offset_hours or 1) * 3600)
end

local SUPPORTED_MODES = { "off", "heat", "eco", "schedule", "frostguard" }

local function mode_event(mode)
  return mock_device:generate_test_message("main",
    capabilities.thermostatMode.thermostatMode[mode]({ data = { supportedThermostatModes = SUPPORTED_MODES } }))
end

local function custom_report(attr_id, dt_id, value)
  return zigbee_test_utils.build_attribute_report(mock_device, Thermostat.ID, { { attr_id, dt_id, value } })
end

local function custom_read(attr_id)
  return cluster_base.read_attribute(mock_device, data_types.ClusterId(Thermostat.ID), data_types.AttributeId(attr_id))
end

local function custom_write(attr_id, value)
  return cluster_base.write_attribute(mock_device, data_types.ClusterId(Thermostat.ID),
    data_types.AttributeId(attr_id), value)
end

local function thermostat_cmd(cmd_id, flag)
  local fc = FrameCtrl(0x00)
  fc:set_cluster_specific()
  return messages.ZigbeeMessageTx({
    address_header = messages.AddressHeader(zb_const.HUB.ADDR, zb_const.HUB.ENDPOINT,
      mock_device:get_short_address(), 1, zb_const.HA_PROFILE_ID, Thermostat.ID),
    body = zcl_messages.ZclMessageBody({
      zcl_header = zcl_messages.ZclHeader({ cmd = data_types.ZCLCommandId(cmd_id), frame_ctrl = fc }),
      zcl_body = generic_body.GenericBody(string.char(flag and 1 or 0)),
    }),
  })
end

test.register_message_test(
  "Local temperature report is emitted as temperatureMeasurement",
  {
    { channel = "zigbee", direction = "receive",
      message = { mock_device.id, Thermostat.attributes.LocalTemperature:build_test_attr_report(mock_device, 2350) } },
    { channel = "capability", direction = "send",
      message = mock_device:generate_test_message("main",
        capabilities.temperatureMeasurement.temperature({ value = 23.5, unit = "C" })) },
  }
)

test.register_message_test(
  "Heating setpoint report is emitted",
  {
    { channel = "zigbee", direction = "receive",
      message = { mock_device.id, Thermostat.attributes.OccupiedHeatingSetpoint:build_test_attr_report(mock_device, 2150) } },
    { channel = "capability", direction = "send",
      message = mock_device:generate_test_message("main",
        capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = 21.5, unit = "C" })) },
  }
)

test.register_message_test(
  "Running state heat bit maps to heating",
  {
    { channel = "zigbee", direction = "receive",
      message = { mock_device.id, Thermostat.attributes.ThermostatRunningState:build_test_attr_report(mock_device, 0x0001) } },
    { channel = "capability", direction = "send",
      message = mock_device:generate_test_message("main",
        capabilities.thermostatOperatingState.thermostatOperatingState.heating()) },
  }
)

test.register_message_test(
  "Running state with no bits maps to idle",
  {
    { channel = "zigbee", direction = "receive",
      message = { mock_device.id, Thermostat.attributes.ThermostatRunningState:build_test_attr_report(mock_device, 0x0000) } },
    { channel = "capability", direction = "send",
      message = mock_device:generate_test_message("main",
        capabilities.thermostatOperatingState.thermostatOperatingState.idle()) },
  }
)

test.register_coroutine_test(
  "Mode is derived from system mode, programming mode and frost flag",
  function()
    test.socket.zigbee:__queue_receive({ mock_device.id,
      Thermostat.attributes.SystemMode:build_test_attr_report(mock_device, 0x04) })
    test.socket.capability:__expect_send(mode_event("heat"))
    test.wait_for_events()

    test.socket.zigbee:__queue_receive({ mock_device.id,
      Thermostat.attributes.ThermostatProgrammingOperationMode:build_test_attr_report(mock_device, 0x04) })
    test.socket.capability:__expect_send(mode_event("eco"))
    test.wait_for_events()

    test.socket.zigbee:__queue_receive({ mock_device.id,
      Thermostat.attributes.ThermostatProgrammingOperationMode:build_test_attr_report(mock_device, 0x01) })
    test.socket.capability:__expect_send(mode_event("schedule"))
    test.wait_for_events()

    test.socket.zigbee:__queue_receive({ mock_device.id, custom_report(0x8001, data_types.Boolean.ID, true) })
    test.socket.capability:__expect_send(mode_event("frostguard"))
    test.wait_for_events()

    test.socket.zigbee:__queue_receive({ mock_device.id,
      Thermostat.attributes.SystemMode:build_test_attr_report(mock_device, 0x00) })
    test.socket.capability:__expect_send(mode_event("off"))
    test.wait_for_events()
  end
)

test.register_coroutine_test(
  "setHeatingSetpoint writes the setpoint and reads it back",
  function()
    test.timer.__create_and_queue_test_time_advance_timer(2, "oneshot")
    test.socket.capability:__queue_receive({ mock_device.id,
      { capability = "thermostatHeatingSetpoint", component = "main", command = "setHeatingSetpoint", args = { 22.5 } } })
    test.socket.zigbee:__expect_send({ mock_device.id,
      Thermostat.attributes.OccupiedHeatingSetpoint:write(mock_device, 2250) })
    test.wait_for_events()
    test.mock_time.advance_time(2)
    test.socket.zigbee:__expect_send({ mock_device.id,
      Thermostat.attributes.OccupiedHeatingSetpoint:read(mock_device) })
    test.wait_for_events()
  end
)

test.register_coroutine_test(
  "setHeatingSetpoint is clamped to the 5-35 range",
  function()
    test.timer.__create_and_queue_test_time_advance_timer(2, "oneshot")
    test.socket.capability:__queue_receive({ mock_device.id,
      { capability = "thermostatHeatingSetpoint", component = "main", command = "setHeatingSetpoint", args = { 3 } } })
    test.socket.zigbee:__expect_send({ mock_device.id,
      Thermostat.attributes.OccupiedHeatingSetpoint:write(mock_device, 500) })
    test.wait_for_events()
  end
)

test.register_coroutine_test(
  "Setting eco mode switches heating on and sends setEco(true)",
  function()
    test.timer.__create_and_queue_test_time_advance_timer(2, "oneshot")
    test.socket.capability:__queue_receive({ mock_device.id,
      { capability = "thermostatMode", component = "main", command = "setThermostatMode", args = { "eco" } } })
    test.socket.zigbee:__expect_send({ mock_device.id, Thermostat.attributes.SystemMode:write(mock_device, 0x04) })
    test.socket.zigbee:__expect_send({ mock_device.id, thermostat_cmd(0x08, true) })
    test.wait_for_events()
    test.mock_time.advance_time(2)
    test.socket.zigbee:__expect_send({ mock_device.id, Thermostat.attributes.SystemMode:read(mock_device) })
    test.socket.zigbee:__expect_send({ mock_device.id,
      Thermostat.attributes.ThermostatProgrammingOperationMode:read(mock_device) })
    test.socket.zigbee:__expect_send({ mock_device.id, custom_read(0x8001) })
    test.wait_for_events()
  end
)

test.register_coroutine_test(
  "Setting heat from eco clears eco and schedule",
  function()
    test.socket.zigbee:__queue_receive({ mock_device.id,
      Thermostat.attributes.SystemMode:build_test_attr_report(mock_device, 0x04) })
    test.socket.capability:__expect_send(mode_event("heat"))
    test.wait_for_events()

    test.timer.__create_and_queue_test_time_advance_timer(2, "oneshot")
    test.socket.capability:__queue_receive({ mock_device.id,
      { capability = "thermostatMode", component = "main", command = "heat", args = {} } })
    test.socket.zigbee:__expect_send({ mock_device.id, thermostat_cmd(0x08, false) })
    test.socket.zigbee:__expect_send({ mock_device.id, thermostat_cmd(0x07, false) })
    test.wait_for_events()
  end
)

test.register_coroutine_test(
  "Setting frostguard writes the frost attribute after a read",
  function()
    test.timer.__create_and_queue_test_time_advance_timer(2, "oneshot")
    test.socket.capability:__queue_receive({ mock_device.id,
      { capability = "thermostatMode", component = "main", command = "setThermostatMode", args = { "frostguard" } } })
    test.socket.zigbee:__expect_send({ mock_device.id, Thermostat.attributes.SystemMode:write(mock_device, 0x04) })
    test.socket.zigbee:__expect_send({ mock_device.id, custom_read(0x8001) })
    test.socket.zigbee:__expect_send({ mock_device.id, custom_write(0x8001, data_types.Boolean(true)) })
    test.wait_for_events()
  end
)

test.register_coroutine_test(
  "Changing preferences writes the matching attributes",
  function()
    test.socket.device_lifecycle:__queue_receive(mock_device:generate_info_changed({
      preferences = { sensorMode = "6", childLock = true, panelBrightness = 80, tempCalibration = -1.5 },
    }))
    test.socket.zigbee:__set_channel_ordering("relaxed")
    test.socket.zigbee:__expect_send({ mock_device.id, custom_read(0x8004) })
    test.socket.zigbee:__expect_send({ mock_device.id, custom_write(0x8004, data_types.Enum8(6)) })
    test.socket.zigbee:__expect_send({ mock_device.id, ThermostatUI.attributes.KeypadLockout:write(mock_device, 1) })
    test.socket.zigbee:__expect_send({ mock_device.id, custom_read(0x8005) })
    test.socket.zigbee:__expect_send({ mock_device.id, custom_write(0x8005, data_types.Uint8(80)) })
    test.socket.zigbee:__expect_send({ mock_device.id,
      Thermostat.attributes.LocalTemperatureCalibration:write(mock_device, -15) })
    test.wait_for_events()
  end
)

test.register_coroutine_test(
  "Clock sync request from the device is answered",
  function()
    test.mock_time.advance_time(1790000000) -- a 2026 timestamp
    test.socket.zigbee:__queue_receive({ mock_device.id, custom_report(0x800A, data_types.Boolean.ID, true) })
    test.socket.zigbee:__expect_send({ mock_device.id, custom_read(0x800B) })
    test.socket.zigbee:__expect_send({ mock_device.id,
      custom_write(0x800B, data_types.Uint32(thermostat_time())) })
    test.socket.zigbee:__expect_send({ mock_device.id, custom_read(0x800A) })
    test.socket.zigbee:__expect_send({ mock_device.id, custom_write(0x800A, data_types.Boolean(false)) })
    test.wait_for_events()
  end
)

test.register_message_test(
  "Refresh reads all state",
  {
    { channel = "capability", direction = "receive",
      message = { mock_device.id, { capability = "refresh", component = "main", command = "refresh", args = {} } } },
    { channel = "zigbee", direction = "send",
      message = { mock_device.id, Thermostat.attributes.LocalTemperature:read(mock_device) } },
    { channel = "zigbee", direction = "send",
      message = { mock_device.id, Thermostat.attributes.OccupiedHeatingSetpoint:read(mock_device) } },
    { channel = "zigbee", direction = "send",
      message = { mock_device.id, Thermostat.attributes.ThermostatRunningState:read(mock_device) } },
    { channel = "zigbee", direction = "send",
      message = { mock_device.id, Thermostat.attributes.SystemMode:read(mock_device) } },
    { channel = "zigbee", direction = "send",
      message = { mock_device.id, Thermostat.attributes.ThermostatProgrammingOperationMode:read(mock_device) } },
    { channel = "zigbee", direction = "send",
      message = { mock_device.id, custom_read(0x8001) } },
    { channel = "zigbee", direction = "send",
      message = { mock_device.id, clusters.RelativeHumidity.attributes.MeasuredValue:read(mock_device) } },
    { channel = "zigbee", direction = "send",
      message = { mock_device.id, clusters.ElectricalMeasurement.attributes.ActivePower:read(mock_device) } },
    { channel = "zigbee", direction = "send",
      message = { mock_device.id, clusters.SimpleMetering.attributes.CurrentSummationDelivered:read(mock_device) } },
  }
)

test.register_coroutine_test(
  "Power is scaled with the device's divisor once known",
  function()
    local EM = clusters.ElectricalMeasurement
    test.socket.zigbee:__queue_receive({ mock_device.id, EM.attributes.ACPowerDivisor:build_test_attr_report(mock_device, 1) })
    test.socket.zigbee:__queue_receive({ mock_device.id, EM.attributes.ActivePower:build_test_attr_report(mock_device, 1200) })
    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.powerMeter.power({ value = 1200.0, unit = "W" })))
    test.wait_for_events()
  end
)

test.register_coroutine_test(
  "Bug #8: energy is not reported until the metering divisor is known (no 100x spike)",
  function()
    local SM = clusters.SimpleMetering
    -- report arrives before the divisor: nothing emitted, scale requested
    test.socket.zigbee:__queue_receive({ mock_device.id, SM.attributes.CurrentSummationDelivered:build_test_attr_report(mock_device, 15668) })
    test.socket.zigbee:__expect_send({ mock_device.id, SM.attributes.Multiplier:read(mock_device) })
    test.socket.zigbee:__expect_send({ mock_device.id, SM.attributes.Divisor:read(mock_device) })
    test.wait_for_events()
    -- divisor arrives, next report is scaled correctly
    test.socket.zigbee:__queue_receive({ mock_device.id, SM.attributes.Divisor:build_test_attr_report(mock_device, 100) })
    test.socket.zigbee:__queue_receive({ mock_device.id, SM.attributes.CurrentSummationDelivered:build_test_attr_report(mock_device, 15668) })
    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.energyMeter.energy({ value = 156.68, unit = "kWh" })))
    test.wait_for_events()
  end
)

test.register_coroutine_test(
  "#14: energy scale requests are rate limited while the divisor is unknown",
  function()
    local SM = clusters.SimpleMetering
    local function energy_report()
      test.socket.zigbee:__queue_receive({ mock_device.id, SM.attributes.CurrentSummationDelivered:build_test_attr_report(mock_device, 15668) })
    end
    local function expect_scale_request()
      test.socket.zigbee:__expect_send({ mock_device.id, SM.attributes.Multiplier:read(mock_device) })
      test.socket.zigbee:__expect_send({ mock_device.id, SM.attributes.Divisor:read(mock_device) })
    end
    test.mock_time.advance_time(1790000000)
    energy_report()
    expect_scale_request()
    test.wait_for_events()
    -- further reports within 5 minutes: nothing sent, nothing emitted
    for _ = 1, 5 do
      test.mock_time.advance_time(5)
      energy_report()
      test.wait_for_events()
    end
    -- after 5 minutes the scale is requested again
    test.mock_time.advance_time(300)
    energy_report()
    expect_scale_request()
    test.wait_for_events()
  end
)

test.register_coroutine_test(
  "Power falls back to raw watts if the device never reports a divisor",
  function()
    local EM = clusters.ElectricalMeasurement
    for _ = 1, 3 do
      test.socket.zigbee:__queue_receive({ mock_device.id, EM.attributes.ActivePower:build_test_attr_report(mock_device, 800) })
      test.socket.zigbee:__expect_send({ mock_device.id, EM.attributes.ACPowerMultiplier:read(mock_device) })
      test.socket.zigbee:__expect_send({ mock_device.id, EM.attributes.ACPowerDivisor:read(mock_device) })
      test.wait_for_events()
    end
    test.socket.zigbee:__queue_receive({ mock_device.id, EM.attributes.ActivePower:build_test_attr_report(mock_device, 800) })
    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.powerMeter.power({ value = 800.0, unit = "W" })))
    test.wait_for_events()
  end
)

test.register_message_test(
  "Humidity report is emitted",
  {
    { channel = "zigbee", direction = "receive",
      message = { mock_device.id, clusters.RelativeHumidity.attributes.MeasuredValue:build_test_attr_report(mock_device, 4500) } },
    { channel = "capability", direction = "send",
      message = mock_device:generate_test_message("main", capabilities.relativeHumidityMeasurement.humidity({ value = 45 })) },
  }
)

local function expect_configure_messages()
  local SM, EM, RH = clusters.SimpleMetering, clusters.ElectricalMeasurement, clusters.RelativeHumidity
  for _, cid in ipairs({ Thermostat.ID, ThermostatUI.ID, RH.ID, SM.ID, EM.ID }) do
    test.socket.zigbee:__expect_send({ mock_device.id,
      zigbee_test_utils.build_bind_request(mock_device, zigbee_test_utils.mock_hub_eui, cid) })
  end
  local expected = {
    Thermostat.attributes.LocalTemperature:configure_reporting(mock_device, 10, 300, 10),
    Thermostat.attributes.OccupiedHeatingSetpoint:configure_reporting(mock_device, 1, 600, 10),
    Thermostat.attributes.SystemMode:configure_reporting(mock_device, 1, 600),
    Thermostat.attributes.ThermostatRunningState:configure_reporting(mock_device, 1, 600),
    Thermostat.attributes.ThermostatProgrammingOperationMode:configure_reporting(mock_device, 1, 600),
    RH.attributes.MeasuredValue:configure_reporting(mock_device, 10, 600, 100),
    EM.attributes.ActivePower:configure_reporting(mock_device, 5, 600, 5),
    SM.attributes.CurrentSummationDelivered:configure_reporting(mock_device, 5, 3600, 1),
    EM.attributes.ACPowerMultiplier:read(mock_device),
    EM.attributes.ACPowerDivisor:read(mock_device),
    SM.attributes.Multiplier:read(mock_device),
    SM.attributes.Divisor:read(mock_device),
    custom_read(0x800B),
    custom_write(0x800B, data_types.Uint32(thermostat_time())),
    custom_read(0x800A),
    custom_write(0x800A, data_types.Boolean(false)),
    Thermostat.attributes.LocalTemperature:read(mock_device),
    Thermostat.attributes.OccupiedHeatingSetpoint:read(mock_device),
    Thermostat.attributes.ThermostatRunningState:read(mock_device),
    Thermostat.attributes.SystemMode:read(mock_device),
    Thermostat.attributes.ThermostatProgrammingOperationMode:read(mock_device),
    custom_read(0x8001),
    RH.attributes.MeasuredValue:read(mock_device),
    EM.attributes.ActivePower:read(mock_device),
    SM.attributes.CurrentSummationDelivered:read(mock_device),
  }
  for _, msg in ipairs(expected) do
    test.socket.zigbee:__expect_send({ mock_device.id, msg })
  end
end

test.register_coroutine_test(
  "doConfigure binds, configures reporting, syncs the clock and refreshes",
  function()
    test.mock_time.advance_time(1790000000)
    test.socket.zigbee:__set_channel_ordering("relaxed")
    test.socket.device_lifecycle:__queue_receive({ mock_device.id, "doConfigure" })
    expect_configure_messages()
    mock_device:expect_metadata_update({ provisioning_state = "PROVISIONED" })
    test.wait_for_events()
  end
)

test.register_coroutine_test(
  "driverSwitched moves the device to the thermostat profile and configures it",
  function()
    test.mock_time.advance_time(1790000000)
    test.socket.zigbee:__set_channel_ordering("relaxed")
    test.socket.device_lifecycle:__queue_receive({ mock_device.id, "driverSwitched" })
    mock_device:expect_metadata_update({ profile = "namron-edge-thermostat", provisioning_state = "PROVISIONED" })
    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.thermostatMode.supportedThermostatModes(SUPPORTED_MODES, { visibility = { displayed = false } })))
    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.thermostatHeatingSetpoint.heatingSetpointRange({ value = { minimum = 5, maximum = 35 }, unit = "C" },
        { visibility = { displayed = false } })))
    expect_configure_messages()
    test.wait_for_events()
  end
)


--- Queue a refresh and expect exactly its reads. Because channel ordering is strict,
--- any message sent earlier by the handler under test makes this fail - which is how
--- the tests below assert "nothing was sent to the device".
local function expect_only_refresh_after(device)
  device = device or mock_device
  test.socket.capability:__queue_receive({ device.id,
    { capability = "refresh", component = "main", command = "refresh", args = {} } })
  for _, msg in ipairs({
    Thermostat.attributes.LocalTemperature:read(device),
    Thermostat.attributes.OccupiedHeatingSetpoint:read(device),
    Thermostat.attributes.ThermostatRunningState:read(device),
    Thermostat.attributes.SystemMode:read(device),
    Thermostat.attributes.ThermostatProgrammingOperationMode:read(device),
    cluster_base.read_attribute(device, data_types.ClusterId(Thermostat.ID), data_types.AttributeId(0x8001)),
    clusters.RelativeHumidity.attributes.MeasuredValue:read(device),
    clusters.ElectricalMeasurement.attributes.ActivePower:read(device),
    clusters.SimpleMetering.attributes.CurrentSummationDelivered:read(device),
  }) do
    test.socket.zigbee:__expect_send({ device.id, msg })
  end
  test.wait_for_events()
end

-- A thermostat that was paired before this driver existed: it still has the stock
-- "Zigbee Switch"-style profile, with none of this driver's preferences.
local switched_device = test.mock_device.build_test_zigbee_device({
  profile = {
    components = { main = { id = "main", capabilities = {
      { id = "switch", version = 1 }, { id = "powerMeter", version = 1 }, { id = "refresh", version = 1 },
    } } },
    preferences = {},
  },
  zigbee_endpoints = {
    [1] = {
      id = 1,
      manufacturer = "Namron AS",
      model = "4512783",
      server_clusters = { 0x0000, 0x0003, 0x0006, 0x0201, 0x0204, 0x0405, 0x0702, 0x0B04 },
    },
  },
})

-- ---------------------------------------------------------------------------
-- Security review 2026-09 regression tests
-- ---------------------------------------------------------------------------

test.register_coroutine_test(
  "SR-1: preference defaults are NOT written when the profile changes (driver switch)",
  function()
    local namron_profile = t_utils.get_profile_definition("namron-edge-thermostat.yml")
    test.socket.device_lifecycle:__queue_receive(switched_device:generate_info_changed({
      profile = namron_profile,
      preferences = { sensorMode = "1", childLock = false, windowDetection = false, panelBrightness = 50,
                      screenOnTime = "1", regulatorPercent = 50, maxHeatTemp = 35, tempCalibration = 0,
                      autoTimeSync = true },
    }))
    expect_only_refresh_after(switched_device)
  end,
  { test_init = function() test.mock_device.add_test_device(switched_device) end }
)

test.register_coroutine_test(
  "SR-2: repeated clock sync requests from the device are rate limited",
  function()
    test.mock_time.advance_time(1790000000)
    local function expect_sync()
      test.socket.zigbee:__expect_send({ mock_device.id, custom_read(0x800B) })
      test.socket.zigbee:__expect_send({ mock_device.id,
        custom_write(0x800B, data_types.Uint32(thermostat_time())) })
      test.socket.zigbee:__expect_send({ mock_device.id, custom_read(0x800A) })
      test.socket.zigbee:__expect_send({ mock_device.id, custom_write(0x800A, data_types.Boolean(false)) })
    end
    test.socket.zigbee:__queue_receive({ mock_device.id, custom_report(0x800A, data_types.Boolean.ID, true) })
    expect_sync()
    test.wait_for_events()

    -- same request again a minute later: ignored
    test.mock_time.advance_time(60)
    test.socket.zigbee:__queue_receive({ mock_device.id, custom_report(0x800A, data_types.Boolean.ID, true) })
    test.wait_for_events()

    -- after the 5 minute window it is answered again
    test.mock_time.advance_time(300)
    test.socket.zigbee:__queue_receive({ mock_device.id, custom_report(0x800A, data_types.Boolean.ID, true) })
    expect_sync()
    test.wait_for_events()
  end
)

test.register_coroutine_test(
  "SR-3: out-of-range preference values are ignored",
  function()
    test.socket.device_lifecycle:__queue_receive(mock_device:generate_info_changed({
      preferences = { sensorMode = "9", panelBrightness = 500, tempCalibration = 12, maxHeatTemp = 99 },
    }))
    expect_only_refresh_after()
  end
)

test.register_coroutine_test(
  "#16: setpoints are limited to the last valid max heat temp, not a rejected preference",
  function()
    test.socket.device_lifecycle:__queue_receive(mock_device:generate_info_changed({
      preferences = { maxHeatTemp = 20 } }))
    test.socket.zigbee:__expect_send({ mock_device.id, custom_read(0x8025) })
    test.socket.zigbee:__expect_send({ mock_device.id, custom_write(0x8025, data_types.Int16(200)) })
    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.thermostatHeatingSetpoint.heatingSetpointRange({ value = { minimum = 5, maximum = 20 }, unit = "C" },
        { visibility = { displayed = false } })))
    test.wait_for_events()
    -- invalid value: not written, and must not raise the setpoint limit
    test.socket.device_lifecycle:__queue_receive(mock_device:generate_info_changed({
      preferences = { maxHeatTemp = 99 } }))
    test.wait_for_events()
    test.socket.capability:__queue_receive({ mock_device.id,
      { capability = "thermostatHeatingSetpoint", component = "main", command = "setHeatingSetpoint", args = { 30 } } })
    test.socket.zigbee:__expect_send({ mock_device.id,
      Thermostat.attributes.OccupiedHeatingSetpoint:write(mock_device, 2000) })
    test.wait_for_events()
  end
)

test.register_coroutine_test(
  "#19: changing the time zone syncs the clock as local standard time",
  function()
    test.mock_time.advance_time(1790000000)
    test.socket.device_lifecycle:__queue_receive(mock_device:generate_info_changed({
      preferences = { utcOffset = 2 } }))
    test.socket.zigbee:__expect_send({ mock_device.id, custom_read(0x800B) })
    test.socket.zigbee:__expect_send({ mock_device.id, custom_write(0x800B, data_types.Uint32(thermostat_time(2))) })
    test.socket.zigbee:__expect_send({ mock_device.id, custom_read(0x800A) })
    test.socket.zigbee:__expect_send({ mock_device.id, custom_write(0x800A, data_types.Boolean(false)) })
    test.wait_for_events()
  end
)

test.register_coroutine_test(
  "#19: an out-of-range time zone is ignored",
  function()
    test.mock_time.advance_time(1790000000)
    test.socket.device_lifecycle:__queue_receive(mock_device:generate_info_changed({
      preferences = { utcOffset = 20 } }))
    expect_only_refresh_after()
  end
)

test.register_message_test(
  "SR-3: an invalid (0x8000) setpoint report is not emitted",
  {
    { channel = "zigbee", direction = "receive",
      message = { mock_device.id, Thermostat.attributes.OccupiedHeatingSetpoint:build_test_attr_report(mock_device, -32768) } },
  }
)

test.register_message_test(
  "SR-3: an implausible temperature report is not emitted",
  {
    { channel = "zigbee", direction = "receive",
      message = { mock_device.id, Thermostat.attributes.LocalTemperature:build_test_attr_report(mock_device, 12000) } },
  }
)

test.register_coroutine_test(
  "SR-3: setThermostatMode('auto') maps to the device's schedule mode",
  function()
    test.timer.__create_and_queue_test_time_advance_timer(2, "oneshot")
    test.socket.capability:__queue_receive({ mock_device.id,
      { capability = "thermostatMode", component = "main", command = "setThermostatMode", args = { "auto" } } })
    test.socket.zigbee:__expect_send({ mock_device.id, Thermostat.attributes.SystemMode:write(mock_device, 0x04) })
    test.socket.zigbee:__expect_send({ mock_device.id, thermostat_cmd(0x08, false) })
    test.socket.zigbee:__expect_send({ mock_device.id, thermostat_cmd(0x07, true) })
    test.wait_for_events()
  end
)

test.run_registered_tests()
