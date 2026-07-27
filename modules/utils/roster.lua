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
    if type(token) ~= "string" or token == "" then
        return false
    end

    -- Lua's %a/%w character classes are ASCII-only in the WoW client. Validate
    -- the ASCII bytes explicitly while allowing UTF-8 bytes through so otherwise
    -- valid accented, Cyrillic, and Asian character names can use priorities.
    local first = token:byte(1)
    if first < 128 and not (first >= 65 and first <= 90) and not (first >= 97 and first <= 122) then
        return false
    end
    for index = 2, #token do
        local byte = token:byte(index)
        if
            byte < 128
            and not (byte >= 65 and byte <= 90)
            and not (byte >= 97 and byte <= 122)
            and not (byte >= 48 and byte <= 57)
            and byte ~= 39
            and byte ~= 45
        then
            return false
        end
    end
    return true
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

--- Resolves a named player to the canonical full roster name when they are
-- online and alive.
-- Realm-aware: a qualified `Name-Realm` requires an exact match; an unqualified
-- name matches its own realm exactly, or a unique online-and-alive short name
-- across realms (ambiguous short names are rejected rather than guessed).
-- @tparam string name Player name, optionally realm-qualified.
-- @treturn string|nil fullName
-- @treturn string|nil reason
function roster.ResolvePresentAndAliveName(name)
    if type(name) ~= "string" or name == "" then
        return nil, "invalid-name"
    end
    if
        type(helpers) ~= "table"
        or type(helpers.IterateGroupMembers) ~= "function"
        or type(helpers.EnsureUnitFullName) ~= "function"
    then
        return nil, "roster-unavailable"
    end
    local qualified = name:find("-", 1, true) ~= nil
    local fullTarget = (helpers.EnsureUnitFullName(name) or ""):lower()
    local shortTarget = name:lower()
    local exactName
    local shortMatch
    local shortMatches = 0
    helpers.IterateGroupMembers(function(_, fullName, _, _, _, online, isDead)
        if online == false or isDead == true then
            return false
        end
        local fullLower = type(fullName) == "string" and fullName:lower() or ""
        if fullLower ~= "" and fullLower == fullTarget then
            exactName = fullName
        elseif not qualified then
            local short = fullLower:match("^([^-]+)")
            if short == shortTarget then
                shortMatches = shortMatches + 1
                shortMatch = fullName
            end
        end
        return false
    end)
    if exactName then
        return exactName
    end
    if not qualified and shortMatches == 1 then
        return shortMatch
    end
    return nil, not qualified and shortMatches > 1 and "ambiguous-name" or "not-present-or-alive"
end

--- Returns whether a named player is in the group, online, and alive.
-- @tparam string name Player name, optionally realm-qualified.
-- @treturn boolean
function roster.IsPresentAndAlive(name)
    return roster.ResolvePresentAndAliveName(name) ~= nil
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

--- Resolves a priority list to the eligible member's canonical full roster name.
-- Non-priority values are returned unchanged. When nobody is eligible, the
-- primary spelling is retained so display-only callers may still show it and a
-- destructive caller can decide whether that name is present in its full roster.
-- @tparam any value
-- @treturn any resolvedValue
-- @treturn boolean wasPriority
function roster.ResolvePriorityFullName(value)
    local segments = SplitPriorityValue(value)
    if not segments then
        return value, false
    end
    for _, candidate in ipairs(segments) do
        local fullName = roster.ResolvePresentAndAliveName(candidate)
        if fullName then
            return fullName, true
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
