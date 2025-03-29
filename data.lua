-- =================
-- Setting Up Events
-- =================

local settings_copy = {
  type = "custom-input",
  name = "pmls-copy",
  key_sequence = "",
  linked_game_control = "copy-entity-settings",
  consuming = "none"
}

local settings_paste = {
  type = "custom-input",
  name = "pmls-paste",
  key_sequence = "",
  linked_game_control = "paste-entity-settings",
  consuming = "none"
}

data:extend { settings_copy }
data:extend { settings_paste }
