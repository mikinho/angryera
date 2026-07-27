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

local ASSIGNED_ROLE_ORDER = {
    TANK = 1,
    HEALER = 2,
    DPS = 3,
}

local function EnumRoleValue(...)
    local enum = type(Enum) == "table" and Enum.LFGRole or nil
    if type(enum) ~= "table" then
        return nil
    end
    for index = 1, select("#", ...) do
        local value = enum[select(index, ...)]
        if value ~= nil then
            return value
        end
    end
end

local function NormalizeAssignedRole(value)
    if value == nil or value == "" then
        return nil, "none"
    end
    if type(value) == "string" then
        local normalized = value:upper()
        if normalized == "TANK" or normalized == "HEALER" then
            return normalized
        end
        if normalized == "DAMAGER" or normalized == "DPS" then
            return "DPS"
        end
        if normalized == "NONE" then
            return nil, "none"
        end
        return nil, "unsupported"
    end

    local tank = EnumRoleValue("Tank", "TANK")
    local healer = EnumRoleValue("Healer", "HEALER")
    local damage = EnumRoleValue("Damage", "Damager", "Dps", "DPS", "DAMAGER")
    local none = type(LFG_ROLE_NO_ROLE) == "number" and LFG_ROLE_NO_ROLE or -1
    if tank ~= nil and value == tank then
        return "TANK"
    end
    if healer ~= nil and value == healer then
        return "HEALER"
    end
    if damage ~= nil and value == damage then
        return "DPS"
    end
    if value == none then
        return nil, "none"
    end
    return nil, "unsupported"
end

local function ShortRosterName(rawName, fullName)
    local short = type(rawName) == "string" and rawName:match("^([^-]+)") or nil
    if type(short) ~= "string" or short == "" then
        short = type(fullName) == "string" and fullName:match("^([^-]+)") or nil
    end
    return short
end

--- Reads Blizzard's assigned tank, healer, and damage roles for the current
-- group without mutating role state. Every group member participates in short
-- name ambiguity detection, including unassigned, offline, and dead members.
-- Assigned results are sorted deterministically by role and canonical name.
-- @treturn table|nil rows `{ Name, RawName, FullName, Role, Online, IsDead, Unit }[]`
-- @treturn string|nil errorCode
function roster.ScanAssignedRoles()
    if type(helpers) ~= "table" or type(helpers.IterateGroupMembers) ~= "function" then
        return nil, "roster-unavailable"
    end
    local assignedRoleFunction = type(UnitGroupRolesAssigned) == "function" and UnitGroupRolesAssigned
        or (type(UnitGroupRolesAssignedEnum) == "function" and UnitGroupRolesAssignedEnum)
    if not assignedRoleFunction then
        return nil, "role-api-unavailable"
    end
    if type(IsInGroup) == "function" and not IsInGroup() and (type(IsInRaid) ~= "function" or not IsInRaid()) then
        return nil, "not-grouped"
    end

    local scanned = {}
    local shortCounts = {}
    local seenFullNames = {}
    local scanError
    local iterated = pcall(helpers.IterateGroupMembers, function(rawName, fullName, _, _, _, online, isDead, unitToken)
        if type(fullName) ~= "string" or fullName == "" then
            scanError = "invalid-roster-member"
            return true
        end
        if type(unitToken) ~= "string" or unitToken == "" then
            scanError = "invalid-roster-unit"
            return true
        end

        local fullKey = fullName:lower()
        if seenFullNames[fullKey] then
            return false
        end
        seenFullNames[fullKey] = true

        local shortName = ShortRosterName(rawName, fullName)
        if type(shortName) ~= "string" or shortName == "" then
            scanError = "invalid-roster-member"
            return true
        end
        local shortKey = shortName:lower()
        shortCounts[shortKey] = (shortCounts[shortKey] or 0) + 1

        local roleOk, assignedRole = pcall(assignedRoleFunction, unitToken)
        if not roleOk then
            scanError = "role-api-failed"
            return true
        end
        local role, roleStatus = NormalizeAssignedRole(assignedRole)
        if roleStatus == "unsupported" then
            scanError = "unsupported-role-value"
            return true
        end

        scanned[#scanned + 1] = {
            RawName = rawName,
            FullName = fullName,
            ShortName = shortName,
            ShortKey = shortKey,
            Role = role,
            Online = online ~= false,
            IsDead = isDead == true,
            Unit = unitToken,
        }
        return false
    end)
    if not iterated then
        return nil, "roster-unavailable"
    end
    if scanError then
        return nil, scanError
    end

    local rows = {}
    for _, entry in ipairs(scanned) do
        if entry.Role then
            rows[#rows + 1] = {
                Name = shortCounts[entry.ShortKey] == 1 and entry.ShortName or entry.FullName,
                RawName = entry.RawName,
                FullName = entry.FullName,
                Role = entry.Role,
                Online = entry.Online,
                IsDead = entry.IsDead,
                Unit = entry.Unit,
            }
        end
    end
    if #rows == 0 then
        return nil, "no-assigned-roles"
    end

    table.sort(rows, function(left, right)
        local leftOrder = ASSIGNED_ROLE_ORDER[left.Role]
        local rightOrder = ASSIGNED_ROLE_ORDER[right.Role]
        if leftOrder ~= rightOrder then
            return leftOrder < rightOrder
        end
        local leftName = left.FullName:lower()
        local rightName = right.FullName:lower()
        if leftName ~= rightName then
            return leftName < rightName
        end
        return left.FullName < right.FullName
    end)
    return rows
end

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
-- name requires one unique short-name match across the full current roster,
-- and that uniquely identified member must be online and alive.
-- Ambiguous short names are rejected rather than preferring the player's realm.
-- @tparam string name Player name, optionally realm-qualified.
-- @treturn string|nil fullName
-- @treturn string|nil reason
function roster.ResolvePresentAndAliveName(name)
    if type(name) ~= "string" or name == "" then
        return nil, "invalid-name"
    end
    if type(helpers) ~= "table" or type(helpers.IterateGroupMembers) ~= "function" then
        return nil, "roster-unavailable"
    end
    local qualified = name:find("-", 1, true) ~= nil
    local target = name:lower()
    local exactName
    local exactEligible = false
    local shortMatch
    local shortMatchEligible = false
    local shortMatches = 0
    helpers.IterateGroupMembers(function(_, fullName, _, _, _, online, isDead)
        local fullLower = type(fullName) == "string" and fullName:lower() or ""
        if qualified and fullLower ~= "" and fullLower == target then
            exactName = fullName
            exactEligible = online ~= false and isDead ~= true
            return true
        end
        if not qualified then
            local short = fullLower:match("^([^-]+)")
            if short == target then
                shortMatches = shortMatches + 1
                shortMatch = fullName
                shortMatchEligible = online ~= false and isDead ~= true
            end
        end
        return false
    end)
    if qualified and exactName and exactEligible then
        return exactName
    end
    if not qualified and shortMatches == 1 and shortMatchEligible then
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
