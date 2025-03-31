-- =============================================
-- Set up variables for tracking copied settings
-- =============================================

local _is_info_copied = false

local _recipe = nil
local _has_ingredients = nil
local _item_product_prototypes = nil
local _current_product_index = nil

local _quality_name = nil
local _item_flying_text_name = nil

local _last_copied_from = nil


local function clear_copied_info()
  _is_info_copied = false

  _recipe = nil
  _has_ingredients = nil
  _item_product_prototypes = nil
  _current_product_index = nil

  _quality_name = nil
  _item_flying_text_name = nil

  _last_copied_from = nil
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

local function create_flying_text(event, text_string, display_position)
  game.players[event.player_index].create_local_flying_text({ text = text_string, position = display_position })
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
  -- https://lua-api.factorio.com/latest/classes/LuaGenericOnOffControlBehavior.html
  local circuit_settings = entity.get_or_create_control_behavior()
  local enable_condition = circuit_settings.circuit_condition

  local current_product_proto = _item_product_prototypes[_current_product_index]

  local stacks_to_limit = 1
  if (enable_condition and enable_condition.first_signal)
  then
    local name_matches = (enable_condition.first_signal.name == current_product_proto.name)
    local qual_matches = (enable_condition.first_signal.quality == nil or enable_condition.first_signal.quality == _quality_name)

    if (name_matches and qual_matches)
    then
      local current_stacks = math.floor(enable_condition.constant / current_product_proto.stack_size)
      stacks_to_limit = _MAGIC_NUMBER_STACK_LIMIT_PROGRESSION[current_stacks] or 1
    end
  end
  local circuit_limit_value = stacks_to_limit * current_product_proto.stack_size

  -- Set the value
  circuit_settings.circuit_enable_disable = true
  circuit_settings.circuit_condition = {
    first_signal = { type = "item", name = current_product_proto.name, quality = _quality_name },
    comparator = circuit_condition_comparator,
    constant = circuit_limit_value
  }

  local floating_text = _item_flying_text_name .. " " .. circuit_condition_comparator .. " " .. circuit_limit_value
  create_flying_text(event, floating_text, entity.position)
end

local function format_flying_text_item_name(item_name, quality_name)
  local quality_name_part = quality_name and (",quality=" .. quality_name) or ""
  return "[item=" .. item_name .. quality_name_part .. "]"
end

local function recipe_has_ingredients(recipe_prototype)
  local ingredients = recipe_prototype.ingredients
  if (ingredients == nil) then return false end
  return #ingredients > 0
end

local function recipe_has_products(recipe_prototype)
  local products = recipe_prototype.products
  if (products == nil) then return false end
  return #products > 0
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

  -- Firstly, set filters to override the vanilla behavior of ingredients-as-filters
  local num_filters = inserter.filter_slot_count
  if (num_filters and num_filters > 0)
  then
    -- first filter set to output item
    inserter.set_filter(1, { name = _item_product_prototypes[_current_product_index].name, quality = _quality_name })

    -- clear remaining filters
    for i = 2, num_filters, 1 do
      inserter.set_filter(i, nil)
    end

    inserter.inserter_filter_mode = "whitelist"
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

-- Setting combinator outputs as ingredients of the recipe
local function combinator_paste_logic(event, combinator)
  local _max_combinator_paste_variants = 3

  local function _get_next_combinator_value_set(control_behavior)
    local num_sections = control_behavior.sections_count
    if (num_sections < 1) then return 1 end

    local section_one_slot_one = control_behavior.get_section(1).get_slot(1)
    if (section_one_slot_one == nil) then return 1 end
    if (section_one_slot_one.value == nil) then return 1 end

    local to_return = ((section_one_slot_one.value.name == "blueprint") and section_one_slot_one.min + 1) or 1
    return (to_return > _max_combinator_paste_variants) and 1 or to_return
  end
  local function _set_signals_in_section(ingredients, section, quality_to_set, override_amount_as_one)
    local index = 1

    for _, ingred in ipairs(ingredients) do
      -- Not limiting to items for 2 reasons:
      --  1) Does not matter when setting filters
      --  2) If using combinators as ingred reminders, fluids are useful to show.
      section.set_slot(index, {
        min = override_amount_as_one and 1 or ingred.amount,
        value = { type = ingred.type, name = ingred.name, quality = quality_to_set }
      })
      index = index + 1
    end
  end

  -- Begin function body here (util functions above)
  if (not _is_info_copied) then return end
  local ingredients = (_has_ingredients and _recipe.prototype.ingredients) or {}

  -- https://lua-api.factorio.com/stable/classes/LuaConstantCombinatorControlBehavior.html
  local combinator_control_behavior = combinator.get_control_behavior()
  local next_value_set = _get_next_combinator_value_set(combinator_control_behavior)

  -- delete all sections
  for i = combinator_control_behavior.sections_count, 1, -1 do
    combinator_control_behavior.remove_section(i)
  end

  -- a metadata section for this mod
  local mod_section = combinator_control_behavior.add_section()
  mod_section.active = false
  mod_section.set_slot(1, {
    min = next_value_set,
    value = {
      type = "item",
      name = "blueprint",
      quality = _quality_name
    }
  })

  -- Creating text here to simplify following code
  local variant_text = "(" .. next_value_set .. "/" .. _max_combinator_paste_variants .. ")"
  local text = "[item=constant-combinator]" .. "[virtual-signal=signal-green]" .. variant_text
  create_flying_text(event, text, combinator.position)

  -- base case, setting blank combinator to ingredients
  if (next_value_set == 1) then
    local ingred_section = combinator_control_behavior.add_section()
    _set_signals_in_section(ingredients, ingred_section, _quality_name, false)
    return
  end

  -- non-base case(s): get all quality permutations for inputs/outputs
  local inputs_outputs_to_use = (next_value_set == 2 and ingredients) or _recipe.prototype.products
  for qual_name, _ in pairs(prototypes.quality) do
    if (qual_name ~= "quality-unknown") then
      local qual_section = combinator_control_behavior.add_section()
      _set_signals_in_section(inputs_outputs_to_use, qual_section, qual_name, true)
      qual_section.multiplier = -15
    end
  end
