-- =============================================
-- Set up variables for tracking copied settings
-- =============================================

local _item_name = nil
local _item_stack_size = nil

local function clear_copied_info()
  _item_name = nil
  _item_stack_size = nil
end

local function set_item_name_and_stack(item_name)
  if (not item_name) then return false end
  if (game.item_prototypes[item_name])
  then
    _item_name = item_name
    _item_stack_size = game.item_prototypes[_item_name].stack_size
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
  local green_connection = entity_connect_from.get_circuit_network(defines.wire_type.green)
  local red_connection = entity_connect_from.get_circuit_network(defines.wire_type.red)

  if (not red_connection and not green_connection)
  then
    -- The only time there WON'T be a circuit connection after this function,
    -- ... is if there isn't a current connection AND no new connection could be made.
    if (not entity_connect_to) then return false end

    entity_connect_from.connect_neighbour {
      wire = defines.wire_type.green,
      target_entity = entity_connect_to
    }
  end

  return true
end


local function set_enable_condition(event, entity, item_name, circuit_condition_comparator)
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

  local circuit_settings = entity.get_or_create_control_behavior()
  local circuit_condition = circuit_settings["circuit_condition"].condition

  local stacks_to_limit = 1
  if (circuit_condition.first_signal.name == item_name)
  then
    local current_stacks = math.floor(circuit_condition.constant / _item_stack_size)
    stacks_to_limit = get_next_stack_amount(current_stacks)
  end

  -- Set the value
  local circuit_limit_value = stacks_to_limit * _item_stack_size
  circuit_settings["circuit_condition"] = {
    condition = {
      first_signal = { type = "item", name = item_name },
      comparator = circuit_condition_comparator,
      constant = circuit_limit_value
    }
  }

  local floating_text = "[item=" .. item_name .. "] " .. circuit_condition_comparator .. " " .. circuit_limit_value
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
  set_enable_condition(event, inserter, _item_name, circuit_condition_comparator)
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

  -- Might not need the below two conditions
  -- circuit_condition.read_contents = false
  -- circuit_condition.enable_disable = true

  set_enable_condition(event, belt, _item_name, circuit_condition_comparator)
end


local function assembler_copy_logic(entity)
  clear_copied_info()

  -- LuaRecipe
  local recipe = entity.get_recipe()
  if (not recipe) then return false end

  local item_name = recipe.prototype.products[1].name
  if (#recipe.prototype.products ~= 1)
  then
    return false
  end

  return set_item_name_and_stack(item_name)
end

local function container_copy_logic(entity)
  -- Nested function for better organization
  local function container_get_inventory_item_name(container)
    local container_inventory = container.get_inventory(defines.inventory.chest)
    local inventory_contents = container_inventory.get_contents()

    local item_names = {}
    for k, _ in pairs(inventory_contents) do
      table.insert(item_names, k)
    end
    if (#item_names == 1)
    then
      return item_names[1]
    else
      return nil
    end
  end

  clear_copied_info()

  local logistic_mode = entity.prototype.logistic_mode
  if (not logistic_mode)
  then
    local item_name = container_get_inventory_item_name(entity)
    return set_item_name_and_stack(item_name)
  end

  -- Storage Chests
  if (logistic_mode == "storage" and entity["storage_filter"])
  then
    local item_name = entity["storage_filter"]
    return set_item_name_and_stack(item_name)
  end

  -- Buffer / Requester Chests
  if (logistic_mode == "requester" or logistic_mode == "buffer")
  then
    local requests = {}
    local request_slot_index = entity.request_slot_count
    while (request_slot_index > 0) do
      local item_stack = entity.get_request_slot(request_slot_index)
      if (item_stack)
      then
        table.insert(requests, (item_stack.name or item_stack))
      end
      request_slot_index = request_slot_index - 1
    end

    if (#requests == 1)
    then
      return set_item_name_and_stack(requests[1])
    end
  end

  -- Logistic Chest fallback
  local item_name = container_get_inventory_item_name(entity)
  return set_item_name_and_stack(item_name)
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
    and "[item=" .. _item_name .. "][virtual-signal=signal-green]"
    or "[virtual-signal=signal-red]"
  )

  -- Give player feedback
  create_flying_text(
    game.players[event.player_index],
    text,
    entity.position
  )
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
