-- -------------------------------------------------------------------------------
-- Angry Era: modules/utils/roster.lua
--
-- Priority-assignment resolution against the live group roster.
-- A variable value of the form `Name > Name > Name` resolves to the first listed
-- member who is present and alive, so an assignment tracks whoever is available.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
AngryEra.utils = AngryEra.utils or {}
AngryEra.utils.roster = {}
local roster = AngryEra.utils.roster
local helpers = AngryEra.utils.helpers

local function IsNameLike(token)
    return type(token) == "string" and token:match("^%a[%w'%-]*$") ~= nil
end

-- Splits on ">" preserving empty segments so malformed lists are rejected.
-- Returns the trimmed name segments, or nil when the value is not a priority list.
local function SplitPriorityValue(value)
    if type(value) ~= "string" or not value:find(">", 1, true) then
        return nil
    end
    local segments = {}
    local startIndex = 1
    while true do
        local separator = value:find(">", startIndex, true)
        local piece = separator and value:sub(startIndex, separator - 1) or value:sub(startIndex)
        local trimmed = piece:match("^%s*(.-)%s*$")
        if not IsNameLike(trimmed) then
            return nil
        end
        segments[#segments + 1] = trimmed
        if not separator then
            break
        end
        startIndex = separator + 1
    end
    if #segments < 2 then
        return nil
    end
    return segments
end

--- Returns whether a named player is in the group, online, and alive.
-- Realm-aware: a qualified `Name-Realm` requires an exact match; an unqualified
-- name matches its own realm exactly, or a unique online-and-alive short name
-- across realms (ambiguous short names are rejected rather than guessed).
-- @tparam string name Player name, optionally realm-qualified.
-- @treturn boolean
function roster.IsPresentAndAlive(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    if
        type(helpers) ~= "table"
        or type(helpers.IterateGroupMembers) ~= "function"
        or type(helpers.EnsureUnitFullName) ~= "function"
    then
        return false
    end
    local qualified = name:find("-", 1, true) ~= nil
    local fullTarget = (helpers.EnsureUnitFullName(name) or ""):lower()
    local shortTarget = name:lower()
    local exact = false
    local shortMatches = 0
    helpers.IterateGroupMembers(function(_, fullName, _, _, _, online, isDead)
        if online == false or isDead == true then
            return false
        end
        local fullLower = type(fullName) == "string" and fullName:lower() or ""
        if fullLower ~= "" and fullLower == fullTarget then
            exact = true
        elseif not qualified then
            local short = fullLower:match("^([^-]+)")
            if short == shortTarget then
                shortMatches = shortMatches + 1
            end
        end
        return false
    end)
    if exact then
        return true
    end
    return not qualified and shortMatches == 1
end

--- Resolves a `Name > Name > Name` priority list to the first eligible member.
-- Non-priority values are returned unchanged. When no listed member is present
-- and alive, the first (primary) name is returned so the assignment still shows.
-- @tparam any value
-- @treturn any resolvedValue
-- @treturn boolean wasPriority Whether the value was a priority list.
function roster.ResolvePriorityValue(value)
    local segments = SplitPriorityValue(value)
    if not segments then
        return value, false
    end
    for _, candidate in ipairs(segments) do
        if roster.IsPresentAndAlive(candidate) then
            return candidate, true
        end
    end
    return segments[1], true
end

--- Rewrites every priority-list value in a resolved variable map in place.
-- @tparam table vars Resolved variable map (mutated).
-- @treturn boolean hadPriority Whether any value was a priority list.
function roster.ApplyPriorityAssignments(vars)
    if type(vars) ~= "table" then
        return false
    end
    local hadPriority = false
    for key, value in pairs(vars) do
        if type(value) == "string" then
            local resolved, wasPriority = roster.ResolvePriorityValue(value)
            if wasPriority then
                vars[key] = resolved
                hadPriority = true
            end
        end
    end
    return hadPriority
end
