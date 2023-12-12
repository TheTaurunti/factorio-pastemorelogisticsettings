-- ============================================
-- Set up variables for in-script data transfer
-- ============================================

local _item_name = nil
local _item_stack_size = nil

local function clear_copied_info()
  _item_name = nil
  _item_stack_size = nil
end

-- ================================
-- Hardcoded Numbers Initialization
-- ================================

local _MAGIC_NUMBER_BUFFER_REQUEST_QUANTITY = 50000
local _MAGIC_NUMBER_STACK_LIMIT_PROGRESSION = {
  [1] = 2,
  [2] = 5,
  [5] = 10,
  [10] = 20,
  [20] = 40,
  [40] = 1 -- allow for looping back around, so fixing a mistake is easy
}

-- =================
-- Utility Functions
-- =================

local function create_flying_text(player, text_string, display_position)
  player.create_local_flying_text({ text = text_string, position = display_position })
end

local function standardize_vector(vector)
  return ((vector.x and vector.y) and vector) or { x = vector[1], y = vector[2] }
end

local function get_real_pickup_dropoff_positions(inserter_entity)
  local direction = inserter_entity.direction
  local inserter_position = standardize_vector(inserter_entity.position)
  local pickup = standardize_vector(inserter_entity.prototype.inserter_pickup_position)
  local dropoff = standardize_vector(inserter_entity.prototype.inserter_drop_position)

  -- Inserter pickup/drop vectors need a translation
  -- ... based on the entity's rotation.
  local ret_pickup = nil
  local ret_dropoff = nil
  if (direction == defines.direction.north)
  then
    ret_pickup = { x = pickup.x, y = pickup.y }
    ret_dropoff = { x = dropoff.x, y = dropoff.y }
    goto end_inserter_rotation_vector_adjustment
  end
  if (direction == defines.direction.south)
  then
    ret_pickup = { x = pickup.x, y = 0 - pickup.y }
    ret_dropoff = { x = dropoff.x, y = 0 - dropoff.y }
    goto end_inserter_rotation_vector_adjustment
  end
  if (direction == defines.direction.east)
  then
    ret_pickup = { x = 0 - pickup.y, y = pickup.x }
    ret_dropoff = { x = 0 - dropoff.y, y = dropoff.x }
    goto end_inserter_rotation_vector_adjustment
  end
  if (direction == defines.direction.west)
  then
    ret_pickup = { x = pickup.y, y = pickup.x }
    ret_dropoff = { x = dropoff.y, y = dropoff.x }
    goto end_inserter_rotation_vector_adjustment
  end
  ::end_inserter_rotation_vector_adjustment::

  -- This only happens if rotation is diagonal.
  -- >> I return nil because ??? how to rotate for diagonal direction
  if (not ret_pickup or not ret_dropoff) then return nil end

  local ret = {
    pickup = {
      inserter_position.x + ret_pickup.x,
      inserter_position.y + ret_pickup.y
    },
    drop = {
      inserter_position.x + ret_dropoff.x,
      inserter_position.y + ret_dropoff.y
    }
  }

  return ret
end

