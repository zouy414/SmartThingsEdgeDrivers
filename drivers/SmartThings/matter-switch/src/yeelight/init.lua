-- Copyright 2024 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local capabilities = require "st.capabilities"
local clusters = require "st.matter.clusters"
local cluster_base = require "st.matter.cluster_base"
local data_types = require "st.matter.data_types"
local device_lib = require "st.device"
local utils = require "st.utils"
local log = require "log"

local lightingEffect = capabilities["amberwonder26407.lightingEffect"]
local YEELIGHT_MANUFACTURER_ID = 0x1312
local PRIVATE_CLUSTER_ENDPOINT_ID = 0x02
local PRIVATE_CLUSTER_ID = 0x1312FC05
local PRIVATE_LIGHTING_EFFECT_ATTR_ID = 0x13120000
local PRIVATE_LIGHTING_EFFECT_CMD_ID = 0x1312000e
local LIGHTING_EFFECT_ID = {
  ["streamer"]      = 0x03, -- AKA ribbon
  ["starrySky"]     = 0x05,
  ["aurora"]        = 0x0F,
  ["spectrum"]      = 0x11,
  ["waterfall"]     = 0x20,
  ["bonfire"]       = 0x22, -- AKA fire
  ["rainbow"]       = 0x27,
  ["waves"]         = 0x2A,
  ["pinball"]       = 0x25, -- AKA bouncingBall
  ["hacking"]       = 0x2E,
  ["meteor"]        = 0x2F,
  ["tide"]          = 0x30,
  ["buildingBlock"] = 0x31
}
local CURRENT_LIGHTING_EFFECT_KEY = "effectID"

local MOST_RECENT_TEMP = "mostRecentTemp"
local MIRED_KELVIN_CONVERSION_CONSTANT = 1000000
local COLOR_TEMPERATURE_KELVIN_MAX = 15000
local COLOR_TEMPERATURE_KELVIN_MIN = 1000
local COLOR_TEMPERATURE_MIRED_MAX = MIRED_KELVIN_CONVERSION_CONSTANT / COLOR_TEMPERATURE_KELVIN_MIN
local COLOR_TEMPERATURE_MIRED_MIN = MIRED_KELVIN_CONVERSION_CONSTANT / COLOR_TEMPERATURE_KELVIN_MAX

local function is_yeelight_products(opts, driver, device)
  -- this sub driver does not support child devices
  if device.network_type == device_lib.NETWORK_TYPE_MATTER and
      device.manufacturer_info.vendor_id == YEELIGHT_MANUFACTURER_ID then
    return true
  end
  return false
end

local function device_init(driver, device)
  device:subscribe()
  device:send(
    cluster_base.subscribe(device, PRIVATE_CLUSTER_ENDPOINT_ID, PRIVATE_CLUSTER_ID, PRIVATE_LIGHTING_EFFECT_ATTR_ID, nil)
  )
end

local function device_added(driver, device)
  device:emit_event(lightingEffect.state("custom"))
end

local function lighting_effect_attr_handler(driver, device, ib, zb_rx)
  for key, value in pairs(LIGHTING_EFFECT_ID) do
    if value == ib.data.value then
      device:emit_event(lightingEffect.state(key))
      device:set_field(CURRENT_LIGHTING_EFFECT_KEY, key, { persist = true })
      return
    end
  end
  log.warn("can not find matched light effect: " .. ib.data.value)
  device:emit_event(lightingEffect.state("custom"))
end

local function hue_attr_handler(driver, device, ib, response)
  if ib.data.value ~= nil then
    local hue = math.floor((ib.data.value / 0xFE * 100) + 0.5)
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.colorControl.hue(hue))
    device:emit_event(lightingEffect.state("custom"))
  end
end

local function sat_attr_handler(driver, device, ib, response)
  if ib.data.value ~= nil then
    local sat = math.floor((ib.data.value / 0xFE * 100) + 0.5)
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.colorControl.saturation(sat))
    device:emit_event(lightingEffect.state("custom"))
  end
end

local function find_child(parent, ep_id)
  return parent:get_child_by_parent_assigned_key(string.format("%d", ep_id))
end

local function temp_attr_handler(driver, device, ib, response)
  if ib.data.value ~= nil then
    if (ib.data.value < COLOR_TEMPERATURE_MIRED_MIN or ib.data.value > COLOR_TEMPERATURE_MIRED_MAX) then
      device.log.warn_with({ hub_logs = true }, string.format("Device reported color temperature %d mired outside of sane range of %.2f-%.2f", ib.data.value, COLOR_TEMPERATURE_MIRED_MIN, COLOR_TEMPERATURE_MIRED_MAX))
      return
    end
    local temp = utils.round(MIRED_KELVIN_CONVERSION_CONSTANT / ib.data.value)
    local temp_device = find_child(device, ib.endpoint_id) or device
    local most_recent_temp = temp_device:get_field(MOST_RECENT_TEMP)
    -- this is to avoid rounding errors from the round-trip conversion of Kelvin to mireds
    if most_recent_temp ~= nil and
        most_recent_temp <= utils.round(MIRED_KELVIN_CONVERSION_CONSTANT / (ib.data.value - 1)) and
        most_recent_temp >= utils.round(MIRED_KELVIN_CONVERSION_CONSTANT / (ib.data.value + 1)) then
      temp = most_recent_temp
    end
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.colorTemperature.colorTemperature(temp))
    device:emit_event(lightingEffect.state("custom"))
  end
end

local function lighting_effect_cap_handler(driver, device, cmd)
  local effectId = data_types.validate_or_build_type(LIGHTING_EFFECT_ID[cmd.args.stateControl], data_types.Uint64, "effectId")
  effectId["field_id"] = 1

  device:send(
    cluster_base.build_cluster_command(
      driver,
      device,
      {
        ["effectId"] = effectId
      },
      0x02,
      PRIVATE_CLUSTER_ID,
      PRIVATE_LIGHTING_EFFECT_CMD_ID,
      nil
    )
  )

  if device:get_field(CURRENT_LIGHTING_EFFECT_KEY) == cmd.args.stateControl then
    device:emit_event(lightingEffect.state(cmd.args.stateControl))
  end
end

local yeelight_smart_lamp = {
  NAME = "Yeelight Smart Lamp",
  lifecycle_handlers = {
    init = device_init,
    added = device_added
  },
  matter_handlers = {
    attr = {
      [PRIVATE_CLUSTER_ID] = {
        [PRIVATE_LIGHTING_EFFECT_ATTR_ID] = lighting_effect_attr_handler
      },
      [clusters.ColorControl.ID] = {
        [clusters.ColorControl.attributes.CurrentHue.ID] = hue_attr_handler,
        [clusters.ColorControl.attributes.CurrentSaturation.ID] = sat_attr_handler,
        [clusters.ColorControl.attributes.ColorTemperatureMireds.ID] = temp_attr_handler
      }
    }
  },
  capability_handlers = {
    [lightingEffect.ID] = {
      [lightingEffect.commands.stateControl.NAME] = lighting_effect_cap_handler
    }
  },
  can_handle = is_yeelight_products
}

return yeelight_smart_lamp
