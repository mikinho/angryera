-- -------------------------------------------------------------------------------
-- Angry Era: modules/debug.lua
--
-- Session-local synchronization tracing. Debug output is disabled by default
-- and never persists in SavedVariables.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra

local function PreciseMilliseconds()
    local clock
    if type(GetTimePreciseSec) == "function" then
        clock = GetTimePreciseSec
    elseif type(GetTime) == "function" then
        clock = GetTime
    end
    if not clock then
        return 0
    end

    local ok, value = pcall(clock)
    if not ok or type(value) ~= "number" or value < 0 then
        return 0
    end
    return math.floor(value * 1000)
end

--- Returns whether session-local synchronization tracing is enabled.
-- @treturn boolean enabled
function AngryEra:IsSyncDebugEnabled()
    return self._syncDebugEnabled == true
end

--- Enables or disables session-local synchronization tracing.
-- @tparam boolean enabled
-- @treturn boolean enabled
function AngryEra:SetSyncDebugEnabled(enabled)
    self._syncDebugEnabled = enabled == true
    if self._syncDebugEnabled then
        self:Print("Synchronization debug enabled for this login. Use /ae debug again to disable it.")
    else
        self:Print("Synchronization debug disabled.")
    end
    return self._syncDebugEnabled
end

--- Toggles session-local synchronization tracing.
-- @treturn boolean enabled
function AngryEra:ToggleSyncDebug()
    return self:SetSyncDebugEnabled(not self:IsSyncDebugEnabled())
end

--- Emits one compact synchronization trace line when debugging is enabled.
-- Page contents and variable values must never be passed to this logger.
-- @tparam string stage Stable trace stage.
-- @tparam[opt] string formatText `string.format` template for compact fields.
-- @param ... Template arguments.
-- @treturn boolean emitted
function AngryEra:SyncDebug(stage, formatText, ...)
    if not self:IsSyncDebugEnabled() then
        return false
    end

    local details = ""
    if type(formatText) == "string" and formatText ~= "" then
        local formatted, result = pcall(string.format, formatText, ...)
        if formatted then
            details = " " .. result
        else
            details = " format-error"
        end
    end
    self:Print(string.format("[sync %sms] %s%s", tostring(PreciseMilliseconds()), tostring(stage), details))
    return true
end

--- Handles `/ae debug`, `/ae debug on|off`, and `/ae debug status`.
-- @tparam[opt] string argument Normalized command argument.
-- @treturn boolean handled
function AngryEra:HandleSyncDebugCommand(argument)
    argument = type(argument) == "string" and argument or ""
    if argument == "" then
        self:ToggleSyncDebug()
    elseif argument == "on" then
        self:SetSyncDebugEnabled(true)
    elseif argument == "off" then
        self:SetSyncDebugEnabled(false)
    elseif argument == "status" then
        self:Print("Synchronization debug is " .. (self:IsSyncDebugEnabled() and "enabled." or "disabled."))
    else
        self:Print("Usage: /ae debug [on|off|status]")
    end
    return true
end
