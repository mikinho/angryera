std = "lua51"
max_line_length = false
codes = true
ranges = true

-- Exclude third-party libraries from code quality checks
exclude_files = {
   "Libs/**/*.lua",
   "libs/**/*.lua"
}

-- Explicitly whitelist the global variables that your addon creates,
-- WoW's standard globals that get mutated, and SavedVariables.
globals = {
   -- Addon Base & Saved Variables
   "AngryAssign",
   "AngryAssign_Pages",
   "AngryAssign_Categories",
   "AngryAssign_State",
   "AngryAssign_Config",
   "AngryAssign_Templates",

   -- Keybind and Display Globals
   "AngryAssign_ToggleWindow",
   "AngryAssign_ToggleLock",
   "AngryAssign_ToggleDisplay",
   "AngryAssign_ShowDisplay",
   "AngryAssign_HideDisplay",
   "AngryAssign_PrevPage",
   "AngryAssign_NextPage",
   "AngryAssign_FirstPage",
   "AngryAssign_PageMenu",
   "AngryAssign_Window",
   "AngryAssign_OutputDisplayed",

   -- Built-in WoW UI Globals mutated by this addon
   "StaticPopupDialogs"
}

-- Luacheck does not support enforcing:
-- 1) quote style (single vs double),
-- 2) indentation style (tabs vs spaces),
-- 3) single-line control statement formatting.
-- These are handled by formatter configuration (see `.stylua.toml`).

ignore = {
   -- We are ignoring 113 (Accessing undefined globals) because we don't 
   -- have the entire WoW API globally mocked out here yet.
   "113", 
   
   "212", -- unused callback arguments are common in UI/event handlers
   "213", -- unused loop variables (e.g., 'for k, _ in ...' where k isn't used)
   "631", -- line length is handled separately by project style checks
}