end

local function entity_with_recipe_copy_logic(entity)
  -- Returns "LuaRecipe, LuaQualityPrototype"
  local recipe, quality = entity.get_recipe()

  -- No recipe set, good to reset data
  if (not recipe) then
    clear_copied_info()
    return false
  end

  -- when re-copying from machine, rotate to next product
  if (_is_info_copied and (recipe.prototype.name == _recipe.prototype.name) and (quality.name == _quality_name))
  then
    -- fmod here is essentially the modulo operator
    -- https://stackoverflow.com/questions/9695697/lua-replacement-for-the-operator
    _current_product_index = math.fmod(_current_product_index, #_item_product_prototypes) + 1
    _item_flying_text_name = format_flying_text_item_name(_item_product_prototypes[_current_product_index].name,
      _quality_name)
    return true
  end


  -- If recipe has no output, there is no reason to copy it's information
  if (not recipe_has_products(recipe.prototype))
  then
    clear_copied_info()
    return false
  end


  -- Now record the information of the recipe
  local item_products = {}
  for _, product in ipairs(recipe.prototype.products) do
    if (product.type == "item")
    then
      table.insert(item_products, prototypes.item[product.name])
    end
  end

  _is_info_copied = true

  _recipe = recipe
  _has_ingredients = recipe_has_ingredients(recipe.prototype)

  _item_product_prototypes = item_products
  _current_product_index = 1

  _quality_name = quality.name
  _item_flying_text_name = format_flying_text_item_name(_item_product_prototypes[_current_product_index].name,
    _quality_name)


  _last_copied_from = entity.type

  return true
end


-- =================
-- Event Definitions
-- =================

local _VALID_PMLS_COPY_TARGETS = {
  ["assembling-machine"] = entity_with_recipe_copy_logic,
  ["furnace"] = entity_with_recipe_copy_logic


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
  local text = "[virtual-signal=signal-red]"
  if (settings_copy_was_successful)
  then
    local variant_text = "(" .. _current_product_index .. "/" .. #_item_product_prototypes .. ")"
    text = _item_flying_text_name .. "[virtual-signal=signal-green]" .. variant_text
  end

  -- Give player feedback
  create_flying_text(event, text, entity.position)
end)


script.on_event("pmls-paste", function(event)
  if (not _is_info_copied or _current_product_index == nil) then return end

  local entity = game.players[event.player_index].selected
  if (not entity) then return end

  if (_last_copied_from == "furnace") then
    if (entity.prototype.type == "inserter")
    then
      inserter_paste_logic(event, entity)
      return
    end
  end

  if (entity.prototype.type == "constant-combinator")
  then
    combinator_paste_logic(event, entity)
    return
  end

  if (entity.prototype.type == "transport-belt")
  then
    transport_belt_paste_logic(event, entity)
    return
  end

  -- https://lua-api.factorio.com/latest/classes/LuaEntityPrototype.html#logistic_mode
  local logistic_mode = entity.prototype.logistic_mode
  if (logistic_mode and (logistic_mode == "storage"))
  then
    entity["storage_filter"] = { name = _item_product_prototypes[_current_product_index].name, quality = _quality_name }

    -- This function is what clears locked slots
    -- https://lua-api.factorio.com/latest/classes/LuaInventory.html#set_bar
    local chest_inventory = entity.get_inventory(defines.inventory.chest)
    chest_inventory.set_bar()

    local text = "[item=storage-chest]" .. _item_flying_text_name
    create_flying_text(event, text, entity.position)
  end
end)


-- https://lua-api.factorio.com/latest/events.html#on_entity_settings_pasted
script.on_event(defines.events.on_entity_settings_pasted, function(event)
  game.print("here")
  if (not _is_info_copied) then return end


  local entity = game.players[event.player_index].selected
  if (not entity) then return end


  -- last_copied_from check to avoid doing work twice
  if (_last_copied_from ~= "furnace")
  then
    -- This has to be done here rather than in pmls-paste, otherwise...
    -- ... vanilla behavior of inserter filters set as ingredients occurs
    if (entity.prototype.type == "inserter")
    then
      inserter_paste_logic(event, entity)
      return
    end
  end


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
      value = { name = _item_product_prototypes[_current_product_index].name, quality = _quality_name },
      min = _MAGIC_NUMBER_BUFFER_REQUEST_QUANTITY
    })

    local floating_text = "[item=buffer-chest]" .. _item_flying_text_name .. " 50k"
    create_flying_text(event, floating_text, entity.position)
  end
end)