local function get_container(surface, position)
  local at_pickup = surface.find_entities_filtered {
    position = position,
    type = { "container", "logistic-container" }
  }
  return (#at_pickup > 0 and at_pickup[1]) or nil
end

local function get_next_stack_amount(current_stacks)
  local immediate_lookup = _MAGIC_NUMBER_STACK_LIMIT_PROGRESSION[current_stacks]
  if (immediate_lookup) then return immediate_lookup end

  local closest = { index = 1, diff = 1000 }
  for k, v in pairs(_MAGIC_NUMBER_STACK_LIMIT_PROGRESSION) do
    local difference = math.abs(current_stacks - v)
    if (difference <= closest.diff)
    then
      closest.index = k
      closest.diff = difference
    end
  end

  return _MAGIC_NUMBER_STACK_LIMIT_PROGRESSION[closest.index]
end

local function inserter_paste_logic(event, inserter)
  -- Check #1 - Can I work with this inserter?
  local pickup_drop_positions = get_real_pickup_dropoff_positions(inserter)
  if (not pickup_drop_positions) then return end

  -- Check #2 - Can I work with this inserter?
  local container_at_pickup = get_container(inserter.surface, pickup_drop_positions.pickup)
  local container_at_dropoff = get_container(inserter.surface, pickup_drop_positions.drop)

  local container_to_connect = container_at_pickup or container_at_dropoff
  local circuit_condition_comparator = container_at_pickup and ">" or "<"

  -- Make a connection, if one doesn't exist
  local green_connection = inserter.get_circuit_network(defines.wire_type.green)
  local red_connection = inserter.get_circuit_network(defines.wire_type.red)
  if ((not green_connection) and (not red_connection) and container_to_connect)
  then
    inserter.connect_neighbour {
      wire = defines.wire_type.green,
      target_entity = container_to_connect
    }
  end

  -- Don't try setting stack size if there is no connection
  if (not (green_connection or red_connection or container_to_connect))
  then
    return
  end

  -- Set the circuit condition
  -- Determine # of stacks for inserter limit
  local circuit_settings = inserter.get_or_create_control_behavior()
  local circuit_condition = circuit_settings["circuit_condition"].condition

  local stacks_to_limit = 1
  if (circuit_condition.first_signal.name == _item_name)
  then
    local current_stacks = math.floor(circuit_condition.constant / _item_stack_size)
    stacks_to_limit = get_next_stack_amount(current_stacks)
  end

  -- Set the value
  local circuit_limit_value = stacks_to_limit * _item_stack_size
  circuit_settings["circuit_condition"] = {
    condition = {
      first_signal = { type = "item", name = _item_name },
      comparator = circuit_condition_comparator,
      constant = circuit_limit_value
    }
  }

  local floating_text = "[item=" .. _item_name .. "] " .. circuit_condition_comparator .. " " .. circuit_limit_value
  create_flying_text(game.players[event.player_index], floating_text, inserter.position)
end


-- =================
-- Event Definitions
-- =================


script.on_event("pmls-copy", function(event)
  -- LuaEntity
  local entity = game.players[event.player_index].selected
  if (not entity) then
    clear_copied_info()
    return
  end

  if (entity.prototype.type ~= "assembling-machine") then return end

  -- LuaRecipe
  local recipe = entity.get_recipe()
  if (not recipe) then
    clear_copied_info()
    return
  end

  if (#recipe.prototype.products ~= 1)
  then
    create_flying_text(game.players[event.player_index], "[virtual-signal=signal-red]", entity.position)
    clear_copied_info()
    return
  end

  -- Need to check item prototypes, as some recipes output fluids.
  local item_name = recipe.prototype.products[1].name
  if (game.item_prototypes[item_name])
  then
    _item_name = item_name
    _item_stack_size = game.item_prototypes[_item_name].stack_size

    create_flying_text(game.players[event.player_index], "[item=" .. _item_name .. "][virtual-signal=signal-green]",
      entity.position)
  end
end)


script.on_event("pmls-paste", function(event)
  if (_item_name == nil or _item_stack_size == nil) then return end

  local entity = game.players[event.player_index].selected
  if (not entity) then return end


  if (entity.prototype.type == "inserter")
  then
    inserter_paste_logic(event, entity)
  end

  -- https://lua-api.factorio.com/latest/classes/LuaEntityPrototype.html#logistic_mode
  local logistic_mode = entity.prototype.logistic_mode
  if (logistic_mode and (logistic_mode == "storage"))
  then
    entity["storage_filter"] = game.item_prototypes[_item_name]

    -- This function is what clears locked slots
    -- https://lua-api.factorio.com/latest/classes/LuaInventory.html#set_bar
    local chest_inventory = entity.get_inventory(defines.inventory.chest)
    chest_inventory.set_bar()

    local text = "[item=logistic-chest-storage][item=" .. _item_name .. "]"
    create_flying_text(game.players[event.player_index], text, entity.position)
  end
end)


-- https://lua-api.factorio.com/latest/events.html#on_entity_settings_pasted
script.on_event(defines.events.on_entity_settings_pasted, function(event)
  if (_item_name == nil or _item_stack_size == nil) then return end

  local entity = game.players[event.player_index].selected
  if (not entity) then return end

  -- https://lua-api.factorio.com/latest/classes/LuaEntityPrototype.html#logistic_mode
  local logistic_mode = entity.prototype.logistic_mode
  if (logistic_mode and (logistic_mode == "buffer"))
  then
    local chest_inventory = entity.get_inventory(defines.inventory.chest)
    chest_inventory.set_bar()

    -- request_slot_count
    -- The index of the configured request with the highest index for this entity.
    -- https://lua-api.factorio.com/latest/classes/LuaEntity.html#request_slot_count
    -- >> Reads 0 when no requests, reads 20 when 20th slot is configured
    -- https://lua-api.factorio.com/latest/classes/LuaEntity.html#clear_request_slot
    local highest_slot_index = entity.request_slot_count
    while (highest_slot_index > 1) do
      entity.clear_request_slot(highest_slot_index)
      highest_slot_index = entity.request_slot_count
    end

    -- https://lua-api.factorio.com/latest/classes/LuaEntity.html#set_request_slot
    entity.set_request_slot({ name = _item_name, count = _MAGIC_NUMBER_BUFFER_REQUEST_QUANTITY }, 1)

    local floating_text = "[item=logistic-chest-buffer][item=" .. _item_name .. "] 50k"
    create_flying_text(game.players[event.player_index], floating_text, entity.position)
  end
end)
