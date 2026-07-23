-- -------------------------------------------------------------------------------
-- Angry Era: modules/smart_markers.lua
--
-- Target and mouseover raid-marker keybindings.
-- -------------------------------------------------------------------------------

local appName, app = ...
local AngryEra = app and app.AngryEra

local markerNames = {
    [1] = "Star",
    [2] = "Circle",
    [3] = "Diamond",
    [4] = "Triangle",
    [5] = "Moon",
    [6] = "Square",
    [7] = "X",
    [8] = "Skull",
}

_G["BINDING_HEADER_" .. appName .. "_SMART_MARKERS"] = "|cff0070DD" .. appName .. " | Smart Markers"
_G["BINDING_NAME_" .. appName .. "_CLEAR_ALL_RAID_TARGETS"] = "Clear All Raid Targets"

for index = 8, 1, -1 do
    local markerName = markerNames[index]
    _G["BINDING_NAME_" .. appName .. "_MARK_TARGET_" .. index] = "Assign " .. markerName .. " to Target"
    _G["BINDING_NAME_" .. appName .. "_MARK_MOUSEOVER_" .. index] = "Assign " .. markerName .. " to Mouseover"
end

function AngryEra_SetRaidTarget(unit, index)
    if GetRaidTargetIndex(unit) ~= index then
        SetRaidTarget(unit, index)
    end
end

function AngryEra_ClearAllRaidTargets()
    for index = 8, 0, -1 do
        SetRaidTarget("player", index)
    end
end

-- -------------------------
-- Metadata auto-markers
-- -------------------------

local AUTO_MARKER_INDEXES = {
    STAR = 1,
    CIRCLE = 2,
    DIAMOND = 3,
    TRIANGLE = 4,
    MOON = 5,
    SQUARE = 6,
    CROSS = 7,
    X = 7,
    SKULL = 8,
}

local AUTO_MARKER_ORDER = { "STAR", "CIRCLE", "DIAMOND", "TRIANGLE", "MOON", "SQUARE", "CROSS", "X", "SKULL" }

local function ResolveMarkerValue(value, vars, meta)
    if type(value) ~= "string" then
        return nil
    end
    local trimmed = value:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end

    local metaToken = trimmed:match("^%$([%w_]+)$")
    if metaToken then
        local resolved = type(meta) == "table" and meta[metaToken] or nil
        if type(resolved) == "string" and resolved ~= "" then
            return resolved
        end
        return nil
    end

    if trimmed:match("^[%w_]+$") then
        local resolved = type(vars) == "table" and vars[trimmed] or nil
        if type(resolved) == "string" and resolved ~= "" then
            return resolved
        end
    end
    return trimmed
end

local function FindRosterUnit(candidate)
    local helpers = AngryEra and AngryEra.utils and AngryEra.utils.helpers
    if not helpers or type(helpers.EnsureUnitFullName) ~= "function" then
        return nil
    end

    local qualified = candidate:find("-", 1, true) ~= nil
    local fullTarget = (helpers.EnsureUnitFullName(candidate) or ""):lower()
    local shortTarget = candidate:lower()

    local exactUnit
    local shortUnit
    local shortMatches = 0
    if type(helpers.IterateGroupMembers) == "function" then
        helpers.IterateGroupMembers(function(_, fullName, _, _, _, _, _, unitToken)
            local fullLower = type(fullName) == "string" and fullName:lower() or ""
            if fullLower ~= "" and fullLower == fullTarget then
                exactUnit = unitToken
                return true
            end
            if not qualified then
                local shortName = fullLower:match("^([^-]+)")
                if shortName == shortTarget then
                    shortMatches = shortMatches + 1
                    shortUnit = unitToken
                end
            end
            return false
        end)
    end

    if exactUnit then
        return exactUnit
    end
    if not qualified and shortMatches == 1 then
        return shortUnit
    end
    if type(helpers.PlayerFullName) == "function" then
        local playerName = helpers.PlayerFullName()
        if type(playerName) == "string" and playerName:lower() == fullTarget then
            return "player"
        end
    end
    return nil
end

local function CanAssignRaidMarkers()
    if IsInRaid() then
        if UnitIsGroupLeader("player") then
            return true
        end
        return (UnitIsGroupAssistant and UnitIsGroupAssistant("player")) == true
    end
    return true
end

--- Applies raid target markers named by displayed-note metadata.
-- Marker keys are matched case-insensitively ($STAR through $SKULL, with $X
-- and $CROSS both mapping to cross). A value resolves in order: `$name` reads
-- another metadata entry, a bare word prefers a template variable of that name,
-- and anything else is a player name. Names resolve realm-aware: exact
-- Name-Realm matches win, an unqualified name accepts a unique cross-realm
-- match, and ambiguous short names are skipped rather than guessed.
-- @tparam table meta Displayed-note metadata with `$` prefixes stripped.
-- @tparam[opt] table vars Resolved public template variables.
-- @treturn number applied Count of markers assigned.
function AngryEra_ApplyAutoMarkers(meta, vars)
    if type(meta) ~= "table" or not CanAssignRaidMarkers() then
        return 0
    end

    local valuesByMarker = {}
    local sortedKeys = {}
    for key in pairs(meta) do
        if type(key) == "string" then
            sortedKeys[#sortedKeys + 1] = key
        end
    end
    table.sort(sortedKeys)
    for _, key in ipairs(sortedKeys) do
        local canonical = key:upper()
        if AUTO_MARKER_INDEXES[canonical] and valuesByMarker[canonical] == nil then
            valuesByMarker[canonical] = meta[key]
        end
    end

    local applied = 0
    local assignedIndexes = {}
    for _, canonical in ipairs(AUTO_MARKER_ORDER) do
        local markerIndex = AUTO_MARKER_INDEXES[canonical]
        local value = valuesByMarker[canonical]
        if value ~= nil and not assignedIndexes[markerIndex] then
            local candidate = ResolveMarkerValue(value, vars, meta)
            local unitToken = candidate and FindRosterUnit(candidate)
            if unitToken then
                assignedIndexes[markerIndex] = true
                AngryEra_SetRaidTarget(unitToken, markerIndex)
                applied = applied + 1
            end
        end
    end
    return applied
end

if AngryEra then
    --- Applies auto-markers from the currently displayed note.
    -- Registered against ANGRYERA_NOTE_UPDATE so markers follow the display.
    -- @treturn number applied
    function AngryEra:ApplyDisplayedNoteMarkers()
        local meta = type(self.GetDisplayedMeta) == "function" and self:GetDisplayedMeta() or nil
        if type(meta) ~= "table" then
            return 0
        end
        local vars = type(self.GetDisplayedVars) == "function" and self:GetDisplayedVars() or nil
        return AngryEra_ApplyAutoMarkers(meta, vars)
    end
end
