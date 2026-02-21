std = "lua51"
max_line_length = false
codes = true
ranges = true

-- Luacheck does not support enforcing:
-- 1) quote style (single vs double),
-- 2) indentation style (tabs vs spaces),
-- 3) single-line control statement formatting.
-- These are handled by formatter configuration (see `.stylua.toml`).

ignore = {
   "111", -- setting non-standard globals (WoW slash cmds/saved vars)
   "112", -- mutating non-standard globals
   "113", -- undefined globals (WoW API and addon framework globals)
   "212", -- unused callback arguments are common in UI/event handlers
   "631", -- line length is handled separately by project style checks
}
