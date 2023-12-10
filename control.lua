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
  [1]=2,
  [2]=5,
  [5]=10,
  [10]=20,
  [20]=40,
  [40]=1 -- allow for looping back around, so fixing a mistake is easy
}

-- =================
-- Utility Functions
-- =================

local function create_flying_text(player, text_string, display_position)
  player.create_local_flying_text({text = text_string, position = display_position})
end


local function set_inserter_limit(event, entity)  
  local green_connection = entity.get_circuit_network(defines.wire_type.green)
  local red_connection = entity.get_circuit_network(defines.wire_type.red)
  if (not green_connection and not red_connection ) then return end
  
  -- determine if limit already set
  local circuit_settings = entity.get_or_create_control_behavior()
  local circuit_condition = circuit_settings["circuit_condition"].condition
  
  local stacks_to_limit = 1
  if (circuit_condition.first_signal.name ~= _item_name)
  then
    circuit_condition.first_signal = {type="item", name=_item_name}
  else  
    -- check the existing constant value, to move to next/nearest one.
    local current_stacks = math.floor(circuit_condition.constant / _item_stack_size)

    current_stacks = (current_stacks < 40) and current_stacks or 40
    current_stacks = (current_stacks > 0) and current_stacks or 1

    while ((current_stacks > 1) and (not _MAGIC_NUMBER_STACK_LIMIT_PROGRESSION[current_stacks])) do
      current_stacks = current_stacks - 1
    end

    stacks_to_limit = _MAGIC_NUMBER_STACK_LIMIT_PROGRESSION[current_stacks]
  end

  
  -- Set the value
  local circuit_limit_value = stacks_to_limit * _item_stack_size
  circuit_settings["circuit_condition"] = {condition = {first_signal = {type = "item", name = _item_name}, constant = circuit_limit_value}}

  local floating_text = "[item=".. _item_name .. "] < " .. circuit_limit_value
  create_flying_text(game.players[event.player_index], floating_text, entity.position)
end


-- =================
-- Event Definitions
-- =================


script.on_event("pmls-copy", function(event)

  -- LuaEntity
  local entity = game.players[event.player_index].selected
  if (not entity) then clear_copied_info() return end

  if (entity.prototype.type ~= "assembling-machine") then return end

  -- LuaRecipe
  local recipe = entity.get_recipe()
  if (not recipe) then clear_copied_info() return end

  local num_products = 0
  for _, product in ipairs(recipe.prototype.products) do
    num_products = num_products + 1
  end
  if (num_products ~= 1)
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
  
    create_flying_text(game.players[event.player_index], "[item=" .. _item_name ..  "][virtual-signal=signal-green]", entity.position)
  end

end)


script.on_event("pmls-paste", function(event)
  if (_item_name == nil or _item_stack_size == nil) then return end

  local entity = game.players[event.player_index].selected
  if (not entity) then return end


  if (entity.prototype.type == "inserter")
  then
    set_inserter_limit(event, entity)
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

    local floating_text = "[item=logistic-chest-storage][item=" .. _item_name .. "]"
    create_flying_text(game.players[event.player_index], floating_text, entity.position)
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
    entity.set_request_slot({name=_item_name, count=_MAGIC_NUMBER_BUFFER_REQUEST_QUANTITY}, 1)
    
    local floating_text = "[item=logistic-chest-buffer][item=" .. _item_name .. "] 50k"
    create_flying_text(game.players[event.player_index], floating_text, entity.position)
  end
end)