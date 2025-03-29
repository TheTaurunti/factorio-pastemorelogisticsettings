-- =============================================
-- Set up variables for tracking copied settings
-- =============================================

local _item_name = nil
local _item_stack_size = nil
local _item_quality_name = nil

local _item_flying_text_name = nil

local function clear_copied_info()
  _item_name = nil
  _item_stack_size = nil
  _item_quality_name = nil
  _item_flying_text_name = nil
end

local function set_item_name_and_stack(item_name, quality_name)
  if (not item_name) then return false end
  if (prototypes.item[item_name])
  then
    _item_name = item_name
    _item_stack_size = prototypes.item[_item_name].stack_size
    _item_quality_name = quality_name

    local quality_name_part = _item_quality_name and (",quality=" .. _item_quality_name) or ""
    _item_flying_text_name = "[item=" .. _item_name .. quality_name_part .. "]"
    return true
  else
    return false
  end
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

local _LOADER_ENTITY_TYPES = {
  ["loader"] = true,
  ["loader-1x1"] = true,
  ["loader-1x2"] = true
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

local function rotate_vector_from_north(vector, direction)
  if (direction == defines.direction.north)
  then
    return { x = vector.x, y = vector.y }
  end
  if (direction == defines.direction.south)
  then
    return { x = vector.x, y = 0 - vector.y }
  end
  if (direction == defines.direction.east)
  then
    return { x = 0 - vector.y, y = vector.x }
  end
  if (direction == defines.direction.west)
  then
    return { x = vector.y, y = vector.x }
  end

  return nil
end


local function connect_neighbor_if_unconnected(entity_connect_from, entity_connect_to)
  local green_connection = entity_connect_from.get_wire_connector(defines.wire_connector_id.circuit_green)
  local red_connection = entity_connect_from.get_wire_connector(defines.wire_connector_id.circuit_red)

  if (not red_connection and not green_connection)
  then
    -- Handles the only "failure" of this function: No current connection AND no connection can be made.
    if (not entity_connect_to) then return false end

    -- We only auto-connect to containers.
    if (
          entity_connect_to.prototype.type ~= "container"
          and entity_connect_to.prototype.type ~= "logistic-container"
        )
    then
      return false
    end

    local green_connection_point = entity_connect_from.get_wire_connector(defines.wire_connector_id.circuit_green, true)
    green_connection_point.connect_to(entity_connect_to.get_wire_connector(defines.wire_connector_id.circuit_green, true))
  end

  return true
end


local function set_enable_condition(event, entity, circuit_condition_comparator)
  -- Nested utility function for better organization
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

  -- https://lua-api.factorio.com/latest/classes/LuaGenericOnOffControlBehavior.html
  local circuit_settings = entity.get_or_create_control_behavior()
  local enable_condition = circuit_settings.circuit_condition

  local stacks_to_limit = 1
  if (enable_condition and enable_condition.first_signal and enable_condition.first_signal.name == _item_name)
  then
    local current_stacks = math.floor(enable_condition.constant / _item_stack_size)
    stacks_to_limit = get_next_stack_amount(current_stacks)
  end
  local circuit_limit_value = stacks_to_limit * _item_stack_size

  -- Set the value
  circuit_settings.circuit_enable_disable = true
  circuit_settings.circuit_condition = {
    first_signal = { type = "item", name = _item_name, quality = _item_quality_name },
    comparator = circuit_condition_comparator,
    constant = circuit_limit_value
  }

  local floating_text = _item_flying_text_name .. " " .. circuit_condition_comparator .. " " .. circuit_limit_value
  create_flying_text(game.players[event.player_index], floating_text, entity.position)
end



-- ===============
-- Main Logic Here
-- ===============


local function inserter_paste_logic(event, inserter)
  -- Defined as nested functions to keep things organized
  local function inserter_get_real_target_positions(inserter_entity)
    -- Inserter pickup/drop vectors need a translation
    -- ... based on the entity's rotation.
    local pickup = standardize_vector(inserter_entity.prototype.inserter_pickup_position)
    local dropoff = standardize_vector(inserter_entity.prototype.inserter_drop_position)

    local ret_pickup = rotate_vector_from_north(pickup, inserter_entity.direction)
    local ret_dropoff = rotate_vector_from_north(dropoff, inserter_entity.direction)

    -- These should only be nil if the inserter has diagonal rotation
    if (not ret_pickup or not ret_dropoff) then return nil end

    local inserter_position = standardize_vector(inserter_entity.position)
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
  local function inserter_get_container(surface, position)
    local at_pickup = surface.find_entities_filtered {
      position = position,
      type = { "container", "logistic-container" }
    }
    return (#at_pickup > 0 and at_pickup[1]) or nil
  end

  -- Check #1 - Can I work with this inserter?
  local pickup_drop_positions = inserter_get_real_target_positions(inserter)
  if (not pickup_drop_positions) then return end

  local container_at_pickup = inserter_get_container(inserter.surface, pickup_drop_positions.pickup)
  local container_at_dropoff = inserter_get_container(inserter.surface, pickup_drop_positions.drop)

  local container_to_connect = container_at_pickup or container_at_dropoff
  local circuit_condition_comparator = container_at_pickup and ">" or "<"

  if (not connect_neighbor_if_unconnected(inserter, container_to_connect))
  then
    return
  end

  -- Set the circuit condition
  set_enable_condition(event, inserter, circuit_condition_comparator)

  -- Need to clear filters because in 2.0 copy pasting from assembler will set filters to ingredients.
  -- It's cool, but completely and entirely against what this mod does - enable/disable condition set to RESULT
  -- OH MY GOD WHY CAN'T I CHANGE THE DAMN FILTERS I TRIED EVERYTHING
  -- >> Best I can do is blacklist the ingredients instead of whitelist. Not ideal but works.	
  inserter.inserter_filter_mode = "blacklist"
end


local function transport_belt_paste_logic(event, belt)
  -- Defining helper as a nested function to try and keep things organized
  local function belt_get_container(neighbors)
    if (#neighbors == 0) then return nil end

    local loader = nil
    for _, neighbor in ipairs(neighbors) do
      if (_LOADER_ENTITY_TYPES[neighbor.type])
      then
        loader = neighbor
      end
    end

    if (not loader) then return nil end
    return loader.loader_container
  end

  local belt_neighbors = belt.belt_neighbours

  -- TEST belt with no neighbors, or just input/just output
  -- TEST belt with underground in/output (should be fine)

  local output_container_entity = belt_get_container(belt_neighbors["outputs"])
  local input_container_entity = belt_get_container(belt_neighbors["inputs"])

  local container_to_connect = input_container_entity or output_container_entity
  local circuit_condition_comparator = input_container_entity and ">" or "<"

  if (not connect_neighbor_if_unconnected(belt, container_to_connect))
  then
    return
  end


  -- Set the circuit condition
  -- Determine # of stacks for inserter limit
  -- https://lua-api.factorio.com/latest/classes/LuaTransportBeltControlBehavior.html

  set_enable_condition(event, belt, circuit_condition_comparator)
end


local function assembler_copy_logic(entity)
  clear_copied_info()

  -- Returns "LuaRecipe, LuaQualityPrototype"
  local recipe, quality = entity.get_recipe()
  if (not recipe) then return false end

  local products = recipe.prototype.products
  if (products and #products ~= 1)
  then
    return false
  end

  return set_item_name_and_stack(products[1].name, quality.name)
end


-- =================
-- Event Definitions
-- =================

local _VALID_PMLS_COPY_TARGETS = {
  ["assembling-machine"] = assembler_copy_logic


  -- After playing around with it, I've found that copying
  -- ... from containers interferes with the expected NORMAL
  -- ... copy-paste settings capability of containers.
  -- >> Best to keep this mod focused on transferring settings
  -- ... between entities you normally CAN'T transfer.
  -- ["container"] = container_copy_logic,
  -- ["logistic-container"] = container_copy_logic
}


script.on_event("pmls-copy", function(event)
  local entity = game.players[event.player_index].selected
  if (not entity) then
    clear_copied_info()
    return
  end


  local settings_copy_function = _VALID_PMLS_COPY_TARGETS[entity.prototype.type]
  if (not settings_copy_function) then return end


  local settings_copy_was_successful = settings_copy_function(entity)
  local text = (
    settings_copy_was_successful
    and (_item_flying_text_name .. "[virtual-signal=signal-green]")
    or "[virtual-signal=signal-red]"
  )

  -- Give player feedback
  create_flying_text(game.players[event.player_index], text, entity.position)
end)


script.on_event("pmls-paste", function(event)
  if (_item_name == nil or _item_stack_size == nil) then return end

  local entity = game.players[event.player_index].selected
  if (not entity) then return end

  if (entity.prototype.type == "inserter")
  then
    inserter_paste_logic(event, entity)
  end

  if (entity.prototype.type == "transport-belt")
  then
    transport_belt_paste_logic(event, entity)
  end

  -- https://lua-api.factorio.com/latest/classes/LuaEntityPrototype.html#logistic_mode
  local logistic_mode = entity.prototype.logistic_mode
  if (logistic_mode and (logistic_mode == "storage"))
  then
    entity["storage_filter"] = prototypes.item[_item_name]

    -- This function is what clears locked slots
    -- https://lua-api.factorio.com/latest/classes/LuaInventory.html#set_bar
    local chest_inventory = entity.get_inventory(defines.inventory.chest)
    chest_inventory.set_bar()

    local text = "[item=storage-chest]" .. _item_flying_text_name
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

    -- logistic request time. Clear existing then make mine.
    local logi_point = entity.get_requester_point()
    while (logi_point.sections_count and logi_point.sections_count > 0) do
      logi_point.remove_section(1)
    end

    -- https://lua-api.factorio.com/latest/classes/LuaLogisticPoint.html#add_section
    local new_section = logi_point.add_section()
    new_section.set_slot(1, {
      value = { name = _item_name, quality = _item_quality_name },
      min = _MAGIC_NUMBER_BUFFER_REQUEST_QUANTITY
    })

    local floating_text = "[item=buffer-chest]" .. _item_flying_text_name .. " 50k"
    create_flying_text(game.players[event.player_index], floating_text, entity.position)
  end
end)
