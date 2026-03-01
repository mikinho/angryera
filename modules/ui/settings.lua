-- -------------------------------------------------------------------------------
-- Angry Era: modules/ui/settings.lua
--
-- Config accessors and orphaned state cleanup.
-- The AceConfig options table lives in init.lua (inside OnInitialize).
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra

local core = AngryEra.core
local configDefaults = core.configDefaults

--- Gets a config value with fallback to defaults.
-- @tparam string key Config key.
-- @treturn any value
function AngryEra:GetConfig(key)
	if AngryAssign_Config[key] == nil then
		return configDefaults[key]
	else
		return AngryAssign_Config[key]
	end
end

--- Sets a config value, storing `nil` for default-equivalent values.
-- @tparam string key Config key.
-- @tparam any value Config value.
function AngryEra:SetConfig(key, value)
	if configDefaults[key] == value then
		AngryAssign_Config[key] = nil
	else
		AngryAssign_Config[key] = value
	end
end

--- Restores all config options to defaults and refreshes display/media.
function AngryEra:RestoreDefaults()
	AngryAssign_Config = {}
	self:UpdateMedia()
	self:UpdateDisplayed()
	LibStub("AceConfigRegistry-3.0"):NotifyChange("AngryEra")
end

function AngryEra:CleanupOrphanedStates()
	if not AngryAssign_State or not AngryAssign_State.tree or not AngryAssign_State.tree.groups then
		return
	end

	local count = 0
	-- Iterate over the saved "expanded/collapsed" state of the tree
	for id, _ in pairs(AngryAssign_State.tree.groups) do
		-- FIX: Check that id is a number before comparing it
		if type(id) == "number" and id < 0 then
			-- Check if the category actually exists (flip ID back to positive)
			if not AngryAssign_Categories[-id] then
				AngryAssign_State.tree.groups[id] = nil
				count = count + 1
			end
		end
	end
end
