std = "lua51"
max_line_length = false
codes = true
ranges = true

-- Explicitly whitelist the global variables that your addon creates 
-- and your SavedVariables from the .toc file.
globals = {
   "AngryAssign",
   "AngryAssign_Pages",
   "AngryAssign_Categories",
   "AngryAssign_State",
   "AngryAssign_Config",
   "AngryAssign_Templates",
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
   "631", -- line length is handled separately by project style checks
}
