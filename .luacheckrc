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
   -- Addon Object
   "AngryEra",

   -- SavedVariables (declared in both TOC files)
   "AngryAssign_Pages",
   "AngryAssign_Categories",
   "AngryAssign_State",
   "AngryAssign_Config",
   "AngryAssign_Templates",
   "AngryAssign_Meta",

   -- Keybind and Display Globals
   "AngryEra_ToggleWindow",
   "AngryEra_ToggleLock",
   "AngryEra_ToggleDisplay",
   "AngryEra_ShowDisplay",
   "AngryEra_HideDisplay",
   "AngryEra_PrevPage",
   "AngryEra_NextPage",
   "AngryEra_FirstPage",
   "AngryEra_PageMenu",
   "AngryEra_OutputDisplayed",
   "AngryEra_Window",
   "AngryEra_SetRaidTarget",
   "AngryEra_ClearAllRaidTargets",

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
